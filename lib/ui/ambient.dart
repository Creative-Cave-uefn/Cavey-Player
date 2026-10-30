import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../app.dart';
import '../core/player.dart';
import 'theme.dart';

/// Откуда фон берёт картинку. Профиль (исполнитель, человек) важнее трека:
/// пока он открыт, фон красит его фото; в остальных местах — обложка текущего трека
class AmbientSource {
  final String key;

  /// Картинка-источник: байты (обложка, баннер на Диске) или адрес в интернете (фото исполнителя)
  final Future<Uint8List?> Function()? bytes;
  final Future<String?> Function()? url;

  /// Картинки нет — мягкое свечение этим цветом (например, цвет друга)
  final Color? color;

  /// Если [bytes]/[url] ничего не дали — запасной источник
  final AmbientSource? fallback;

  const AmbientSource(this.key, {this.bytes, this.url, this.color, this.fallback});
}

/// Источник фона, который сейчас задаёт открытая страница (профиль). null — фон от трека
class AmbientScope {
  static final ValueNotifier<AmbientSource?> override = ValueNotifier(null);
  static Object? _owner;

  static void claim(Object owner, AmbientSource? source) {
    _owner = owner;
    if (override.value?.key != source?.key) override.value = source;
  }

  static void release(Object owner) {
    if (!identical(_owner, owner)) return; // фон уже забрала следующая страница
    _owner = null;
    override.value = null;
  }

  /// Ярче и сочнее, меньше затемнения — для кинотеатра
  static final ValueNotifier<bool> vivid = ValueNotifier(false);

  /// Цветное свечение, которое просит страница (шапка «Любимого», профиль без баннера).
  /// Рисуется на всём окне, а не внутри страницы — поэтому без обрезанных краёв
  static final ValueNotifier<Color?> glow = ValueNotifier(null);
  static Object? _glowOwner;

  static void claimGlow(Object owner, Color? color) {
    _glowOwner = owner;
    glow.value = color;
  }

  static void releaseGlow(Object owner) {
    if (!identical(_glowOwner, owner)) return;
    _glowOwner = null;
    glow.value = null;
  }
}

/// Ставится на страницу: пока она открыта, по всему окну мягко светится [color]. Сам ничего не рисует
class AmbientGlow extends StatefulWidget {
  final Color? color;
  const AmbientGlow({super.key, required this.color});

  @override
  State<AmbientGlow> createState() => _AmbientGlowState();
}

