import 'package:flutter/material.dart';

import '../mobile_main.dart';
import '../ui/theme.dart';
import 'mobile_youtube_service.dart';

/// First Android YouTube vertical slice: one HTTPS video -> local M4A -> optional Drive.
class MobileYoutubePage extends StatefulWidget {
  const MobileYoutubePage({super.key, required this.services});
  final MobileServices services;

  @override
  State<MobileYoutubePage> createState() => _MobileYoutubePageState();
}

class _MobileYoutubePageState extends State<MobileYoutubePage> {
  final link = TextEditingController();
  bool addToLibrary = true;
  String? folderId;

  @override
  void initState() {
    super.initState();
    final folders = widget.services.library.data.sources;
    if (folders.isNotEmpty) folderId = folders.first.id;
  }

  @override
  void dispose() {
    link.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final youtube = widget.services.youtube;
    final folders = widget.services.library.data.sources;
    return Scaffold(
      backgroundColor: C.bg,
      appBar: AppBar(title: const Text('Скачать с YouTube')),
      body: AnimatedBuilder(
        animation: youtube,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text('Аудио из YouTube', style: TextStyle(fontSize: 23, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            const Text(
              'Скачивание выполняется на телефоне, без компьютера и сервера. '
              'Поддерживается ссылка на одно видео. Скачивай только записи, '
              'на которые у тебя есть права и разрешение.',
              style: TextStyle(color: C.muted, height: 1.5),
            ),
            const SizedBox(height: 22),
            TextField(
              controller: link,
              keyboardType: TextInputType.url,
              autocorrect: false,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                labelText: 'Ссылка YouTube',
                hintText: 'https://www.youtube.com/watch?v=...',
                prefixIcon: Icon(Icons.link_rounded),
              ),
              onChanged: (_) => setState(() {}),
              enabled: !youtube.busy,
            ),
            const SizedBox(height: 16),
            if (folders.isNotEmpty) ...[
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: addToLibrary,
                title: const Text('Добавить в общую библиотеку'),
                subtitle: const Text('После скачивания отправить аудио на Google Drive'),
                onChanged: youtube.busy ? null : (v) => setState(() => addToLibrary = v),
              ),
              if (addToLibrary)
                DropdownButtonFormField<String>(
                  value: folderId != null && folders.any((f) => f.id == folderId) ? folderId : null,
                  decoration: const InputDecoration(labelText: 'Папка библиотеки'),
                  items: [
                    for (final folder in folders)
                      DropdownMenuItem(value: folder.id, child: Text(folder.name, overflow: TextOverflow.ellipsis)),
                  ],
                  onChanged: youtube.busy ? null : (id) => setState(() => folderId = id),
                  isExpanded: true,
                ),
              const SizedBox(height: 16),
            ],
            FilledButton.icon(
              onPressed: youtube.busy ||
                      !MobileYoutubeService.isYoutubeUrl(link.text) ||
                      (addToLibrary && folders.isNotEmpty && folderId == null)
                  ? null
                  : () => youtube.download(link.text,
                      uploadFolderId: addToLibrary && folders.isNotEmpty ? folderId : null),
              icon: const Icon(Icons.download_rounded),
              label: Text(youtube.busy ? 'Скачиваю…' : 'Скачать аудио'),
            ),
            if (youtube.busy) ...[
              const SizedBox(height: 20),
              LinearProgressIndicator(value: youtube.progress > 0 ? youtube.progress : null),
            ],
            if (youtube.status.isNotEmpty) ...[
              const SizedBox(height: 18),
              Text(youtube.status, style: const TextStyle(color: C.muted)),
            ],
            if (youtube.error != null) ...[
              const SizedBox(height: 10),
              SelectableText(youtube.error!, style: const TextStyle(color: C.danger)),
            ],
            if (youtube.lastFile != null) ...[
              const SizedBox(height: 20),
              const Text('Файл сохранён в папке приложения Music/YouTube. '
                  'Для воспроизведения через библиотеку используй добавление в Google Drive.',
                  style: TextStyle(color: C.muted, height: 1.5)),
            ],
            const SizedBox(height: 20),
            const Text('В первой версии поддерживается формат M4A без перекодирования. '
                'Загрузка может не работать для отдельных видео, требующих авторизации '
                'или недоступных в выбранном регионе.',
                style: TextStyle(color: C.faint, fontSize: 12, height: 1.5)),
          ],
        ),
      ),
    );
  }
}
