import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../core/models.dart';
import '../mobile_main.dart';
import '../ui/theme.dart';

/// Фон, как на ПК: обложка текущего трека один раз размывается в маленькую картинку,
/// дальше несколько её копий плавно вращаются и плывут (большой слой + три «пятна»).
/// На каждом кадре ничего не размывается, поэтому прокрутка не тормозит. Фон замирает,
/// когда приложение свёрнуто, и замедляется на паузе.
class MobileAmbient extends StatefulWidget {
  const MobileAmbient({super.key, required this.services});
  final MobileServices services;

  @override
  State<MobileAmbient> createState() => _MobileAmbientState();
}

class _MobileAmbientState extends State<MobileAmbient> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static final Map<String, ui.Image> _cache = {};
  static final List<String> _order = [];
  static final Expando<ui.Image> _blob = Expando();

  final ValueNotifier<double> _clock = ValueNotifier(0);
  Ticker? _ticker;
  Duration _last = Duration.zero;
  double _speed = 0.8;
  bool _hidden = false;
  bool _settled = false;

  String? _key;
  ui.Image? _image;
  int _seq = 0;
  Timer? _retry;
  int _attempts = 0;

  @override
  void initState() {
    super.initState();
    widget.services.player.addListener(_changed);
    WidgetsBinding.instance.addObserver(this);
    _ticker = createTicker(_onTick)..start();
    _sync();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.services.player.removeListener(_changed);
    _retry?.cancel();
    _ticker?.dispose();
    _clock.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _hidden = state == AppLifecycleState.hidden || state == AppLifecycleState.paused || state == AppLifecycleState.inactive;
    _updateTicker();
  }

  void _changed() {
    _sync();
    _updateTicker();
  }

  void _updateTicker() {
    final t = _ticker;
    if (t == null) return;
    final paused = !widget.services.player.playing && _settled;
    if (widget.services.player.playing) _settled = false;
    final mute = _hidden || paused;
    if (t.muted != mute) {
      t.muted = mute;
      if (!mute) _last = Duration.zero;
    }
  }

  void _onTick(Duration elapsed) {
    final dt = (elapsed - _last).inMicroseconds / 1e6;
    if (dt < 1 / 20) return; // 20 кадров в секунду: движение медленное, разницы почти не видно
    _last = elapsed;
    final playing = widget.services.player.playing;
    final target = playing ? 1.0 : 0.0;
    _speed += (target - _speed) * math.min(1.0, dt * 0.8);
    _clock.value += math.min(dt, 0.1) * _speed;
    if (!playing && _speed < 0.03) {
      _settled = true;
      _updateTicker();
    }
  }

  Future<void> _sync() async {
    final Track? t = widget.services.player.current;
    final key = t?.id;
    if (key == _key) return;
    _key = key;
    final seq = ++_seq;
    _retry?.cancel();
    if (t == null) {
      if (mounted) setState(() => _image = null);
      return;
    }
    final hit = _cache[t.id];
    if (hit != null) {
      setState(() => _image = hit);
      return;
    }
    ui.Image? img;
    try {
      final covers = widget.services.covers;
      final Uint8List? bytes = covers.peek(t, px: 160) ?? await covers.forTrack(t, px: 160);
      if (bytes != null) img = await _blurred(await _decode(bytes));
    } catch (_) {}
    if (img != null && !_cache.containsKey(t.id)) {
      _cache[t.id] = img;
      _order.add(t.id);
      if (_order.length > 16) _cache.remove(_order.removeAt(0));
    }
    if (!mounted || seq != _seq) return;
    setState(() => _image = img);
    if (img == null && _attempts < 4) {
      // Обложка могла ещё не загрузиться: пробуем позже
      _attempts++;
      _retry = Timer(Duration(seconds: 3 * _attempts), () {
        if (!mounted) return;
        _key = null;
        _sync();
      });
    } else if (img != null) {
      _attempts = 0;
    }
  }

  static Future<ui.Image?> _decode(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes, targetWidth: 64);
    final frame = await codec.getNextFrame();
    codec.dispose();
    return frame.image;
  }

  static Future<ui.Image?> _blurred(ui.Image? src) async {
    if (src == null) return null;
    try {
      const size = 288.0;
      final rec = ui.PictureRecorder();
      final canvas = Canvas(rec);
      final paint = Paint()
        ..filterQuality = FilterQuality.medium
        ..imageFilter = ui.ImageFilter.blur(sigmaX: 30, sigmaY: 30, tileMode: TileMode.clamp);
      canvas.drawImageRect(src, Rect.fromLTWH(0, 0, src.width.toDouble(), src.height.toDouble()),
          const Rect.fromLTWH(-44, -44, size + 88, size + 88), paint);
      final base = await rec.endRecording().toImage(size.toInt(), size.toInt());
      // Пятно: края уходят в прозрачность, чтобы плавающие слои не имели видимых границ
      final rec2 = ui.PictureRecorder();
      final c2 = Canvas(rec2);
      const r = Rect.fromLTWH(0, 0, size, size);
      c2.drawImage(base, Offset.zero, Paint());
      c2.drawRect(
        r,
        Paint()
          ..blendMode = BlendMode.dstIn
          ..shader = RadialGradient(colors: _fadeColors(Colors.white), stops: _fadeStops()).createShader(r),
      );
      _blob[base] = await rec2.endRecording().toImage(size.toInt(), size.toInt());
      return base;
    } catch (_) {
      return null;
    } finally {
      src.dispose();
    }
  }

  static List<Color> _fadeColors(Color c, {int steps = 16}) => [
        for (var i = 0; i <= steps; i++)
          () {
            final t = i / steps;
            return c.withValues(alpha: c.a * (1 - t * t * (3 - 2 * t)));
          }(),
      ];

  static List<double> _fadeStops({int steps = 16}) => [for (var i = 0; i <= steps; i++) i / steps];

  @override
  Widget build(BuildContext context) {
    final img = _image;
    return RepaintBoundary(
      child: Stack(fit: StackFit.expand, children: [
        const ColoredBox(color: C.bg),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 600),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          layoutBuilder: (current, previous) => Stack(fit: StackFit.expand, children: [...previous, if (current != null) current]),
          child: img == null
              ? const _BrandGlow(key: ValueKey('brand'))
              : CustomPaint(
                  key: ValueKey(img),
                  painter: _LivingPainter(img, _blob[img] ?? img, _clock),
                  child: const SizedBox.expand(),
                ),
        ),
        // Затемнение: снизу темнее, там плеер и навигация
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0x59000000), Color(0x8C000000)],
            ),
          ),
        ),
      ]),
    );
  }
}

