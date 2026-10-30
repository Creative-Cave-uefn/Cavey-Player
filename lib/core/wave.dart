import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'dl/service.dart';
import 'library.dart';
import 'log.dart';
import 'models.dart';
import 'player.dart';
import 'social.dart';
import 'store.dart';
import 'web_info.dart';

/// Характер волны, как в Яндекс Музыке
enum WaveMode { mix, favorite, unfamiliar, popular }

extension WaveModeText on WaveMode {
  String get title => switch (this) {
        WaveMode.mix => 'Всё сразу',
        WaveMode.favorite => 'Любимое',
        WaveMode.unfamiliar => 'Незнакомое',
        WaveMode.popular => 'Популярное',
      };

  String get hint => switch (this) {
        WaveMode.mix => 'Любимое вперемешку с тем, что вы ещё не слушали',
        WaveMode.favorite => 'Лайки и то, что вы часто слушаете',
        WaveMode.unfamiliar => 'Треки из библиотеки, которые вы ещё не слышали, — от близких по вкусу исполнителей',
        WaveMode.popular => 'Что чаще всего слушают и лайкают друзья',
      };
}

/// Что волна узнала о вкусе. Хранится только на этом компьютере
class WaveTaste {
  /// Ключ исполнителя (в нижнем регистре) → симпатия: растёт от дослушиваний, падает от пропусков
  final Map<String, double> artists = {};

  /// «Не нравится»: эти треки волна больше не ставит
  final Set<String> disliked = {};

  /// Сколько раз трек пропустили в первые 30 секунд
  final Map<String, int> skips = {};

  void bump(String artist, double by) {
    final v = ((artists[artist] ?? 0) + by).clamp(-10.0, 20.0).toDouble();
    if (v.abs() < 0.05) {
      artists.remove(artist);
    } else {
      artists[artist] = v;
    }
  }

  Map<String, dynamic> toJson() => {
        'artists': artists.map((k, v) => MapEntry(k, double.parse(v.toStringAsFixed(2)))),
        'disliked': disliked.toList(),
        'skips': skips,
      };

  static WaveTaste fromJson(dynamic j) {
    final t = WaveTaste();
    if (j is! Map) return t;
    final a = j['artists'];
    if (a is Map) a.forEach((k, v) => t.artists['$k'] = (v as num?)?.toDouble() ?? 0);
    for (final x in (j['disliked'] as List? ?? const [])) {
      t.disliked.add('$x');
    }
    final s = j['skips'];
    if (s is Map) s.forEach((k, v) => t.skips['$k'] = (v as num?)?.toInt() ?? 0);
    return t;
  }
}

/// Всё, из чего волна выбирает следующий трек
class WaveInputs {
  final List<Track> tracks;
  final Set<String> liked; // мои лайки
  final Map<String, int> myPlays; // мои прослушивания за две недели
  final Map<String, int> crowd; // прослушивания и лайки друзей
  final Set<String> favArtists; // исполнители, отмеченные «в любимых»
  final Map<String, List<String>> related; // исполнитель → похожие (ключи)
  final WaveTaste taste;
  final Map<String, double> session; // поправки за эту волну: пропустил — меньше, дослушал — больше

  WaveInputs({
    required this.tracks,
    this.liked = const {},
    this.myPlays = const {},
    this.crowd = const {},
    this.favArtists = const {},
    this.related = const {},
    WaveTaste? taste,
    this.session = const {},
  }) : taste = taste ?? WaveTaste();
}

class WaveEngine {
  /// Симпатия к каждому исполнителю: лайки, прослушивания, «любимые», то, что волна выучила, и похожие
  static Map<String, double> affinity(WaveInputs x) {
    final a = <String, double>{};
    void add(String k, double v) => a[k] = (a[k] ?? 0) + v;
    for (final t in x.tracks) {
      final w = (x.liked.contains(t.id) ? 3.0 : 0.0) + min(x.myPlays[t.id] ?? 0, 6) * 0.7;
      if (w == 0) continue;
      final names = t.artists;
      for (var i = 0; i < names.length; i++) {
        add(names[i].toLowerCase(), i == 0 ? w : w * 0.6);
      }
    }
    for (final k in x.favArtists) {
      add(k, 6);
    }
    x.taste.artists.forEach(add);
    x.session.forEach(add);
    // Похожим исполнителям достаётся часть симпатии — так волна находит новое, но близкое
    final spill = <String, double>{};
    a.forEach((k, v) {
      if (v <= 0) return;
      for (final r in x.related[k] ?? const <String>[]) {
        spill[r] = max(spill[r] ?? 0, v * 0.4);
      }
    });
    spill.forEach((k, v) {
      final cur = a[k];
      if (cur == null || (cur >= 0 && cur < v)) a[k] = v;
    });
    return a;
  }

