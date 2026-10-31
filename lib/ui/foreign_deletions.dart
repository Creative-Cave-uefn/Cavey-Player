import 'package:flutter/material.dart';

import '../core/library.dart';
import 'glass_popup.dart';
import 'theme.dart';
import 'widgets.dart';

/// Окно «Друзья предлагают удалить» (А3): мои файлы, которые удалил не я.
/// Пока владелец не нажал «Удалить», файл остаётся на Диске.
bool _asking = false;

Future<void> askForeignDeletions(BuildContext context, LibraryController lib) async {
  if (_asking) return;
  final pending = lib.foreignDeletions;
  if (pending.isEmpty) return;
  _asking = true;
  try {
    final names = {for (final id in pending.keys) id: lib.data.deletedName[id] ?? 'Трек'};
    final ids = pending.keys.toList();
    final answer = await showGlassDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Друзья предлагают удалить: ${ids.length}', style: display(18)),
        content: SizedBox(
          width: 420,
          height: (ids.length * 44.0).clamp(80, 320),
          child: ListView(children: [
            for (final id in ids)
              ListTile(
                dense: true,
                title: Text(names[id]!, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(lib.data.members[pending[id]] ?? pending[id]!, style: const TextStyle(color: C.muted)),
              ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Оставить')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: C.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Удалить (в корзину Диска)'),
          ),
        ],
      ),
    );
    if (answer == true) {
      await lib.approveForeignDeletions(ids);
    } else if (answer == false) {
      await lib.keepForeignDeletions(ids);
    }
  } finally {
    _asking = false;
  }
}
