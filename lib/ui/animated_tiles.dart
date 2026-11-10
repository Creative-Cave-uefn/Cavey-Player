import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Плитка для [AnimatedTiles]: ключ нужен, чтобы плитка помнила себя при перестановке
class TileSlot {
  final Object key;
  final Widget child;
  const TileSlot(this.key, this.child);
}

/// Плитки одного размера в несколько столбцов (как Wrap), но при смене ширины (разворачивается левая или правая
/// панель, меняется окно) каждая плитка плавно переезжает на новое место, а не прыгает.
class AnimatedTiles extends StatelessWidget {
  final List<TileSlot> tiles;
  final double tileWidth;

  /// Высота строки (расстояние между верхами соседних рядов без промежутка). Плитки сверху выравниваются
  final double rowHeight;
  final double spacing;
  final double runSpacing;
  final Duration duration;
  const AnimatedTiles({
    super.key,
    required this.tiles,
    required this.tileWidth,
    required this.rowHeight,
    this.spacing = 12,
    this.runSpacing = 12,
    this.duration = const Duration(milliseconds: 320),
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final width = box.maxWidth.isFinite ? box.maxWidth : tileWidth;
      final cols = math.max(1, ((width + spacing) / (tileWidth + spacing)).floor());
      final rows = tiles.isEmpty ? 0 : (tiles.length / cols).ceil();
      final height = rows == 0 ? 0.0 : rows * rowHeight + (rows - 1) * runSpacing;
      return SizedBox(
        height: height,
        width: width,
        child: Stack(clipBehavior: Clip.none, children: [
          for (var i = 0; i < tiles.length; i++)
            AnimatedPositioned(
              key: ValueKey(tiles[i].key),
              duration: duration,
              curve: Curves.easeOutCubic,
              left: (i % cols) * (tileWidth + spacing),
              top: (i ~/ cols) * (rowHeight + runSpacing),
              width: tileWidth,
              // Высоту не задаём: плитка занимает сколько ей нужно, но не больше строки
              child: Align(alignment: Alignment.topLeft, child: tiles[i].child),
            ),
        ]),
      );
    });
  }
}