  static double _score(Track t, WaveInputs x, WaveMode mode, Map<String, double> aff, int maxCrowd) {
    var a = double.negativeInfinity;
    for (final n in t.artists) {
      a = max(a, aff[n.toLowerCase()] ?? 0);
    }
    if (a == double.negativeInfinity) a = 0;
    final aN = a > 0 ? a / (a + 6) : max(-0.9, a / 10); // от -0.9 до 1
    final fam = x.myPlays[t.id] ?? 0;
    final liked = x.liked.contains(t.id);
    final pop = (x.crowd[t.id] ?? 0) / maxCrowd;
    final fresh = fam == 0 && !liked;
    var w = switch (mode) {
      WaveMode.mix => 0.4 + 2.0 * aN + (liked ? 1.0 : 0) + 0.6 * pop + (fresh ? 0.4 : 0),
      WaveMode.favorite => 0.1 + 1.6 * aN + (liked ? 2.5 : 0) + 0.15 * min(fam, 6),
      WaveMode.unfamiliar => fresh ? 0.4 + 2.2 * aN + 0.6 * pop : 0.003,
      WaveMode.popular => 0.1 + 3.0 * pop + 0.8 * aN + (liked ? 0.3 : 0),
    };
    w *= pow(0.45, x.taste.skips[t.id] ?? 0);
    return max(w, 0.002);
  }

  /// Следующие [n] треков. [recent] — что уже звучало или стоит в очереди: их не повторяем,
  /// пока в библиотеке есть из чего выбрать. Один исполнитель два раза подряд — только если больше некого.
  static List<String> pick(WaveInputs x, WaveMode mode, int n, {List<String> recent = const [], Random? rnd}) {
    rnd ??= Random();
    final pool = [for (final t in x.tracks) if (!x.taste.disliked.contains(t.id)) t];
    if (pool.isEmpty || n <= 0) return const [];
    // Не повторяем последние треки; в маленькой библиотеке — только самые свежие
    final int window = min(recent.length, max(0, pool.length - n) ~/ 2 + min<int>(pool.length ~/ 2, 60));
    final avoid = recent.sublist(recent.length - min(window, recent.length)).toSet();
    var cands = [for (final t in pool) if (!avoid.contains(t.id)) t];
    if (cands.isEmpty) cands = pool;

    final aff = affinity(x);
    var maxCrowd = 1;
    for (final v in x.crowd.values) {
      if (v > maxCrowd) maxCrowd = v;
    }
    final weights = [for (final t in cands) _score(t, x, mode, aff, maxCrowd)];

    Set<String> lastArtists = {};
    if (recent.isNotEmpty) {
      final last = x.tracks.where((t) => t.id == recent.last);
      if (last.isNotEmpty) lastArtists = {for (final a in last.first.artists) a.toLowerCase()};
    }

    final out = <String>[];
    final taken = List<bool>.filled(cands.length, false);
    for (var k = 0; k < n && out.length < cands.length; k++) {
      var total = 0.0;
      final eff = List<double>.filled(cands.length, 0);
      for (var i = 0; i < cands.length; i++) {
        if (taken[i]) continue;
        var w = weights[i];
        if (cands[i].artists.any((a) => lastArtists.contains(a.toLowerCase()))) w *= 0.3;
        eff[i] = w;
        total += w;
      }
      if (total <= 0) break;
      var r = rnd.nextDouble() * total;
      var chosen = -1;
      for (var i = 0; i < cands.length; i++) {
        if (taken[i]) continue;
        r -= eff[i];
        chosen = i;
        if (r <= 0) break;
      }
      if (chosen < 0) break;
      taken[chosen] = true;
      out.add(cands[chosen].id);
      lastArtists = {for (final a in cands[chosen].artists) a.toLowerCase()};
    }
    return out;
  }
}

