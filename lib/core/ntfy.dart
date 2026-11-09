import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'log.dart';

/// Быстрый канал сообщений между участниками библиотеки на бесплатном сервере ntfy.
/// Google Диск остаётся источником истины: сюда уходят только короткие сигналы («у меня новое событие»)
/// и действия джем-сессии, а если сервер недоступен, всё работает через Диск, только медленнее.
///
/// Тема канала выводится из идентификатора общей папки cave-data и соли: посторонний, не знающий папки,
/// тему не угадает. Сообщения содержат только служебные поля (почты и id треков), без названий и файлов.
class NtfyChannel {
  final String server;
  final String topic;

  /// Служебные поля сообщений: от кого и что
  final void Function(Map<String, dynamic> message) onMessage;

  /// Связь с сервером появилась или пропала
  final void Function(bool online)? onState;

  NtfyChannel({required this.server, required this.topic, required this.onMessage, this.onState});

  /// Тема по идентификатору общей папки: 32 символа от SHA-256
  static String topicFor(String hubFolderId) {
    final h = sha256.convert(utf8.encode('cavey-ntfy-v1|$hubFolderId')).toString();
    return 'cavey-${h.substring(0, 32)}';
  }

  http.Client? _client;
  bool _stopped = false;
  bool online = false;
  int _backoff = 1;
  String? _lastId;

  /// Сервер отказал по лимиту: до этого времени ничего не отправляем, всё идёт через Диск
  DateTime? _limitedUntil;

  /// Можно ли сейчас отправлять: связь есть и сервер не ограничил нас по лимиту
  bool get canSend {
    final limited = _limitedUntil;
    return online && (limited == null || !DateTime.now().isBefore(limited));
  }

  /// Сервер ограничил отправку (лимит сообщений в сутки у бесплатного ntfy)
  bool get limited {
    final l = _limitedUntil;
    return l != null && DateTime.now().isBefore(l);
  }

  void start() {
    _stopped = false;
    unawaited(_loop());
  }

  Future<void> _loop() async {
    while (!_stopped) {
      final client = http.Client();
      _client = client;
      try {
        final since = _lastId == null ? 'since=0s' : 'since=$_lastId';
        final req = http.Request('GET', Uri.parse('$server/$topic/json?$since'));
        final res = await client.send(req).timeout(const Duration(seconds: 15));
        if (res.statusCode != 200) throw Exception('ntfy: ${res.statusCode}');
        _setOnline(true);
        _backoff = 1;
        await for (final line in res.stream.transform(utf8.decoder).transform(const LineSplitter())) {
          if (_stopped) break;
          if (line.trim().isEmpty) continue;
          try {
            final j = jsonDecode(line);
            if (j is! Map) continue;
            _lastId = '${j['id'] ?? _lastId}';
            if (j['event'] != 'message') continue;
            final body = jsonDecode('${j['message']}');
            if (body is Map<String, dynamic>) onMessage(body);
          } catch (_) {
            // не наше сообщение или обрезанная строка
          }
        }
      } catch (e) {
        if (!_stopped) AppLog.warn('ntfy: нет связи', e);
      } finally {
        client.close();
        if (identical(_client, client)) _client = null;
      }
      _setOnline(false);
      if (_stopped) break;
      await Future<void>.delayed(Duration(seconds: _backoff));
      _backoff = (_backoff * 2).clamp(1, 30);
    }
  }

  void _setOnline(bool v) {
    if (online == v) return;
    online = v;
    onState?.call(v);
  }

  /// Отправляет сообщение; false — не получилось (тогда вызывающий полагается на Диск)
  Future<bool> send(Map<String, dynamic> message) async {
    final limited = _limitedUntil;
    if (limited != null && DateTime.now().isBefore(limited)) return false;
    final body = jsonEncode(message);
    if (utf8.encode(body).length > 3900) return false;
    try {
      final res = await http
          .post(Uri.parse('$server/$topic'), body: body, headers: {'Content-Type': 'text/plain; charset=utf-8'})
          .timeout(const Duration(seconds: 5));
      if (res.statusCode == 429) {
        _limitedUntil = DateTime.now().add(const Duration(minutes: 2));
        AppLog.warn('ntfy: лимит сообщений, пока работаем через Диск');
        return false;
      }
      return res.statusCode == 200;
    } catch (e) {
      AppLog.warn('ntfy: сообщение не ушло', e);
      return false;
    }
  }

  void stop() {
    _stopped = true;
    _client?.close();
    _client = null;
    _setOnline(false);
  }
}
