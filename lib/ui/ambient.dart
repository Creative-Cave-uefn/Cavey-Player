import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../app.dart';
import '../core/models.dart';
import 'theme.dart';

/// Фон всего окна: размытая обложка текущего трека, плавно сменяется вместе с треком.
/// Обложка размывается один раз в маленькую картинку (160×160) и дальше просто растягивается:
/// на каждом кадре ничего не размываем, поэтому прокрутка и анимации не тормозят.
class AmbientBackground extends StatefulWidget {
  const AmbientBackground({super.key});

  @override
  State<AmbientBackground> createState() => _AmbientBackgroundState();
}

class _AmbientBackgroundState extends State<AmbientBackground> {
  static final Map<String, ui.Image> _cache = {};
  static final List<String> _order = [];

  String? _key;
  ui.Image? _image;
  int _seq = 0;
  VoidCallback? _unlisten;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_unlisten != null) return;
    final player = Services.of(context).player;
    void onPlayer() => _sync(player.current);
    player.addListener(onPlayer);
    _unlisten = () => player.removeListener(onPlayer);
    _sync(player.current);
  }

  @override
  void dispose() {
    _unlisten?.call();
    super.dispose();
  }

  Future<void> _sync(Track? t) async {
    final app = Services.of(context);
    final key = t == null ? null : app.covers.keyOf(t);
    if (key == _key) return;
    _key = key;
    final seq = ++_seq;
    if (t == null || key == null) {
      setState(() => _image = null);
      return;
    }
    final hit = _cache[key];
    if (hit != null) {
      setState(() => _image = hit);
      return;
    }
    final bytes = await app.covers.forTrack(t);
    final img = bytes == null ? null : await _blurred(bytes);
    if (!mounted || seq != _seq) return;
    if (img != null) {
      _cache[key] = img;
      _order.add(key);
      // Держим несколько последних: назад-вперёд по очереди без пересчёта
      if (_order.length > 8) _cache.remove(_order.removeAt(0));
    }
    setState(() => _image = img);
  }

  static Future<ui.Image?> _blurred(Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: 64);
      final frame = await codec.getNextFrame();
      final src = frame.image;
      const size = 160.0;
      final rec = ui.PictureRecorder();
      final canvas = Canvas(rec);
      final paint = Paint()
        ..filterQuality = FilterQuality.medium
        ..imageFilter = ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16, tileMode: TileMode.clamp);
      // Чуть шире холста, чтобы края размытия не темнели
      canvas.drawImageRect(src, Rect.fromLTWH(0, 0, src.width.toDouble(), src.height.toDouble()),
          const Rect.fromLTWH(-24, -24, size + 48, size + 48), paint);
      final img = await rec.endRecording().toImage(size.toInt(), size.toInt());
      src.dispose();
      codec.dispose();
      return img;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final img = _image;
    return RepaintBoundary(
      child: Stack(fit: StackFit.expand, children: [
        const ColoredBox(color: C.bg),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 1200),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          layoutBuilder: (current, previous) => Stack(fit: StackFit.expand, children: [...previous, if (current != null) current]),
          child: img == null
              ? const _BrandGlow(key: ValueKey('brand'))
              : RawImage(
                  key: ValueKey(img),
                  image: img,
                  fit: BoxFit.cover,
                  filterQuality: FilterQuality.medium,
                  opacity: const AlwaysStoppedAnimation(0.85),
                ),
        ),
        // Затемнение: текст читается на любой обложке, снизу темнее — там плеер
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

/// Пока ничего не играет: мягкое свечение фирменных цветов
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
