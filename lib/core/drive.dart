// Тонкая обёртка над Google Drive REST API v3. Каждый запрос делается от имени
// конкретного аккаунта: разные папки могут быть доступны разным аккаунтам.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
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
      ? 'У Cavey нет доступа к Google Диску: при входе не отметили галочку про Диск. Нажмите «Войти заново» и отметьте её.'
      : 'Google Диск ответил $status: $message';
}

class DriveFile {
  final String id;
  final String name;
  final String mimeType;
  final int size;
  final String md5; // контрольная сумма файла (у файлов Google-документов её нет)
  final String modifiedTime;
  final String createdTime;
  final String ownerEmail;
  final String ownerName;

  /// Публичные свойства файла. Брокер загрузки пишет туда cave_uploader, cave_uploaded_at, cave_source, cave_upload_id
  final Map<String, String> properties;

  DriveFile.fromJson(Map j)
      : id = j['id'] as String,
        name = (j['name'] as String?) ?? '',
        mimeType = (j['mimeType'] as String?) ?? '',
        size = int.tryParse('${j['size'] ?? 0}') ?? 0,
        md5 = (j['md5Checksum'] as String?) ?? '',
        modifiedTime = (j['modifiedTime'] as String?) ?? '',
        createdTime = (j['createdTime'] as String?) ?? '',
        ownerEmail = _person(j)['emailAddress'] ?? '',
        ownerName = _person(j)['displayName'] ?? '',
        properties = _props(j['properties']);

  static Map<String, String> _props(Object? raw) =>
      raw is Map ? {for (final e in raw.entries) '${e.key}': '${e.value}'} : const {};

  /// Кто загрузил файл. У файлов, загруженных через брокер, это проверенная почта из свойства cave_uploader
  /// (владелец на Диске у них один и тот же — аккаунт с подпиской). У старых файлов свойства нет —
  /// тогда загрузил тот, кто ими владеет на Диске.
  String get uploaderEmail {
    final p = (properties[uploaderKey] ?? '').trim().toLowerCase();
    return p.isNotEmpty ? p : ownerEmail;
  }

  /// Загружен через брокер (есть свойство cave_uploader), а не старым способом
  bool get viaBroker => (properties[uploaderKey] ?? '').trim().isNotEmpty;

  /// Откуда трек: deezer, soulseek, youtube, bandcamp или manual; у старых файлов пусто
  String get uploadSource => properties['cave_source'] ?? '';

  /// Когда загружен (по часам брокера); у старых файлов — время создания на Диске
  String get uploadedAt => (properties['cave_uploaded_at'] ?? '').isNotEmpty ? properties['cave_uploaded_at']! : createdTime;

  static const uploaderKey = 'cave_uploader';

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

  static const fields = 'id,name,mimeType,size,md5Checksum,modifiedTime,createdTime,owners(emailAddress,displayName),lastModifyingUser(emailAddress,displayName),properties';
}

/// A bounded account-level Drive change feed. Changes are filtered against
/// the known subtree; unknown resource shapes always request a full scan.
class DriveChanges {
  final String nextCursor;
  final Set<String> ids;
  final Set<String> parents;
  final bool unknown;

  const DriveChanges(this.nextCursor, this.ids, this.parents, {this.unknown = false});

  bool affects(Set<String> fileIds, Set<String> folderIds) =>
      unknown ||
      ids.any((id) => fileIds.contains(id) || folderIds.contains(id)) ||
      parents.any(folderIds.contains);
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
  final http.Client _http;

  DriveApi(this.accounts, {http.Client? client}) : _http = client ?? http.Client();

  /// GET is safe to retry after an abrupt close before HTTP headers arrive.
  /// Mutating requests must never be repeated after an ambiguous connection loss.
  static bool isRetryableReadFailure(Object error) =>
      error is http.ClientException || error is SocketException ||
      error is HttpException || error is TimeoutException;

