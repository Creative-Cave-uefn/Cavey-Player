import 'dart:async';

import 'package:flutter/material.dart';

import '../app.dart';
import '../core/migration.dart';
import 'glass_popup.dart';
import 'theme.dart';
import 'widgets.dart';

/// Окно при запуске: «Ранее на ваш Google Диск были загружены треки…». Показывается, пока есть что переносить
Future<void> offerMigrationAtStart(BuildContext context) async {
  final app = Services.of(context);
  final stats = await app.migration.offerAtStart();
  if (stats == null || !context.mounted) return;
  final go = await showGlassDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Освободить место на вашем Диске', style: display(18)),
      content: SizedBox(
        width: 440,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            'Ранее на ваш Google Диск были загружены треки (${stats.count}), которые можно перенести на общий диск, '
            'чтобы освободить ${formatBytes(stats.bytes)} вашего Google-хранилища.',
            style: const TextStyle(height: 1.45),
          ),
          const SizedBox(height: 12),
          const Text(
            'Файлы не копируются и не перекачиваются: у них просто меняется владелец, поэтому плейлисты, лайки, '
            'статистика и офлайн-копии остаются на месте. Перенос идёт в фоне, Cavey можно пользоваться как обычно.',
            style: TextStyle(color: C.faint, fontSize: 12.5, height: 1.45),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Позже', style: TextStyle(color: C.muted))),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Перенести')),
      ],
    ),
  );
  if (go == true) {
    unawaited(app.migration.run());
  } else {
    await app.migration.snooze();
  }
}

/// Блок «Перенос на диск владельца» в Настройки → Библиотека
class MigrationSection extends StatefulWidget {
  const MigrationSection({super.key});

  @override
  State<MigrationSection> createState() => _MigrationSectionState();
}

class _MigrationSectionState extends State<MigrationSection> {
  Future<(MigrationStats, Map<String, MigrationStats>, bool)>? _future;
  int _stamp = -1;

  Future<(MigrationStats, Map<String, MigrationStats>, bool)> _load(AppServices app) async {
    final mine = await app.migration.candidates();
    final owner = await app.lib.hubOwnerEmail();
    final iAmOwner = owner != null && app.lib.isMyAccount(owner);
    final all = iAmOwner ? await app.migration.remainingByPerson() : const <String, MigrationStats>{};
    return (LibraryMigration.statsOf(mine), all, iAmOwner);
  }

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    return ListenableBuilder(
      listenable: app.migration,
      builder: (context, _) {
        final m = app.migration;
        // Пересчитываем список после каждого шага переноса
        final stamp = m.moved + m.failed + (m.running ? 1 : 0) * 1000;
        if (_future == null || stamp != _stamp) {
          _stamp = stamp;
          _future = _load(app);
        }
        return FutureBuilder<(MigrationStats, Map<String, MigrationStats>, bool)>(
          future: _future,
          builder: (context, snap) {
            final d = snap.data;
            final mine = d?.$1;
            final all = d?.$2 ?? const <String, MigrationStats>{};
            final iAmOwner = d?.$3 ?? false;
            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Перенос на диск владельца', style: display(20)),
              const SizedBox(height: 8),
              Text(
                'Треки, загруженные на ваш Google Диск раньше, занимают ваше место. Их можно передать владельцу подписки без копирования: '
                'плейлисты, лайки и статистика не пострадают.',
                style: const TextStyle(color: C.muted, fontSize: 13, height: 1.45),
              ),
              const SizedBox(height: 12),
              if (m.running)
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(m.status, style: const TextStyle(color: C.muted)),
                  const SizedBox(height: 8),
                  LinearProgressIndicator(value: m.total == 0 ? null : (m.moved + m.failed) / m.total),
                ])
              else if (iAmOwner)
                const Text('Вы владелец подписки: ваши файлы уже на вашем диске.', style: TextStyle(color: C.muted))
              else if (mine == null)
                const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
              else if (mine.count == 0)
                const Text('Переносить нечего: все ваши треки уже на диске владельца.', style: TextStyle(color: C.muted))
              else
                Row(children: [
                  FilledButton.icon(
                    onPressed: () => unawaited(m.run()),
                    icon: const Icon(Icons.drive_file_move_outlined, size: 18),
                    label: Text('Перенести ${countTracks(mine.count)} · ${formatBytes(mine.bytes)}'),
                  ),
                ]),
              if (m.error != null) ...[
                const SizedBox(height: 8),
                Text(m.error!, style: const TextStyle(color: C.danger, fontSize: 13)),
              ] else if (!m.running && m.failed > 0) ...[
                const SizedBox(height: 8),
                Text('Не удалось перенести: ${m.failed}. Повторите позже.', style: const TextStyle(color: C.danger, fontSize: 13)),
              ],
              if (iAmOwner && all.isNotEmpty) ...[
                const SizedBox(height: 16),
                const Text('Ещё лежит на дисках участников', style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                for (final e in all.entries)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(children: [
                      Expanded(child: Text(app.lib.firstNameOf(e.key), maxLines: 1, overflow: TextOverflow.ellipsis)),
                      Text('${countTracks(e.value.count)} · ${formatBytes(e.value.bytes)}', style: const TextStyle(color: C.muted, fontSize: 13)),
                    ]),
                  ),
                const SizedBox(height: 4),
                const Text('Перенос делает каждый участник у себя в Cavey (Google передаёт владение только текущим владельцем). '
                    'Файлы тех, кто не откроет Cavey, останутся у них.',
                    style: TextStyle(color: C.faint, fontSize: 12, height: 1.4)),
              ],
            ]);
          },
        );
      },
    );
  }
}