/// Трек, который волна скачала на пробу
class WaveTrial {
  final String id; // id файла на Диске
  final int deezer; // id трека в Deezer — чтобы не скачать его снова после удаления
  final DateTime at; // когда загружен
  WaveTrial(this.id, this.deezer, this.at);

  Map<String, dynamic> toJson() => {'id': id, 'dz': deezer, 'at': at.toUtc().toIso8601String()};
  static WaveTrial? fromJson(dynamic j) {
    if (j is! Map) return null;
    final at = DateTime.tryParse('${j['at']}');
    if (at == null || j['id'] == null) return null;
    return WaveTrial('${j['id']}', (j['dz'] as num?)?.toInt() ?? 0, at);
  }
}

/// Сколько живёт скачанный волной трек, если его никто не сохранил
const waveTrialTime = Duration(hours: 24);

/// «Моя волна»: бесконечная очередь, которая подстраивается по ходу.
/// Дослушали — больше такого, пропустили в начале — меньше, «не нравится» — больше не ставим.
/// Ещё волна сама скачивает новые треки похожих исполнителей. Если за сутки трек никто не послушал
/// второй раз, не лайкнул и не добавил в плейлист — он удаляется с Диска.
class WaveService extends ChangeNotifier implements QueueFeeder {
  final AppStore store;
  final LibraryController lib;
  final PlayerController player;
  final SocialController social;
  final WebInfoService web;
  final DownloadService downloads;

  WaveTaste taste = WaveTaste();
  WaveMode mode = WaveMode.mix;
  final Map<String, double> _session = {};
  final List<String> _recent = [];
  final Map<String, List<String>> _related = {}; // исполнитель → кто звучит в его «радио»
  Timer? _saveTimer;
  Timer? _sweepTimer;
  bool _learning = false;

  // ---------- новинки ----------

  /// Качать новые треки в волну
  bool discover = true;

  /// Не больше стольких новых треков в день: защищает Диск
  static const dailyLimit = 25;
  final Map<String, WaveTrial> trials = {};
  final Set<int> _rejected = {}; // удалённые после пробы — не качаем снова
  String _day = '';
  int _today = 0;
  int _sinceFresh = 0; // сколько треков прошло после последнего нового
  int _pending = 0; // загрузок в работе
  String discoverStatus = '';

  WaveService._(this.store, this.lib, this.player, this.social, this.web, this.downloads);

  static Future<WaveService> open(AppStore store, LibraryController lib, PlayerController player, SocialController social,
      WebInfoService web, DownloadService downloads) async {
    final w = WaveService._(store, lib, player, social, web, downloads);
    try {
      final j = await store.readJson('wave.json');
      if (j is Map) {
        w.taste = WaveTaste.fromJson(j['taste']);
        w.mode = WaveMode.values.firstWhere((m) => m.name == j['mode'], orElse: () => WaveMode.mix);
        for (final x in (j['recent'] as List? ?? const [])) {
          w._recent.add('$x');
        }
        final rel = j['radioArtists'];
        if (rel is Map) rel.forEach((k, v) => w._related['$k'] = [for (final x in (v as List? ?? const [])) '$x']);
        w.discover = j['discover'] != false;
        for (final x in (j['trials'] as List? ?? const [])) {
          final t = WaveTrial.fromJson(x);
          if (t != null) w.trials[t.id] = t;
        }
        for (final x in (j['rejected'] as List? ?? const [])) {
          if (x is num) w._rejected.add(x.toInt());
        }
        w._day = '${j['day'] ?? ''}';
        w._today = (j['today'] as num?)?.toInt() ?? 0;
      }
    } catch (e) {
      AppLog.warn('Моя волна: не прочитались настройки', e);
    }
    // Волна играла при закрытии — продолжаем её после перезапуска
    if (player.settings.session?['wave'] == true && player.current != null) player.attachFeeder(w);
    player.addListener(w._onPlayer);
    // Пробные треки проверяем не сразу: сначала должны подтянуться прослушивания друзей
    Timer(const Duration(minutes: 3), w.sweep);
    w._sweepTimer = Timer.periodic(const Duration(minutes: 20), (_) => w.sweep());
    return w;
  }