class _AmbientGlowState extends State<AmbientGlow> {
  void _claim() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) AmbientScope.claimGlow(this, widget.color);
      });

  @override
  void initState() {
    super.initState();
    _claim();
  }

  @override
  void didUpdateWidget(covariant AmbientGlow old) {
    super.didUpdateWidget(old);
    if (old.color != widget.color) _claim();
  }

  @override
  void dispose() {
    final me = this;
    WidgetsBinding.instance.addPostFrameCallback((_) => AmbientScope.releaseGlow(me));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// Оборачивает страницу профиля: пока она на экране, фон окна красит её [source]
class AmbientOverride extends StatefulWidget {
  final AmbientSource? source;
  final Widget child;
  const AmbientOverride({super.key, required this.source, required this.child});

  @override
  State<AmbientOverride> createState() => _AmbientOverrideState();
}

class _AmbientOverrideState extends State<AmbientOverride> {
  // Менять фон прямо во время построения нельзя — делаем это сразу после кадра
  void _claim() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) AmbientScope.claim(this, widget.source);
      });

  @override
  void initState() {
    super.initState();
    _claim();
  }

  @override
  void didUpdateWidget(covariant AmbientOverride old) {
    super.didUpdateWidget(old);
    if (old.source?.key != widget.source?.key) _claim();
  }

  @override
  void dispose() {
    final me = this;
    WidgetsBinding.instance.addPostFrameCallback((_) => AmbientScope.release(me));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Палитра фона: несколько главных цветов картинки и тёмная основа под ними
class AmbientPalette {
  final Color base;
  final List<Color> blobs; // всегда [blobCount] цветов, самые заметные первыми
  const AmbientPalette(this.base, this.blobs);

  static const blobCount = 5;

  static AmbientPalette lerp(AmbientPalette a, AmbientPalette b, double t) => AmbientPalette(
        Color.lerp(a.base, b.base, t)!,
        [for (var i = 0; i < blobCount; i++) Color.lerp(a.blobs[i], b.blobs[i], t)!],
      );

  /// Пока ничего не играет — фирменные синие тона
  static const brand = AmbientPalette(Color(0xFF0E1230), [
    Color(0xFF2E3A8C),
    Color(0xFF4A2F7A),
    Color(0xFF1F4F7A),
    Color(0xFF33407F),
    Color(0xFF26305E),
  ]);

  /// Один цвет (друг без фото) — оттенки вокруг него
  factory AmbientPalette.of(Color c) {
    final h = HSLColor.fromColor(c);
    Color v(double dh, double l) =>
        h.withHue((h.hue + dh) % 360).withSaturation(math.min(1.0, h.saturation * 1.1 + 0.1)).withLightness(l).toColor();
    return AmbientPalette(v(0, 0.1), [v(0, 0.45), v(-18, 0.38), v(22, 0.34), v(0, 0.3), v(-8, 0.42)]);
  }

  /// Главные цвета картинки: k-средних по крошечной копии (32×32), потом цвета делаем сочнее
  static Future<AmbientPalette?> fromImage(ui.Image img) async {
    final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (data == null) return null;
    final px = <(double, double, double)>[];
    final bytes = data.buffer.asUint8List();
    for (var i = 0; i + 3 < bytes.length; i += 4) {
      if (bytes[i + 3] < 128) continue;
      px.add((bytes[i].toDouble(), bytes[i + 1].toDouble(), bytes[i + 2].toDouble()));
    }
    if (px.isEmpty) return null;
    return _cluster(px); // 1024 точки — быстрее, чем запускать отдельный поток
  }

  static AmbientPalette _cluster(List<(double, double, double)> px) {
    const k = 6;
    var centers = [for (var i = 0; i < k; i++) px[(i * px.length / k).floor()]];
    var counts = List<int>.filled(k, 0);
    for (var iter = 0; iter < 8; iter++) {
      final sum = List.generate(k, (_) => [0.0, 0.0, 0.0]);
      counts = List<int>.filled(k, 0);
      for (final p in px) {
        var best = 0;
        var bd = double.infinity;
        for (var j = 0; j < k; j++) {
          final c = centers[j];
          final d = (p.$1 - c.$1) * (p.$1 - c.$1) * 0.3 + (p.$2 - c.$2) * (p.$2 - c.$2) * 0.59 + (p.$3 - c.$3) * (p.$3 - c.$3) * 0.11;
          if (d < bd) {
            bd = d;
            best = j;
          }
        }
        sum[best][0] += p.$1;
        sum[best][1] += p.$2;
        sum[best][2] += p.$3;
        counts[best]++;
      }
      centers = [
        for (var j = 0; j < k; j++) counts[j] == 0 ? centers[j] : (sum[j][0] / counts[j], sum[j][1] / counts[j], sum[j][2] / counts[j]),
      ];
    }
    final hsl = [
      for (var j = 0; j < k; j++)
        (HSLColor.fromColor(Color.fromARGB(255, centers[j].$1.round(), centers[j].$2.round(), centers[j].$3.round())), counts[j]),
    ];
    // Заметность: доля на картинке плюс насыщенность — яркое пятно на обложке важнее серого фона
    double weight((HSLColor, int) e) => e.$2 / px.length * (0.35 + e.$1.saturation) * (e.$1.lightness < 0.06 ? 0.3 : 1);
    hsl.sort((a, b) => weight(b).compareTo(weight(a)));
    Color pop(HSLColor c, double minL, double maxL) => c
        .withSaturation(math.min(1.0, c.saturation * 1.35 + 0.08))
        .withLightness(c.lightness.clamp(minL, maxL).toDouble())
        .toColor();
    final blobs = [for (var i = 0; i < blobCount; i++) pop(hsl[i % hsl.length].$1, 0.3, 0.6)];
    // Основа — самый частый цвет, но глубоко затемнённый: на нём читается текст
    final common = (List.of(hsl)..sort((a, b) => b.$2.compareTo(a.$2))).first.$1;
    final base = common.withSaturation(math.min(1.0, common.saturation * 1.2 + 0.1)).withLightness(0.13).toColor();
    return AmbientPalette(base, blobs);
  }
}

/// Фон всего окна: «живые» цветные пятна из главных цветов обложки трека или фото профиля.
/// Пятна — это градиенты, а не растянутая картинка: они рисуются гладко, без ступенек в цвете,
/// и считать для новой обложки нужно только палитру — смена фона почти мгновенная
class AmbientBackground extends StatefulWidget {
  const AmbientBackground({super.key});

  @override
  State<AmbientBackground> createState() => _AmbientBackgroundState();
}

class _AmbientBackgroundState extends State<AmbientBackground> with TickerProviderStateMixin {
  static final Map<String, AmbientPalette> _cache = {};
  static final List<String> _order = [];

  // ---------- движение ----------
  /// Время фона в секундах: идёт быстрее на быстрых треках, медленнее на медленных и на паузе, но всегда идёт
  final ValueNotifier<double> _clock = ValueNotifier(0);
  Ticker? _ticker;
  Duration _lastTick = Duration.zero;
  double _speed = 0.8;
  double? _bpm;
  String? _bpmFor;
  PlayerController? _player;

  // ---------- смена палитры ----------
  AmbientPalette _from = AmbientPalette.brand;
  AmbientPalette _to = AmbientPalette.brand;
  late final AnimationController _mix = AnimationController(vsync: this, duration: const Duration(milliseconds: 900), value: 1);

  AmbientPalette get _current => AmbientPalette.lerp(_from, _to, Curves.easeInOut.transform(_mix.value));

  void _show(AmbientPalette p) {
    if (!mounted) return;
    _from = _current;
    _to = p;
    _mix.forward(from: 0);
  }

  void _onTick(Duration elapsed) {
    final dt = (elapsed - _lastTick).inMicroseconds / 1e6;
    if (dt < 1 / 30) return; // 30 кадров в секунду фону хватает
    _lastTick = elapsed;
    final p = _player;
    if (p == null) return;
    final bpm = _bpm;
    final tempo = bpm == null ? 1.0 : (bpm / 105).clamp(0.55, 2.2).toDouble();
    final target = p.playing ? tempo : tempo * 0.4;
    _speed += (target - _speed) * math.min(1.0, dt * 0.8); // скорость меняется плавно
    _clock.value += math.min(dt, 0.1) * _speed;
  }

  void _trackTempo() {
    final app = Services.of(context);
    final t = app.player.current;
    if (t == null || t.id == _bpmFor) return;
    _bpmFor = t.id;
    _bpm = null;
    final id = t.id;
    app.web.bpm(t.artists.first, t.title).then((b) {
      if (mounted && _bpmFor == id) _bpm = b;
    });
  }

  String? _key;
  bool _found = false; // для текущего ключа палитра уже есть
  final Map<String, DateTime> _retried = {};
  Timer? _tick;
  int _seq = 0;
  VoidCallback? _unlisten;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_unlisten != null) return;
    final player = _player = Services.of(context).player;
    final covers = Services.of(context).covers;
    void changed() {
      _sync();
      _trackTempo();
    }

    // Обложка догрузилась позже, чем трек включился: фон без картинки пробует ещё раз
    void coversReady() {
      final k = _key;
      if (_found || k == null) return;
      // Сигналы от обложек частые (прокрутка списков) — повторяем не чаще раза в 4 секунды
      final last = _retried[k];
      if (last != null && DateTime.now().difference(last) < const Duration(seconds: 4)) return;
      _retried[k] = DateTime.now();
      _key = null;
      _sync();
    }

    player.addListener(changed);
    covers.addListener(coversReady);
    // Подстраховка: раз в 2 секунды сверяемся с текущим треком. Если ничего не поменялось — сразу выходим
    _tick = Timer.periodic(const Duration(seconds: 2), (_) => _sync());
    AmbientScope.override.addListener(changed);
    _unlisten = () {
      _tick?.cancel();
      player.removeListener(changed);
      covers.removeListener(coversReady);
      AmbientScope.override.removeListener(changed);
    };
    _sync();
    _trackTempo();
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void dispose() {
    _unlisten?.call();
    _ticker?.dispose();
    _mix.dispose();
    _clock.dispose();
    super.dispose();
  }

  AmbientSource? _trackSource() {
    final app = Services.of(context);
    final t = app.player.current;
    if (t == null) return null;
    // Маленькая копия обложки — та же, что в списке и в плеере: она уже в памяти, фон меняется сразу
    final covers = app.covers;
    return AmbientSource(covers.keyOf(t), bytes: () async => covers.peek(t, px: 160) ?? await covers.forTrack(t, px: 160));
  }

  Future<void> _sync() async {
    final src = AmbientScope.override.value ?? _trackSource();
    if (src?.key == _key) return;
    _key = src?.key;
    _found = false;
    final seq = ++_seq;
    var s = src;
    while (s != null) {
      final hit = _cache[s.key];
      if (hit != null) {
        _found = true;
        _show(hit);
        return;
      }
      AmbientPalette? pal;
      try {
        final b = s.bytes;
        final u = s.url;
        ui.Image? img;
        if (b != null) {
          final bytes = await b();
          if (bytes != null) img = await _decode(bytes);
        } else if (u != null) {
          final link = await u();
          if (link != null && link.isNotEmpty) img = await _fromUrl(link);
        }
        if (img != null) {
          try {
            pal = await AmbientPalette.fromImage(img);
          } finally {
            img.dispose();
          }
        }
      } catch (_) {}
      // Готовую палитру запоминаем, даже если трек уже сменился: вернёмся к нему — фон появится сразу
      if (pal != null && !_cache.containsKey(s.key)) {
        _cache[s.key] = pal;
        _order.add(s.key);
        if (_order.length > 64) _cache.remove(_order.removeAt(0));
      }
      if (!mounted || seq != _seq) return;
      if (pal != null) {
        _found = true;
        _show(pal);
        return;
      }
      if (s.color != null) {
        _found = true;
        _show(AmbientPalette.of(s.color!));
        return;
      }
      s = s.fallback;
    }
    if (!mounted || seq != _seq) return;
    if (src == null) _show(AmbientPalette.brand); // трек без обложки оставляет прежние цвета — меньше мигания
  }

  static Future<ui.Image?> _decode(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes, targetWidth: 32, targetHeight: 32);
    final frame = await codec.getNextFrame();
    codec.dispose();
    return frame.image;
  }

  /// Фото по адресу: маленькой копией, через обычный кеш картинок Flutter
  static Future<ui.Image?> _fromUrl(String url) {
    final done = Completer<ui.Image?>();
    final stream = ResizeImage(NetworkImage(url), width: 32, height: 32).resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener((info, _) {
      if (!done.isCompleted) done.complete(info.image.clone());
      info.dispose();
      stream.removeListener(listener);
    }, onError: (_, __) {
      if (!done.isCompleted) done.complete(null);
      stream.removeListener(listener);
    });
    stream.addListener(listener);
    return done.future.timeout(const Duration(seconds: 15), onTimeout: () => null);
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Stack(fit: StackFit.expand, children: [
        ValueListenableBuilder<bool>(
          valueListenable: AmbientScope.vivid,
          builder: (context, vivid, _) => CustomPaint(
            painter: _LivingPainter(this, _clock, _mix, vivid: vivid),
            child: const SizedBox.expand(),
          ),
        ),
        // Затемнение только снизу, где плеер, и совсем лёгкое сверху — цвета остаются сочными
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                for (var i = 0; i <= 16; i++)
                  Color.lerp(const Color(0x14000000), const Color(0x59000000), () {
                    final t = i / 16;
                    return t * t * (3 - 2 * t);
                  }())!,
              ],
              stops: smoothFadeStops(),
            ),
          ),
        ),
        // Свечение страницы — на всё окно, плавно появляется и исчезает
        ValueListenableBuilder<Color?>(
          valueListenable: AmbientScope.glow,
          builder: (context, c, _) => AnimatedSwitcher(
            duration: const Duration(milliseconds: 700),
            child: c == null ? const SizedBox.expand(key: ValueKey('no-glow')) : SmoothGlow(key: ValueKey(c), color: c),
          ),
        ),
      ]),
    );
  }
}

