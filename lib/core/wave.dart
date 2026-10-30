import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

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
    final window = min(recent.length, max(0, pool.length - n) ~/ 2 + min(pool.length ~/ 2, 60));
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

/// «Моя волна»: бесконечная очередь из библиотеки, которая подстраивается по ходу.
/// Дослушали — больше такого, пропустили в начале — меньше, «не нравится» — больше не ставим.
class WaveService extends ChangeNotifier implements QueueFeeder {
  final AppStore store;
  final LibraryController lib;
  final PlayerController player;
  final SocialController social;
  final WebInfoService web;

  WaveTaste taste = WaveTaste();
  WaveMode mode = WaveMode.mix;
  final Map<String, double> _session = {};
  final List<String> _recent = [];
  final Map<String, List<String>> _related = {};
  Timer? _saveTimer;
  bool _learning = false;

  WaveService._(this.store, this.lib, this.player, this.social, this.web);

  static Future<WaveService> open(
      AppStore store, LibraryController lib, PlayerController player, SocialController social, WebInfoService web) async {
    final w = WaveService._(store, lib, player, social, web);
    try {
      final j = await store.readJson('wave.json');
      if (j is Map) {
        w.taste = WaveTaste.fromJson(j['taste']);
        w.mode = WaveMode.values.firstWhere((m) => m.name == j['mode'], orElse: () => WaveMode.mix);
        for (final x in (j['recent'] as List? ?? const [])) {
          w._recent.add('$x');
        }
        final rel = j['related'];
        if (rel is Map) rel.forEach((k, v) => w._related['$k'] = [for (final x in (v as List? ?? const [])) '$x']);
      }
    } catch (e) {
      AppLog.warn('Моя волна: не прочитались настройки', e);
    }
    // Волна играла при закрытии — продолжаем её после перезапуска
    if (player.settings.session?['wave'] == true && player.current != null) player.attachFeeder(w);
    player.addListener(w._onPlayer);
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
    unawaited(_learnRelated());
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
    unawaited(_learnRelated(extra: t.artists));
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
    unawaited(_learnRelated(extra: [name]));
  }

  void setMode(WaveMode m) {
    if (m == mode) return;
    mode = m;
    if (active) player.replaceUpcoming(more(4));
    _save();
    notifyListeners();
  }

  /// «Не нравится»: убираем трек из волны навсегда и сразу переключаем
  Future<void> dislike() async {
    final t = player.current;
    if (t == null) return;
    taste.disliked.add(t.id);
    for (final a in t.artists) {
      final k = a.toLowerCase();
      taste.bump(k, -1.5);
      _session[k] = (_session[k] ?? 0) - 4;
    }
    _save();
    notifyListeners();
    lib.messages.add('«${t.title}» больше не попадётся в волне');
    await player.next();
  }

  void undislike(String id) {
    if (taste.disliked.remove(id)) {
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
    final tracks = lib.allTracks;
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

  /// Исполнители, которые волне нравятся больше всего (для страницы «Моя волна»)
  List<(String, double)> topArtists([int n = 12]) {
    final aff = WaveEngine.affinity(_inputs());
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
    _save();
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

  // ---------- похожие исполнители из интернета ----------

  Future<void> _learnRelated({List<String> extra = const []}) async {
    if (_learning) return;
    _learning = true;
    try {
      final top = [for (final e in topArtists(8)) e.$1];
      final names = <String>{for (final a in extra) a.toLowerCase(), ...top}.where((k) => !_related.containsKey(k)).take(8);
      for (final key in names) {
        try {
          final name = lib.artist(key)?.name ?? key;
          final a = await web.artist(name, low: true);
          if (a == null) {
            _related[key] = const [];
            continue;
          }
          final rel = await web.related(a.id);
          _related[key] = [for (final r in rel) r.name.toLowerCase()];
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
        'related': _related,
      });
    } catch (e) {
      AppLog.warn('Моя волна: не сохранилось', e);
    }
  }
}
