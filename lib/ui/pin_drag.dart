import 'package:flutter/material.dart';

import '../app.dart';
import '../core/pin_order.dart';
import 'theme.dart';

/// Пункт коллекции, который можно перетащить мышью. Бросили на другой пункт — он занимает его место:
/// внутри закреплённых это перестановка, из остальных в закреплённые — закрепление, и наоборот
class PinDrag extends StatelessWidget {
  final String token;
  final Widget child;

  /// Полоска-указатель, куда встанет пункт: слева у плиток или сверху у строк
  final bool vertical;
  final void Function(String dragged, String target) onDrop;
  const PinDrag({super.key, required this.token, required this.child, required this.onDrop, this.vertical = false});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth.isFinite ? box.maxWidth : 200.0;
      return DragTarget<String>(
        onWillAcceptWithDetails: (d) => d.data != token,
        onAcceptWithDetails: (d) => onDrop(d.data, token),
        builder: (context, over, _) => Stack(clipBehavior: Clip.none, children: [
          Draggable<String>(
            data: token,
            maxSimultaneousDrags: 1,
            dragAnchorStrategy: pointerDragAnchorStrategy,
            feedback: Material(
              type: MaterialType.transparency,
              child: IgnorePointer(
                child: Opacity(opacity: 0.85, child: SizedBox(width: w, child: child)),
              ),
            ),
            childWhenDragging: Opacity(opacity: 0.35, child: child),
            child: child,
          ),
          if (over.isNotEmpty)
            Positioned(
              left: vertical ? 0 : -6,
              right: vertical ? 0 : null,
              top: vertical ? -1 : 0,
              bottom: vertical ? null : 0,
              width: vertical ? null : 3,
              height: vertical ? 3 : null,
              child: IgnorePointer(
                child: DecoratedBox(decoration: BoxDecoration(color: C.accent, borderRadius: BorderRadius.circular(2))),
              ),
            ),
        ]),
      );
    });
  }
}

/// Булавка в углу или в конце строки закреплённого пункта
class PinMark extends StatelessWidget {
  final double size;
  const PinMark({super.key, this.size = 14});

  @override
  Widget build(BuildContext context) => Icon(Icons.push_pin_rounded, size: size, color: C.accent);
}

/// Применяет бросок: считает новый порядок закреплённых и сохраняет его в библиотеке
void applyPinDrop(AppServices app, List<String> shown, int pinnedShown, String dragged, String target) {
  final after = dropOnto(shown, pinnedShown, dragged, target);
  if (after == null) return;
  final all = app.lib.pinned;
  app.lib.setPinned(mergePins(all, shown.take(pinnedShown).toList(), after));
}
