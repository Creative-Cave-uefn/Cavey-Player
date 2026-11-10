import 'package:flutter/material.dart';

import '../core/library.dart';
import '../core/models.dart';
import 'delete_dialog.dart';
import 'glass_popup.dart';
import 'theme.dart';
import 'widgets.dart';

/// Окно «Друзья предлагают удалить» (А3): мои файлы, которые удалил не я.
/// Пока загрузивший не нажал «Удалить», файл остаётся на Диске.
bool _asking = false;

/// «≈ 320 кбит/с · 8,2 МБ» — всё, что можно сказать о качестве по размеру и длительности
String _quality(Track t) {
  final parts = <String>[];
  final ms = t.durationMs ?? 0;
  if (ms > 0 && t.size > 0) parts.add('≈ ${(t.size * 8 / ms).round()} кбит/с');
  if (t.size > 0) parts.add('${(t.size / 1048576).toStringAsFixed(1).replaceAll('.', ',')} МБ');
  return parts.join(' · ');
}

Future<void> askForeignDeletions(BuildContext context, LibraryController lib) async {
  if (_asking) return;
  final pending = lib.foreignDeletions;
  if (pending.isEmpty) return;
  _asking = true;
  try {
    final ids = pending.keys.toList();
    final selected = <String>{...ids};
    final answer = await showGlassDialog<Set<String>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text('Друзья предлагают удалить: ${ids.length}', style: display(18)),
          content: SizedBox(
            width: 540,
            height: (ids.length * 112.0).clamp(120, 440),
            child: ListView(children: [
              for (final id in ids)
                _DeletionCard(
                  lib: lib,
                  id: id,
                  proposer: pending[id]!,
                  checked: selected.contains(id),
                  onChanged: (v) => setState(() => v ? selected.add(id) : selected.remove(id)),
                ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, <String>{}), child: const Text('Оставить все')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: C.danger),
              onPressed: selected.isEmpty ? null : () => Navigator.pop(ctx, {...selected}),
              child: Text('Удалить выбранные (${selected.length})'),
            ),
          ],
        ),
      ),
    );
    if (answer == null) return;
    final del = ids.where(answer.contains).toList();
    final keep = ids.where((id) => !answer.contains(id)).toList();
    if (del.isNotEmpty) await lib.approveForeignDeletions(del);
    if (keep.isNotEmpty) await lib.keepForeignDeletions(keep);
  } finally {
    _asking = false;
  }
}

class _DeletionCard extends StatelessWidget {
  final LibraryController lib;
  final String id, proposer;
  final bool checked;
  final ValueChanged<bool> onChanged;
  const _DeletionCard({required this.lib, required this.id, required this.proposer, required this.checked, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final info = lib.data.deletedInfo[id];
    final snap = info?['t'];
    final track = snap is Map ? LibraryController.trackFromSnapshot(id, snap) : null;
    final keepInfo = info?['keep'];
    final keepTrack = keepInfo is Map && keepInfo['t'] is Map
        ? LibraryController.trackFromSnapshot('${keepInfo['id']}', keepInfo['t'] as Map)
        : null;
    final reason = '${info?['k'] ?? ''}';
    final note = '${info?['note'] ?? ''}';
    final title = track?.title ?? (lib.data.deletedName[id] ?? 'Трек');
    final artist = track?.displayArtist ?? '';

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: C.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: checked ? C.danger.withValues(alpha: 0.5) : C.line),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Checkbox(value: checked, onChanged: (v) => onChanged(v ?? false)),
        if (track != null) ...[
          CoverImage(track: track, size: 64, radius: 8),
          const SizedBox(width: 12),
        ],
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
            if (artist.isNotEmpty) Text(artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.muted, fontSize: 13)),
            if (track != null && _quality(track).isNotEmpty)
              Text(_quality(track), style: const TextStyle(color: C.faint, fontSize: 12)),
            const SizedBox(height: 4),
            Text('Предлагает ${lib.nameOf(proposer)}', style: const TextStyle(color: C.muted, fontSize: 12)),
            if (reason.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(color: C.danger.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(6)),
                    child: Text(deleteReasonLabel(reason), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                  ),
                  if (note.isNotEmpty) Text('«$note»', style: const TextStyle(color: C.muted, fontSize: 12)),
                ]),
              ),
            if (keepTrack != null) _KeepCopy(lib: lib, keep: keepTrack),
          ]),
        ),
      ]),
    );
  }
}

/// Для дубликатов: какая копия остаётся в библиотеке
class _KeepCopy extends StatelessWidget {
  final LibraryController lib;
  final Track keep;
  const _KeepCopy({required this.lib, required this.keep});

  @override
  Widget build(BuildContext context) {
    final live = lib.data.tracks[lib.data.resolve(keep.id)] ?? keep; // если копию успели поправить — показываем свежую
    final who = live.by.isEmpty ? '' : 'загрузил(а) ${lib.nameOf(live.by)}';
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(color: C.bg.withValues(alpha: 0.4), borderRadius: BorderRadius.circular(8)),
      child: Row(children: [
        CoverImage(track: live, size: 36, radius: 6),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Останется эта копия', style: TextStyle(color: C.faint, fontSize: 11)),
            Text('${live.title} — ${live.displayArtist}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5)),
            Text([if (who.isNotEmpty) who, _quality(live)].where((e) => e.isNotEmpty).join(' · '),
                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.faint, fontSize: 11.5)),
          ]),
        ),
      ]),
    );
  }
}