  static Duration retryDelay(int attempt, {int? retryAfterSeconds}) {
    if (retryAfterSeconds != null && retryAfterSeconds >= 0) {
      return Duration(seconds: min(retryAfterSeconds, 30));
    }
    final base = min(500 * (1 << attempt), 6000);
    return Duration(milliseconds: base + Random().nextInt(350));
  }

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
    final reading = method == 'GET';
    final maxAttempts = reading ? 5 : 3;
    var refreshToken = false;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      final token = await accounts.token(email, force: refreshToken);
      refreshToken = false;
      final req = http.Request(method, uri)..headers['Authorization'] = 'Bearer $token';
      if (headers != null) req.headers.addAll(headers);
      if (body != null) req.bodyBytes = body;
      final http.Response res;
      try {
        res = await http.Response.fromStream(
          await _http.send(req).timeout(const Duration(seconds: 30)),
        ).timeout(const Duration(seconds: 60));
      } catch (e) {
        if (reading && isRetryableReadFailure(e) && attempt + 1 < maxAttempts) {
          await Future<void>.delayed(retryDelay(attempt));
          continue;
        }
        if (e is TimeoutException) {
          throw DriveException(408, 'Google Диск не ответил вовремя');
        }
        if (isRetryableReadFailure(e)) {
          throw DriveException(503,
              'Google Диск разорвал соединение. Повторные попытки исчерпаны: $e');
        }
        rethrow;
      }
      if (res.statusCode == 401 && attempt == 0) {
        refreshToken = true; // do not refresh on every transient network retry
        continue;
      }
      if ((res.statusCode == 429 || res.statusCode >= 500) &&
          attempt + 1 < maxAttempts) {
        final retryAfter = int.tryParse(res.headers['retry-after'] ?? '');
        await Future<void>.delayed(retryDelay(attempt, retryAfterSeconds: retryAfter));
        continue;
      }
      if (res.statusCode >= 400) throw DriveException(res.statusCode, _errorText(res));
      return res;
    }
    throw DriveException(503, 'Google Диск не ответил после повторных попыток');
  }

  static String _errorText(http.Response res) {
    try {
      final j = jsonDecode(res.body);
      return '${j['error']['message']}';
    } catch (_) {
      return res.reasonPhrase ?? 'ошибка';
    }
  }

  /// Сколько места на Google Диске занято у аккаунта и сколько всего (limit пуст, если лимита нет)
  Future<StorageQuota> storageQuota(String email) async {
    final res = await send(email, 'GET', api('about', {'fields': 'storageQuota'}));
    final q = (jsonDecode(res.body) as Map)['storageQuota'] as Map? ?? const {};
    return StorageQuota(int.tryParse('${q['usage'] ?? 0}') ?? 0, int.tryParse('${q['limit'] ?? ''}'));
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

  /// Capture this BEFORE scanning. Changes arriving during the full walk are
  /// then seen on the next scan rather than accidentally lost.
  Future<String> startPageToken(String email) async {
    final res = await send(email, 'GET', api('changes/startPageToken'));
    return (jsonDecode(res.body) as Map)['startPageToken'] as String;
  }

  Future<DriveChanges> changesSince(String email, String cursor) async {
    final ids = <String>{};
    final parents = <String>{};
    var unknown = false;
    var page = cursor;
    for (var i = 0; i < 20; i++) {
      final res = await send(email, 'GET', api('changes', {
        'pageToken': page,
        'pageSize': '1000',
        'includeRemoved': 'true',
        'includeItemsFromAllDrives': 'true',
        'fields': 'nextPageToken,newStartPageToken,changes(fileId,removed,file(id,parents,mimeType,trashed))',
      }));
      final body = jsonDecode(res.body) as Map;
      for (final item in (body['changes'] as List? ?? const [])) {
        if (item is! Map) {
          unknown = true;
          continue;
        }
        final id = item['fileId'];
        if (id is String && id.isNotEmpty) {
          ids.add(id);
        } else {
          unknown = true;
        }
        final file = item['file'];
        if (file is Map) {
          final p = file['parents'];
          if (p is List) {
            for (final v in p) {
              if (v is String) parents.add(v);
            }
          } else if (item['removed'] != true) {
            unknown = true;
          }
        } else if (item['removed'] != true) {
          unknown = true;
        }
      }
      final next = body['nextPageToken'] as String?;
      if (next == null) {
        final newCursor = body['newStartPageToken'] as String?;
        if (newCursor == null || newCursor.isEmpty) {
          throw const FormatException('Drive changes: missing newStartPageToken');
        }
        return DriveChanges(newCursor, ids, parents, unknown: unknown);
      }
      if (next == page) throw const FormatException('Drive changes: repeated cursor');
      page = next;
    }
    throw const FormatException('Drive changes: too many pages; full rescan required');
  }

  Future<Uint8List> readRange(String email, String id, int start, int endInclusive) async {
    final res = await send(email, 'GET', mediaUrl(id), headers: {'Range': 'bytes=$start-$endInclusive'});
    return res.bodyBytes;
  }

  /// Persist interrupted downloads only for the same source revision.
  Future<void> downloadToFile(
    String email, String id, File target, {
    String? expectedModified,
    void Function(int got, int total)? onProgress,
  }) async {
    final part = File('${target.path}.part');
    final marker = File('${target.path}.part.version');
    final revision = expectedModified ?? '';
    final savedRevision = await marker.exists() ? await marker.readAsString() : '';
    if (revision.isEmpty || savedRevision != revision) {
      if (await part.exists()) await part.delete();
      if (await marker.exists()) await marker.delete();
    }
    if (revision.isNotEmpty && !await marker.exists()) {
      await marker.writeAsString(revision, flush: true);
    }
    Object? lastError;
    for (var attempt = 0; attempt < 5; attempt++) {
      var offset = await part.exists() ? await part.length() : 0;
      final token = await accounts.token(email);
      final req = http.Request('GET', mediaUrl(id))
        ..headers['Authorization'] = 'Bearer $token';
      if (offset > 0) req.headers['Range'] = 'bytes=$offset-';
      try {
        final res = await _http.send(req).timeout(const Duration(seconds: 30));
        if (res.statusCode == 416 && offset > 0) {
          await res.stream.drain<void>();
          await part.delete();
          if (attempt < 4) continue;
          throw DriveException(416, 'Изменился размер файла при скачивании');
        }
        if (res.statusCode == 401 && attempt == 0) {
          await res.stream.drain<void>();
          await accounts.token(email, force: true);
          continue;
        }
        if (res.statusCode == 429 || res.statusCode >= 500) {
          await res.stream.drain<void>();
          if (attempt < 4) {
            await Future<void>.delayed(retryDelay(attempt));
            continue;
          }
          throw DriveException(res.statusCode, 'Google Диск временно недоступен');
        }
        if (res.statusCode >= 400) {
          final body = await http.Response.fromStream(res);
          throw DriveException(res.statusCode, _errorText(body));
        }
        if (res.statusCode != 200 && res.statusCode != 206) {
          await res.stream.drain<void>();
          throw DriveException(res.statusCode, 'Неожиданный ответ на скачивание');
        }
        var total = res.contentLength ?? 0;
        if (res.statusCode == 206) {
          final match = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$')
              .firstMatch(res.headers['content-range'] ?? '');
          final first = match == null ? null : int.tryParse(match.group(1)!);
          final last = match == null ? null : int.tryParse(match.group(2)!);
          final entire = match == null ? null : int.tryParse(match.group(3)!);
          if (first != offset || last == null || entire == null ||
              last < first! || last >= entire) {
            await res.stream.drain<void>();
            throw DriveException(502, 'Google Диск вернул неверный Content-Range');
          }
          total = entire;
        } else if (offset > 0) {
          // A full HTTP 200 response must replace, not append to, a partial.
          offset = 0;
        }
        final sink = part.openWrite(mode: offset == 0 ? FileMode.write : FileMode.append);
        var got = offset;
        var transferred = 0;
        try {
          await for (final chunk in res.stream.timeout(const Duration(seconds: 30))) {
            sink.add(chunk);
            got += chunk.length;
            transferred += chunk.length;
            onProgress?.call(got, total);
          }
        } finally {
          await sink.close();
        }
        final promised = res.contentLength;
        if ((promised != null && transferred != promised) ||
            (total > 0 && got != total)) {
          throw DriveException(503, 'Скачивание прервано: $got из $total байт');
        }
        if (await target.exists()) await target.delete();
        await part.rename(target.path);
        if (await marker.exists()) await marker.delete();
        return;
      } on DriveException catch (e) {
        lastError = e;
        if (!(e.status == 408 || e.status == 429 || e.status >= 500) ||
            attempt == 4) rethrow;
      } catch (e) {
        lastError = e;
        if (!isRetryableReadFailure(e) || attempt == 4) rethrow;
      }
      await Future<void>.delayed(retryDelay(attempt));
    }
    throw DriveException(503, 'Не удалось докачать файл: $lastError');
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

  /// Загружает файл с компьютера в папку на Диске (возобновляемая загрузка, подходит для больших файлов)
  Future<DriveFile> uploadFile(String email, String parent, File file, {void Function(double progress)? onProgress}) async {
    final name = file.uri.pathSegments.where((s) => s.isNotEmpty).last;
    final length = await file.length();
    final start = await send(
      email,
      'POST',
      upload('files', {'uploadType': 'resumable', 'fields': DriveFile.fields}),
      headers: {
        'Content-Type': 'application/json; charset=UTF-8',
        'X-Upload-Content-Length': '$length',
      },
      body: utf8.encode(jsonEncode({'name': name, 'parents': [parent]})),
    );
    final location = start.headers['location'];
    if (location == null) throw DriveException(500, 'Диск не дал адрес для загрузки');
    final token = await accounts.token(email);
    final req = http.StreamedRequest('PUT', Uri.parse(location))
      ..headers['Authorization'] = 'Bearer $token'
      ..contentLength = length;
    final response = _http.send(req);
    var sent = 0;
    await for (final chunk in file.openRead()) {
      req.sink.add(chunk);
      sent += chunk.length;
      if (length > 0) onProgress?.call(sent / length);
    }
    req.sink.close();
    final res = await http.Response.fromStream(await response);
    if (res.statusCode != 200 && res.statusCode != 201) throw DriveException(res.statusCode, _errorText(res));
    return DriveFile.fromJson(jsonDecode(res.body) as Map);
  }

  /// Resumable upload chunks must be divisible by 256 KiB (except the last).
  static const int mediaChunkBytes = 4 * 1024 * 1024; // reduce HTTP round-trips for replacement uploads
  static const Duration mediaChunkTimeout = Duration(seconds: 90);

  /// Convert the HTTP 308 Range acknowledgement into the next byte offset.
  /// An absent Range means Google has not committed any bytes yet.
  static int resumableOffset(String? range, int totalBytes) {
    if (range == null) return 0;
    final match = RegExp(r'^bytes=0-(\d+)$').firstMatch(range.trim());
    if (match == null) throw DriveException(502, 'Google Drive вернул некорректный Range при загрузке');
    final last = int.tryParse(match.group(1)!);
    if (last == null || last < 0 || last >= totalBytes) {
      throw DriveException(502, 'Google Drive подтвердил неверный размер загруженной части');
    }
    return last + 1;
  }

  /// A dedicated client allows a timed-out request to be cancelled without
  /// affecting playback and other Google Drive operations.
  Future<http.Response> _sendMediaChunk(http.Request req) async {
    final client = http.Client();
    try {
      Future<http.Response> perform() async {
        final stream = await client.send(req);
        return await http.Response.fromStream(stream);
      }
      return await perform().timeout(mediaChunkTimeout);
    } on TimeoutException {
      throw DriveException(408, 'Google Drive не ответил на часть файла за 90 секунд');
    } finally {
      client.close();
    }
  }

  /// Replace audio without changing the file ID. Confirm each chunk with
  /// Google Drive; after a lost response probe the session before retrying.
  Future<DriveFile> replaceFileMedia(String email, String id, File file,
      {required String mime, void Function(double progress)? onProgress,
       void Function(String status)? onStatus}) async {
    final length = await file.length();
    if (length < 1024) throw DriveException(0, 'Файл для замены пустой');
    onStatus?.call('Google Drive: создаю сессию замены');
    final start = await send(
      email, 'PATCH',
      upload('files/$id', {'uploadType': 'resumable', 'fields': DriveFile.fields}),
      headers: {
        'Content-Type': 'application/json; charset=UTF-8',
        'X-Upload-Content-Type': mime,
        'X-Upload-Content-Length': '$length',
      },
      body: utf8.encode('{}'),
    );
    final location = start.headers['location'];
    if (location == null) throw DriveException(500, 'Диск не создал сессию замены');
    return uploadToSession(Uri.parse(location), file,
        mime: mime, authEmail: email, onProgress: onProgress, onStatus: onStatus);
  }

  /// Передаёт файл по готовому адресу сессии возобновляемой загрузки, частями по [mediaChunkBytes].
  /// Если связь оборвалась, спрашивает у Google, сколько байт уже принято, и продолжает с этого места.
  ///
  /// [authEmail] — чьим токеном подписывать запросы. Для сессии, которую открыл брокер, он не нужен:
  /// адрес сессии сам служит ключом, а токен друга к чужой сессии не относится.
  Future<DriveFile> uploadToSession(Uri uri, File file,
      {required String mime, String? authEmail, void Function(double progress)? onProgress,
       void Function(String status)? onStatus}) async {
    final length = await file.length();
    if (uri.scheme != 'https' || uri.host != 'www.googleapis.com') {
      throw DriveException(500, 'Небезопасный адрес сессии Google Диска');
    }
    onStatus?.call('Google Drive: передаю файл по частям');
    onProgress?.call(0);

    Future<Map<String, String>> auth() async =>
        authEmail == null ? const {} : {'Authorization': 'Bearer ${await accounts.token(authEmail)}'};

    var offset = 0;
    var failures = 0;
    final reader = await file.open();
    try {
      Future<http.Response> queryStatus() async {
        final req = http.Request('PUT', uri)
          ..followRedirects = false
          ..headers.addAll(await auth())
          ..headers['Content-Range'] = 'bytes */$length'
          ..headers['Content-Type'] = mime;
        return _sendMediaChunk(req);
      }

      /// Ask Google which bytes it already has before retrying a lost chunk.
      Future<DriveFile?> recover() async {
        failures++;
        if (failures > 3) {
          throw DriveException(408, 'Google Drive не отвечает: три попытки возобновления не удались');
        }
        onStatus?.call('Google Drive: соединение прервалось, восстанавливаю (${failures}/3)');
        await Future<void>.delayed(Duration(seconds: failures));
        try {
          final status = await queryStatus();
          if (status.statusCode == 200 || status.statusCode == 201) {
            onProgress?.call(1);
            return DriveFile.fromJson(jsonDecode(status.body) as Map);
          }
          if (status.statusCode == 308) {
            final confirmed = resumableOffset(status.headers['range'], length);
            if (confirmed > offset) failures = 0;
            offset = confirmed;
            onProgress?.call(offset / length);
          } else if (status.statusCode == 404 || status.statusCode == 410) {
            throw DriveException(status.statusCode, 'Сессия загрузки истекла; повторите');
          } else if (status.statusCode == 401 && authEmail != null) {
            await accounts.token(authEmail, force: true);
          }
        } on DriveException catch (e) {
          if (e.status == 404 || e.status == 410 || e.status == 502) rethrow;
        } catch (_) {
          // If the status probe also fails, retry after the next backoff.
        }
        return null;
      }

      while (offset < length) {
        final end = min(offset + mediaChunkBytes, length);
        await reader.setPosition(offset);
        final chunk = await reader.read(end - offset);
        if (chunk.length != end - offset) {
          throw DriveException(0, 'Не удалось прочитать часть подготовленного файла');
        }
        final req = http.Request('PUT', uri)
          ..followRedirects = false
          ..headers.addAll(await auth())
          ..headers['Content-Type'] = mime
          ..headers['Content-Range'] = 'bytes $offset-${end - 1}/$length'
          ..bodyBytes = chunk;
        http.Response response;
        try {
          response = await _sendMediaChunk(req);
        } catch (_) {
          final finished = await recover();
          if (finished != null) return finished;
          continue;
        }
        if (response.statusCode == 200 || response.statusCode == 201) {
          onProgress?.call(1);
          onStatus?.call('Google Drive: файл сохранён');
          return DriveFile.fromJson(jsonDecode(response.body) as Map);
        }
        if (response.statusCode == 308) {
          final confirmed = resumableOffset(response.headers['range'], length);
          if (confirmed <= offset) {
            final finished = await recover();
            if (finished != null) return finished;
            continue;
          }
          offset = confirmed;
          failures = 0;
          onProgress?.call(offset / length);
          continue;
        }
        if (response.statusCode == 401 && authEmail != null) {
          await accounts.token(authEmail, force: true);
        }
        if (response.statusCode == 401 || response.statusCode == 408 ||
            response.statusCode == 429 || response.statusCode >= 500) {
          final finished = await recover();
          if (finished != null) return finished;
          continue;
        }
        throw DriveException(response.statusCode, _errorText(response));
      }

      // An HTTP 308 after the last chunk is unusual. Do not assume success.
      final finalStatus = await queryStatus();
      if (finalStatus.statusCode == 200 || finalStatus.statusCode == 201) {
        onProgress?.call(1);
        onStatus?.call('Google Drive: файл сохранён');
        return DriveFile.fromJson(jsonDecode(finalStatus.body) as Map);
      }
      throw DriveException(finalStatus.statusCode,
          'Google Drive не подтвердил завершение загрузки файла');
    } finally {
      await reader.close();
    }
  }

  /// Удаляет файл с Диска безвозвратно (может только владелец). Для музыки не используется: там [trash]
  Future<void> deleteFile(String email, String id) async {
    await send(email, 'DELETE', api('files/$id'));
  }

  /// Перемещает файл в корзину Диска
  Future<void> trash(String email, String id) async {
    await send(email, 'PATCH', api('files/$id'),
        headers: {'Content-Type': 'application/json; charset=utf-8'}, body: utf8.encode(jsonEncode({'trashed': true})));
  }

  /// Файлы library.json, которые видит аккаунт (свои и расшаренные), новые первыми
  Future<List<Map<String, dynamic>>> findLibraries(String email) async {
    final res = await send(
      email,
      'GET',
      api('files', {
        'q': "name = 'library.json' and trashed = false",
        'fields': 'files(id,parents,modifiedTime,size)',
        'orderBy': 'modifiedTime desc',
        'pageSize': '20',
        'corpora': 'allDrives',
        'includeItemsFromAllDrives': 'true',
      }),
    );
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    return [for (final f in (j['files'] as List? ?? const [])) (f as Map).cast<String, dynamic>()];
  }

  /// Первый шаг передачи владения: назначает [newOwner] «ожидающим владельцем» файла. Вызывается от имени нынешнего владельца.
  /// Письмо Google при этом не отправляется; сам перенос завершает принятие владения (в Cavey — через брокера)
  Future<void> offerOwnership(String email, String fileId, String newOwner) async {
    await send(
      email,
      'POST',
      api('files/$fileId/permissions', {'sendNotificationEmail': 'false'}),
      headers: {'Content-Type': 'application/json; charset=utf-8'},
      body: utf8.encode(jsonEncode({'role': 'writer', 'type': 'user', 'emailAddress': newOwner, 'pendingOwner': true})),
    );
  }

  /// Даёт другому человеку доступ к файлу или папке. Google сам пришлёт ему письмо.
  Future<void> share(String email, String fileId, String withEmail, {String role = 'writer', String? message}) async {
    await send(
      email,
      'POST',
      api('files/$fileId/permissions', {
        'sendNotificationEmail': 'true',
        if (message != null) 'emailMessage': message,
      }),
      headers: {'Content-Type': 'application/json; charset=utf-8'},
      body: utf8.encode(jsonEncode({'role': role, 'type': 'user', 'emailAddress': withEmail})),
    );
  }

  /// Drive's version increases for every remote mutation, even when timestamps
  /// would otherwise look equal. Return the version of THIS successful write.
  Future<(String, String?)> updateFileWithVersion(
      String email, String id, String content, {String mime = 'application/json'}) async {
    final res = await send(
      email,
      'PATCH',
      upload('files/$id', {'uploadType': 'media', 'fields': 'id,modifiedTime,version'}),
      headers: {'Content-Type': '$mime; charset=utf-8'},
      body: utf8.encode(content),
    );
    final body = jsonDecode(res.body) as Map;
    return ((body['modifiedTime'] as String?) ?? '', body['version']?.toString());
  }

  /// Existing callers that only need the timestamp retain their interface.
  Future<String> updateFile(String email, String id, String content, {String mime = 'application/json'}) async {
    final saved = await updateFileWithVersion(email, id, content, mime: mime);
    return saved.$1;
  }
}

class StorageQuota {
  final int used;
  final int? limit;
  const StorageQuota(this.used, this.limit);
}
