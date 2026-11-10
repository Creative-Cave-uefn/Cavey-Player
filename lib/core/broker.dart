// Клиент брокера загрузки (Google Apps Script, см. tools/broker).
//
// Файл, загруженный в общую папку, занимает место того, кто его создал. Чтобы место не тратилось у друзей,
// сессию загрузки открывает брокер от имени владельца библиотеки, а байты уходят прямо в Google по адресу сессии.
// Кто загрузил файл, брокер записывает в свойство файла cave_uploader (почта берётся из проверенного токена).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'auth.dart';
import 'drive.dart';

/// Ошибка брокера. [code] — машинный код из ответа брокера или одно из наших:
/// unavailable (не достучались), outdated (приложение слишком старое), no_broker (адрес брокера не задан).
class BrokerException implements Exception {
  final String code;
  final String message;
  const BrokerException(this.code, this.message);

  /// Временная причина: файл стоит оставить в очереди «Ожидают загрузки» и повторить позже
  bool get deferrable => const {'unavailable', 'owner_full', 'rate_limited', 'internal', 'no_broker'}.contains(code);

  /// Повторять сразу, несколько раз подряд, имеет смысл
  bool get quickRetry => const {'unavailable', 'rate_limited', 'internal'}.contains(code);

  @override
  String toString() => message;

  /// Понятное объяснение для человека
  static String friendly(String code, String fallback) {
    switch (code) {
      case 'owner_full':
        return 'На диске владельца библиотеки закончилось место. Файл ждёт в очереди — сообщите владельцу.';
      case 'unavailable':
        return 'Сервис загрузки сейчас недоступен. Файл ждёт в очереди и будет загружен позже.';
      case 'not_member':
        return 'Вы не участник библиотеки Cave Player: попросите владельца открыть вам доступ к папке.';
      case 'no_broker':
        return 'Сервис загрузки не настроен: в cave-data нет config.json с адресом брокера.';
      case 'outdated':
        return fallback;
      case 'rate_limited':
        return 'Слишком много загрузок подряд. Подождите немного — файл ждёт в очереди.';
      case 'too_big':
      case 'bad_type':
      case 'bad_name':
      case 'bad_parent':
      case 'forbidden':
        return fallback;
      default:
        return fallback;
    }
  }
}

/// Настройки из cave-data/config.json
class BrokerConfig {
  final String url;
  final String minClientVersion;
  const BrokerConfig(this.url, this.minClientVersion);

  static BrokerConfig? fromJson(Object? j) {
    if (j is! Map) return null;
    final url = '${j['broker'] ?? ''}'.trim();
    if (!url.startsWith('https://')) return null;
    return BrokerConfig(url, '${j['minClientVersion'] ?? ''}'.trim());
  }

  /// Новее ли [needed] версии [have] (числа через точку; всё после первого не-числа отбрасывается)
  static bool isNewer(String needed, String have) {
    List<int> parse(String v) => [
          for (final p in v.split(RegExp(r'[-+ ]')).first.split('.')) int.tryParse(p) ?? 0,
        ];
    final a = parse(needed), b = parse(have);
    for (var i = 0; i < 4; i++) {
      final x = i < a.length ? a[i] : 0, y = i < b.length ? b[i] : 0;
      if (x != y) return x > y;
    }
    return false;
  }
}

class BrokerSession {
  final Uri uri;
  final String uploadId;
  const BrokerSession(this.uri, this.uploadId);
}

class BrokerQuota {
  final int? free;
  final int? limit;
  final int used;
  const BrokerQuota(this.free, this.limit, this.used);
}

class UploadBroker {
  final AccountManager accounts;
  final DriveApi drive;
  final http.Client _http = http.Client();

  UploadBroker(this.accounts, this.drive);

  static String mimeFor(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    switch (ext) {
      case 'mp3':
        return 'audio/mpeg';
      case 'flac':
        return 'audio/flac';
      case 'm4a':
      case 'alac':
        return 'audio/mp4';
      case 'aac':
        return 'audio/aac';
      case 'ogg':
      case 'opus':
        return 'audio/ogg';
      case 'wav':
        return 'audio/wav';
      case 'wma':
        return 'audio/x-ms-wma';
      case 'aif':
      case 'aiff':
        return 'audio/aiff';
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'webp':
        return 'image/webp';
      case 'json':
        return 'application/json';
      default:
        return 'application/octet-stream';
    }
  }

