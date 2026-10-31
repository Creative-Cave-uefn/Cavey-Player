import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app.dart';
import '../core/downloader/service.dart';
import 'shell.dart';
import 'theme.dart';
import 'widgets.dart';

/// Раздел «Скачать»: ссылка или название → трек на Диске и в библиотеке у всех
class DownloadPage extends StatefulWidget {
  final bool compact;
  const DownloadPage({super.key, required this.compact});
  @override
  State<DownloadPage> createState() => _DownloadPageState();
}

class _DownloadPageState extends State<DownloadPage> {
  final _input = TextEditingController();
  String? _target;
  bool _makePlaylist = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final dl = Services.of(context).downloads;
      if (dl.toolsVersion.isEmpty) dl.refreshVersion();
    });
  }

  void _start() {
    final app = Services.of(context);
    final target = _target ?? app.settings.hubId;
    if (target == null || _input.text.trim().isEmpty) return;
    app.downloads.enqueue(_input.text, target, makePlaylist: _makePlaylist);
    _input.clear();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
    if (text != null && text.isNotEmpty) {
      _input.text = text;
      _input.selection = TextSelection.collapsed(offset: text.length);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final pad = widget.compact ? 20.0 : 36.0;
    return ListenableBuilder(
      listenable: Listenable.merge([app.downloads, app.lib]),
      builder: (context, _) {
        final dl = app.downloads;
        final sources = app.lib.data.sources;
        final target = sources.any((s) => s.id == _target) ? _target : (sources.any((s) => s.id == app.settings.hubId) ? app.settings.hubId : sources.firstOrNull?.id);
        return ListView(padding: EdgeInsets.fromLTRB(pad, 34, pad, 40), children: [
          Text('Скачать', style: display(36, weight: FontWeight.w700)),
          const SizedBox(height: 10),
          Text(
            switch (app.settings.downloadProvider) {
              'sockseek' => 'Soulseek (Sockseek): «Исполнитель - Название» или ссылка Spotify, Deezer, Яндекс Музыки. Ищет файлы в P2P сети.',
              'bandcamp' => 'Bandcamp: вставьте прямую ссылку на трек или альбом (artist.bandcamp.com/track/... или /album/...). Скачивается доступный для прослушивания аудиопоток, а не оригинальный FLAC.',
              _ => 'YouTube / YouTube Music: ссылка YouTube, Spotify, Deezer, Яндекс Музыки или «Исполнитель - Название». Аудио ищется на YouTube и загружается в библиотеку.',
            },
            style: const TextStyle(color: C.muted, fontSize: 15, height: 1.5),
          ),
          const SizedBox(height: 8),
          Text('Активный источник: ${switch (app.settings.downloadProvider) { 'bandcamp' => 'Bandcamp', 'sockseek' => 'Soulseek', _ => 'YouTube' }}. Переключить можно в настройках аккаунта.',
              style: const TextStyle(color: C.faint, fontSize: 13)),
          const SizedBox(height: 24),
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(14), border: Border.all(color: C.line)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    autofocus: true,
                    decoration: InputDecoration(
                      hintText: app.settings.downloadProvider == 'bandcamp' ? 'Ссылка Bandcamp на трек или альбом' : 'Ссылка или «Исполнитель - Название»',
                      prefixIcon: const Icon(Icons.link_rounded, size: 18),
                      suffixIcon: IconButton(
                        tooltip: 'Вставить из буфера',
                        icon: const Icon(Icons.content_paste_rounded, size: 18),
                        onPressed: _paste,
                      ),
                    ),
                    onSubmitted: (_) => _start(),
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton.icon(
                  onPressed: target == null ? null : _start,
                  icon: const Icon(Icons.download_rounded, size: 18),
                  label: const Text('Скачать'),
                ),
              ]),
              const SizedBox(height: 14),
              DropdownButtonFormField<String>(
                value: app.settings.downloadProvider,
                decoration: const InputDecoration(labelText: 'Источник музыки'),
                items: const [
                  DropdownMenuItem(value: 'youtube', child: Text('YouTube')),
                  DropdownMenuItem(value: 'sockseek', child: Text('Soulseek / Sockseek')),
                  DropdownMenuItem(value: 'bandcamp', child: Text('Bandcamp')),
                ],
                onChanged: dl.busy ? null : (value) {
                  if (value == null) return;
                  setState(() => app.settings.downloadProvider = value);
                  app.lib.saveSettings();
                },
              ),
              const SizedBox(height: 14),
              Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                const Text('Куда положить:', style: TextStyle(color: C.muted)),
                if (sources.isEmpty)
                  const Text('сначала добавьте папку с музыкой', style: TextStyle(color: C.danger))
                else
                  DropdownButton<String>(
                    value: target,
                    dropdownColor: C.raised,
                    underline: const SizedBox.shrink(),
                    items: [
                      for (final s in sources)
                        DropdownMenuItem(value: s.id, child: Text(s.id == app.settings.hubId ? '${s.name} (общая папка)' : s.name)),
                    ],
                    onChanged: (v) => setState(() => _target = v),
                  ),
                const Text('Альбомы и плейлисты — в отдельную подпапку.', style: TextStyle(color: C.faint, fontSize: 13)),
              ]),
              const SizedBox(height: 6),
              InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: () => setState(() => _makePlaylist = !_makePlaylist),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    SizedBox(
                      width: 24,
                      height: 24,
                      child: Checkbox(
                        value: _makePlaylist,
                        activeColor: C.accent,
                        checkColor: C.accentInk,
                        onChanged: (v) => setState(() => _makePlaylist = v ?? true),
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Flexible(
                      child: Text('Сделать плейлист в Cavey (для ссылок на плейлисты)', style: TextStyle(color: C.muted)),
                    ),
                  ]),
                ),
              ),
            ]),
          ),
          const SizedBox(height: 14),
          Row(children: [
            Expanded(
              child: Text(
                dl.installing
                    ? 'Устанавливаю программы для скачивания…'
                    : dl.moduleVersion.isEmpty
                        ? 'Модуль скачки и программы для него ставятся сами при первом скачивании.'
                        : 'Модуль скачки ${dl.moduleVersion} · yt-dlp: ${dl.toolsVersion.isEmpty ? '…' : dl.toolsVersion}. '
                            'Обновляются сами.',
                style: const TextStyle(color: C.faint, fontSize: 13),
              ),
            ),
            TextButton.icon(
              onPressed: dl.busy ? null : dl.updateTools,
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: const Text('Обновить загрузчик'),
            ),
          ]),
          const SizedBox(height: 26),
          if (dl.jobs.isNotEmpty)
            Row(children: [
              Expanded(child: Text('Задания', style: display(20))),
              if (dl.jobs.any((j) => j.state == JobState.done || j.state == JobState.failed))
                TextButton(onPressed: dl.clearFinished, child: const Text('Убрать завершённые')),
            ]),
          const SizedBox(height: 10),
          for (final j in dl.jobs) _JobCard(job: j),
        ]);
      },
    );
  }
}