  bool get active => identical(player.feeder, this);
  bool _wasActive = false;

  void _onPlayer() {
    if (active != _wasActive) {
      _wasActive = active;
      notifyListeners();
    }
  }

  // ---------- запуск ----------

  Future<void> start([WaveMode? m]) async {
    if (m != null) mode = m;
    _session.clear();
    final first = more(4);
    if (first.isEmpty) {
      lib.messages.add('В библиотеке пока нечего включить');
      return;
    }
    await player.playFeed(this, first);
    _save();
    notifyListeners();
    unawaited(_learnRadio());
  }

  /// Волна по треку: начинаем с него и держимся рядом с его исполнителями
  Future<void> startFrom(Track t) async {
    _session.clear();
    for (final a in t.artists) {
      _session[a.toLowerCase()] = 8;
    }
    _remember([t.id]);
    await player.playFeed(this, [t.id, ...more(3)]);
    _save();
    notifyListeners();
    unawaited(_learnRadio(extra: t.artists));
  }

  /// Волна по исполнителю
  Future<void> startFromArtist(String name) async {
    _session
      ..clear()
      ..[name.toLowerCase()] = 10;
    final first = more(4);
    if (first.isEmpty) return;
    await player.playFeed(this, first);
    _save();
    notifyListeners();
    unawaited(_learnRadio(extra: [name]));
  }

  void setMode(WaveMode m) {
    if (m == mode) return;
    mode = m;
    if (active) player.replaceUpcoming(more(4));
    _save();
    notifyListeners();
  }

  void setDiscover(bool on) {
    discover = on;
    _save();
    notifyListeners();
  }

  /// «Не нравится»: убираем трек из волны навсегда и сразу переключаем.
  /// Если его волна скачала на пробу — сразу удаляем с Диска
  Future<void> dislike() async {
    final t = player.current;
    if (t == null) return;
    taste.disliked.add(t.id);
    for (final a in t.artists) {
      final k = a.toLowerCase();
      taste.bump(k, -1.5);
      _session[k] = (_session[k] ?? 0) - 4;
    }
    final trial = trials[t.id];
    _save();
    notifyListeners();
    await player.next();
    if (trial != null && !_kept(t.id)) {
      _drop(trial);
      lib.messages.add('«${t.title}» удалён: не понравился');
    } else {
      lib.messages.add('«${t.title}» больше не попадётся в волне');
    }
  }

  void undislike(String id) {
    if (taste.disliked.remove(id)) {
      _save();
      notifyListeners();
    }
  }

  /// Оставить пробный трек в библиотеке насовсем
  void keep(String id) {
    if (trials.remove(id) != null) {
      _save();
      notifyListeners();
    }
  }

  void resetTaste() {
    taste = WaveTaste();
    _session.clear();
    _recent.clear();
    _save();
    notifyListeners();
  }

  // ---------- что волна знает ----------

  WaveInputs _inputs() {
    final me = lib.me;
    // Пробные треки волна ставит сама один раз: повтор должен быть чьим-то выбором, а не волны
    final tracks = [for (final t in lib.allTracks) if (!trials.containsKey(t.id)) t];
    final liked = {for (final t in tracks) if (lib.isLiked(t.id)) t.id};
    final myPlays = <String, int>{};
    final crowd = <String, int>{};
    for (final m in social.members.values) {
      final mine = m.email == me;
      for (final day in m.plays.values) {
        day.forEach((raw, n) {
          final id = lib.data.resolve(raw);
          final into = mine ? myPlays : crowd;
          into[id] = (into[id] ?? 0) + n;
        });
      }
    }
    lib.data.likes.forEach((id, who) {
      final others = who.where((e) => e != me).length;
      if (others > 0) crowd[id] = (crowd[id] ?? 0) + others * 2;
    });
    final fav = {for (final a in lib.artists) if (lib.isFavArtist(a.key)) a.key};
    return WaveInputs(
      tracks: tracks,
      liked: liked,
      myPlays: myPlays,
      crowd: crowd,
      favArtists: fav,
      related: _related,
      taste: taste,
      session: _session,
    );
  }

