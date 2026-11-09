import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show min;

import 'package:http/http.dart' as http;

import '../config.dart';
import 'log.dart';
import 'store.dart';

/// Похожий трек или исполнитель из Last.fm: [match] от 0 до 1
class LfmItem {
  final String artist;
  final String title; // пусто для исполнителя
  final double match;
  const LfmItem(this.artist, this.title, this.match);

  List<dynamic> toJson() => [artist, title, match];
  static LfmItem? fromJson(dynamic j) {
    if (j is! List || j.length < 3) return null;
    return LfmItem('${j[0]}', '${j[1]}', (j[2] as num?)?.toDouble() ?? 0);
  }
}

/// Запрос в очереди: [prio] 1 — нужен прямо сейчас (играет трек, ищем новинку), 0 — фоновый (теги)
class _Req {
  final int prio;
  final int seq;
  final Future<void> Function() run;
  _Req(this.prio, this.seq, this.run);
}

/// Запись о запросе для отчёта: чем кончился и сколько шёл
class _Rec {
  final DateTime at;
  final String kind; // ok, notfound, timeout, net, nonjson, badkey, ratelimit, api8/api11/api16, parse
  final String what; // метод и о чём спрашивали
  final int ms;
  final String detail;
  _Rec(this.at, this.kind, this.what, this.ms, this.detail);
}

/// Похожесть по Last.fm: строится на том, что миллионы людей слушают подряд.
/// Даёт похожие треки (а не только исполнителей), поэтому волна держит настроение песни.
///
/// Запросы идут по одному с паузой, ответы хранятся неделю — API не перегружаем.
/// Важное про ошибки: ответ «не найдено» запоминается, а сбой (таймаут, 5xx, не-JSON, временная ошибка
/// Last.fm) — нет. Сбой возвращается как `null`, чтобы вызывающий не принял его за «данных нет».
/// Если подряд случилось три сбоя, Last.fm считается недоступным и на время паузы все запросы
/// отвечают сразу, а не по 8 секунд каждый.
///
/// Журнал (cave-player.log, строки «Last.fm: …»): каждый сбой с причиной, кодом, заголовками и началом
/// тела ответа; пауза с последними ответами перед ней; при паузе — проверка связи (DNS, TCP, TLS, HTTP
/// и контрольный запрос к Deezer), чтобы понять, ЧТО именно не работает; возвращение связи; раз в 15 минут
/// или 50 запросов — итоги с задержками. Ключ API в журнал не попадает никогда.
class LastFm {
  /// [store] может быть null (тесты): тогда кеш живёт только в памяти.
  /// Проверка связи при паузе включена, только если клиент не подменён (в тестах в сеть не ходим)
  final AppStore? store;
  LastFm(this.store,
      {http.Client? client, Duration timeout = const Duration(seconds: 8), Duration spacing = const Duration(milliseconds: 250)})
      : _http = client ?? http.Client(),
        _timeout = timeout,
        _spacing = spacing,
        _diagEnabled = client == null;

  static const _ttl = Duration(days: 7);
  static final _never = DateTime.fromMillisecondsSinceEpoch(0);
  static const _host = 'ws.audioscrobbler.com';

  final http.Client _http;
  final Duration _timeout;
  final Duration _spacing;
  final bool _diagEnabled;
  final Map<String, (DateTime, List<LfmItem>)> _cache = {};
  final Map<String, Future<List<LfmItem>?>> _inflight = {};
  final List<_Req> _waiting = [];
  bool _pumping = false;
  int _seq = 0;
  DateTime _last = _never;
  Future<void>? _loading;
  Timer? _saveTimer;

  /// Пока ключ не отвергнут: при ошибке ключа перестаём спрашивать до перезапуска
  bool _keyOk = true;
  bool get available => kLastFmKey.isNotEmpty && _keyOk;

  // ---------- пауза при сбоях ----------

