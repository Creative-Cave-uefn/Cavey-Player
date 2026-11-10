import 'dart:math' as math;

import 'beats.dart' show camelotOf;

// АвтоDJ: какой трек поставить после какого. Идеи из AutoDJ для Mixxx и самого Mixxx:
// • не больше N % разницы в темпе, двойной и половинный темп считаются своими (160 → 80);
// • гармоничное сведение: тональности рядом на круге Camelot звучат вместе, дальние — «рвут» слух;
// • недавно игравшие треки пропускаются;
// • плавная цепочка для плейлиста: каждый следующий трек подходит предыдущему.
// Чистый Dart: ничего не знает ни о плеере, ни о Flutter, поэтому проверяется обычными тестами.

/// Тональность на круге Camelot: цифра 1…12 и буква (A — минор, B — мажор)
class Camelot {
  final int n;
  final bool minor;
  const Camelot(this.n, this.minor);

  @override
  bool operator ==(Object other) => other is Camelot && other.n == n && other.minor == minor;

  @override
  int get hashCode => n * 2 + (minor ? 1 : 0);

  @override
  String toString() => '$n${minor ? 'A' : 'B'}';

  /// Понимает Camelot («8A», «08b»), Open Key («1m», «1d») и обычную запись («Am», «F#m», «Bb», «A minor», «Db major»).
  /// Не получилось разобрать — null
  static Camelot? parse(String? raw) {
    if (raw == null) return null;
    final s = raw.trim().replaceAll('♯', '#').replaceAll('♭', 'b');
    if (s.isEmpty) return null;

    final cam = RegExp(r'^(\d{1,2})\s*([abAB])$').firstMatch(s);
    if (cam != null) {
      final n = int.parse(cam.group(1)!);
      if (n < 1 || n > 12) return null;
      return Camelot(n, cam.group(2)!.toLowerCase() == 'a');
    }

    // Open Key: цифра и буква d (мажор) или m (минор); 1d = C = 8B
    final open = RegExp(r'^(\d{1,2})\s*([dmDM])$').firstMatch(s);
    if (open != null) {
      final n = int.parse(open.group(1)!);
      if (n < 1 || n > 12) return null;
      return Camelot((n + 6) % 12 + 1, open.group(2)!.toLowerCase() == 'm');
    }

    final std = RegExp(r'^([A-Ga-g])\s*([#b]?)\s*(m|min|minor|moll|maj|major|dur)?$', caseSensitive: false).firstMatch(s);
    if (std == null) return null;
    const pitch = {'c': 0, 'd': 2, 'e': 4, 'f': 5, 'g': 7, 'a': 9, 'b': 11};
    var pc = pitch[std.group(1)!.toLowerCase()]!;
    final acc = std.group(2) ?? '';
    if (acc == '#') pc += 1;
    if (acc.toLowerCase() == 'b') pc += 11;
    final mode = (std.group(3) ?? '').toLowerCase();
    final minor = mode == 'm' || mode == 'min' || mode == 'minor' || mode == 'moll';
    return parse(camelotOf(pc % 12, minor));
  }

  /// Насколько тональности [a] и [b] подходят друг другу при сведении, 0…1:
  /// та же — 1; соседи по кругу — 0,85; относительные мажор и минор — 0,9; через одну — 0,5; остальное — плохо
  static double compat(Camelot a, Camelot b) {
    final d = (a.n - b.n).abs();
    final step = math.min(d, 12 - d);
    if (a.minor == b.minor) {
      return switch (step) {
        0 => 1.0,
        1 => 0.85,
        2 => 0.5,
        5 => 0.15,
        _ => 0.0,
      };
    }
    return switch (step) {
      0 => 0.9,
      1 => 0.45,
      _ => 0.0,
    };
  }
}

/// На сколько (долей: 0,05 — это 5 %) надо изменить темп [to], чтобы он совпал с [from].
/// Двойной и половинный темп считаются совпадением: 80 и 160 — одно и то же
double bpmStretch(double from, double to) {
  if (from <= 0 || to <= 0) return double.infinity;
  var best = double.infinity;
  for (final k in const [0.5, 1.0, 2.0]) {
    final d = (to * k / from - 1).abs();
    if (d < best) best = d;
  }
  return best;
}

/// Настройки АвтоDJ
class DjOptions {
  /// Самая большая допустимая разница в темпе (0,25 — 25 %, как в AutoDJ для Mixxx)
  final double maxBpmAdjust;

  /// Учитывать тональность
  final bool harmonic;

  /// Сколько не повторять уже игравшие треки
  final Duration avoidRepeat;

  const DjOptions({this.maxBpmAdjust = 0.25, this.harmonic = true, this.avoidRepeat = const Duration(minutes: 60)});
}

/// Что АвтоDJ знает о треке
class DjSong {
  final String id;

  /// Темп; null — не известен
  final double? bpm;

  /// Тональность; null — не известна
  final Camelot? key;

