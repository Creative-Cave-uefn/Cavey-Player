import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding;

import 'dj.dart';
import 'dl/service.dart';
import 'intel/service.dart' show IntelService;
import 'lastfm.dart';
import 'library.dart';
import 'log.dart';
import 'models.dart';
import 'player.dart';
import 'radio.dart';
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

/// Настроение волны: набор тегов Last.fm, по которым узнаём подходящих исполнителей
class WaveMood {
  final String id;
  final String title;
  final List<String> tags;

  /// «Антитеги»: если они есть у исполнителя или песни, под это настроение она не подходит
  /// (саундтрек к игре на романтику, тяжёлый метал на спокойное и т. п.)
  final List<String> anti;
  const WaveMood(this.id, this.title, this.tags, [this.anti = const []]);

  /// Оценка по тегам (тег → вес 0..1): плюс за теги настроения, минус за антитеги.
  /// Теги слабее 0,1 — шум (у любого исполнителя найдётся «love» с парой голосов), их не считаем.
  /// Больше 0 — подходит, 0 — теги есть, но про другое, меньше 0 — явно не то
  double raw(Map<String, double> have) {
    double sum(List<String> list) {
      var v = 0.0;
      for (final t in list) {
        final w = have[t] ?? 0;
        if (w >= 0.1) v += w;
      }
      return v;
    }

    return (sum(tags) - sum(anti)) * 1.5;
  }
}

const waveMoods = [
  WaveMood('energy', 'Бодрое', ['energetic', 'upbeat', 'workout', 'party', 'dance', 'hype', 'gym', 'driving', 'drum and bass'],
      ['sleep', 'lullaby', 'slowcore', 'sad', 'sadcore', 'ambient']),
  WaveMood('calm', 'Спокойное', ['chill', 'chillout', 'calm', 'relax', 'relaxing', 'mellow', 'ambient', 'downtempo', 'lo-fi', 'lofi'],
      ['metal', 'death metal', 'hardcore', 'screamo', 'hardstyle', 'noise', 'drum and bass', 'punk']),
  WaveMood('sad', 'Грустное', ['sad', 'melancholic', 'melancholy', 'depressive', 'emotional', 'heartbreak', 'sadcore', 'depressing'],
      ['party', 'dance', 'happy', 'upbeat', 'funny', 'comedy']),
  WaveMood('love', 'Романтичное', ['romantic', 'love', 'sensual', 'sexy', 'love songs', 'r&b', 'rnb'],
      ['soundtrack', 'ost', 'video game music', 'game', 'anime', 'chiptune', 'metal', 'death metal', 'hardcore', 'punk', 'noise', 'screamo']),
  WaveMood('dark', 'Мрачное', ['dark', 'gloomy', 'atmospheric', 'darkwave', 'phonk', 'witch house', 'post-punk'],
      ['happy', 'cute', 'kawaii', 'children', 'party', 'upbeat']),
  WaveMood('focus', 'Для фокуса', ['instrumental', 'focus', 'study', 'concentration', 'beats', 'instrumental hip-hop', 'post-rock'],
      ['party', 'metal', 'screamo', 'hardcore', 'noise']),
];

WaveMood? moodById(String? id) => waveMoods.where((m) => m.id == id).firstOrNull;

/// Что волна узнала о вкусе. Хранится только на этом компьютере
class WaveTaste {
  /// Ключ исполнителя (в нижнем регистре) → симпатия: растёт от дослушиваний, падает от пропусков
  final Map<String, double> artists = {};

  // Минусы привязаны к «контексту» волны: '' — обычная, 'custom' — своя подборка, иначе id настроения.
  // Так «не люблю эмо-рэп» из обычной волны не мешает в «мрачном» настроении, где он как раз к месту.
  // И всё забывается: человек меняется, а один пропуск в плохой день не должен хоронить трек навсегда.

  /// «Не нравится»: эти треки волна не ставит — в том контексте, где их отметили, и [dislikeTtl]
  final Set<String> disliked = {};

  /// Где и когда отметили «не нравится»; нет записи — считаем, что в обычной волне и без срока
  final Map<String, (String, DateTime)> dislikedMeta = {};

  static const dislikeTtl = Duration(days: 30);
  static const skipTtl = Duration(days: 21);

  bool isDisliked(String id, String ctx) => disliked.contains(id) && (dislikedMeta[id]?.$1 ?? '') == ctx;

  void dislike(String id, String ctx, [DateTime? now]) {
    disliked.add(id);
    dislikedMeta[id] = (ctx, now ?? DateTime.now());
  }

  bool undislike(String id) {
    dislikedMeta.remove(id);
    return disliked.remove(id);
  }

  /// Сколько раз трек пропустили в первые 30 секунд — в обычной волне (контекст '')
  final Map<String, int> skips = {};

  /// То же в волнах с настроением или своей подборкой: контекст → трек → пропуски
  final Map<String, Map<String, int>> ctxSkips = {};

  /// Когда трек пропускали в последний раз: ключ «контекст|трек». По сроку [skipTtl] пропуски забываются
  final Map<String, DateTime> skipAt = {};

  Map<String, int> skipsIn(String ctx) => ctx.isEmpty ? skips : (ctxSkips[ctx] ?? const {});
  int skipsOf(String id, String ctx) => skipsIn(ctx)[id] ?? 0;

  void addSkip(String id, String ctx, [DateTime? now]) {
    final m = ctx.isEmpty ? skips : ctxSkips.putIfAbsent(ctx, () => {});
    m[id] = (m[id] ?? 0) + 1;
    skipAt['$ctx|$id'] = now ?? DateTime.now();
  }

  /// Дослушали — один пропуск прощается
  void forgiveSkip(String id, String ctx) {
    final m = ctx.isEmpty ? skips : ctxSkips[ctx];
    final s = m?[id];
    if (m == null || s == null) return;
    if (s <= 1) {
      m.remove(id);
      skipAt.remove('$ctx|$id');
    } else {
      m[id] = s - 1;
    }
  }

  /// Минусы исполнителям по контекстам (всегда ≤ 0). Остывают быстрее плюсов
  final Map<String, Map<String, double>> neg = {};
  Map<String, double> negFor(String ctx) => neg[ctx] ?? const {};

  /// Д8: треки, которые когда-либо слушали дольше 30 секунд (длинная память для «Незнакомого»)
  final Set<String> heard = {};

  void markHeard(String id) {
    heard.remove(id);
    heard.add(id);
    while (heard.length > 6000) {
      heard.remove(heard.first);
    }
  }

  /// «Нравится в волне»: трек не сохраняется в любимое, но волна ищет от него похожие
  final Set<String> upvoted = {};

  /// Исполнитель и название понравившихся в волне: живут, даже если пробный трек потом удалился
  final List<(String, String)> seeds = [];

  void addSeed(String artist, String title) {
    seeds.removeWhere((x) => x.$1 == artist && x.$2 == title);
    seeds.add((artist, title));
    if (seeds.length > 40) seeds.removeAt(0);
  }

  /// Когда в последний раз применялось затухание
  DateTime? decayedAt;

  /// Д2: симпатии без новых сигналов остывают — ×0,98 за каждый прошедший день
  void decay([DateTime? now]) {
    now ??= DateTime.now();
    _expire(now);
    final last = decayedAt;
    if (last == null) {
      decayedAt = now;
      return;
    }
    final days = now.difference(last).inDays;
    if (days < 1) return;
    final k = pow(0.98, days).toDouble();
    artists.updateAll((_, v) => v * k);
    artists.removeWhere((_, v) => v.abs() < 0.05);
    // Минусы остывают заметно быстрее плюсов: ×0,92 в день, то есть вдвое примерно за неделю
    final kn = pow(0.92, days).toDouble();
    for (final m in neg.values) {
      m.updateAll((_, v) => v * kn);
      m.removeWhere((_, v) => v.abs() < 0.05);
    }
    neg.removeWhere((_, m) => m.isEmpty);
    decayedAt = last.add(Duration(days: days));
  }

  /// Забываем старые «не нравится» и пропуски
  void _expire(DateTime now) {
    dislikedMeta.removeWhere((id, m) {
      if (now.difference(m.$2) <= dislikeTtl) return false;
      disliked.remove(id);
      return true;
    });
    skipAt.removeWhere((key, at) {
      if (now.difference(at) <= skipTtl) return false;
      final i = key.indexOf('|');
      final ctx = i < 0 ? '' : key.substring(0, i);
      final m = ctx.isEmpty ? skips : ctxSkips[ctx];
      m?.remove(key.substring(i + 1));
      return true;
    });
    ctxSkips.removeWhere((_, m) => m.isEmpty);
  }

  /// Плюс идёт в общую симпатию к исполнителю, минус — только в симпатию в контексте [ctx]
  void bump(String artist, double by, {String ctx = ''}) {
    if (by < 0) {
      final m = neg.putIfAbsent(ctx, () => {});
      final v = ((m[artist] ?? 0) + by).clamp(-10.0, 0.0).toDouble();
      if (v.abs() < 0.05) {
        m.remove(artist);
      } else {
        m[artist] = v;
      }
      return;
    }
    final v = ((artists[artist] ?? 0) + by).clamp(-10.0, 20.0).toDouble();
    if (v.abs() < 0.05) {
      artists.remove(artist);
    } else {
      artists[artist] = v;
    }
  }

