import 'dart:math' as math;

import 'automix.dart';
import 'dj.dart';
import 'library.dart';
import 'models.dart';
import 'player.dart' show QueueFeeder;
import 'store.dart' show Settings;

// Радио и АвтоDJ без интернета. В LMS радио бесконечно добавляет треки, похожие на то, что стоит в очереди;
// в Mixxx АвтоDJ подбирает следующий трек по темпу и тональности. Здесь обе идеи работают на данных, которые уже есть
// в плеере: теги, плейлисты, жанр и звук из разбора автомикса. Last.fm для этого не нужен.

/// Что плеер знает о каждом треке библиотеки для оценки «похоже ли». Пересобирается, когда меняется библиотека
/// или появляются новые разборы звука
class SimIndex {
  final LibraryController lib;
  final MixAnalyzer? Function() mixer;
  SimIndex(this.lib, this.mixer);

  final Map<String, SimTrack> _tracks = {};
  int _rev = -1;
  int _profiles = -1;

  SimTrack? of(String id) => _tracks[id];

  /// Все треки индекса
  Iterable<SimTrack> get all => _tracks.values;

  /// Пересобирает индекс, если что-то изменилось. Быстро, если нет
  void refresh() {
    final m = mixer();
    final count = m?.profileCount ?? 0;
    if (_rev == lib.revision && _profiles == count && _tracks.isNotEmpty) return;
    _rev = lib.revision;
    _profiles = count;
    final lists = <String, Set<String>>{};
    for (final p in lib.data.playlists) {
      for (final id in p.items) {
        (lists[id] ??= <String>{}).add(p.id);
      }
    }
    _tracks.clear();
    for (final t in lib.allTracks) {
      final pr = m?.profileCached(t.id);
      _tracks[t.id] = SimTrack(
        t.id,
        artists: {for (final a in t.artists) a.toLowerCase()},
        album: t.albumKey,
        year: yearOf(t.year),
        genres: genresOf(pr?.genre ?? ''),
        bpm: pr?.bpm,
        key: Camelot.parse(pr?.key),
        lists: lists[t.id] ?? const {},
      );
    }
  }

  /// Год из тега («2019», «2019-05-01»); null — не указан
  static int? yearOf(String raw) {
    if (raw.length < 4) return null;
    final y = int.tryParse(raw.substring(0, 4));
    return y != null && y > 1900 && y < 2100 ? y : null;
  }

  /// Жанры из строки тега («Rock; Pop», «hip hop/rap»)
  static Set<String> genresOf(String raw) {
    if (raw.isEmpty) return const {};
    return {
      for (final g in raw.toLowerCase().split(RegExp(r'[;,/|]')))
        if (g.trim().length > 1) g.trim()
    };
  }

  /// Трек для АвтоDJ: темп, тональность и громкость из разбора звука
  DjSong song(Track t) {
    final pr = mixer()?.profileCached(t.id);
    return DjSong(t.id,
        bpm: pr?.bpm, key: Camelot.parse(pr?.key), loudDb: pr?.loudDb, artist: t.artists.isEmpty ? '' : t.artists.first.toLowerCase());
  }

  /// Насколько каждый трек библиотеки похож на один из [seeds] (наибольшее значение); только те, где больше [floor]
  Map<String, double> similarTo(Iterable<String> seeds, {double floor = 0.12}) {
    refresh();
    final src = [for (final id in seeds) if (_tracks[id] != null) _tracks[id]!];
    final out = <String, double>{};
    if (src.isEmpty) return out;
    for (final c in _tracks.values) {
      var best = 0.0;
      for (final s in src) {
        final v = similarity(s, c);
        if (v > best) best = v;
      }
      if (best >= floor) out[c.id] = best;
    }
    return out;
  }
}

/// Бесконечная очередь «Радио / АвтоDJ». Два режима:
/// • [radio] = true — треки всей библиотеки, похожие на последние дослушанные (как радио в LMS), с мягким сведением по темпу и тональности;
/// • [radio] = false — только треки из [pool] (плейлист, альбом), без повторов, пока играют остальные; каждый следующий подходит
///   предыдущему по темпу и тональности (как АвтоDJ в Mixxx).
class RadioFeeder implements QueueFeeder {
  final LibraryController lib;
  final SimIndex index;
  final List<String> pool;
  final bool radio;
  final DjOptions options;
  final math.Random _rnd;

  final Map<String, DateTime> _recent = {};
  final Set<String> _skipped = {};
  final List<String> _seeds = [];
  String? _last;

  RadioFeeder(this.lib, this.index,
      {List<String> seed = const [], this.pool = const [], this.radio = false, this.options = const DjOptions(), math.Random? rnd})
      : _rnd = rnd ?? math.Random() {
    _seeds.addAll(seed.skip(seed.length > 3 ? seed.length - 3 : 0));
    if (seed.isNotEmpty) _last = seed.last;
    final now = DateTime.now();
    for (final id in seed) {
      _recent[id] = now;
    }
  }

  @override
  String get label => radio ? 'Далее в радио' : 'Далее в АвтоDJ';