class _JobCard extends StatelessWidget {
  final DownloadJob job;
  const _JobCard({required this.job});

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (job.state) {
      JobState.queued => ('В очереди', C.faint),
      JobState.running => (job.total > 1 ? 'Скачиваю ${job.done + job.failed} из ${job.total}' : 'Скачиваю…', C.accent),
      JobState.done => (job.failed > 0 ? 'Готово, не скачалось: ${job.failed}' : 'Готово', const Color(0xFF7CD3B8)),
      JobState.failed => ('Не получилось', C.danger),
    };
    final progress = job.total > 1 ? (job.done + job.failed) / job.total : null;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: C.line)),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: job.state == JobState.running,
          tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
          title: Text(job.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                job.folderName.isEmpty ? label : '$label, в «${job.folderName}»',
                style: TextStyle(color: color, fontSize: 13),
              ),
              if (job.state == JobState.running) ...[
                const SizedBox(height: 6),
                LinearProgressIndicator(value: progress),
              ],
              if (job.playlistId != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: TextButton.icon(
                    style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(0, 30)),
                    onPressed: () => NavScope.of(context).go(Nav('playlist', job.playlistId!)),
                    icon: const Icon(Icons.queue_music_rounded, size: 16),
                    label: Text('Открыть плейлист «${job.playlistName}»'),
                  ),
                ),
            ]),
          ),
          children: [
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 260),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: const Color(0x40000000), borderRadius: BorderRadius.circular(8)),
              child: SingleChildScrollView(
                reverse: true,
                child: SelectableText(
                  job.log.isEmpty ? 'Пока пусто' : job.log.join('\n'),
                  style: const TextStyle(fontFamily: 'Consolas', fontSize: 12, color: C.muted, height: 1.4),
                ),
              ),
            ),
            if (job.input != job.title)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(job.input, style: const TextStyle(color: C.faint, fontSize: 12)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Плашка «перетащите сюда» для экрана всех треков
class DropHint extends StatelessWidget {
  const DropHint({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: C.line, width: 1.5),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.file_upload_outlined, size: 18, color: C.faint),
        const SizedBox(width: 10),
        Flexible(
          child: Text(
            'Перетащите сюда файлы или папки с музыкой — они загрузятся на Диск. '
            'Ссылки и названия — в разделе «Скачать».',
            style: const TextStyle(color: C.faint, fontSize: 13),
          ),
        ),
      ]),
    );
  }
}