/// Пока ничего не играет: мягкое свечение фирменных цветов, как на ПК
class _BrandGlow extends StatelessWidget {
  const _BrandGlow({super.key});

  @override
  Widget build(BuildContext context) => const DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(-0.3, -0.6),
            radius: 1.3,
            colors: [Color(0xFF2A3266), Color(0xFF151A36), C.bg],
            stops: [0.0, 0.5, 1.0],
          ),
        ),
      );
}

class _LivingPainter extends CustomPainter {
  _LivingPainter(this.base, this.blob, this.clock) : super(repaint: clock);
  final ui.Image base;
  final ui.Image blob;
  final ValueListenable<double> clock;

  @override
  void paint(Canvas canvas, Size size) {
    final t = clock.value;
    final w = size.width, h = size.height;
    final m = math.max(w, h);
    final c = size.center(Offset.zero);
    final paint = Paint()..filterQuality = FilterQuality.medium;

    void layer(ui.Image img, double rot, Offset off, double scale, double alpha) {
      canvas.save();
      canvas.translate(c.dx + off.dx, c.dy + off.dy);
      canvas.rotate(rot);
      final s = m * scale;
      paint.color = Color.fromRGBO(255, 255, 255, alpha);
      canvas.drawImageRect(img, Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
          Rect.fromCenter(center: Offset.zero, width: s, height: s), paint);
      canvas.restore();
    }

    double breathe(double speed, double phase) => 1 + 0.12 * math.sin(t * speed + phase);
    layer(base, t * 0.16, Offset(math.sin(t * 0.33) * w * 0.1, math.cos(t * 0.27) * h * 0.1), 2.0 * breathe(0.4, 0), 0.9);
    layer(blob, -t * 0.27 + 1.3, Offset(math.sin(t * 0.45 + 1) * w * 0.38, math.sin(t * 0.9 + 2) * h * 0.3), 1.2 * breathe(0.55, 1), 0.8);
    layer(blob, t * 0.35 + 2.6, Offset(math.cos(t * 0.38 + 3) * w * 0.4, math.sin(t * 0.76) * h * 0.34), 0.95 * breathe(0.7, 2), 0.65);
    layer(blob, t * 0.22 + 4.1, Offset(math.sin(t * 0.31 + 4) * w * 0.3, math.cos(t * 0.62 + 1) * h * 0.36), 0.75 * breathe(0.5, 3), 0.5);
  }

  @override
  bool shouldRepaint(_LivingPainter old) => !identical(old.base, base) || !identical(old.blob, blob);
}
