// Тонкая обёртка над Google Drive REST API v3. Каждый запрос делается от имени
// конкретного аккаунта: разные папки могут быть доступны разным аккаунтам.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'auth.dart';

class DriveException implements Exception {
  final int status;
  final String message;
  DriveException(this.status, this.message);
  bool get notFound => status == 404;
  bool get forbidden => status == 403 && !insufficientScope;
  bool get insufficientScope => status == 403 && message.toLowerCase().contains('insufficient');
  @override
  String toString() => insufficientScope
      ? 'У Cave Player нет доступа к Google Диску: при входе не отметили галочку про Диск. Нажмите «Войти заново» и отметьте её.'
      : 'Google Диск ответил $status: $message';
}

class DriveFile {
  final String id;
  final String name;
  final String mimeType;
  final int size;
  final String modifiedTime;
  final String ownerEmail;
  final String ownerName;

  DriveFile.fromJson(Map j)
      : id = j['id'] as String,
        name = (j['name'] as String?) ?? '',
        mimeType = (j['mimeType'] as String?) ?? '',
        size = int.tryParse('${j['size'] ?? 0}') ?? 0,
        modifiedTime = (j['modifiedTime'] as String?) ?? '',
        ownerEmail = _person(j)['emailAddress'] ?? '',
        ownerName = _person(j)['displayName'] ?? '';

  bool get isFolder => mimeType == 'application/vnd.google-apps.folder';

  // В общих дисках (Shared drives) владельца нет — берём того, кто последним менял файл
  static Map<String, String> _person(Map j) {
    final owners = j['owners'];
    if (owners is List && owners.isNotEmpty && owners.first is Map) {
      return (owners.first as Map).map((k, v) => MapEntry('$k', '$v'));
    }
    final last = j['lastModifyingUser'];
    if (last is Map) return last.map((k, v) => MapEntry('$k', '$v'));
    return const {};
  }

  static const fields = 'id,name,mimeType,size,modifiedTime,owners(emailAddress,displayName),lastModifyingUser(emailAddress,displayName)';
}

/// Достаёт ID папки или файла из ссылки Google Диска (или возвращает строку как есть).
String? parseDriveId(String input) {
  final s = input.trim();
  if (s.isEmpty) return null;
  final m = RegExp(r'/(?:folders|d)/([A-Za-z0-9_-]{10,})').firstMatch(s) ?? RegExp(r'[?&]id=([A-Za-z0-9_-]{10,})').firstMatch(s);
  if (m != null) return m.group(1);
  if (RegExp(r'^[A-Za-z0-9_-]{10,}$').hasMatch(s)) return s;
  return null;
}

String folderUrl(String id) => 'https://drive.google.com/drive/folders/$id';

class DriveApi {
  final AccountManager accounts;
  final http.Client _http = http.Client();

  DriveApi(this.accounts);

  static Uri api(String path, [Map<String, String>? q]) =>
      Uri.https('www.googleapis.com', '/drive/v3/$path', {'supportsAllDrives': 'true', ...?q});

  static Uri upload(String path, [Map<String, String>? q]) =>
      Uri.https('www.googleapis.com', '/upload/drive/v3/$path', {'supportsAllDrives': 'true', ...?q});

  /// Прямая ссылка на содержимое файла (для плеера, с заголовком Authorization)
  static Uri mediaUrl(String fileId) => api('files/$fileId', {'alt': 'media'});