  int _fails = 0; // подряд неудачных запросов
  int _trips = 0; // сколько раз подряд срабатывала пауза: растёт, пока Last.fm не ответит
  DateTime _pausedUntil = _never;
  String _pauseWhy = '';
  DateTime? _firstFailAt; // с какого момента идёт серия сбоев

  /// Last.fm сейчас не спрашиваем: недавно подряд не ответил или просил подождать
  bool get paused => DateTime.now().isBefore(_pausedUntil);

  Duration get pauseLeft {
    final left = _pausedUntil.difference(DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  /// Почему Last.fm не работает, для строки в интерфейсе. Пусто — всё в порядке
  String get status {
    if (!_keyOk) return 'Last.fm: ключ не принят';
    if (!paused) return '';
    final left = pauseLeft;
    final t = left.inMinutes >= 1 ? '${left.inMinutes + 1} мин' : '${left.inSeconds + 1} с';
    return 'Last.fm недоступен ($_pauseWhy), повторю через $t';
  }

  void _fail(String why) {
    _firstFailAt ??= DateTime.now();
    if (++_fails < 3) return;
    _fails = 0;
    _trips++;
    _pause(Duration(minutes: const [1, 2, 5, 10][min(_trips, 4) - 1]), why, trip: true);
  }

  void _pause(Duration d, String why, {bool trip = false}) {
    _pausedUntil = DateTime.now().add(d);
    _pauseWhy = why;
    AppLog.warn('Last.fm: пауза ${d.inSeconds} с ($why), срабатывание №$_trips. Последние ответы: ${_recentSummary(6)}');
    if (trip) _autoDiagnose();
  }

  void _ok() {
    final since = _firstFailAt;
    if (since != null) {
      final dur = DateTime.now().difference(since);
      if (dur > const Duration(seconds: 15) || _trips > 0) {
        AppLog.info('Last.fm: снова отвечает; серия сбоев шла ${_fmt(dur)}, пауз было $_trips');
      }
    }
    _firstFailAt = null;
    _fails = 0;
    _trips = 0;
    _pausedUntil = _never;
    _pauseWhy = '';
  }

  static String _fmt(Duration d) => d.inMinutes >= 1 ? '${d.inMinutes} мин ${d.inSeconds % 60} с' : '${d.inSeconds} с';

  // ---------- журнал и статистика ----------

  final List<_Rec> _recent = []; // последние 200 запросов, для отчёта
  int _total = 0, _cacheHits = 0;
  final Map<String, int> _totalByKind = {};

  // Итоги периода: пишем в журнал раз в 15 минут или 50 запросов, чтобы не раздувать его
  final Map<String, int> _win = {};
  final List<int> _winLat = [];
  int _winCache = 0;
  DateTime _winStart = DateTime.now();

  // Одинаковые сбои в журнал не чаще раза в 20 секунд, остальные считаем
  final Map<String, DateTime> _logAt = {};
  final Map<String, int> _logSuppressed = {};

  /// Ключ API не должен попасть в журнал ни в каком виде: исключения http печатают адрес запроса целиком
  static String _redact(String s) {
    var r = s.replaceAll(RegExp(r'api_key=[^&\s]*', caseSensitive: false), 'api_key=***');
    if (kLastFmKey.isNotEmpty) r = r.replaceAll(kLastFmKey, '***');
    return r;
  }

  /// «Метод — о чём спрашивали»: видно, если виснет на конкретном исполнителе или треке
  static String _subject(Map<String, String> q) {
    String cut(String s) => s.length > 50 ? '${s.substring(0, 50)}…' : s;
    final what = [
      for (final k in const ['artist', 'track', 'tag'])
        if ((q[k] ?? '').isNotEmpty) cut(q[k]!),
    ];
    return '${q['method']}${what.isEmpty ? '' : ' «${what.join(' — ')}»'}';
  }

  /// Самое полезное из заголовков ответа: по ним видно прокси, CDN и страницы-заглушки
  static String _headers(http.Response r) {
    final out = [
      for (final k in const ['server', 'content-type', 'retry-after', 'via', 'x-cache', 'location'])
        if (r.headers[k] != null) '$k=${_redact(r.headers[k]!)}',
    ];
    return out.isEmpty ? 'заголовков нет' : out.join('; ');
  }

  /// Начало тела ответа одной строкой: например, «Доступ ограничен» от провайдера
  static String _snippet(http.Response r) {
    try {
      final s = utf8.decode(r.bodyBytes, allowMalformed: true).replaceAll(RegExp(r'\s+'), ' ').trim();
      if (s.isEmpty) return '(пусто)';
      return _redact(s.length > 160 ? '${s.substring(0, 160)}…' : s);
    } catch (_) {
      return '(не читается)';
    }
  }

  String _recentSummary(int n) {
    if (_recent.isEmpty) return 'пока ничего';
    return _recent.reversed.take(n).map((r) => '${r.kind} ${r.ms} мс').join(', ');
  }

  /// Записывает итог запроса в память и в журнал
  void _note(String kind, Stopwatch sw, String what, [String detail = '']) {
    final ms = sw.elapsedMilliseconds;
    final now = DateTime.now();
    _recent.add(_Rec(now, kind, what, ms, detail));
    if (_recent.length > 200) _recent.removeAt(0);
    _total++;
    _totalByKind[kind] = (_totalByKind[kind] ?? 0) + 1;
    _win[kind] = (_win[kind] ?? 0) + 1;
    if (kind == 'ok' || kind == 'notfound') {
      _winLat.add(ms);
      if (ms > 4000) AppLog.info('Last.fm: медленный ответ, $ms мс — $what');
    } else {
      _logFail(kind, '$kind, $ms мс — $what${detail.isEmpty ? '' : ': $detail'}');
    }
    _maybeSummary(now);
  }

  void _logFail(String kind, String line) {
    final now = DateTime.now();
    final last = _logAt[kind];
    if (last != null && now.difference(last) < const Duration(seconds: 20)) {
      _logSuppressed[kind] = (_logSuppressed[kind] ?? 0) + 1;
      return;
    }
    final skipped = _logSuppressed.remove(kind) ?? 0;
    _logAt[kind] = now;
    AppLog.warn('Last.fm: сбой $line${skipped > 0 ? ' (ещё $skipped таких же подряд не записаны)' : ''}');
  }

  void _maybeSummary(DateTime now) {
    final n = _win.values.fold<int>(0, (a, b) => a + b);
    if (n == 0) return;
    if (n < 50 && now.difference(_winStart) < const Duration(minutes: 15)) return;
    final lat = [..._winLat]..sort();
    String pct(double p) => lat.isEmpty ? '—' : '${lat[min(lat.length - 1, (lat.length * p).floor())]}';
    final kinds = _win.entries.map((e) => '${e.key}×${e.value}').join(', ');
    AppLog.info('Last.fm: итоги за ${now.difference(_winStart).inMinutes} мин — запросов в сеть $n ($kinds), '
        'из кеша $_winCache; ответ p50 ${pct(0.5)} мс, p95 ${pct(0.95)} мс, максимум ${lat.isEmpty ? '—' : lat.last} мс');
    _win.clear();
    _winLat.clear();
    _winCache = 0;
    _winStart = now;
  }

  // ---------- проверка связи ----------

  String? _lastDiag;
  DateTime _lastDiagAt = _never;
  Future<String>? _diagnosing;

  /// При паузе из-за сети сами выясняем, что сломано; не чаще раза в 10 минут
  void _autoDiagnose() {
    if (!_diagEnabled) return;
    if (DateTime.now().difference(_lastDiagAt) < const Duration(minutes: 10)) return;
    unawaited(diagnoseNow().catchError((Object e) => 'ошибка проверки: $e'));
  }

  /// Проверка по шагам: DNS → TCP → TLS → запрос с ключом, плюс контроль — доступен ли вообще Deezer.
  /// Показывает, на каком шаге рвётся связь. Результат ещё и пишется в журнал
  Future<String> diagnoseNow() => _diagnosing ??= _runDiagnosis().whenComplete(() => _diagnosing = null);

  Future<String> _runDiagnosis() async {
    final out = <String>[];
    Future<void> step(String name, Future<String> Function() f) async {
      final sw = Stopwatch()..start();
      try {
        final r = await f().timeout(const Duration(seconds: 8));
        out.add('$name: $r (${sw.elapsedMilliseconds} мс)');
      } on TimeoutException {
        out.add('$name: нет ответа за 8 с');
      } catch (e) {
        out.add('$name: ошибка ${_redact('${e.runtimeType}: $e')} (${sw.elapsedMilliseconds} мс)');
      }
    }

    // Прокси из окружения: dart:io читает именно их; в пароле нужды нет, показываем только хост
    final proxies = [
      for (final k in const ['HTTPS_PROXY', 'https_proxy', 'HTTP_PROXY', 'http_proxy', 'ALL_PROXY'])
        if ((Platform.environment[k] ?? '').isNotEmpty) '$k=${Uri.tryParse(Platform.environment[k]!)?.host ?? '?'}',
    ];
    out.add('прокси в окружении: ${proxies.isEmpty ? 'нет' : proxies.join(', ')}');

    await step('DNS $_host', () async => (await InternetAddress.lookup(_host)).map((a) => a.address).join(', '));
    await step('DNS api.deezer.com (контроль)', () async => (await InternetAddress.lookup('api.deezer.com')).map((a) => a.address).join(', '));
    await step('TCP $_host:443', () async {
      final s = await Socket.connect(_host, 443, timeout: const Duration(seconds: 6));
      s.destroy();
      return 'соединение установлено';
    });
    await step('TLS $_host', () async {
      final s = await SecureSocket.connect(_host, 443, timeout: const Duration(seconds: 6));
      final c = s.peerCertificate;
      s.destroy();
      return 'рукопожатие прошло, сертификат: ${c?.subject ?? '?'}, выдан: ${c?.issuer ?? '?'}';
    });
    await step('HTTP Last.fm с ключом', () async {
      final r = await _http.get(Uri.https(_host, '/2.0/', {'method': 'chart.gettopartists', 'limit': '1', 'api_key': kLastFmKey, 'format': 'json'}));
      dynamic j;
      try {
        j = jsonDecode(utf8.decode(r.bodyBytes));
      } catch (_) {}
      final err = j is Map ? j['error'] : null;
      return 'HTTP ${r.statusCode}, ${_headers(r)}, '
          '${j is Map ? (err == null ? 'JSON без ошибок, ключ принят' : 'ошибка Last.fm $err: ${j['message']}') : 'не JSON, тело: ${_snippet(r)}'}';
    });
    await step('HTTP api.deezer.com (контроль)', () async {
      final r = await _http.get(Uri.https('api.deezer.com', '/infos'));
      return 'HTTP ${r.statusCode}';
    });

    _lastDiagAt = DateTime.now();
    _lastDiag = out.join('\n');
    for (final l in out) {
      AppLog.info('Last.fm: проверка связи — $l');
    }
    return _lastDiag!;
  }

  /// Отчёт для «Скопировать»: состояние, счётчики, последние запросы и последняя проверка связи
  String report() {
    final b = StringBuffer()
      ..writeln('Last.fm — отчёт на ${DateTime.now().toIso8601String()}')
      ..writeln('Ключ: ${kLastFmKey.isEmpty ? 'не задан' : (_keyOk ? 'не отвергнут' : 'ОТВЕРГНУТ')}; '
          '${paused ? status : 'пауза не активна'}; в очереди: ${_waiting.length}')
      ..writeln('Всего запросов в сеть: $_total (${_totalByKind.entries.map((e) => '${e.key}×${e.value}').join(', ')}); из кеша: $_cacheHits');
    if (_lastDiag != null) {
      b
        ..writeln('\nПоследняя проверка связи (${_lastDiagAt.toIso8601String()}):')
        ..writeln(_lastDiag);
    }
    b.writeln('\nПоследние запросы (${min(_recent.length, 40)} из ${_recent.length}):');
    for (final r in _recent.skip(_recent.length > 40 ? _recent.length - 40 : 0)) {
      b.writeln('${r.at.toIso8601String().substring(11, 19)} ${r.kind.padRight(9)} ${r.ms.toString().padLeft(5)} мс  ${r.what}'
          '${r.detail.isEmpty ? '' : '  — ${r.detail}'}');
    }
    return b.toString();
  }

  // ---------- кеш ----------

  Future<void> _load() => _loading ??= _doLoad();

  Future<void> _doLoad() async {
    try {
      final j = await store?.readJson('lastfm.json');
      if (j is! Map) return;
      j.forEach((k, v) {
        if (v is! Map) return;
        final at = DateTime.tryParse('${v['at']}');
        if (at == null || DateTime.now().difference(at) > _ttl) return;
        _cache['$k'] = (at, [for (final x in (v['items'] as List? ?? const [])) if (LfmItem.fromJson(x) case final i?) i]);
      });
    } catch (_) {}
  }

  void _save() {
    final s = store;
    if (s == null) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 5), () async {
      // Самые старые ответы выбрасываем, чтобы файл не рос бесконечно
      final entries = _cache.entries.toList()..sort((a, b) => b.value.$1.compareTo(a.value.$1));
      final keep = entries.take(600);
      try {
        await s.writeJson('lastfm.json', {
          for (final e in keep) e.key: {'at': e.value.$1.toUtc().toIso8601String(), 'items': [for (final i in e.value.$2) i.toJson()]},
        });
      } catch (e) {
        AppLog.warn('Last.fm: не сохранился кеш', e);
      }
    });
  }