  Map<String, double> _affinity() => WaveEngine.affinity(_inputs());

  /// Исполнители, которые волне нравятся больше всего (для страницы «Моя волна»)
  List<(String, double)> topArtists([int n = 12]) {
    final aff = _affinity();
    final list = [
      for (final e in aff.entries)
        if (e.value > 0 && lib.artist(e.key) != null) (e.key, e.value)
    ]..sort((a, b) => b.$2.compareTo(a.$2));
    return list.take(n).toList();
  }

  void _remember(List<String> ids) {
    _recent.addAll(ids);
    if (_recent.length > 200) _recent.removeRange(0, _recent.length - 200);
  }

  // ---------- QueueFeeder ----------

  @override
  List<String> more(int n) {
    final x = _inputs();
    final ahead = player.feeder == this ? player.queue.skip(player.index) : const <String>[];
    final ids = WaveEngine.pick(x, mode, n, recent: [..._recent, ...ahead]);
    _remember(ids);
    _sinceFresh += ids.length;
    _save();
    _maybeDiscover();
    return ids;
  }

  @override
  void heard(Track t, Duration listened, {required bool skipped}) {
    final keys = [for (final a in t.artists) a.toLowerCase()];
    final total = Duration(milliseconds: t.durationMs ?? 0);
    final early = skipped && listened < const Duration(seconds: 30);
    final finished = !skipped || (total > Duration.zero && listened.inMilliseconds > total.inMilliseconds * 0.7);
    if (early) {
      taste.skips[t.id] = (taste.skips[t.id] ?? 0) + 1;
      for (final k in keys) {
        taste.bump(k, -0.6);
        _session[k] = (_session[k] ?? 0) - 2.5;
      }
      // Сразу убираем из ближайшей очереди этого же исполнителя — волна реагирует, а не через десять треков
      player.dropUpcoming((id) {
        final u = lib.data.tracks[id];
        return u != null && u.artists.any((a) => keys.contains(a.toLowerCase()));
      });
    } else if (finished) {
      final s = taste.skips[t.id];
      if (s != null && s <= 1) {
        taste.skips.remove(t.id);
      } else if (s != null) {
        taste.skips[t.id] = s - 1;
      }
      for (final k in keys) {
        taste.bump(k, 0.4);
        _session[k] = (_session[k] ?? 0) + 1.5;
      }
    }
    _save();
  }

  // ---------- «радио» исполнителей ----------

  /// Для любимых исполнителей спрашиваем у Deezer их «радио». Кто там звучит — тот и похож:
  /// это то, что люди слушают вместе, а не просто «похожие» по жанру
  Future<void> _learnRadio({List<String> extra = const []}) async {
    if (_learning) return;
    _learning = true;
    try {
      final top = [for (final e in topArtists(8)) e.$1];
      final keys = <String>{for (final a in extra) a.toLowerCase(), ...top}.where((k) => !_related.containsKey(k)).take(8);
      for (final key in keys) {
        try {
          final list = await _radioOf(key);
          if (list == null) continue;
          final count = <String, int>{};
          for (final t in list) {
            for (final a in splitArtists(t.artist)) {
              final k = a.toLowerCase();
              if (k != key) count[k] = (count[k] ?? 0) + 1;
            }
          }
          final sorted = count.keys.toList()..sort((a, b) => count[b]!.compareTo(count[a]!));
          _related[key] = sorted.take(25).toList();
        } catch (_) {
          // нет сети — спросим в следующий раз
        }
      }
      if (_related.length > 150) {
        for (final k in _related.keys.take(_related.length - 150).toList()) {
          _related.remove(k);
        }
      }
      _save();
    } finally {
      _learning = false;
    }
  }

  Future<List<WebTrack>?> _radioOf(String key) async {
    final name = lib.artist(key)?.name ?? key;
    final a = await web.artist(name, low: true);
    if (a == null) return null;
    return web.radio(a.id);
  }