  Future<http.Response> send(
    String email,
    String method,
    Uri uri, {
    Map<String, String>? headers,
    List<int>? body,
  }) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      final token = await accounts.token(email, force: attempt == 1);
      final req = http.Request(method, uri)..headers['Authorization'] = 'Bearer $token';
      if (headers != null) req.headers.addAll(headers);
      if (body != null) req.bodyBytes = body;
      final res = await http.Response.fromStream(await _http.send(req));
      if (res.statusCode == 401 && attempt == 0) continue;
      // 429 / 5xx — Google просит подождать
      if ((res.statusCode == 429 || res.statusCode >= 500) && attempt < 2) {
        await Future<void>.delayed(Duration(milliseconds: 600 * (attempt + 1) + Random().nextInt(400)));
        continue;
      }
      if (res.statusCode >= 400) throw DriveException(res.statusCode, _errorText(res));
      return res;
    }
    throw DriveException(401, 'нет доступа');
  }

  static String _errorText(http.Response res) {
    try {
      final j = jsonDecode(res.body);
      return '${j['error']['message']}';
    } catch (_) {
      return res.reasonPhrase ?? 'ошибка';
    }
  }

  Future<Map<String, dynamic>> getFile(String email, String id, {String fields = 'id,name,mimeType,modifiedTime'}) async {
    final res = await send(email, 'GET', api('files/$id', {'fields': fields}));
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<List<DriveFile>> listChildren(String email, String folderId, {String? nameEquals}) async {
    final out = <DriveFile>[];
    String? page;
    var q = "'$folderId' in parents and trashed = false";
    if (nameEquals != null) q += " and name = '${nameEquals.replaceAll("'", r"\'")}'";
    do {
      final res = await send(
        email,
        'GET',
        api('files', {
          'q': q,
          'fields': 'nextPageToken,files(${DriveFile.fields})',
          'pageSize': '1000',
          'includeItemsFromAllDrives': 'true',
          if (page != null) 'pageToken': page,
        }),
      );
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      for (final f in (j['files'] as List? ?? const [])) {
        out.add(DriveFile.fromJson(f as Map));
      }
      page = j['nextPageToken'] as String?;
    } while (page != null);
    return out;
  }

  Future<Uint8List> readRange(String email, String id, int start, int endInclusive) async {
    final res = await send(email, 'GET', mediaUrl(id), headers: {'Range': 'bytes=$start-$endInclusive'});
    return res.bodyBytes;
  }

  Future<Uint8List> download(String email, String id) async {
    final res = await send(email, 'GET', mediaUrl(id));
    return res.bodyBytes;
  }

  Future<String> createFolder(String email, String name, {String? parent}) async {
    final meta = {
      'name': name,
      'mimeType': 'application/vnd.google-apps.folder',
      if (parent != null) 'parents': [parent],
    };
    final res = await send(email, 'POST', api('files', {'fields': 'id'}),
        headers: {'Content-Type': 'application/json; charset=utf-8'}, body: utf8.encode(jsonEncode(meta)));
    return (jsonDecode(res.body) as Map)['id'] as String;
  }

  /// Создаёт текстовый файл в папке. Возвращает {id, modifiedTime}.
  Future<Map<String, dynamic>> createFile(String email, String parent, String name, String content,
      {String mime = 'application/json'}) async {
    const boundary = 'cave-player-boundary-7f3a9c';
    final meta = jsonEncode({'name': name, 'parents': [parent], 'mimeType': mime});
    final body = '--$boundary\r\n'
        'Content-Type: application/json; charset=UTF-8\r\n\r\n'
        '$meta\r\n'
        '--$boundary\r\n'
        'Content-Type: $mime; charset=UTF-8\r\n\r\n'
        '$content\r\n'
        '--$boundary--';
    final res = await send(
      email,
      'POST',
      upload('files', {'uploadType': 'multipart', 'fields': 'id,modifiedTime'}),
      headers: {'Content-Type': 'multipart/related; boundary=$boundary'},
      body: utf8.encode(body),
    );
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  /// Перезаписывает содержимое файла. Возвращает новый modifiedTime.
  Future<String> updateFile(String email, String id, String content, {String mime = 'application/json'}) async {
    final res = await send(
      email,
      'PATCH',
      upload('files/$id', {'uploadType': 'media', 'fields': 'id,modifiedTime'}),
      headers: {'Content-Type': '$mime; charset=utf-8'},
      body: utf8.encode(content),
    );
    return ((jsonDecode(res.body) as Map)['modifiedTime'] as String?) ?? '';
  }
}