/// Стеклянная панель: полупрозрачная, со светлой обводкой
class Glass extends StatelessWidget {
  final Widget child;
  final double radius;
  final EdgeInsetsGeometry? padding;
  final Color color;
  const Glass({super.key, required this.child, this.radius = 24, this.padding, this.color = C.surface});

  @override
  Widget build(BuildContext context) => Container(
        padding: padding,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: C.line),
        ),
        child: child,
      );
}

/// Плавный градиент без «лесенки»: прозрачность меняется не по прямой, а по S-кривой
/// и разбита на много шагов — нет резких переломов, которые глаз ловит как полосы
List<Color> smoothFadeColors(Color c, {int steps = 16}) => [
      for (var i = 0; i <= steps; i++)
        () {
          final t = i / steps;
          final e = 1 - t * t * (3 - 2 * t); // smoothstep: мягкий вход и мягкий выход
          return c.withValues(alpha: c.a * e);
        }(),
    ];

List<double> smoothFadeStops({int steps = 16}) => [for (var i = 0; i <= steps; i++) i / steps];

/// Цветное свечение сверху страницы (шапка «Любимого», профили): плавно уходит в прозрачность
/// и медленно «дышит» — центр света неспешно смещается влево-вправо
class SmoothGlow extends StatefulWidget {
  final Color color;
  const SmoothGlow({super.key, required this.color});