  /// Громкость тела трека в дБ (шкала автомикса)
  final double? loudDb;

  /// Главный исполнитель в нижнем регистре: одного исполнителя подряд стараемся не ставить
  final String artist;

  const DjSong(this.id, {this.bpm, this.key, this.loudDb, this.artist = ''});

  /// Про трек известно хоть что-то, по чему можно подбирать
  bool get known => bpm != null || key != null;
}

class AutoDj {
  const AutoDj._();

  /// Насколько хорошо [b] идёт после [a], 0…1. Неизвестное темп и тональность считаются нейтральными,
  /// но хуже, чем точное совпадение; известное несовпадение темпа — почти ноль
  static double transition(DjSong a, DjSong b, [DjOptions o = const DjOptions()]) {
    final ab = a.bpm, bb = b.bpm;
    var tempo = 0.55;
    if (ab != null && bb != null) {
      final s = bpmStretch(ab, bb);
      if (s > o.maxBpmAdjust) return 0.02;
      tempo = math.exp(-s / 0.08);
    }
    var key = o.harmonic ? 0.6 : 1.0;
    final ak = a.key, bk = b.key;
    if (o.harmonic && ak != null && bk != null) key = Camelot.compat(ak, bk);
    var energy = 0.8;
    final la = a.loudDb, lb = b.loudDb;
    if (la != null && lb != null) energy = math.exp(-(la - lb).abs() / 8.0);
    return 0.02 + 0.55 * tempo + 0.33 * key + 0.10 * energy;
  }

  /// Следующий трек после [cur]: случайный из лучших по совместимости, чем лучше — тем вероятнее.
  /// [recent] — когда треки играли в последний раз: их пропускаем, пока есть из чего выбирать.
  /// null — выбирать не из чего
  static DjSong? pickNext(DjSong cur, List<DjSong> pool,
      {Map<String, DateTime> recent = const {}, DjOptions options = const DjOptions(), math.Random? rnd, DateTime? now}) {
    final t = now ?? DateTime.now();
    var cands = [for (final s in pool) if (s.id != cur.id) s];
    if (cands.isEmpty) return null;
    final fresh = [
      for (final s in cands)
        if (!_recently(recent[s.id], t, options.avoidRepeat)) s
    ];
    if (fresh.isNotEmpty) cands = fresh;
    final scored = <(DjSong, double)>[];
    for (final s in cands) {
      var v = transition(cur, s, options);
      if (s.artist.isNotEmpty && s.artist == cur.artist) v *= 0.5;
      scored.add((s, v));
    }
    scored.sort((x, y) => y.$2.compareTo(x.$2));
    final top = scored.take(8).toList();
    var total = 0.0;
    for (final e in top) {
      total += e.$2 * e.$2;
    }
    if (total <= 0) return top.first.$1;
    var r = (rnd ?? math.Random()).nextDouble() * total;
    for (final e in top) {
      r -= e.$2 * e.$2;
      if (r <= 0) return e.$1;
    }
    return top.last.$1;
  }

  static bool _recently(DateTime? at, DateTime now, Duration within) => at != null && now.difference(at) < within;

  /// Самый длинный список, который выстраиваем целиком (перебор — квадрат длины); остальное идёт следом как есть
  static const maxChain = 2000;

  /// Выстраивает [songs] в плавную цепочку: каждый следующий подходит предыдущему. Начинает с [startId],
  /// иначе с самого медленного. Треки, про которые ничего не известно, остаются в конце в прежнем порядке.
  /// Результат — id в новом порядке; повторов и потерь нет
  static List<String> chain(List<DjSong> songs, {DjOptions options = const DjOptions(), String? startId}) {
    final known = <DjSong>[], unknown = <DjSong>[];
    for (final s in songs) {
      (s.known ? known : unknown).add(s);
    }
    final head = known.take(maxChain).toList();
    final overflow = known.skip(maxChain).toList();
    final left = List<DjSong>.of(head);
    final out = <DjSong>[];
    if (left.isNotEmpty) {
      var first = left.first;
      final wanted = startId == null ? -1 : left.indexWhere((s) => s.id == startId);
      if (wanted >= 0) {
        first = left[wanted];
      } else {
        for (final s in left) {
          if ((s.bpm ?? 100) < (first.bpm ?? 100)) first = s;
        }
      }
      left.remove(first);
      out.add(first);
    }
    while (left.isNotEmpty) {
      final last = out.last;
      final before = out.length >= 2 ? out[out.length - 2] : null;
      var bestAt = 0;
      var bestScore = -1.0;
      for (var i = 0; i < left.length; i++) {
        final s = left[i];
        var v = transition(last, s, options);
        if (s.artist.isNotEmpty && s.artist == last.artist) v *= 0.5;
        if (before != null && s.artist.isNotEmpty && s.artist == before.artist) v *= 0.85;
        if (v > bestScore) {
          bestScore = v;
          bestAt = i;
        }
      }
      out.add(left.removeAt(bestAt));
    }
    return [for (final s in out) s.id, for (final s in overflow) s.id, for (final s in unknown) s.id];
  }
}