  /// С чего начать: [startId], иначе самый медленный из известных по темпу (так начинают сеты), иначе первый
  List<String> begin({String? startId, int count = 4}) {
    final ids = _ids();
    if (ids.isEmpty) return const [];
    index.refresh();
    String? first = startId != null && ids.contains(startId) ? startId : null;
    if (first == null) {
      double? slow;
      for (final id in ids) {
        final t = lib.data.tracks[id];
        if (t == null) continue;
        final b = index.song(t).bpm;
        if (b != null && (slow == null || b < slow)) {
          slow = b;
          first = id;
        }
      }
      first ??= ids.first;
    }
    _recent[first] = DateTime.now();
    _last = first;
    return [first, ...more(count - 1)];
  }

  List<String> _ids() => pool.isNotEmpty
      ? [for (final id in pool) if (lib.data.tracks[id] != null) id]
      : [for (final t in lib.allTracks) t.id];

  @override
  List<String> more(int n) {
    final ids = _ids();
    if (ids.isEmpty || n <= 0) return const [];
    index.refresh();
    final out = <String>[];
    // Сходство со «вкусом» считаем один раз на всю выдачу: на большой библиотеке это самое дорогое
    final sims = radio ? index.similarTo(_seeds.isEmpty && _last != null ? [_last!] : _seeds) : const <String, double>{};
    for (var i = 0; i < n; i++) {
      final next = _pick(ids, sims);
      if (next == null) break;
      out.add(next);
      _recent[next] = DateTime.now();
      _last = next;
    }
    return out;
  }

  String? _pick(List<String> ids, Map<String, double> sims) {
    final curTrack = _last == null ? null : lib.data.tracks[_last!];
    final cur = curTrack == null ? null : index.song(curTrack);
    final now = DateTime.now();
    bool fresh(String id) {
      final at = _recent[id];
      return id != _last && !_skipped.contains(id) && (at == null || now.difference(at) >= options.avoidRepeat);
    }

    var cands = [for (final id in ids) if (fresh(id)) id];
    // Всё уже играло: в маленьком плейлисте начинаем заново, но не тот же трек подряд
    if (cands.isEmpty) cands = [for (final id in ids) if (id != _last) id];
    if (cands.isEmpty) return null;

    if (!radio) {
      final songs = <DjSong>[
        for (final id in cands)
          if (lib.data.tracks[id] != null) index.song(lib.data.tracks[id]!)
      ];
      if (cur == null) return songs.isEmpty ? null : songs[_rnd.nextInt(songs.length)].id;
      return AutoDj.pickNext(cur, songs, recent: _recent, options: options, rnd: _rnd, now: now)?.id;
    }

    // Радио: сперва самые похожие на недавно дослушанное, потом из них — те, что лучше сводятся с играющим
    final scored = <(String, double)>[
      for (final id in cands)
        if ((sims[id] ?? 0) > 0) (id, sims[id]!)
    ]..sort((a, b) => b.$2.compareTo(a.$2));
    var top = scored.take(40).toList();
    if (top.length < 8) {
      // Похожих мало (теги не заполнены, плейлистов нет): добавляем случайные, чтобы радио не зацикливалось на горстке
      final extra = List<String>.of(cands)..shuffle(_rnd);
      for (final id in extra) {
        if (top.length >= 20) break;
        if (!top.any((e) => e.$1 == id)) top.add((id, 0.02));
      }
    }
    final weights = <double>[];
    for (final e in top) {
      var s = e.$2;
      final t = lib.data.tracks[e.$1];
      if (cur != null && t != null) s = 0.55 * s + 0.45 * AutoDj.transition(cur, index.song(t), options);
      if (t != null && curTrack != null && t.artists.isNotEmpty && curTrack.artists.isNotEmpty && t.artists.first == curTrack.artists.first) s *= 0.5;
      weights.add(s * s);
    }
    var total = 0.0;
    for (final w in weights) {
      total += w;
    }
    if (total <= 0) return top[_rnd.nextInt(top.length)].$1;
    var r = _rnd.nextDouble() * total;
    for (var i = 0; i < top.length; i++) {
      r -= weights[i];
      if (r <= 0) return top[i].$1;
    }
    return top.last.$1;
  }

  @override
  void heard(Track t, Duration listened, {required bool skipped}) {
    if (skipped && listened < const Duration(seconds: 30)) {
      _skipped.add(t.id); // пропустили сразу — в этой сессии не повторяем
      return;
    }
    _seeds.remove(t.id);
    _seeds.add(t.id);
    while (_seeds.length > 3) {
      _seeds.removeAt(0);
    }
  }
}

/// Настройки АвтоDJ из личных настроек: самая большая разница темпа, гармоничное сведение, сколько не повторять треки
DjOptions djOptionsOf(Settings s) => DjOptions(
      maxBpmAdjust: (s.viewNum('dj.bpm', 25) / 100).clamp(0.05, 0.5).toDouble(),
      harmonic: s.viewOf('dj.key', '1') == '1',
      avoidRepeat: Duration(minutes: s.viewNum('dj.avoid', 60).clamp(0, 600).round()),
    );