  Map<String, dynamic> toJson() => {
        'artists': artists.map((k, v) => MapEntry(k, double.parse(v.toStringAsFixed(2)))),
        'neg': {
          for (final e in neg.entries)
            if (e.value.isNotEmpty) e.key: e.value.map((k, v) => MapEntry(k, double.parse(v.toStringAsFixed(2)))),
        },
        'disliked': disliked.toList(),
        'dislikedMeta': {for (final e in dislikedMeta.entries) e.key: [e.value.$1, e.value.$2.toUtc().toIso8601String()]},
        'skips': skips,
        'ctxSkips': ctxSkips,
        'skipAt': {for (final e in skipAt.entries) e.key: e.value.toUtc().toIso8601String()},
        'upvoted': upvoted.toList(),
        'seeds': [for (final x in seeds) [x.$1, x.$2]],
        'heard': heard.toList(),
        if (decayedAt != null) 'decayedAt': decayedAt!.toUtc().toIso8601String(),
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
    for (final x in (j['upvoted'] as List? ?? const [])) {
      t.upvoted.add('$x');
    }
    for (final x in (j['seeds'] as List? ?? const [])) {
      if (x is List && x.length >= 2) t.seeds.add(('${x[0]}', '${x[1]}'));
    }
    for (final x in (j['heard'] as List? ?? const [])) {
      t.heard.add('$x');
    }
    t.decayedAt = DateTime.tryParse('${j['decayedAt'] ?? ''}');
    final n = j['neg'];
    if (n is Map) {
      n.forEach((c, m) {
        if (m is Map) t.neg['$c'] = {for (final e in m.entries) '${e.key}': (e.value as num?)?.toDouble() ?? 0};
      });
    }
    final cs = j['ctxSkips'];
    if (cs is Map) {
      cs.forEach((c, m) {
        if (m is Map) t.ctxSkips['$c'] = {for (final e in m.entries) '${e.key}': (e.value as num?)?.toInt() ?? 0};
      });
    }
    final sa = j['skipAt'];
    if (sa is Map) {
      sa.forEach((k, v) {
        final at = DateTime.tryParse('$v');
        if (at != null) t.skipAt['$k'] = at;
      });
    }
    final dm = j['dislikedMeta'];
    if (dm is Map) {
      dm.forEach((k, v) {
        final at = v is List && v.length >= 2 ? DateTime.tryParse('${v[1]}') : null;
        if (at != null) t.dislikedMeta['$k'] = ('${(v as List)[0]}', at);
      });
    }
    // Данные старого формата: у «не нравится» и пропусков не было ни контекста, ни срока.
    // Считаем их данными обычной волны и даём обычный срок жизни от сегодняшнего дня
    final now = DateTime.now();
    for (final id in t.disliked) {
      t.dislikedMeta.putIfAbsent(id, () => ('', now));
    }
    t.skips.forEach((id, _) => t.skipAt.putIfAbsent('|$id', () => now));
    t.ctxSkips.forEach((c, m) => m.forEach((id, _) => t.skipAt.putIfAbsent('$c|$id', () => now)));
    // Раньше минусы исполнителям лежали вместе с плюсами и действовали во всех волнах.
    // Переносим их в обычную волну, где они остынут быстро
    for (final k in t.artists.keys.toList()) {
      final v = t.artists[k]!;
      if (v >= 0) continue;
      t.artists.remove(k);
      final m = t.neg.putIfAbsent('', () => {});
      m[k] = min(m[k] ?? 0, v.clamp(-10.0, 0.0).toDouble());
    }
    t.decay();
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
  final Map<String, double> boost; // трек → насколько он похож на недавно дослушанные (0..1, по Last.fm и по звуку)
  final Map<String, double> audioNeg; // трек → насколько он по звуку похож на недавно пропущенные (0..1)
  final Set<String> focus; // своя подборка: только эти исполнители и похожие на них (пусто — все)
  final Map<String, double>? mood; // выбрано настроение: трек → насколько подходит (0..1)
  final Map<String, double> bpm; // известный темп треков (Д6)
  final double? curBpm; // темп играющего сейчас трека
  final Map<String, Camelot> keys; // тональность треков по разбору звука (АвтоDJ)
  final Camelot? curKey; // тональность играющего сейчас трека

  /// Контекст волны: '' — обычная, 'custom' — своя подборка, иначе id настроения.
  /// Бан, пропуски и минусы исполнителям действуют только в том контексте, где их поставили
  final String ctx;

  /// Во сколько раз лайки весят больше обычного. 1 — как всегда; в режиме настройки — больше
  final double likeBoost;

  WaveInputs({
    this.ctx = '',
    this.likeBoost = 1.0,
    required this.tracks,
    this.liked = const {},
    this.myPlays = const {},
    this.crowd = const {},
    this.favArtists = const {},
    this.related = const {},
    WaveTaste? taste,
    this.session = const {},
    this.boost = const {},
    this.audioNeg = const {},
    this.focus = const {},
    this.mood,
    this.bpm = const {},
    this.curBpm,
    this.keys = const {},
    this.curKey,
  }) : taste = taste ?? WaveTaste();
}

class WaveEngine {
  /// С какой похожести трек считается «похожим» для отдельного слота
  static const similarFloor = 0.15;

  /// Доля треков из похожих, когда они есть
  static const similarShare = 0.65;

  /// Сколько последних треков помнить, чтобы не ставить того же исполнителя слишком часто
  static const artistGap = 3;

  /// Насколько выбор тянется к лучшим трекам: веса возводятся в эту степень.
  /// 1 — чистая лотерея по весам; больше — меньше случайных «мимо», но и меньше неожиданного
  static const focusPower = 1.35;