/// Что известно о треке для оценки «похоже ли» без интернета (по тегам, как в LMS, и по тому, где трек лежит)
class SimTrack {
  final String id;

  /// Исполнители в нижнем регистре
  final Set<String> artists;

  /// Ключ альбома
  final String album;
  final int? year;

  /// Жанры и настроения в нижнем регистре
  final Set<String> genres;
  final double? bpm;
  final Camelot? key;

  /// Плейлисты, где трек лежит: если два трека есть в одних плейлистах, их собирал вместе человек
  final Set<String> lists;

  const SimTrack(this.id,
      {this.artists = const {}, this.album = '', this.year, this.genres = const {}, this.bpm, this.key, this.lists = const {}});
}

/// Насколько [a] похож на [b], 0…1: один альбом и исполнитель, общие жанры, плейлисты, эпоха, темп и тональность.
/// Работает без интернета — волна не остаётся без подсказок, когда Last.fm недоступен
double similarity(SimTrack a, SimTrack b) {
  if (a.id == b.id) return 0;
  var s = 0.0;
  if (a.album.isNotEmpty && a.album == b.album) s += 0.5;
  if (a.artists.any(b.artists.contains)) s += 0.4;
  if (a.lists.isNotEmpty && b.lists.isNotEmpty) {
    final shared = a.lists.where(b.lists.contains).length;
    s += math.min(0.5, 0.2 * shared);
  }
  if (a.genres.isNotEmpty && b.genres.isNotEmpty) {
    final inter = a.genres.where(b.genres.contains).length;
    final union = a.genres.length + b.genres.length - inter;
    if (union > 0) s += 0.45 * inter / union;
  }
  final ya = a.year, yb = b.year;
  if (ya != null && yb != null) s += 0.15 * math.max(0.0, 1 - (ya - yb).abs() / 12);
  final ba = a.bpm, bb = b.bpm;
  if (ba != null && bb != null && bpmStretch(ba, bb) <= 0.06) s += 0.08;
  final ka = a.key, kb = b.key;
  if (ka != null && kb != null && Camelot.compat(ka, kb) >= 0.85) s += 0.05;
  return s.clamp(0.0, 1.0).toDouble();
}

/// Насколько трек подходит под настроение по звуку и жанру из тегов, 0…1. Нужна, когда Last.fm недоступен
/// и тегов исполнителя нет. [mood] — id настроения волны, [tags] и [anti] — его слова-подсказки и «антитеги».
/// null — про трек ничего не известно (нет ни темпа, ни громкости, ни тональности, ни жанра)
double? moodFitLocal(String mood, List<String> tags, List<String> anti,
    {double? bpm, Camelot? key, double? loudDb, String genre = ''}) {
  final g = genre.toLowerCase();
  var hits = 0, bad = 0;
  if (g.isNotEmpty) {
    for (final t in tags) {
      if (g.contains(t)) hits++;
    }
    for (final t in anti) {
      if (g.contains(t)) bad++;
    }
  }
  // Энергия 0…1: быстрый и громкий — ближе к 1. Двойной и половинный темп приводим к привычному
  double? tempo;
  if (bpm != null && bpm > 0) {
    var b = bpm;
    while (b > 170) {
      b /= 2;
    }
    while (b < 60) {
      b *= 2;
    }
    tempo = ((b - 70) / 80).clamp(0.0, 1.0).toDouble();
  }
  double? loud;
  if (loudDb != null) loud = ((loudDb + 24) / 12).clamp(0.0, 1.0).toDouble();
  double? energy;
  if (tempo != null && loud != null) {
    energy = (tempo + loud) / 2;
  } else {
    energy = tempo ?? loud;
  }
  if (energy == null && key == null && g.isEmpty) return null;

  final minor = key?.minor;
  double? a;
  switch (mood) {
    case 'energy':
      a = energy;
    case 'calm':
      if (energy != null) a = 1 - energy;
    case 'sad':
      a = (energy != null ? (1 - energy) * 0.6 : 0.3) + (minor == true ? 0.4 : 0.0);
    case 'love':
      if (energy != null) a = ((1 - (energy - 0.4).abs() * 1.6).clamp(0.0, 1.0) * 0.7).toDouble();
    case 'dark':
      a = (minor == true ? 0.55 : 0.1) + (energy != null ? (energy < 0.6 ? 0.25 : 0.0) : 0.1);
    case 'focus':
      if (energy != null) a = ((1 - (energy - 0.45).abs() * 2).clamp(0.0, 1.0) * 0.7).toDouble();
  }
  var v = (a ?? 0.12) * 0.8;
  if (hits > 0) v += math.min(0.6, 0.3 + 0.15 * hits);
  if (bad > 0) v -= 0.5;
  return v.clamp(0.0, 1.0).toDouble();
}