  // ---------- скачивание новинок ----------

  String _todayKey() => DateTime.now().toIso8601String().substring(0, 10);

  int get downloadedToday => _day == _todayKey() ? _today : 0;

  /// Каждый какой трек волны — новый из интернета
  int? get _every => switch (mode) {
        WaveMode.mix => 4,
        WaveMode.unfamiliar => 2,
        WaveMode.favorite || WaveMode.popular => null,
      };

  String? get _targetSource {
    final sources = lib.data.sources;
    if (sources.isEmpty) return null;
    final hub = lib.settings.hubId;
    return sources.any((s) => s.id == hub) ? hub : sources.first.id;
  }

  void _maybeDiscover() {
    final every = _every;
    if (!discover || !active || every == null || _pending > 0 || _sinceFresh < every) return;
    if (downloadedToday >= dailyLimit || _targetSource == null || !lib.hasHub) return;
    unawaited(_discoverOne());
  }

  Future<void> _discoverOne() async {
    _pending++;
    _sinceFresh = 0;
    _status('Ищу новое для волны…');
    try {
      final pick = await _findFresh();
      if (pick == null) {
        _status('Нового пока не нашлось');
        _pending--;
        return;
      }
      final src = _targetSource!;
      final folder = await lib.ensureSubfolder(src, src, 'Моя волна');
      _status('Качаю «${pick.title}» — ${pick.artist}');
      var got = false;
      final job = downloads.enqueue(pick.link, src, folderId: folder, path: 'Моя волна', quiet: true, onTrack: (t) {
        got = true;
        _onDownloaded(t, pick);
      });
      if (job == null) {
        _pending--;
        return;
      }
      // Ждём конца задания, чтобы не ставить в очередь загрузчика десяток треков разом
      void check() {
        if (job.state == JobState.done || job.state == JobState.failed) {
          downloads.removeListener(check);
          _pending--;
          if (!got) {
            _rejected.add(pick.id); // не скачался или уже был — в следующий раз ищем другой
            _status('');
          }
          _save();
        }
      }

      downloads.addListener(check);
    } catch (e) {
      _pending--;
      _status('');
      AppLog.warn('Моя волна: новинка', e);
    }
  }

  void _status(String s) {
    discoverStatus = s;
    notifyListeners();
  }

  /// Новый трек: из «радио» того, что играет сейчас, и любимых исполнителей.
  /// Чем больше «радио» сходятся на исполнителе, тем вероятнее его трек
  Future<WebTrack?> _findFresh() async {
    final seeds = <String>[];
    final cur = player.current;
    if (cur != null) seeds.add(cur.artists.first.toLowerCase());
    final top = topArtists(10).map((e) => e.$1).toList()..shuffle();
    for (final k in top) {
      if (!seeds.contains(k)) seeds.add(k);
      if (seeds.length >= 3) break;
    }
    if (seeds.isEmpty) {
      final all = lib.artists;
      if (all.isEmpty) return null;
      seeds.add(all[Random().nextInt(all.length)].key);
    }
    final votes = <int, double>{};
    final byId = <int, WebTrack>{};
    for (var i = 0; i < seeds.length; i++) {
      List<WebTrack>? list;
      try {
        list = await _radioOf(seeds[i]);
      } catch (_) {}
      if (list == null) continue;
      for (final t in list) {
        byId[t.id] = t;
        votes[t.id] = (votes[t.id] ?? 0) + (i == 0 ? 2 : 1);
      }
    }
    final aff = _affinity();
    final trialIds = {for (final t in trials.values) t.deezer};
    final artistVotes = <String, double>{};
    votes.forEach((id, v) {
      final k = byId[id]!.artist.toLowerCase();
      artistVotes[k] = (artistVotes[k] ?? 0) + v;
    });
    final cands = <(WebTrack, double)>[];
    for (final t in byId.values) {
      if (t.link.isEmpty || _rejected.contains(t.id) || trialIds.contains(t.id)) continue;
      if (lib.existing(t.artist, t.title) != null) continue;
      final names = splitArtists(t.artist).map((a) => a.toLowerCase());
      if (names.any((k) => (aff[k] ?? 0) <= -3)) continue; // исполнителя постоянно пропускают
      if (t.seconds > 0 && (t.seconds < 90 || t.seconds > 600)) continue; // интро, скиты и часовые миксы
      var w = votes[t.id]! + (artistVotes[t.artist.toLowerCase()] ?? 0) * 0.5;
      // Новые для библиотеки исполнители интереснее, но и новая песня знакомого — тоже хорошо
      if (lib.artist(t.artist.toLowerCase()) == null) w *= 1.3;
      cands.add((t, w));
    }
    if (cands.isEmpty) return null;
    cands.sort((a, b) => b.$2.compareTo(a.$2));
    final top5 = cands.take(5).toList();
    var total = 0.0;
    for (final c in top5) {
      total += c.$2;
    }
    var r = Random().nextDouble() * total;
    for (final c in top5) {
      r -= c.$2;
      if (r <= 0) return c.$1;
    }
    return top5.first.$1;
  }