  @override
  State<SmoothGlow> createState() => _SmoothGlowState();
}

class _SmoothGlowState extends State<SmoothGlow> with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(vsync: this, duration: const Duration(seconds: 16))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = smoothFadeColors(widget.color);
    final stops = smoothFadeStops();
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _anim,
        builder: (context, _) {
          final v = Curves.easeInOutSine.transform(_anim.value);
          return DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment(-0.5 + v, -1.1),
                radius: 1.6,
                colors: colors,
                stops: stops,
              ),
            ),
          );
        },
      ),
    );
  }
}


/// «Живой» фон, как в Apple Music: цветные пятна плывут по восьмёркам навстречу друг другу,
/// дышат и меняют размер. Узор не повторяется ровно: у пятен разные периоды. Каждое пятно — радиальный
/// градиент с плавным краем, поэтому нет ни границ, ни ступенек в цвете
class _LivingPainter extends CustomPainter {
  final _AmbientBackgroundState state;
  final ValueListenable<double> clock;
  final bool vivid;
  _LivingPainter(this.state, this.clock, Animation<double> mix, {required this.vivid}) : super(repaint: Listenable.merge([clock, mix]));

  @override
  void paint(Canvas canvas, Size size) {
    final pal = state._current;
    final t = clock.value;
    final w = size.width, h = size.height;
    final m = math.max(w, h);
    final c = size.center(Offset.zero);
    final full = Offset.zero & size;
    // Основа: в кинотеатре светлее
    final base = vivid ? Color.lerp(pal.base, pal.blobs.first, 0.25)! : pal.base;
    canvas.drawRect(full, Paint()..color = base);

    final stops = smoothFadeStops(steps: 24);
    void blob(Color color, Offset off, double radius, double alpha) {
      final center = c + off;
      final r = m * radius;
      final paint = Paint()
        ..shader = RadialGradient(colors: smoothFadeColors(color.withValues(alpha: alpha), steps: 24), stops: stops)
            .createShader(Rect.fromCircle(center: center, radius: r));
      canvas.drawCircle(center, r, paint);
    }

    double breathe(double speed, double phase) => 1 + 0.14 * math.sin(t * speed + phase);
    final a = vivid ? 1.0 : 0.85;
    final b = pal.blobs;
    // Большие пятна — медленно, маленькие — быстрее и шире по окну
    blob(b[0], Offset(math.sin(t * 0.21) * w * 0.22, math.cos(t * 0.17) * h * 0.2 - h * 0.15), 0.85 * breathe(0.35, 0), a);
    blob(b[1], Offset(math.sin(t * 0.33 + 1) * w * 0.38, math.sin(t * 0.66 + 2) * h * 0.3), 0.7 * breathe(0.5, 1), a * 0.9);
    blob(b[2], Offset(math.cos(t * 0.29 + 3) * w * 0.4, math.sin(t * 0.58) * h * 0.34), 0.6 * breathe(0.6, 2), a * 0.85);
    blob(b[3], Offset(math.sin(t * 0.25 + 4) * w * 0.33, math.cos(t * 0.5 + 1) * h * 0.36), 0.55 * breathe(0.45, 3), a * 0.8);
    blob(b[4], Offset(math.cos(t * 0.37 + 5) * w * 0.3, math.sin(t * 0.41 + 4) * h * 0.3), 0.45 * breathe(0.7, 4), a * 0.75);
  }

  @override
  bool shouldRepaint(_LivingPainter old) => old.vivid != vivid || !identical(old.state, state);
}
