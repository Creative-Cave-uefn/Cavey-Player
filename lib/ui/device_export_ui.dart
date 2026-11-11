import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../app.dart';
import '../core/device_export.dart';
import '../core/models.dart';
import 'glass_popup.dart';
import 'theme.dart';

/// «Скачать на устройство»: спрашивает папку (последняя запоминается) и запускает выгрузку.
/// [folderName] — для альбома и плейлиста: файлы лягут в подпапку с этим названием и будут пронумерованы
Future<void> exportToDevice(BuildContext context, List<Track> tracks,
    {String? folderName, bool withArtist = true, bool? numbered, String? title}) async {
  final app = Services.of(context);
  if (tracks.isEmpty) {
    app.lib.messages.add('Здесь пока нет треков');
    return;
  }
  final last = app.settings.viewOf('export.dir', '');
  final dir = await getDirectoryPath(
    initialDirectory: last.isEmpty ? null : last,
    confirmButtonText: 'Сохранить сюда',
  );
  if (dir == null) return;
  app.settings.view['export.dir'] = dir;
  app.lib.viewChanged();
  app.exporter.start(tracks, dir, folderName: folderName, numbered: numbered ?? folderName != null, withArtist: withArtist, title: title);
  app.lib.messages.add(folderName == null ? 'Сохраняю на устройство…' : 'Сохраняю «$folderName» на устройство…');
}

/// Карточка выгрузки внизу окна: сколько сохранено и кнопка «Открыть папку»
class ExportCard extends StatelessWidget {
  const ExportCard({super.key});

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    return ListenableBuilder(
      listenable: app.exporter,
      builder: (context, _) {
        final jobs = app.exporter.jobs;
        if (jobs.isEmpty) return const SizedBox.shrink();
        // Material нужен тексту: вне Scaffold без него шрифт по умолчанию и жёлтое подчёркивание
        return Material(
          type: MaterialType.transparency,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final j in jobs.take(3)) _JobCard(job: j, key: ValueKey(j)),
          ]),
        );
      },
    );
  }
}

class _JobCard extends StatelessWidget {
  final ExportJob job;
  const _JobCard({super.key, required this.job});

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    return ListenableBuilder(
      listenable: job,
      builder: (context, _) {
        final progress = job.total == 0 ? 1.0 : (job.done + job.failed) / job.total;
        final status = job.finished
            ? (job.failed > 0 ? 'Сохранено ${job.done} из ${job.total}' : 'Сохранено: ${job.done} из ${job.total}')
            : 'Сохраняю ${job.done + job.failed + 1} из ${job.total}';
        // Та же стеклянная карточка, что у остальных уведомлений приложения
        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: SizedBox(
            width: 330,
            child: GlassPanel(
          radius: 16,
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              Icon(job.finished ? Icons.check_circle_rounded : Icons.download_rounded, size: 18, color: C.accent),
              const SizedBox(width: 8),
              Expanded(child: Text(job.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.text, fontWeight: FontWeight.w600, fontSize: 14))),
              IconButton(
                tooltip: job.finished ? 'Закрыть' : 'Отменить',
                iconSize: 18,
                visualDensity: VisualDensity.compact,
                onPressed: () => app.exporter.dismiss(job),
                icon: const Icon(Icons.close_rounded, color: C.muted),
              ),
            ]),
            Text(job.finished || job.current.isEmpty ? status : '$status · ${job.current}',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.muted, fontSize: 12)),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(value: job.finished ? 1 : progress, minHeight: 4),
              ),
            ),
            if (job.finished && job.done > 0)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 6), visualDensity: VisualDensity.compact),
                  onPressed: () => openFolder(job.dir),
                  icon: const Icon(Icons.folder_open_rounded, size: 18),
                  label: const Text('Открыть папку'),
                ),
              ),
          ]),
            ),
          ),
        );
      },
    );
  }
}