  /// Название без «(feat. …)», «[Remastered]», «- Radio Edit» и т. п.: с ними Last.fm часто не узнаёт песню
  static String cleanTitle(String t) {
    var s = t.replaceAll(RegExp(r'\s*[\(\[][^\)\]]*[\)\]]'), '');
    s = s.replaceAll(RegExp(r'\s+[-–—]\s+.*(remaster|edit|version|mix|live|mono|stereo|bonus|demo).*$', caseSensitive: false), '');
    s = s.replaceAll(RegExp(r'\s+(feat|ft)\.?\s.*$', caseSensitive: false), '');
    s = s.trim();
    return s.isEmpty ? t.trim() : s;
  }

  // ---------- запросы ----------
  // Первые четыре при сбое возвращают пустой список (им всё равно: нет данных — нет подсказки).
  // Теги возвращают null при сбое, потому что их результат запоминается надолго.

  /// Похожие на трек: до 100 штук, самые похожие первыми
  Future<List<LfmItem>> similarTracks(String artist, String title) async =>
      await _get(
        't:${artist.toLowerCase()}|${cleanTitle(title).toLowerCase()}',
        {'method': 'track.getsimilar', 'artist': artist, 'track': cleanTitle(title), 'limit': '100'},
        (j) {
          final list = (j['similartracks'] as Map?)?['track'];
          return [
            for (final x in (list is List ? list : const []))
              if (x is Map) LfmItem('${(x['artist'] as Map?)?['name'] ?? ''}', '${x['name'] ?? ''}', _num(x['match']))
          ];
        },
      ) ??
      const [];