  /// Один запрос к брокеру. Apps Script отвечает на POST редиректом (302) на адрес с результатом,
  /// который нужно забрать обычным GET — dart:io сам такой редирект для POST не проходит.
  Future<Map<String, dynamic>> _call(String url, String email, Map<String, Object?> body, {bool refreshed = false}) async {
    final token = await accounts.token(email, force: refreshed);
    http.Response res;
    try {
      final req = http.Request('POST', Uri.parse(url))
        ..followRedirects = false
        ..headers['Content-Type'] = 'text/plain; charset=utf-8'
        ..body = jsonEncode({...body, 'token': token});
      res = await http.Response.fromStream(await _http.send(req).timeout(const Duration(seconds: 45)))
          .timeout(const Duration(seconds: 60));
      for (var hop = 0; hop < 5 && const {301, 302, 303, 307, 308}.contains(res.statusCode); hop++) {
        final loc = res.headers['location'];
        if (loc == null) break;
        res = await _http.get(Uri.parse(loc)).timeout(const Duration(seconds: 45));
      }
    } on AuthException {
      rethrow;
    } on TimeoutException {
      throw const BrokerException('unavailable', 'Сервис загрузки не ответил вовремя');
    } on SocketException catch (e) {
      throw BrokerException('unavailable', 'Нет связи с сервисом загрузки: ${e.message}');
    } on http.ClientException catch (e) {
      throw BrokerException('unavailable', 'Нет связи с сервисом загрузки: ${e.message}');
    }
    Object? j;
    try {
      j = jsonDecode(utf8.decode(res.bodyBytes));
    } catch (_) {
      j = null;
    }
    if (j is! Map) {
      // Вместо JSON Google отдал страницу ошибки: у скрипта кончилась квота вызовов или он снят с публикации
      throw BrokerException('unavailable', 'Сервис загрузки ответил непонятно (${res.statusCode})');
    }
    if (j['ok'] == true) return j.cast<String, dynamic>();
    final code = '${j['code'] ?? 'internal'}';
    if ((code == 'bad_token' || code == 'no_token') && !refreshed) {
      return _call(url, email, body, refreshed: true);
    }
    throw BrokerException(code, BrokerException.friendly(code, '${j['error'] ?? 'Ошибка сервиса загрузки'}'));
  }

  Future<BrokerSession> begin(String url, String email,
      {required String name, required int size, required String parentId, String source = 'manual'}) async {
    final r = await _call(url, email, {
      'action': 'begin',
      'name': name,
      'size': size,
      'mime': mimeFor(name),
      'parentId': parentId,
      'source': source,
    });
    final uri = Uri.tryParse('${r['sessionUri'] ?? ''}');
    if (uri == null || uri.scheme != 'https' || uri.host != 'www.googleapis.com') {
      throw const BrokerException('internal', 'Сервис загрузки вернул неверный адрес сессии');
    }
    return BrokerSession(uri, '${r['uploadId'] ?? ''}');
  }

  /// Загружает файл целиком: открывает сессию у брокера и передаёт байты напрямую в Google (с докачкой).
  /// Короткие сбои самого брокера повторяются несколько раз подряд.
  Future<DriveFile> upload(String url, String email, File file,
      {required String parentId,
      String? name,
      String source = 'manual',
      void Function(double)? onProgress,
      void Function(String)? onStatus}) async {
    final fileName = name ?? file.uri.pathSegments.where((s) => s.isNotEmpty).last;
    final size = await file.length();
    late BrokerSession session;
    for (var attempt = 0;; attempt++) {
      try {
        session = await begin(url, email, name: fileName, size: size, parentId: parentId, source: source);
        break;
      } on BrokerException catch (e) {
        if (!e.quickRetry || attempt >= 2) rethrow;
        await Future<void>.delayed(Duration(seconds: 2 + attempt * 6));
      }
    }
    try {
      return await drive.uploadToSession(session.uri, file,
          mime: mimeFor(fileName), onProgress: onProgress, onStatus: onStatus);
    } on DriveException catch (e) {
      // 403 с storageQuotaExceeded означает, что у владельца закончилось место
      if (e.message.contains('storageQuotaExceeded') || e.message.toLowerCase().contains('storage quota')) {
        throw BrokerException('owner_full', BrokerException.friendly('owner_full', e.message));
      }
      if (e.status == 408 || e.status == 429 || e.status >= 500 || e.status == 404 || e.status == 410) {
        throw BrokerException('unavailable', 'Загрузка прервалась: ${e.message}');
      }
      rethrow;
    } on SocketException catch (e) {
      throw BrokerException('unavailable', 'Загрузка прервалась: ${e.message}');
    } on TimeoutException {
      throw const BrokerException('unavailable', 'Загрузка прервалась: Google не ответил вовремя');
    }
  }

  /// Удаляет (в корзину) файл через брокера: так можно удалить файл, который принадлежит владельцу библиотеки
  Future<void> delete(String url, String email, String fileId) async {
    await _call(url, email, {'action': 'delete', 'fileId': fileId});
  }

  Future<BrokerQuota> quota(String url, String email) async {
    final r = await _call(url, email, {'action': 'quota'});
    return BrokerQuota((r['free'] as num?)?.toInt(), (r['limit'] as num?)?.toInt(), (r['usage'] as num?)?.toInt() ?? 0);
  }
}