  void _onDownloaded(Track t, WebTrack from) {
    trials[t.id] = WaveTrial(t.id, from.id, DateTime.now());
    final today = _todayKey();
    if (_day != today) {
      _day = today;
      _today = 0;
    }
    _today++;
    _status('');
    if (active) player.insertSoon(t.id);
    _save();
    notifyListeners();
  }

  // ---------- пробный срок ----------

  /// Трек остаётся, если его кто-то лайкнул, добавил в плейлист или послушал второй раз
  bool _kept(String id) {
    if (lib.data.likes[id]?.isNotEmpty ?? false) return true;
    if (lib.data.playlists.any((p) => p.items.contains(id))) return true;
    return social.playsOf(id) >= 2;
  }

  /// Что с пробным треком: сохранится он или сколько осталось
  (bool, Duration) trialState(String id) {
    final t = trials[id];
    if (t == null) return (true, Duration.zero);
    final left = t.at.add(waveTrialTime).difference(DateTime.now());
    return (_kept(id), left.isNegative ? Duration.zero : left);
  }

  List<Track> get trialTracks => [
        for (final t in trials.values)
          if (lib.data.tracks[t.id] != null) lib.data.tracks[t.id]!
      ];

  void _drop(WaveTrial t) {
    trials.remove(t.id);
    _rejected.add(t.deezer);
    if (_rejected.length > 1000) _rejected.remove(_rejected.first);
    final track = lib.data.tracks[t.id];
    if (track != null) lib.deleteTracks([track]);
    _save();
  }

  /// Раз в 20 минут: сохранённые оставляем насовсем, просроченные удаляем с Диска
  void sweep() {
    if (trials.isEmpty || !lib.hasHub || !social.loaded) return;
    var removed = 0;
    for (final t in trials.values.toList()) {
      final id = lib.data.resolve(t.id);
      if (lib.data.tracks[id] == null) {
        trials.remove(t.id); // уже удалили руками
        continue;
      }
      if (_kept(id)) {
        trials.remove(t.id);
        continue;
      }
      // Пока играет — не трогаем
      if (player.current?.id == id) continue;
      if (DateTime.now().difference(t.at) >= waveTrialTime) {
        _drop(t);
        removed++;
      }
    }
    if (removed > 0) {
      player.dropUpcoming((id) => lib.data.tracks[id] == null);
      AppLog.info('Моя волна: удалено непонравившихся новинок: $removed');
    }
    _save();
    notifyListeners();
  }

  // ---------- сохранение ----------

  void _save() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), flush);
  }

  Future<void> flush() async {
    _saveTimer?.cancel();
    try {
      await store.writeJson('wave.json', {
        'mode': mode.name,
        'taste': taste.toJson(),
        'recent': _recent,
        'radioArtists': _related,
        'discover': discover,
        'trials': [for (final t in trials.values) t.toJson()],
        'rejected': _rejected.toList(),
        'day': _day,
        'today': _today,
      });
    } catch (e) {
      AppLog.warn('Моя волна: не сохранилось', e);
    }
  }

  @override
  void dispose() {
    _sweepTimer?.cancel();
    _saveTimer?.cancel();
    super.dispose();
  }
}