  /// Похожие исполнители
  Future<List<LfmItem>> similarArtists(String artist) async =>
      await _get(
        'a:${artist.toLowerCase()}',
        {'method': 'artist.getsimilar', 'artist': artist, 'limit': '30'},
        (j) {
          final list = (j['similarartists'] as Map?)?['artist'];
          return [
            for (final x in (list is List ? list : const []))
              if (x is Map) LfmItem('${x['name'] ?? ''}', '', _num(x['match']))
          ];
        },
      ) ??
      const [];

  /// Самые популярные песни исполнителя: [match] — от 1 у первой до 0 у последней
  Future<List<LfmItem>> topTracks(String artist) async =>
      await _get(
        'top:${artist.toLowerCase()}',
        {'method': 'artist.gettoptracks', 'artist': artist, 'limit': '30'},
        (j) {
          final list = (j['toptracks'] as Map?)?['track'];
          final l = list is List ? list : const [];
          return [
            for (var i = 0; i < l.length; i++)
              if (l[i] is Map)
                LfmItem('${((l[i] as Map)['artist'] as Map?)?['name'] ?? artist}', '${(l[i] as Map)['name'] ?? ''}',
                    1 - i / l.length)
          ];
        },
      ) ??
      const [];

  /// Самые популярные песни с тегом (настроением)
  Future<List<LfmItem>> tagTracks(String tag) async =>
      await _get(
        'tag:$tag',
        {'method': 'tag.gettoptracks', 'tag': tag, 'limit': '100'},
        (j) {
          final list = (j['tracks'] as Map?)?['track'];
          final l = list is List ? list : const [];
          return [
            for (var i = 0; i < l.length; i++)
              if (l[i] is Map)
                LfmItem('${((l[i] as Map)['artist'] as Map?)?['name'] ?? ''}', '${(l[i] as Map)['name'] ?? ''}', 1 - i / l.length)
          ];
        },
      ) ??
      const [];

