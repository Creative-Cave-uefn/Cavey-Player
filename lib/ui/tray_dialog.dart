import 'package:flutter/material.dart';

import 'theme.dart';
import 'glass_popup.dart';

/// Первый раз по крестику: свернуть в трей или закрыть совсем.
/// true — в трей, false — закрыть, null — человек передумал.
Future<bool?> askTrayOnClose(BuildContext context) {
  return showGlassDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Закрыть Cave Player?', style: display(18)),
      content: const SizedBox(
        width: 400,
        child: Text(
          'Можно свернуть Cave Player в трей: музыка продолжит играть, а открыть окно можно значком у часов. '
          'Выбор можно поменять в настройках.',
          style: TextStyle(color: C.muted, height: 1.45),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена', style: TextStyle(color: C.muted))),
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Закрыть совсем')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Свернуть в трей')),
      ],
    ),
  );
}