  /// Симпатия к каждому исполнителю: лайки, прослушивания, «любимые», то, что волна выучила, и похожие
  static Map<String, double> affinity(WaveInputs x) {
    final a = <String, double>{};
    void add(String k, double v) => a[k] = (a[k] ?? 0) + v;
    for (final t in x.tracks) {
      final w = (x.liked.contains(t.id) ? 3.0 * x.likeBoost : 0.0) + min(x.myPlays[t.id] ?? 0, 6) * 0.7;
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
    x.taste.negFor(x.ctx).forEach(add);
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
    final fresh = fam == 0 && !liked && !x.taste.heard.contains(t.id); // Д8: слышал когда-то — уже не новое
    var w = switch (mode) {
      WaveMode.mix => 0.4 + 2.0 * aN + (liked ? 1.0 * x.likeBoost : 0) + 0.6 * pop + (fresh ? 0.4 : 0),
      WaveMode.favorite => 0.1 + 1.6 * aN + (liked ? 2.5 * x.likeBoost : 0) + 0.15 * min(fam, 6),
      WaveMode.unfamiliar => fresh ? 0.4 + 2.2 * aN + 0.6 * pop : 0.003,
      WaveMode.popular => 0.1 + 3.0 * pop + 0.8 * aN + (liked ? 0.3 * x.likeBoost : 0),
    };
    // Похож на то, что вы только что дослушали, — держим настроение
    w *= 1 + 2.5 * (x.boost[t.id] ?? 0);
    // Звучит как то, что только что пропустили, — слегка отодвигаем (не больше чем вдвое)
    final an = x.audioNeg[t.id];
    if (an != null) w *= 1 - 0.5 * min(0.6, an) / 0.6;
    // Своя подборка исполнителей: остальные почти не звучат
    if (x.focus.isNotEmpty && !t.artists.any((a) => x.focus.contains(a.toLowerCase()))) w *= 0.04;
    // Настроение: неподходящие треки отходят далеко на второй план
    final mood = x.mood;
    if (mood != null) w *= 0.08 + 2.5 * (mood[t.id] ?? 0);
    // Д6: резкий скачок темпа относительно играющего трека слегка штрафуем (двойной/половинный темп — не скачок)
    final cb = x.curBpm, tb = x.bpm[t.id];
    if (cb != null && tb != null && cb > 0 && tb > 0) {
      var r = log(tb / cb) / ln2; // в октавах
      r = (r - r.roundToDouble()).abs() < r.abs() ? r - r.roundToDouble() : r;
      w *= 1 - min(0.35, r.abs() * 0.5);
    }
    // Тональность по кругу Camelot: рядом — слегка поощряем, далеко — слегка штрафуем (как в АвтоDJ)
    final ck = x.curKey, tk = x.keys[t.id];
    if (ck != null && tk != null) w *= 0.8 + 0.4 * Camelot.compat(ck, tk);
    if (x.taste.upvoted.contains(t.id)) w *= 1.6;
    w *= pow(0.45, x.taste.skipsOf(t.id, x.ctx));
    return max(w, 0.002);
  }

  /// Следующие [n] треков. [recent] — что уже звучало или стоит в очереди: их не повторяем,
  /// пока в библиотеке есть из чего выбрать. Один исполнитель два раза подряд — только если больше некого.
  static List<String> pick(WaveInputs x, WaveMode mode, int n,
      {List<String> recent = const [], Random? rnd, int sinceWide = 0}) {
    rnd ??= Random();
    final pool = [for (final t in x.tracks) if (!x.taste.isDisliked(t.id, x.ctx)) t];
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
    final weights = [for (final t in cands) pow(_score(t, x, mode, aff, maxCrowd), focusPower).toDouble()];

    // Исполнители последних треков: самый последний — сильный штраф, два-три назад — послабее.
    // Так один исполнитель не идёт не только подряд, но и через трек
    final byId = {for (final t in x.tracks) t.id: t};
    final lately = <Set<String>>[
      for (final id in recent.reversed.take(artistGap))
        if (byId[id] case final t?) {for (final a in t.artists) a.toLowerCase()},
    ];
    double spacing(Track t) {
      for (var j = 0; j < lately.length; j++) {
        if (t.artists.any((a) => lately[j].contains(a.toLowerCase()))) return j == 0 ? 0.25 : 0.25 + 0.25 * j;
      }
      return 1;
    }

    final out = <String>[];
    final taken = List<bool>.filled(cands.length, false);
    final hasSimilar = cands.any((t) => (x.boost[t.id] ?? 0) >= similarFloor);
    for (var k = 0; k < n && out.length < cands.length; k++) {
      // Примерно два трека из трёх — из похожих на недавно дослушанные, если такие есть.
      // Иначе похожие тонут среди тысячи остальных треков библиотеки
      // Д7: каждый 5-й трек — из другого круга; и если последние 5 были все «похожие», слот ослабляем
      final wideSlot = (sinceWide + k + 1) % 5 == 0;
      final last5 = recent.length >= 5 ? recent.sublist(recent.length - 5) : const <String>[];
      final stuck = last5.length == 5 && last5.every((id) => (x.boost[id] ?? 0) >= similarFloor);
      final onlySimilar = hasSimilar && !wideSlot && !stuck && rnd.nextDouble() < similarShare;
      var total = 0.0;
      final eff = List<double>.filled(cands.length, 0);
      for (final restrict in onlySimilar ? [true, false] : [false]) {
        total = 0;
        for (var i = 0; i < cands.length; i++) {
          eff[i] = 0;
          if (taken[i]) continue;
          if (restrict && (x.boost[cands[i].id] ?? 0) < similarFloor) continue;
          final w = weights[i] * spacing(cands[i]);
          eff[i] = w;
          total += w;
        }
        if (total > 0) break;
      }
      if (total <= 0) break;
      var r = rnd.nextDouble() * total;
      var chosen = -1;
      for (var i = 0; i < cands.length; i++) {
        if (eff[i] <= 0) continue;
        r -= eff[i];
        chosen = i;
        if (r <= 0) break;
      }
      if (chosen < 0) break;
      taken[chosen] = true;
      out.add(cands[chosen].id);
      lately.insert(0, {for (final a in cands[chosen].artists) a.toLowerCase()});
      if (lately.length > artistGap) lately.removeLast();
    }
    return out;
  }
}

/// Трек, который волна скачала на пробу
class WaveTrial {
  final String id; // id файла на Диске
  final String key; // «исполнитель|название» — чтобы не скачать его снова после удаления
  final DateTime at; // когда загружен
  DateTime? until; // до какого времени живёт; дослушанный целиком трек продлевается (Д10)
  WaveTrial(this.id, this.key, this.at, {this.until});

  DateTime get expires => until ?? at.add(waveTrialTime);

  Map<String, dynamic> toJson() =>
      {'id': id, 'k': key, 'at': at.toUtc().toIso8601String(), if (until != null) 'until': until!.toUtc().toIso8601String()};
  static WaveTrial? fromJson(dynamic j) {
    if (j is! Map) return null;
    final at = DateTime.tryParse('${j['at']}');
    if (at == null || j['id'] == null) return null;
    return WaveTrial('${j['id']}', '${j['k'] ?? ''}', at, until: DateTime.tryParse('${j['until'] ?? ''}'));
  }
}

/// Кандидат в новинки: что качать
class _Fresh {
  final String artist, title;
  final String? link; // ссылка Deezer, если нашлась; иначе ищем по названию
  _Fresh(this.artist, this.title, this.link);
  String get key => LibraryController.dupKey(artist, title);
}

/// Сколько живёт скачанный волной трек, если его никто не сохранил
const waveTrialTime = Duration(hours: 24);

/// На сколько дней продлевается трек, который дослушали до конца
const waveTrialExtended = Duration(days: 7);

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
  final LastFm lastfm;

  WaveTaste taste = WaveTaste();
  WaveMode mode = WaveMode.mix;
  final Map<String, double> _session = {};
  final List<String> _recent = [];
  final Map<String, List<String>> _related = {}; // исполнитель → похожие исполнители
  final Map<String, double> _boost = {}; // трек библиотеки → похожесть на недавно дослушанные
  final Map<String, double> _audioNeg = {}; // трек библиотеки → похожесть по звуку на недавно пропущенные

  /// Признаки звука (если подключены): по ним волна находит треки, звучащие как дослушанные, и обходит звучащие как пропущенные.
  /// Без них или без разбора у части треков волна работает как раньше
  IntelService? intel;
  final List<String> _good = []; // недавно дослушанные треки: от них ищем похожие
  Timer? _saveTimer;
  Timer? _sweepTimer;
  bool _learning = false;
  int _sinceWide = 0; // Д7: сколько треков прошло с последнего «из другого круга»
  String? _lastTrack;

  /// Сколько треков библиотеки похожи на текущий (для страницы волны)
  int similarInLibrary = 0;

  // ---------- настроение и своя подборка ----------

  /// Выбранное настроение (id из [waveMoods]) или null — любое
  String? mood;

  /// Своя подборка исполнителей: волна держится их и похожих на них
  final List<String> custom = [];

  /// Теги исполнителей из Last.fm: ключ исполнителя → тег → вес
  final Map<String, Map<String, double>> _tags = {};
  bool _tagging = false;
  final Map<String, double> _bpms = {}; // Д6: id трека → темп, узнаётся по мере прослушивания
  final Map<String, Map<String, double>> _trackTags = {}; // Д5: id трека → тег → вес
  final Set<String> _trackTagsAsked = {};
  int tagsKnown = 0, tagsTotal = 0;

  // ---------- новинки ----------

  // ---------- режим настройки ----------

  /// Отдельный режим для быстрой настройки волны (включается в Настройках → «Не лезь — убьёт»).
  /// Пропуск ничего не штрафует: ни трек, ни исполнителя, ни пробный файл. Лайки, «нравится» и дослушивания
  /// весят в [tuningBoost] раза больше, поэтому вкус схватывается за несколько треков.
  /// Явное «не нравится» работает как всегда: это осознанное нажатие
  bool tuning = false;
  static const tuningBoost = 1.5;

  double get _tuneK => tuning ? tuningBoost : 1.0;

  void setTuning(bool on) {
    if (tuning == on) return;
    tuning = on;
    AppLog.info('Моя волна: режим настройки ${on ? 'включён' : 'выключен'}');
    _save();
    notifyListeners();
    if (active) player.refillFeed(keep: (id) => trials.containsKey(id));
  }

  /// Качать новые треки в волну
  bool discover = true;

  /// Не больше стольких новых треков в день: защищает Диск (Д15: 25 / 50 / 100, по умолчанию 50)
  int dailyLimit = 50;
  static const dailyLimits = [25, 50, 100];

  void setDailyLimit(int v) {
    if (!dailyLimits.contains(v) || v == dailyLimit) return;
    dailyLimit = v;
    _save();
    notifyListeners();
    _maybeDiscover();
  }
  final Map<String, WaveTrial> trials = {};
  final Set<String> _rejected = {}; // удалённые после пробы — не качаем снова
  String _day = '';
  int _today = 0;
  int _sinceFresh = 0; // сколько треков прошло после последнего нового
  int _pending = 0; // загрузок в работе
  String discoverStatus = '';

  WaveService._(this.store, this.lib, this.player, this.social, this.web, this.downloads, this.lastfm);

