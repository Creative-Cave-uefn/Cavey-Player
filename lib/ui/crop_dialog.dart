import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'theme.dart';
import 'glass_popup.dart';

/// Окно кадрирования: картинку двигают мышью и увеличивают колесом или ползунком, рамка стоит на месте.
/// Возвращает PNG вырезанной области или null (отмена, или файл не открылся как картинка).
/// [aspect] — ширина к высоте рамки, [outWidth] — максимальная ширина результата в пикселях.
Future<Uint8List?> cropImageDialog(
  BuildContext context,
  Uint8List source, {
  required String title,
  double aspect = 1,
  int outWidth = 800,
  bool round = false,
}) async {
  final ui.Image img;
  try {
    final buf = await ui.ImmutableBuffer.fromUint8List(source);
    final desc = await ui.ImageDescriptor.encoded(buf);
    final w = desc.width;
    final h = desc.height;
    if (w <= 0 || h <= 0) return null;
    // Огромные фото уменьшаем при чтении, чтобы не держать в памяти сотни мегабайт
    final long = math.max(w, h);
    final k = long > 3000 ? 3000 / long : 1.0;
    final codec = await desc.instantiateCodec(targetWidth: (w * k).round(), targetHeight: (h * k).round());
    img = (await codec.getNextFrame()).image;
    codec.dispose();
    desc.dispose();
    buf.dispose();
  } catch (_) {
    return null;
  }
  if (!context.mounted) {
    img.dispose();
    return null;
  }
  final result = await showGlassDialog<Uint8List>(
    context: context,
    builder: (ctx) => _CropDialog(image: img, title: title, aspect: aspect, outWidth: outWidth, round: round),
  );
  img.dispose();
  return result;
}

class _CropDialog extends StatefulWidget {
  final ui.Image image;
  final String title;
  final double aspect;
  final int outWidth;
  final bool round;
  const _CropDialog({required this.image, required this.title, required this.aspect, required this.outWidth, required this.round});

  @override
  State<_CropDialog> createState() => _CropDialogState();
}

class _CropDialogState extends State<_CropDialog> {
  static const _maxZoom = 6.0;

  late final double vw = widget.aspect > 1.5 ? 520 : 400;
  late final double vh = vw / widget.aspect;
  double get iw => widget.image.width.toDouble();
  double get ih => widget.image.height.toDouble();
  late final double minScale = math.max(vw / iw, vh / ih);

  double _zoom = 1;
  late double _cx = iw / 2;
  late double _cy = ih / 2;
  bool _busy = false;

  double get _scale => minScale * _zoom;

  /// Область картинки, которая сейчас лежит в рамке
  Rect get _src {
    final s = _scale;
    final hw = vw / (2 * s);
    final hh = vh / (2 * s);
    return Rect.fromLTRB(_cx - hw, _cy - hh, _cx + hw, _cy + hh);
  }

  void _clamp() {
    final s = _scale;
    final hw = vw / (2 * s);
    final hh = vh / (2 * s);
    _cx = _cx.clamp(hw, math.max(hw, iw - hw)).toDouble();
    _cy = _cy.clamp(hh, math.max(hh, ih - hh)).toDouble();
  }

  void _setZoom(double z) => setState(() {
        _zoom = z.clamp(1.0, _maxZoom).toDouble();
        _clamp();
      });

  Future<void> _done() async {
    setState(() => _busy = true);
    try {
      final src = _src;
      final w = math.max(1, math.min(widget.outWidth, src.width.round()));
      final h = math.max(1, (w / widget.aspect).round());
      final rec = ui.PictureRecorder();
      final canvas = Canvas(rec);
      canvas.drawImageRect(widget.image, src, Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
          Paint()..filterQuality = FilterQuality.high..isAntiAlias = true);
      final pic = rec.endRecording();
      final out = await pic.toImage(w, h);
      final data = await out.toByteData(format: ui.ImageByteFormat.png);
      out.dispose();
      pic.dispose();
      if (!mounted) return;
      if (data == null) {
        setState(() => _busy = false);
        return;
      }
      Navigator.pop(context, data.buffer.asUint8List());
    } catch (_) {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title, style: display(18)),
      content: SizedBox(
        width: vw,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Listener(
            onPointerSignal: (e) {
              if (e is PointerScrollEvent) _setZoom(_zoom * (e.scrollDelta.dy < 0 ? 1.1 : 1 / 1.1));
            },
            child: MouseRegion(
              cursor: SystemMouseCursors.grab,
              child: GestureDetector(
                onPanUpdate: (d) => setState(() {
                  _cx -= d.delta.dx / _scale;
                  _cy -= d.delta.dy / _scale;
                  _clamp();
                }),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: CustomPaint(
                    size: Size(vw, vh),
                    painter: _CropPainter(widget.image, _src, widget.round),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(children: [
            const Icon(Icons.zoom_out_rounded, size: 18, color: C.muted),
            Expanded(child: Slider(value: _zoom, min: 1, max: _maxZoom, onChanged: _busy ? null : _setZoom)),
            const Icon(Icons.zoom_in_rounded, size: 18, color: C.muted),
          ]),
          const Text('Перетащите картинку мышью, колесо мыши или ползунок меняют масштаб.',
              style: TextStyle(color: C.faint, fontSize: 12, height: 1.4)),
        ]),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('Отмена', style: TextStyle(color: C.muted))),
        FilledButton(onPressed: _busy ? null : _done, child: const Text('Готово')),
      ],
    );
  }
}

class _CropPainter extends CustomPainter {
  final ui.Image image;
  final Rect src;
  final bool round;
  _CropPainter(this.image, this.src, this.round);

  @override
  void paint(Canvas canvas, Size size) {
    final dst = Offset.zero & size;
    canvas.drawImageRect(image, src, dst, Paint()..filterQuality = FilterQuality.medium);
    if (round) {
      final shade = Path.combine(PathOperation.difference, Path()..addRect(dst), Path()..addOval(dst));
      canvas.drawPath(shade, Paint()..color = Colors.black.withValues(alpha: 0.55));
      canvas.drawOval(dst.deflate(0.5), Paint()..style = PaintingStyle.stroke..color = Colors.white70);
    } else {
      final line = Paint()..color = Colors.white.withValues(alpha: 0.28)..strokeWidth = 1;
      for (var i = 1; i < 3; i++) {
        canvas.drawLine(Offset(size.width * i / 3, 0), Offset(size.width * i / 3, size.height), line);
        canvas.drawLine(Offset(0, size.height * i / 3), Offset(size.width, size.height * i / 3), line);
      }
      canvas.drawRect(dst.deflate(0.5), Paint()..style = PaintingStyle.stroke..color = Colors.white54);
    }
  }

  @override
  bool shouldRepaint(_CropPainter old) => old.src != src || old.image != image || old.round != round;
}