  static List<LfmItem> _tags(Map j) {
    final list = (j['toptags'] as Map?)?['tag'];
    return [
      for (final x in (list is List ? list : const []))
        if (x is Map && _num(x['count']) >= 5) LfmItem('${x['name'] ?? ''}'.toLowerCase(), '', _num(x['count']) / 100)
    ].take(20).toList();
  }

  /// Теги исполнителя (жанры и настроения): в [artist] — название тега, [match] — вес от 0 до 1.
  /// `null` — Last.fm не ответил; пустой список — ответил, что тегов нет. Запрос фоновый
  Future<List<LfmItem>?> artistTags(String artist) =>
      _get('tags:${artist.toLowerCase()}', {'method': 'artist.gettoptags', 'artist': artist}, _tags, prio: 0);

  /// Теги конкретной песни (Д5): точнее, чем теги исполнителя. `null` — Last.fm не ответил. Запрос фоновый
  Future<List<LfmItem>?> trackTags(String artist, String title) => _get(
      'ttags:${artist.toLowerCase()}|${title.toLowerCase()}', {'method': 'track.gettoptags', 'artist': artist, 'track': title}, _tags,
      prio: 0);

  static double _num(dynamic v) => v is num ? v.toDouble() : double.tryParse('$v') ?? 0;

