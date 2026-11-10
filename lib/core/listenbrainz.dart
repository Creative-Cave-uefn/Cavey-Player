import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;

import 'log.dart';
import 'models.dart';
import 'player.dart';
import 'store.dart';

/// Скробблинг в ListenBrainz, как в LMS. ListenBrainz — открытый аналог Last.fm: хранит историю прослушиваний
/// и по ней строит рекомендации. Нужен только токен со страницы listenbrainz.org/settings.
///
/// Правила те же, что у сервиса: трек засчитывается, когда прослушана половина или четыре минуты, но не короче 30 секунд.
/// Как только трек начался, отправляется «сейчас играет». Если сети нет, прослушивания копятся и уходят позже.
class ListenBrainz {
  static const _host = 'api.listenbrainz.org';
  static const _tokenKey = 'lb.token';
  static const _onKey = 'lb.on';

  final Settings settings;
  final PlayerController player;
  final http.Client _http;
  ListenBrainz(this.settings, this.player, {http.Client? client}) : _http = client ?? http.Client();

  /// Токен из настроек
  String get token => (settings.view[_tokenKey] ?? '').trim();

  /// Скробблинг включён: токен введён и переключатель не выключен
  bool get enabled => token.isNotEmpty && settings.viewOf(_onKey, '1') == '1';

  /// Что случилось в последний раз (для строки в настройках); пусто — всё в порядке
  String status = '';

  Timer? _timer;
  String? _id;
  DateTime _started = DateTime.now();
  DateTime _tick = DateTime.now();
  int _playedMs = 0;
  bool _sent = false;
  final List<Map<String, dynamic>> _pending = [];

  /// Сколько прослушиваний ждут отправки
  int get pending => _pending.length;

  void start() {
    player.addListener(_onPlayer);
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _onTick());
  }

  void dispose() {
    _timer?.cancel();
    player.removeListener(_onPlayer);
    _http.close();
  }

  void _onPlayer() {
    final cur = player.current;
    if (cur?.id == _id) return;
    _id = cur?.id;
    _started = DateTime.now();
    _tick = _started;
    _playedMs = 0;
    _sent = false;
    if (cur != null && enabled && _scrobblable(cur)) unawaited(_playingNow(cur));
  }

  /// Без исполнителя ListenBrainz запись не примет
  static bool _scrobblable(Track t) => t.artist.trim().isNotEmpty && t.title.trim().isNotEmpty;

  void _onTick() {
    final now = DateTime.now();
    final elapsed = now.difference(_tick).inMilliseconds;
    _tick = now;
    final cur = player.current;
    if (cur == null || cur.id != _id) return;
    // Считаем только время, пока трек играет; длинные провалы (сон компьютера) в счёт не идут
    if (player.playing && elapsed > 0 && elapsed < 15000) _playedMs += elapsed;
    if (_pending.isNotEmpty && enabled) unawaited(flush());
    if (_sent || !enabled || !_scrobblable(cur)) return;
    final total = player.duration.inMilliseconds > 0 ? player.duration.inMilliseconds : (cur.durationMs ?? 0);
    if (total > 0 && total < 30000) return;
    final need = total > 0 ? math.min(240000, total ~/ 2) : 240000;
    if (_playedMs < need) return;
    _sent = true;
    _pending.add(_listen(cur, _started));
    if (_pending.length > 200) _pending.removeAt(0);
    unawaited(flush());
  }

  Map<String, dynamic> _meta(Track t) => {
        'artist_name': t.artist.trim(),
        'track_name': t.title.trim(),
        if (t.album.trim().isNotEmpty) 'release_name': t.album.trim(),
        'additional_info': {
          'media_player': 'Cavey Player',
          'submission_client': 'Cavey Player',
          if (t.durationMs != null && t.durationMs! > 0) 'duration_ms': t.durationMs,
        },
      };

  Map<String, dynamic> _listen(Track t, DateTime at) => {
        'listened_at': at.millisecondsSinceEpoch ~/ 1000,
        'track_metadata': _meta(t),
      };

  Future<void> _playingNow(Track t) async {
    try {
      final r = await _post({
        'listen_type': 'playing_now',
        'payload': [
          {'track_metadata': _meta(t)}
        ],
      });
      _note(r);
    } catch (e) {
      status = 'ListenBrainz: $e';
    }
  }

  bool _flushing = false;

  /// Отправляет накопившиеся прослушивания. Ошибка сети — оставляем на потом; отказ сервера — выбрасываем, он не изменится
  Future<void> flush() async {
    if (_flushing || _pending.isEmpty || !enabled) return;
    _flushing = true;
    try {
      final batch = List<Map<String, dynamic>>.of(_pending.take(50));
      final type = batch.length == 1 ? 'single' : 'import';
      final r = await _post({'listen_type': type, 'payload': batch});
      _note(r);
      if (r == 200 || (r >= 400 && r < 500 && r != 429 && r != 401)) {
        _pending.removeRange(0, batch.length);
        if (r == 200) {
          AppLog.info('ListenBrainz: отправлено прослушиваний — ${batch.length}');
        } else {
          AppLog.warn('ListenBrainz: сервер отклонил ${batch.length} прослушиваний (HTTP $r), они удалены');
        }
      }
    } catch (e) {
      status = 'ListenBrainz: нет связи ($e), повторю позже';
    } finally {
      _flushing = false;
    }
  }

  Future<int> _post(Map<String, dynamic> body) async {
    final r = await _http
        .post(Uri.https(_host, '/1/submit-listens'),
            headers: {'Authorization': 'Token $token', 'Content-Type': 'application/json'}, body: jsonEncode(body))
        .timeout(const Duration(seconds: 15));
    return r.statusCode;
  }

  void _note(int code) {
    if (code == 200) {
      status = '';
    } else if (code == 401) {
      status = 'ListenBrainz: токен не принят';
    } else if (code == 429) {
      status = 'ListenBrainz: слишком много запросов, подожду';
    } else {
      status = 'ListenBrainz: ответ сервера $code';
    }
  }

  /// Проверка токена: имя пользователя ListenBrainz или null, если токен не принят или нет связи
  Future<String?> validate([String? candidate]) async {
    final t = (candidate ?? token).trim();
    if (t.isEmpty) return null;
    try {
      final r = await _http
          .get(Uri.https(_host, '/1/validate-token'), headers: {'Authorization': 'Token $t'})
          .timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) return null;
      final j = jsonDecode(utf8.decode(r.bodyBytes));
      if (j is Map && j['valid'] == true) return '${j['user_name'] ?? ''}';
      return null;
    } catch (_) {
      return null;
    }
  }
}