  static Future<WaveService> open(AppStore store, LibraryController lib, PlayerController player, SocialController social,
      WebInfoService web, DownloadService downloads) async {
    final w = WaveService._(store, lib, player, social, web, downloads, LastFm(store));
    try {
      final j = await store.readJson('wave.json');
      if (j is Map) {
        w.taste = WaveTaste.fromJson(j['taste']);
        w.mode = WaveMode.values.firstWhere((m) => m.name == j['mode'], orElse: () => WaveMode.mix);
        for (final x in (j['recent'] as List? ?? const [])) {
          w._recent.add('$x');
        }
        final rel = j['similarArtists'];
        if (rel is Map) rel.forEach((k, v) => w._related['$k'] = [for (final x in (v as List? ?? const [])) '$x']);
        w.discover = j['discover'] != false;
        w.tuning = j['tuning'] == true;
        final dl = (j['dailyLimit'] as num?)?.toInt();
        if (dl != null && WaveService.dailyLimits.contains(dl)) w.dailyLimit = dl;
        for (final x in (j['trials'] as List? ?? const [])) {
          final t = WaveTrial.fromJson(x);
          if (t != null) w.trials[t.id] = t;
        }
        for (final x in (j['rejected'] as List? ?? const [])) {
          if (x is String && x.isNotEmpty) w._rejected.add(x);
        }
        w.mood = moodById(j['mood'] as String?)?.id;
        for (final x in (j['custom'] as List? ?? const [])) {
          w.custom.add('$x');
        }
        final tg = j['artistTags'];
        if (tg is Map) {
          // До версии 2 любой сбой Last.fm (таймаут, 5xx) записывался как «тегов нет». Отличить такие записи
          // от настоящих нельзя, поэтому один раз выбрасываем все пустые — спросим заново
          final fixed = j['tagsV'] == 2;
          tg.forEach((k, v) {
            if (v is! Map || (!fixed && v.isEmpty)) return;
            w._tags['$k'] = v.map((t, x) => MapEntry('$t', (x as num?)?.toDouble() ?? 0));
          });
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
    lib.addListener(w._markInputsDirty);
    social.addListener(w._markInputsDirty);
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
      if (!active) cleanup(); // Д16: сессия волны закончилась
    }
    // Новый трек в волне: сразу ищем похожие на него и пересобираем то, что после следующего
    final cur = player.current;
    if (active && cur != null && cur.id != _lastTrack) {
      _lastTrack = cur.id;
      unawaited(_onTrackStart(cur));
    } else if (!active) {
      _lastTrack = null;
    }
  }

  Future<void> _onTrackStart(Track t) async {
    // Д6: темп играющего трека нужен, чтобы следующие не отличались резко
    if (!_bpms.containsKey(t.id)) {
      unawaited(web.bpm(t.artists.first, t.title).then((b) {
        if (b != null) _bpms[t.id] = b;
      }, onError: (Object _) {}));
    }
    if (mood != null) unawaited(_loadTags());
    final found = await _learnFrom(t);
    if (!active || player.current?.id != t.id) return;
    // То же без интернета: по тегам, плейлистам, жанру, темпу и тональности. Работает, даже когда Last.fm недоступен
    final local = _learnLocal(t);
    if (found + local > 0) player.refillFeed(keep: (id) => trials.containsKey(id));
    // В библиотеке почти нет похожих — значит, их надо скачать, не дожидаясь очереди
    if (found < 3) _maybeDiscover(force: true);
    notifyListeners();
  }

  // ---------- запуск ----------

  Future<void> start([WaveMode? m]) async {
    cleanup(); // Д16: чистка в начале каждой сессии
    if (m != null) mode = m;
    _session.clear();
    _boost.clear();
    _audioNeg.clear();
    _applyCustom();
    // Понравившееся в волне раньше — сразу ориентир для похожих
    final seeds = List.of(taste.seeds)..shuffle();
    for (final (a, ti) in seeds.take(2)) {
      await _learnFromName(a, ti, wait: const Duration(seconds: 2), decay: false);
    }
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
    _boost.clear();
    _audioNeg.clear();
    custom.clear();
    await _learnFrom(t, wait: const Duration(seconds: 3)); // похожие на него — сразу в первую очередь
    _lastTrack = t.id;
    await player.playFeed(this, [t.id, ...more(3)]);
    _save();
    notifyListeners();
    unawaited(_learnRadio(extra: t.artists));
  }

  /// Волна по исполнителю — это своя подборка из одного исполнителя
  Future<void> startFromArtist(String name) async {
    custom
      ..clear()
      ..add(name);
    await start();
  }

  // ---------- своя подборка ----------

  void addCustom(String name) {
    final n = name.trim();
    if (n.isEmpty || custom.any((c) => c.toLowerCase() == n.toLowerCase())) return;
    custom.add(n);
    _customChanged();
  }

  void removeCustom(String name) {
    custom.removeWhere((c) => c.toLowerCase() == name.toLowerCase());
    _customChanged();
  }

  void clearCustom() {
    custom.clear();
    _customChanged();
  }

  void _customChanged() {
    _save();
    notifyListeners();
    unawaited(() async {
      await _learnRadio(extra: custom, force: true);
      _applyCustom();
      if (active) player.refillFeed(keep: (id) => trials.containsKey(id));
      notifyListeners();
    }());
  }

  /// Свои исполнители и похожие на них — главный круг; сами они звучат чаще
  Set<String> get _focus {
    if (custom.isEmpty) return const {};
    final out = <String>{};
    for (final c in custom) {
      final k = c.toLowerCase();
      out.add(k);
      out.addAll((_related[k] ?? const <String>[]).take(12));
    }
    return out;
  }

  void _applyCustom() {
    for (final c in custom) {
      _session[c.toLowerCase()] = 10;
    }
  }

  // ---------- настроение ----------

  /// В каком «контексте» идёт волна: от него зависит, какие минусы и баны действуют
  String get _ctx => mood ?? (custom.isNotEmpty ? 'custom' : '');

  void setMood(String? id) {
    mood = moodById(id)?.id;
    // Минусы, набранные в этой сессии (пропуски, «не нравится»), — про прежнее настроение, в новом их не тянем
    _session.removeWhere((_, v) => v < 0);
    _save();
    notifyListeners();
    if (mood != null) unawaited(_loadTags());
    if (active) player.refillFeed(keep: (id) => trials.containsKey(id));
  }

  /// Насколько трек подходит под настроение: по тегам его исполнителей
  Map<String, double>? _moodMap(List<Track> tracks) {
    final m = moodById(mood);
    if (m == null) return null;
    final byArtist = <String, double>{};
    // Теги ещё не загрузились (или Last.fm их не знает) — ни поощряем, ни наказываем. Раньше здесь был 0,
    // и пока теги приходили, волна крутила только тех нескольких исполнителей, у кого они уже были
    // Неизвестный — заметно хуже подходящего, но лучше «теги есть, и они про другое». Раньше здесь было 0,3,
    // и исполнители без тегов (саундтреки, игровая музыка) обгоняли известных, но не подходящих под настроение
    const unknown = 0.12;
    double fit(String key) => byArtist.putIfAbsent(key, () {
          final tags = _tags[key];
          if (tags == null || tags.isEmpty) return unknown;
          return m.raw(tags).clamp(0.0, 1.0).toDouble();
        });
    double fitTrack(Track t) {
      // Д5: теги самой песни точнее; если по ним нет ни плюса, ни минуса — теги исполнителя
      final own = _trackTags[t.id];
      if (own != null && own.isNotEmpty) {
        final r = m.raw(own);
        if (r > 0) return min(1.0, r);
        if (r < 0) return 0; // сама песня помечена как «не то»
      }
      final art = t.artists.map((a) => fit(a.toLowerCase())).fold<double>(0, (a, b) => a > b ? a : b);
      // Тегов Last.fm нет (недоступен или не знает исполнителя): смотрим на звук и жанр самого трека
      if (art <= unknown + 1e-9) {
        final loc = _localMood(t, m);
        if (loc != null) return loc;
      }
      return art;
    }

    return {
      for (final t in tracks)
        if (fitTrack(t) case final v when v > 0) t.id: v
    };
  }

  /// Подходит ли трек под настроение по темпу, громкости, тональности и жанру из разбора звука; null — трек не разобран
  double? _localMood(Track t, WaveMood m) {
    final p = player.mixer?.profileCached(t.id);
    if (p == null) return null;
    return moodFitLocal(m.id, m.tags, m.anti, bpm: p.bpm, key: Camelot.parse(p.key), loudDb: p.loudDb, genre: p.genre);
  }

  /// Теги исполнителей библиотеки: сначала тех, у кого больше треков. Хранятся, повторно не спрашиваем
  Future<void> _loadTags() async {
    if (_tagging || !lastfm.available) return;
    _tagging = true;
    try {
      final artists = List.of(lib.artists)..sort((a, b) => b.tracks.length.compareTo(a.tracks.length));
      final todo = [for (final a in artists.take(400)) if (!_tags.containsKey(a.key)) a];
      // Д14: сначала исполнители из ближайшей очереди — настроение заработает раньше
      final near = <String>{
        for (final t in player.upcoming.take(20)) ...t.artists.map((a) => a.toLowerCase()),
        if (player.current != null) ...player.current!.artists.map((a) => a.toLowerCase()),
      };
      todo.sort((a, b) => (near.contains(a.key) ? 0 : 1).compareTo(near.contains(b.key) ? 0 : 1));
      tagsTotal = min(artists.length, 400);
      tagsKnown = tagsTotal - todo.length;
      notifyListeners();
      // Д5: теги ближайших песен очереди (не больше 12 за раз)
      var asked = 0;
      for (final t in [if (player.current != null) player.current!, ...player.upcoming.take(11)]) {
        if (mood == null || asked >= 12 || lastfm.paused || !lastfm.available) break;
        if (!_trackTagsAsked.add(t.id)) continue;
        asked++;
        final tags = await lastfm.trackTags(t.artists.first, t.title);
        if (tags == null) {
          _trackTagsAsked.remove(t.id); // Last.fm не ответил — спросим в следующий раз
          continue;
        }
        if (tags.isNotEmpty) _trackTags[t.id] = {for (final x in tags) x.artist: x.match};
      }
      var n = 0;
      for (final a in todo) {
        if (mood == null || !lastfm.available) break;
        final tags = await lastfm.artistTags(a.name);
        if (tags == null) {
          // Last.fm не ответил. «Тегов нет» не записываем: это отравило бы кеш насовсем.
          // Если он ушёл на паузу — выходим и вернёмся, когда пауза кончится
          if (lastfm.paused) break;
          continue;
        }
        _tags[a.key] = {for (final t in tags) t.artist: t.match};
        tagsKnown++;
        if (++n % 3 == 0) notifyListeners(); // счётчик на странице волны двигается, а не «висит»
        if (n % 10 == 0) {
          _save();
          if (active) player.refillFeed(keep: (id) => trials.containsKey(id));
        }
      }
    } catch (e) {
      AppLog.warn('Моя волна: теги настроения', e);
    } finally {
      _tagging = false;
      _save();
      notifyListeners();
      _retryTagsLater();
    }
  }

  Timer? _tagRetry;

  /// Last.fm ушёл на паузу посреди загрузки тегов — продолжаем, когда пауза закончится
  void _retryTagsLater() {
    _tagRetry?.cancel();
    if (mood == null || !lastfm.available || !lastfm.paused) return;
    _tagRetry = Timer(lastfm.pauseLeft + const Duration(seconds: 2), () {
      if (mood != null) unawaited(_loadTags());
    });
  }

  /// Что не так с Last.fm, если не так (для страницы волны); пусто — всё в порядке
  String get lastfmStatus => lastfm.status;

  // ---------- почему этот трек ----------

  /// Короткая подпись под текущим треком: откуда волна его взяла
  String reasonFor(String id) {
    if (trials.containsKey(id)) return 'новое из интернета';
    if ((_boost[id] ?? 0) >= WaveEngine.similarFloor) return 'похож на то, что вы только что слушали';
    final t = lib.data.tracks[id];
    if (t == null) return '';
    final focus = _focus;
    if (focus.isNotEmpty && t.artists.any((a) => focus.contains(a.toLowerCase()))) return 'из вашей подборки исполнителей';
    if (isUpvoted(id)) return 'вам понравилось в волне';
    if (lib.isLiked(id)) return 'из вашего любимого';
    final m = moodById(mood);
    if (m != null && (_moodMap([t])?[id] ?? 0) > 0) return 'под настроение «${m.title.toLowerCase()}»';
    final me = lib.me;
    if (lib.data.likes[id]?.any((e) => e != me) ?? false) return 'нравится друзьям';
    return 'по вашему вкусу';
  }

  // ---------- «нравится в волне» ----------

  bool isUpvoted(String id) => taste.upvoted.contains(id);

  /// Нравится: в любимое не сохраняется и пробный трек не спасает от удаления,
  /// но волна ставит больше похожего — прямо со следующего трека
  Future<void> upvote() async {
    final t = player.current;
    if (t == null) return;
    if (taste.upvoted.remove(t.id)) {
      taste.seeds.removeWhere((x) => x.$1 == t.artists.first && x.$2 == t.title);
      _save();
      notifyListeners();
      return;
    }
    taste.upvoted.add(t.id);
    taste.addSeed(t.artists.first, t.title);
    for (final a in t.artists) {
      final k = a.toLowerCase();
      taste.bump(k, 2 * _tuneK);
      _session[k] = (_session[k] ?? 0) + 4 * _tuneK;
    }
    _good.remove(t.id);
    _good.add(t.id);
    _save();
    notifyListeners();
    final found = await _learnFrom(t, decay: false, strength: 1.3);
    if (active) player.refillFeed(keep: (id) => trials.containsKey(id));
    if (found < 3) _maybeDiscover(force: true);
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
    taste.dislike(t.id, _ctx);
    for (final a in t.artists) {
      final k = a.toLowerCase();
      taste.bump(k, -1.5, ctx: _ctx);
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
    if (taste.undislike(id)) {
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

  // Д13: тяжёлую часть (перебор всех треков и прослушиваний друзей) считаем заново только когда
  // изменилась библиотека или прослушивания, но не чаще, чем раз в 30 секунд
  bool _inputsDirty = true;
  DateTime _inputsAt = DateTime.fromMillisecondsSinceEpoch(0);
  int _inputsTrials = -1;
  List<Track> _cTracks = const [];
  Set<String> _cLiked = const {};
  Map<String, int> _cMyPlays = const {};
  Map<String, int> _cCrowd = const {};
  Set<String> _cFav = const {};

  void _markInputsDirty() => _inputsDirty = true;

  WaveInputs _inputs() {
    final stale = DateTime.now().difference(_inputsAt) > const Duration(seconds: 30);
    if (_inputsDirty && (stale || _inputsTrials != trials.length) || _inputsTrials != trials.length) {
      _rebuildInputs();
    }
    _refreshTempo();
    return WaveInputs(
      ctx: _ctx,
      likeBoost: _tuneK,
      tracks: _cTracks,
      liked: _cLiked,
      myPlays: _cMyPlays,
      crowd: _cCrowd,
      favArtists: _cFav,
      related: _related,
      taste: taste,
      session: _session,
      boost: _boost,
      audioNeg: _audioNeg,
      focus: _focus,
      mood: _moodMap(_cTracks),
      bpm: _tempoMap,
      curBpm: player.current == null ? null : (_tempoMap[player.current!.id] ?? _bpms[player.current!.id]),
      keys: _keyMap,
      curKey: player.current == null ? null : _keyMap[player.current!.id],
    );
  }

  // ---------- темп и тональность из разбора звука ----------

  Map<String, double> _tempoMap = const {};
  Map<String, Camelot> _keyMap = const {};
  DateTime _tempoAt = DateTime.fromMillisecondsSinceEpoch(0);
  int _tempoCount = -1;

  /// Темп и тональность всех разобранных треков библиотеки. Пересобираем, когда появились новые разборы
  void _refreshTempo() {
    final m = player.mixer;
    final count = m?.profileCount ?? 0;
    if (count == _tempoCount && DateTime.now().difference(_tempoAt) < const Duration(minutes: 2)) return;
    _tempoCount = count;
    _tempoAt = DateTime.now();
    final bpm = <String, double>{};
    final keys = <String, Camelot>{};
    if (m != null) {
      for (final t in _cTracks) {
        final p = m.profileCached(t.id);
        if (p == null) continue;
        final b = p.bpm;
        if (b != null) bpm[t.id] = b;
        final k = Camelot.parse(p.key);
        if (k != null) keys[t.id] = k;
      }
    }
    // Темп из Deezer — для тех, кого ещё не разобрали
    _bpms.forEach((id, b) => bpm.putIfAbsent(id, () => b));
    _tempoMap = bpm;
    _keyMap = keys;
  }

  void _rebuildInputs() {
    _inputsDirty = false;
    _inputsAt = DateTime.now();
    _inputsTrials = trials.length;
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
    _cTracks = tracks;
    _cLiked = liked;
    _cMyPlays = myPlays;
    _cCrowd = crowd;
    _cFav = {for (final a in lib.artists) if (lib.isFavArtist(a.key)) a.key};
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
  String get label => 'Далее в волне';

  @override
  List<String> more(int n) {
    final x = _inputs();
    final ahead = player.feeder == this ? player.queue.skip(player.index) : const <String>[];
    final ids = [...WaveEngine.pick(x, mode, n, recent: [..._recent, ...ahead], sinceWide: _sinceWide)];
    _sinceWide = (_sinceWide + ids.length) % 5;
    // Д15: пришёл черёд новинки — ставим готовую из запаса в конец выдачи
    final every = _every;
    if (discover && every != null && ids.isNotEmpty && _sinceFresh + ids.length >= every) {
      final busy = {..._recent, ...ahead, ...ids};
      final ready = _stockIds.where((id) => !busy.contains(id)).firstOrNull;
      if (ready != null) {
        ids[ids.length - 1] = ready;
        _sinceFresh = 0;
      } else {
        _sinceFresh += ids.length;
      }
    } else {
      _sinceFresh += ids.length;
    }
    _remember(ids);
    _save();
    _maybeDiscover();
    return ids;
  }

  bool get _inBackground {
    final st = WidgetsBinding.instance.lifecycleState;
    return st == AppLifecycleState.hidden || st == AppLifecycleState.paused;
  }

  /// Сколько разных песен исполнителя [key] пропущено в начале
  int _skippedSongsOf(String key) {
    var n = 0;
    for (final id in taste.skipsIn(_ctx).keys) {
      final u = lib.data.tracks[id];
      if (u != null && u.artists.any((a) => a.toLowerCase() == key)) n++;
    }
    return n;
  }

  @override
  void heard(Track t, Duration listened, {required bool skipped}) {
    taste.decay();
    _audioNeg.updateAll((_, v) => v * 0.97);
    _audioNeg.removeWhere((_, v) => v < 0.05);
    final keys = [for (final a in t.artists) a.toLowerCase()];
    final total = Duration(milliseconds: t.durationMs ?? 0);
    final early = skipped && listened < const Duration(seconds: 30);
    // Режим настройки: ранний пропуск ничего не значит — ни штрафа треку и исполнителю,
    // ни удаления пробного файла. Человек листает, чтобы найти, что нравится
    if (early && tuning) return;
    if (listened >= const Duration(seconds: 30)) taste.markHeard(t.id);
    final finished = !skipped || (total > Duration.zero && listened.inMilliseconds > total.inMilliseconds * 0.7);
    final trial = trials[t.id];
    if (trial != null && finished && !early) {
      // Д10: дослушали — трек заслужил ещё неделю и может прозвучать снова
      final until = DateTime.now().add(waveTrialExtended);
      if (until.isAfter(trial.expires)) trial.until = until;
    }
    if (early) {
      // Д10: ранний пропуск пробного трека — удаляем сразу (через корзину), если его никто не сохранил
      if (trial != null && !_kept(t.id)) {
        Timer(const Duration(seconds: 2), () {
          final cur = trials[t.id];
          if (cur != null && player.current?.id != t.id && !_kept(t.id)) _drop(cur);
        });
      }
      taste.addSkip(t.id, _ctx);
      _learnAudioNeg(t);
      // Д1: основной штраф получает сам трек (skips). Исполнителя заметно наказываем,
      // только когда пропущены минимум две его разные песни. Всё это — только для текущего контекста
      // (настроения), и со временем забывается
      for (final k in keys) {
        final songs = _skippedSongsOf(k);
        if (songs >= 2) {
          taste.bump(k, -0.6, ctx: _ctx);
          _session[k] = (_session[k] ?? 0) - 2.5;
        } else {
          taste.bump(k, -0.1, ctx: _ctx);
          _session[k] = (_session[k] ?? 0) - 0.5;
        }
      }
      if (keys.any((k) => _skippedSongsOf(k) >= 2)) {
        // Сразу убираем из ближайшей очереди этого же исполнителя — волна реагирует, а не через десять треков
        player.dropUpcoming((id) {
          final u = lib.data.tracks[id];
          return u != null && u.artists.any((a) => keys.contains(a.toLowerCase()));
        }, keepVisible: true);
      }
    } else if (finished) {
      taste.forgiveSkip(t.id, _ctx);
      // Д3: если окно скрыто, человек ничего не нажимал — дослушивание весит вдвое меньше
      final bg = _inBackground ? 0.5 : 1.0;
      for (final k in keys) {
        taste.bump(k, 0.4 * bg * _tuneK);
        _session[k] = (_session[k] ?? 0) + 1.5 * bg * _tuneK;
      }
      _good.remove(t.id);
      _good.add(t.id);
      if (_good.length > 10) _good.removeAt(0);
    }
    _save();
  }

  late final SimIndex _sim = SimIndex(lib, () => player.mixer);

  /// Пропустили трек в самом начале: треки, звучащие очень похоже, получают небольшой штраф (пока не забудется)
  void _learnAudioNeg(Track t) {
    try {
      final sims = intel?.similarMap([t.id], floor: 0.7, limit: 80) ?? const <String, double>{};
      sims.forEach((id, v) {
        if (id == t.id) return;
        final x = min(0.6, (v - 0.6) * 1.5);
        if (x < 0.1) return;
        if ((_audioNeg[id] ?? 0) < x) _audioNeg[id] = x;
      });
    } catch (e) {
      AppLog.warn('Моя волна: штраф за похожее на пропущенное', e);
    }
  }

  /// Похожие на трек (и на два последних дослушанных) по тому, что известно локально: один альбом и исполнитель,
  /// общие плейлисты, жанр из тегов, эпоха, темп и тональность. Прибавка слабее, чем от Last.fm, и не выше 0,6:
  /// иначе волна ходила бы только по альбому. Возвращает, сколько похожих нашлось
  int _learnLocal(Track t) {
    try {
      final sims = _sim.similarTo([t.id, ..._good.reversed.take(2)]);
      var n = 0;
      sims.forEach((id, v) {
        if (id == t.id) return;
        final x = min(0.6, v * 0.7);
        if (x < 0.1) return;
        if ((_boost[id] ?? 0) < x) _boost[id] = x;
        n++;
      });
      // Похожие по звуку (тембр, гармония, ритм, энергия из разбора аудио): прибавка мягкая, как и у локальных данных
      final audio = intel?.similarMap([t.id, ..._good.reversed.take(2)], floor: 0.45) ?? const <String, double>{};
      audio.forEach((id, v) {
        if (id == t.id) return;
        final x = min(0.6, (v - 0.35) * 1.2);
        if (x < 0.1) return;
        if ((_boost[id] ?? 0) < x) _boost[id] = x;
        n++;
      });
      if (n > similarInLibrary) similarInLibrary = n;
      AppLog.info('Моя волна: похожие на «${t.title}» по локальным данным: $n');
      return n;
    } catch (e) {
      AppLog.warn('Моя волна: локальный подбор похожих', e);
      return 0;
    }
  }

  /// Похожие на трек по Last.fm: те, что есть в библиотеке, получают прибавку к весу.
  /// Если самой песни в библиотеке нет — прибавку получают её исполнители (слабее).
  /// Старые прибавки слабеют — волна плавно следует за тем, что играет сейчас. Возвращает,
  /// сколько похожих треков нашлось в библиотеке
  Future<int> _learnFrom(Track t, {Duration? wait, bool decay = true, double strength = 1}) =>
      _learnFromName(t.artists.first, t.title, self: t.id, wait: wait, decay: decay, strength: strength);

  Future<int> _learnFromName(String artist, String title,
      {String? self, Duration? wait, bool decay = true, double strength = 1}) async {
    if (!lastfm.available) return 0;
    try {
      var f = lastfm.similarTracks(artist, title);
      if (wait != null) f = f.timeout(wait, onTimeout: () => const <LfmItem>[]);
      var items = await f;
      final add = <String, double>{};
      void put(String id, double v) {
        if (id == self) return;
        if ((add[id] ?? 0) < v) add[id] = v;
      }

      final artistScore = <String, double>{};
      for (final i in items) {
        final m = i.match.clamp(0.0, 1.0).toDouble();
        final hit = lib.existing(i.artist, i.title);
        if (hit != null) put(hit.id, m);
        final k = i.artist.toLowerCase();
        artistScore[k] = max(artistScore[k] ?? 0, m);
      }
      // О треке Last.fm ничего не знает — берём похожих исполнителей
      if (items.length < 5) {
        final sim = await lastfm.similarArtists(artist);
        for (final a in sim) {
          final k = a.artist.toLowerCase();
          artistScore[k] = max(artistScore[k] ?? 0, a.match.clamp(0.0, 1.0).toDouble() * 0.8);
        }
        items = [...items, ...sim];
      }
      artistScore.forEach((k, v) {
        final a = lib.artist(k);
        if (a == null) return;
        for (final tr in a.tracks) {
          put(tr.id, 0.15 + 0.35 * v); // не сама песня, но тот же круг
        }
      });
      if (decay) {
        _boost.updateAll((_, v) => v * 0.5);
        _boost.removeWhere((_, v) => v < 0.05);
      }
      add.forEach((id, v) {
        final x = min(1.0, v * strength);
        if ((_boost[id] ?? 0) < x) _boost[id] = x;
      });
      similarInLibrary = add.length;
      AppLog.info('Моя волна: похожие на «$artist — $title»: Last.fm ${items.length}, в библиотеке ${add.length}');
      return add.length;
    } catch (e) {
      AppLog.warn('Моя волна: Last.fm', e);
      return 0;
    }
  }

  // ---------- «радио» исполнителей ----------

  /// Для любимых исполнителей спрашиваем у Deezer их «радио». Кто там звучит — тот и похож:
  /// это то, что люди слушают вместе, а не просто «похожие» по жанру
  Future<void> _learnRadio({List<String> extra = const [], bool force = false}) async {
    if (_learning && !force) return;
    _learning = true;
    try {
      final top = [for (final e in topArtists(8)) e.$1];
      final keys = <String>{for (final a in extra) a.toLowerCase(), ...top}.where((k) => !_related.containsKey(k)).take(8);
      for (final key in keys) {
        try {
          final name = lib.artist(key)?.name ?? key;
          final lfm = await lastfm.similarArtists(name);
          if (lfm.isNotEmpty) {
            _related[key] = [for (final a in lfm.take(25)) a.artist.toLowerCase()];
            continue;
          }
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
        WaveMode.mix => 3,
        WaveMode.unfamiliar => 2,
        WaveMode.favorite || WaveMode.popular => 8, // изредка
      };

  /// Скольких скачанных, но ещё не звучавших новинок держим про запас
  int get _stockTarget => switch (mode) {
        WaveMode.mix || WaveMode.unfamiliar => 2,
        WaveMode.favorite || WaveMode.popular => 1,
      };

  Iterable<String> get _stockIds => [
        for (final t in trials.values)
          if (lib.data.tracks[t.id] != null && !taste.heard.contains(t.id) && !taste.disliked.contains(t.id)) t.id
      ];

  String? get _targetSource {
    final sources = lib.data.sources;
    if (sources.isEmpty) return null;
    final hub = lib.settings.hubId;
    return sources.any((s) => s.id == hub) ? hub : sources.first.id;
  }

  /// [force] — в библиотеке не нашлось похожих: качаем, не дожидаясь своей очереди
  void _maybeDiscover({bool force = false}) {
    final every = _every;
    // Д15: держим 1–2 новинки про запас и качаем до двух треков параллельно
    if (!discover || !active || every == null || _pending >= 2) return;
    // После пустого поиска или серии неудачных загрузок не долбим Last.fm и загрузчик на каждом треке
    if (DateTime.now().isBefore(_discoverPausedUntil)) return;
    if (!force && _stockIds.length + _pending >= _stockTarget) return;
    if (downloadedToday >= dailyLimit || _targetSource == null || !lib.hasHub) return;
    unawaited(_discoverOne());
  }

  /// До какого времени новинки не ищем (после пустого поиска или нескольких неудач подряд)
  DateTime _discoverPausedUntil = DateTime.fromMillisecondsSinceEpoch(0);

  /// Сколько загрузок новинок подряд не принесли трек
  int _failStreak = 0;

  /// Дольше этого задание загрузчика не ждём: слот освобождается, даже если оно «зависло»
  static const _jobPatience = Duration(minutes: 10);

  Future<void> _discoverOne() async {
    _pending++;
    // Слот возвращаем ровно один раз, что бы ни случилось. Раньше состояние «отменено» его не возвращало,
    // и после двух отменённых заданий новинки не качались до перезапуска плеера
    var released = false;
    void release() {
      if (released) return;
      released = true;
      _pending--;
    }

    _status('Ищу новое для волны…');
    try {
      final pick = await _findFresh().timeout(const Duration(seconds: 60), onTimeout: () => null);
      if (pick == null) {
        AppLog.info('Моя волна: нового для скачивания не нашлось. Причины: ${_why.isEmpty ? 'поиск не уложился в 60 с' : _why.join('; ')}'
            '${lastfm.status.isEmpty ? '' : ' (${lastfm.status})'}');
        _discoverPausedUntil = DateTime.now().add(const Duration(minutes: 2));
        _status('');
        release();
        return;
      }
      final src = _targetSource!;
      final folder = await lib.ensureSubfolder(src, src, 'Моя волна');
      _status('Качаю «${pick.title}» — ${pick.artist}');
      var got = false;
      final job = downloads.enqueue(pick.link ?? '${pick.artist} - ${pick.title}', src, folderId: folder, path: 'Моя волна', quiet: true, onTrack: (t) {
        got = true;
        _onDownloaded(t, pick);
      });
      if (job == null) {
        _status('');
        release();
        return;
      }
      // Ждём конца задания, чтобы не ставить в очередь загрузчика десяток треков разом
      Timer? patience;
      // finish и check ссылаются друг на друга; в Dart локальная функция до своего объявления не видна,
      // поэтому check объявлена переменной заранее
      late final void Function() check;
      void finish() {
        downloads.removeListener(check);
        patience?.cancel();
        release();
        if (got) {
          _failStreak = 0;
        } else {
          _rejected.add(pick.key); // не скачался или уже был — в следующий раз ищем другой
          final why = job.log.isEmpty ? '' : ' — ${job.log.last}';
          AppLog.warn('Моя волна: не удалось скачать «${pick.title}» (${pick.artist}), задание: ${job.state.name}$why');
          if (++_failStreak >= 3) {
            // Загрузчик, похоже, не работает: не крутим бесконечный цикл поиск → неудача
            _failStreak = 0;
            _discoverPausedUntil = DateTime.now().add(const Duration(minutes: 10));
            _status('Новое не скачивается: загрузчик не справляется (подробности в журнале). Повторю через 10 минут');
          } else {
            _status('');
          }
        }
        _save();
      }

      check = () {
        if (job.state == JobState.done || job.state == JobState.failed || job.state == JobState.cancelled) finish();
      };

      downloads.addListener(check);
      patience = Timer(_jobPatience, () {
        if (released) return;
        AppLog.warn('Моя волна: загрузка «${pick.title}» не закончилась за ${_jobPatience.inMinutes} минут, перестаю ждать');
        finish();
      });
      check(); // вдруг задание уже закончилось
    } catch (e) {
      release();
      _status('');
      AppLog.warn('Моя волна: новинка', e);
    }
  }

  void _status(String s) {
    discoverStatus = s;
    notifyListeners();
  }

  Set<String> get _trialKeys => {for (final t in trials.values) t.key};

  bool _skippedArtist(String artist, Map<String, double> aff) =>
      splitArtists(artist).any((a) => (aff[a.toLowerCase()] ?? 0) <= -3);

  /// Почему поиск новинки ничего не нашёл — попадает в журнал, чтобы было видно, где обрывается цепочка
  final List<String> _why = [];

  Future<_Fresh?> _findFresh() async {
    _why.clear();
    if (lastfm.available) {
      final f = await _findFreshLastFm();
      if (f != null) return f;
    } else {
      _why.add('Last.fm недоступен${lastfm.status.isEmpty ? '' : ' (${lastfm.status})'}');
    }
    // Deezer про настроение ничего не знает: под настроение его «радио» только портит подбор
    if (mood != null) return null;
    return _findFreshDeezer();
  }

  /// Новый трек по Last.fm. Источники, каждый со своим весом:
  /// похожие на то, что играет сейчас, на пару последних дослушанных и на понравившиеся в волне;
  /// популярное у своих исполнителей и похожих на них; песни с тегами выбранного настроения.
  /// Трек, на который указывают сразу несколько, — самый вероятный
  Future<_Fresh?> _findFreshLastFm() async {
    final score = <String, double>{};
    final item = <String, LfmItem>{};
    void vote(List<LfmItem> list, double w) {
      for (final i in list) {
        final k = LibraryController.dupKey(i.artist, i.title);
        if (k.isEmpty) continue;
        item[k] = i;
        score[k] = (score[k] ?? 0) + i.match.clamp(0.0, 1.0).toDouble() * w;
      }
    }

    final cur = player.current;
    if (cur != null) vote(await lastfm.similarTracks(cur.artists.first, cur.title), 1.5);
    var n = 0;
    for (final id in _good.reversed) {
      final t = lib.data.tracks[id];
      if (t == null || t.id == cur?.id) continue;
      vote(await lastfm.similarTracks(t.artists.first, t.title), 1.0);
      if (++n >= 2) break;
    }
    final seeds = List.of(taste.seeds)..shuffle();
    for (final (a, t) in seeds.take(1)) {
      vote(await lastfm.similarTracks(a, t), 1.2);
    }
    if (custom.isNotEmpty) {
      // Своя подборка: хиты одного из своих исполнителей или похожего на них
      final pool = [...custom.map((c) => c.toLowerCase()), ..._focus];
      final who = pool[Random().nextInt(pool.length)];
      vote(await lastfm.topTracks(lib.artist(who)?.name ?? who), custom.any((c) => c.toLowerCase() == who) ? 1.4 : 1.1);
    }
    final m = moodById(mood);
    if (m != null) {
      // Под настроение: песни с его тегами весят заметно больше «похожих на играющее»
      final pool = List.of(m.tags)..shuffle();
      for (final tag in pool.take(2)) {
        vote(await lastfm.tagTracks(tag), 1.4);
      }
    }
    if (score.isEmpty) {
      _why.add('Last.fm: похожих треков не вернул (последний ответ: ${lastfm.status.isEmpty ? 'без ошибок' : lastfm.status})');
      return null;
    }
    final aff = _affinity();
    final trialKeys = _trialKeys;
    final cands = <(LfmItem, double)>[];
    final focus = _focus;
    var nRejected = 0, nTrial = 0, nHave = 0, nSkipped = 0;
    score.forEach((k, v) {
      final i = item[k]!;
      if (_rejected.contains(k)) {
        nRejected++;
        return;
      }
      if (trialKeys.contains(k)) {
        nTrial++;
        return;
      }
      if (lib.existing(i.artist, i.title) != null) {
        nHave++;
        return;
      }
      if (_skippedArtist(i.artist, aff)) {
        nSkipped++;
        return;
      }
      final ak = i.artist.toLowerCase();
      var w = v;
      // Новый для библиотеки исполнитель интереснее, но новая песня знакомого — тоже хорошо
      if (lib.artist(ak) == null) w *= 1.2;
      // Близкий по вкусу исполнитель — вероятнее; в своей подборке чужие почти не качаем
      if ((aff[ak] ?? 0) > 0) w *= 1.3;
      if (focus.isNotEmpty && !focus.contains(ak)) w *= 0.2;
      cands.add((i, w));
    });
    if (cands.isEmpty) {
      _why.add('Last.fm: кандидатов ${score.length}, отсеяно: уже в «отклонённых» $nRejected, уже на пробе $nTrial, '
          'уже в библиотеке $nHave, исполнитель в минусе $nSkipped');
      return null;
    }
    cands.sort((a, b) => b.$2.compareTo(a.$2));
    var top = cands.take(8).toList();
    if (m != null) {
      // Новинку проверяем по тегам исполнителя: не подходящих под настроение не качаем,
      // иначе один саундтрек тянет за собой «похожие» и настроение теряется
      final shortlist = cands.take(14).toList();
      final fitted = <(LfmItem, double)>[];
      var offMood = 0;
      for (final (i, w) in shortlist) {
        List<LfmItem>? got;
        if (!lastfm.paused) got = await lastfm.artistTags(i.artist, urgent: true);
        if (got == null || got.isEmpty) {
          fitted.add((i, w * 0.4)); // теги неизвестны — не поощряем и не отсекаем
          continue;
        }
        final r = m.raw({for (final x in got) x.artist: x.match});
        if (r <= 0) {
          offMood++;
          continue;
        }
        fitted.add((i, w * (0.5 + 2 * min(1.0, r))));
      }
      if (fitted.isEmpty) {
        _why.add('под настроение «${m.title}» не подошёл никто из ${shortlist.length} кандидатов (отсеяно по тегам: $offMood)');
        return null;
      }
      fitted.sort((a, b) => b.$2.compareTo(a.$2));
      top = fitted.take(8).toList();
    }
    // До трёх попыток: раньше первый же интро/скит/часовой микс обрывал поиск целиком,
    // а тот же кандидат мог выпасть снова на следующем заходе
    for (var attempt = 0; attempt < 3 && top.isNotEmpty; attempt++) {
      final pick = _weighted(top);
      top.removeWhere((c) => identical(c.$1, pick));
      final want = LibraryController.dupKey(pick.artist, pick.title);
      String? link;
      var odd = false;
      // Ссылку берём из Deezer: так загрузчик возьмёт точные теги и обложку
      try {
        final r = await web.search('${pick.artist} ${pick.title}');
        for (final t in r.tracks) {
          if (LibraryController.dupKey(t.artist, t.title) != want) continue;
          if (t.seconds > 0 && (t.seconds < 90 || t.seconds > 600)) {
            odd = true; // интро, скиты, миксы
            break;
          }
          if (t.link.isNotEmpty) {
            link = t.link;
            break;
          }
        }
      } catch (e) {
        AppLog.warn('Моя волна: поиск в Deezer «${pick.artist} — ${pick.title}»', e);
        _why.add('поиск в Deezer упал: ${e.runtimeType}');
      }
      if (odd) {
        _rejected.add(want);
        _why.add('«${pick.title}» отпал по длительности (интро/микс)');
        continue;
      }
      if (link == null) _why.add('в Deezer не нашлась ссылка на «${pick.artist} — ${pick.title}», качаю по названию');
      return _Fresh(pick.artist, pick.title, link);
    }
    _why.add('три попытки подряд отпали по длительности');
    return null;
  }

  static T _weighted<T>(List<(T, double)> list) {
    var total = 0.0;
    for (final c in list) {
      total += c.$2;
    }
    var r = Random().nextDouble() * total;
    for (final c in list) {
      r -= c.$2;
      if (r <= 0) return c.$1;
    }
    return list.first.$1;
  }

  /// Запасной путь, если Last.fm ничего не знает: «радио» исполнителей в Deezer
  Future<_Fresh?> _findFreshDeezer() async {
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
      } catch (e) {
        AppLog.warn('Моя волна: радио Deezer «${seeds[i]}»', e);
        _why.add('радио Deezer «${seeds[i]}» упало: ${e.runtimeType}');
      }
      if (list == null) continue;
      for (final t in list) {
        byId[t.id] = t;
        votes[t.id] = (votes[t.id] ?? 0) + (i == 0 ? 2 : 1);
      }
    }
    final aff = _affinity();
    final trialKeys = _trialKeys;
    final artistVotes = <String, double>{};
    votes.forEach((id, v) {
      final k = byId[id]!.artist.toLowerCase();
      artistVotes[k] = (artistVotes[k] ?? 0) + v;
    });
    final cands = <(WebTrack, double)>[];
    var dRej = 0, dHave = 0, dSkip = 0, dOdd = 0;
    for (final t in byId.values) {
      final key = LibraryController.dupKey(t.artist, t.title);
      if (t.link.isEmpty || key.isEmpty || trialKeys.contains(key)) continue;
      if (_rejected.contains(key)) {
        dRej++;
        continue;
      }
      if (lib.existing(t.artist, t.title) != null) {
        dHave++;
        continue;
      }
      if (_skippedArtist(t.artist, aff)) {
        dSkip++; // исполнителя постоянно пропускают
        continue;
      }
      if (t.seconds > 0 && (t.seconds < 90 || t.seconds > 600)) {
        dOdd++; // интро, скиты и часовые миксы
        continue;
      }
      var w = votes[t.id]! + (artistVotes[t.artist.toLowerCase()] ?? 0) * 0.5;
      // Новые для библиотеки исполнители интереснее, но и новая песня знакомого — тоже хорошо
      if (lib.artist(t.artist.toLowerCase()) == null) w *= 1.3;
      cands.add((t, w));
    }
    if (cands.isEmpty) {
      _why.add('Deezer: треков ${byId.length}, отсеяно: отклонённых $dRej, уже есть $dHave, исполнитель в минусе $dSkip, по длительности $dOdd');
      return null;
    }
    cands.sort((a, b) => b.$2.compareTo(a.$2));
    final t = _weighted(cands.take(5).toList());
    return _Fresh(t.artist, t.title, t.link);
  }

  void _onDownloaded(Track t, _Fresh from) {
    trials[t.id] = WaveTrial(t.id, from.key, DateTime.now());
    final today = _todayKey();
    if (_day != today) {
      _day = today;
      _today = 0;
    }
    _today++;
    _status('');
    // Д15: новинка ждёт своей очереди про запас; сразу ставим, только если её черёд уже пришёл
    final every = _every;
    if (active && (every == null || _sinceFresh >= every)) {
      _sinceFresh = 0;
      player.insertSoon(t.id);
    }
    _save();
    notifyListeners();
    _maybeDiscover();
  }

  // ---------- пробный срок ----------

  /// Трек остаётся, если его кто-то лайкнул, добавил в плейлист или послушал второй раз
  bool _kept(String id) {
    // Д12: в этот трек объединили другие копии (их файлы ушли в корзину) — он теперь единственный экземпляр
    if (lib.data.merged.keys.any((k) => lib.data.resolve(k) == id)) return true;
    if (lib.data.likes[id]?.isNotEmpty ?? false) return true;
    if (lib.data.playlists.any((p) => p.items.contains(id))) return true;
    return social.playsOf(id) >= 2;
  }

  /// Что с пробным треком: сохранится он или сколько осталось
  (bool, Duration) trialState(String id) {
    final t = trials[id];
    if (t == null) return (true, Duration.zero);
    final left = t.expires.difference(DateTime.now());
    return (_kept(id), left.isNegative ? Duration.zero : left);
  }

  List<Track> get trialTracks => [
        for (final t in trials.values)
          if (lib.data.tracks[t.id] != null) lib.data.tracks[t.id]!
      ];

  void _drop(WaveTrial t) {
    trials.remove(t.id);
    final track = lib.data.tracks[t.id];
    if (t.key.isNotEmpty) _rejected.add(t.key);
    if (track != null) _rejected.add(LibraryController.dupKey(track.artist, track.title)); // теги могли отличаться
    _rejected.remove('');
    while (_rejected.length > 1000) {
      _rejected.remove(_rejected.first);
    }
    if (track != null) lib.deleteTracks([track]);
    _save();
  }

  /// Д16: удаляет (через корзину) пробные треки, которые волна уже «наказала»: ранний пропуск
  /// или исполнитель с симпатией ≤ −3. Сохранённые людьми и обычные треки библиотеки не трогает.
  void cleanup() {
    if (trials.isEmpty || !lib.hasHub || !social.loaded) return;
    final aff = WaveEngine.affinity(_inputs());
    var removed = 0;
    for (final t in trials.values.toList()) {
      final id = lib.data.resolve(t.id);
      final track = lib.data.tracks[id];
      if (track == null || _kept(id) || player.current?.id == id) continue;
      final skipped = taste.skipsOf(t.id, _ctx) > 0;
      if (skipped || _skippedArtist(track.artist, aff)) {
        _drop(t);
        removed++;
      }
    }
    if (removed > 0) {
      player.dropUpcoming((id) => lib.data.tracks[id] == null);
      AppLog.info('Моя волна: убрано наказанных пробных треков: $removed');
      notifyListeners();
    }
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
      if (!DateTime.now().isBefore(t.expires)) {
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
        'similarArtists': _related,
        'discover': discover,
        'tuning': tuning,
        'mood': mood,
        'dailyLimit': dailyLimit,
        'custom': custom,
        'tagsV': 2,
        'artistTags': _tags.map((k, v) => MapEntry(k, v.map((t, x) => MapEntry(t, double.parse(x.toStringAsFixed(2)))))),
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
    lib.removeListener(_markInputsDirty);
    social.removeListener(_markInputsDirty);
    _sweepTimer?.cancel();
    _saveTimer?.cancel();
    _tagRetry?.cancel();
    super.dispose();
  }
}