  Future<List<LfmItem>?> _get(String key, Map<String, String> q, List<LfmItem> Function(Map) parse, {int prio = 1}) async {
    if (!available) return null;
    await _load();
    final hit = _cache[key];
    if (hit != null && DateTime.now().difference(hit.$1) < _ttl) {
      _cacheHits++;
      _winCache++;
      return hit.$2;
    }
    if (paused) return null;
    return _inflight[key] ??= _fetch(q, key, parse, prio).whenComplete(() {
      _inflight.remove(key); // блок, а не «=>»: иначе колбэк вернёт сам future и тот будет ждать сам себя
    });
  }

  Future<List<LfmItem>?> _fetch(Map<String, String> q, String key, List<LfmItem> Function(Map) parse, int prio) {
    final done = Completer<List<LfmItem>?>();
    _waiting.add(_Req(prio, _seq++, () async {
      List<LfmItem>? result;
      try {
        result = await _request(key, q, parse);
      } catch (e) {
        AppLog.warn('Last.fm: запрос не удался', _redact('$e'));
      } finally {
        // Завершаем ровно один раз и при любом исходе: иначе вызывающий завис бы навсегда
        if (!done.isCompleted) done.complete(result);
      }
    }));
    unawaited(_pump());
    return done.future;
  }

  /// По одному запросу за раз, не чаще раз в [_spacing]; срочные обгоняют фоновые.
  /// Любая ошибка внутри запроса ловится в [_fetch], поэтому очередь не может «умереть»
  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (_waiting.isNotEmpty) {
        _waiting.sort((a, b) => a.prio != b.prio ? b.prio.compareTo(a.prio) : a.seq.compareTo(b.seq));
        final r = _waiting.removeAt(0);
        final wait = _spacing - DateTime.now().difference(_last);
        if (wait > Duration.zero) await Future<void>.delayed(wait);
        _last = DateTime.now();
        await r.run();
      }
    } finally {
      _pumping = false;
    }
  }

  Future<List<LfmItem>?> _request(String key, Map<String, String> q, List<LfmItem> Function(Map) parse) async {
    if (paused || !available) return null; // пока ждали своей очереди, Last.fm успел «упасть»
    final sw = Stopwatch()..start();
    final what = _subject(q);
    final http.Response res;
    try {
      res = await _http
          .get(Uri.https(_host, '/2.0/', {...q, 'api_key': kLastFmKey, 'format': 'json', 'autocorrect': '1'}))
          .timeout(_timeout);
    } on TimeoutException {
      _note('timeout', sw, what, 'нет ответа за ${_timeout.inSeconds} с');
      _fail('нет ответа');
      return null;
    } catch (e) {
      // Тип исключения важен: SocketException — сеть/DNS, HandshakeException — TLS, ClientException — оборванное соединение
      _note('net', sw, what, _redact('${e.runtimeType}: $e'));
      _fail('нет связи');
      return null;
    }
    dynamic j;
    try {
      j = jsonDecode(utf8.decode(res.bodyBytes));
    } catch (_) {}
    if (j is! Map) {
      // Страница-заглушка провайдера, 502 от прокси и т. п. — это сбой, а не «данных нет»
      _note('nonjson', sw, what, 'HTTP ${res.statusCode}, ${_headers(res)}, тело: ${_snippet(res)}');
      _fail('ответ ${res.statusCode}');
      return null;
    }
    final err = (j['error'] as num?)?.toInt();
    final msg = 'HTTP ${res.statusCode}, ошибка $err: ${_redact('${j['message']}')}';
    if (err == 10 || err == 26) {
      _keyOk = false;
      _note('badkey', sw, what, msg);
      AppLog.warn('Last.fm: ключ не принят ($msg); до перезапуска плеера Last.fm не спрашиваем');
      return null;
    }
    if (err == 29) {
      _note('ratelimit', sw, what, '$msg, ${_headers(res)}');
      _pause(const Duration(seconds: 30), 'лимит запросов'); // не сбой сети: просто подождём
      return null;
    }
    if (err == 8 || err == 11 || err == 16) {
      _note('api$err', sw, what, msg);
      _fail('сервис ответил ошибкой $err'); // временная ошибка Last.fm — не запоминаем
      return null;
    }
    // Сюда доходят и успешные ответы, и 6 — «не найдено»: это настоящий ответ, его запоминаем
    final List<LfmItem> items;
    try {
      items = err == null ? parse(j).where((i) => i.artist.isNotEmpty).toList() : <LfmItem>[];
    } catch (e) {
      _note('parse', sw, what, 'неожиданная структура ответа: ${_redact('$e')}, тело: ${_snippet(res)}');
      _fail('странный ответ');
      return null;
    }
    _note(err == null ? 'ok' : 'notfound', sw, what, err == null ? '${items.length} шт.' : msg);
    _ok();
    _cache[key] = (DateTime.now(), items);
    _save();
    return items;
  }
}
