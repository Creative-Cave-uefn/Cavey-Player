import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../app.dart';
import '../core/models.dart';
import '../core/tags.dart';
import 'shell.dart';
import 'theme.dart';
import 'tracks_view.dart';
import 'widgets.dart';

// ---------- исполнители ----------

class ArtistsPage extends StatelessWidget {
  final bool compact;
  const ArtistsPage({super.key, required this.compact});

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final pad = compact ? 20.0 : 36.0;
    return ListenableBuilder(
      listenable: app.lib,
      builder: (context, _) {
        final artists = app.lib.artists;
        return CustomScrollView(slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(pad, 34, pad, 22),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Исполнители', style: display(36, weight: FontWeight.w700)),
                if (artists.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text('${artists.length} ${plural(artists.length, 'исполнитель', 'исполнителя', 'исполнителей')}',
                      style: const TextStyle(color: C.muted, fontSize: 15)),
                ],
              ]),
            ),
          ),
          if (artists.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: EmptyState(
                icon: Icons.mic_none_rounded,
                title: 'Исполнителей пока нет',
                text: 'Они появятся, когда в библиотеке будут треки.',
              ),
            ),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(pad - 12, 0, pad - 12, 32),
            sliver: SliverFixedExtentList(
              itemExtent: 64,
              delegate: SliverChildBuilderDelegate(
                (context, i) {
                  final a = artists[i];
                  return InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => NavScope.of(context).go(Nav('artist', a.key)),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Row(children: [
                        ClipOval(child: CoverImage(track: a.coverTrack, size: 44, radius: 0)),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Text(a.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
                        ),
                        Text(
                          '${countTracks(a.tracks.length)}, ${a.albums} ${plural(a.albums, 'альбом', 'альбома', 'альбомов')}',
                          style: const TextStyle(color: C.muted, fontSize: 13),
                        ),
                      ]),
                    ),
                  );
                },
                childCount: artists.length,
              ),
            ),
          ),
        ]);
      },
    );
  }
}

class ArtistPage extends StatelessWidget {
  final String artistKey;
  final bool compact;
  const ArtistPage({super.key, required this.artistKey, required this.compact});

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    return ListenableBuilder(
      listenable: app.lib,
      builder: (context, _) {
        final a = app.lib.artist(artistKey);
        if (a == null) {
          return const EmptyState(icon: Icons.mic_none_rounded, title: 'Исполнитель пропал', text: 'Его треки удалили из библиотеки.');
        }
        return TracksPage(
          title: a.name,
          subtitle: '${countTracks(a.tracks.length)}, ${a.albums} ${plural(a.albums, 'альбом', 'альбома', 'альбомов')}',
          tracks: a.tracks,
          cover: a.coverTrack,
          compact: compact,
          empty: const SizedBox.shrink(),
        );
      },
    );
  }
}

// ---------- недавно добавленные ----------

class RecentPage extends StatelessWidget {
  final bool compact;
  const RecentPage({super.key, required this.compact});

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    return ListenableBuilder(
      listenable: app.lib,
      builder: (context, _) {
        final tracks = app.lib.recent;
        return TracksPage(
          title: 'Недавно добавленные',
          subtitle: tracks.isEmpty ? null : 'Новые сверху',
          tracks: tracks,
          compact: compact,
          empty: const EmptyState(
            icon: Icons.schedule_rounded,
            title: 'Пока пусто',
            text: 'Здесь будут треки, которые недавно появились в папках с музыкой.',
          ),
        );
      },
    );
  }
}

// ---------- дубликаты ----------

class DuplicatesPage extends StatelessWidget {
  const DuplicatesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    return ListenableBuilder(
      listenable: app.lib,
      builder: (context, _) {
        final lib = app.lib;
        final groups = lib.duplicates;
        return ListView(padding: const EdgeInsets.fromLTRB(36, 34, 36, 40), children: [
          Text('Дубликаты', style: display(36, weight: FontWeight.w700)),
          const SizedBox(height: 10),
          const Text(
            'Треки с одинаковыми исполнителем и названием. Лишнюю копию можно скрыть из библиотеки у всех, '
            'а свою — ещё и отправить в корзину Диска (оттуда её можно восстановить 30 дней).',
            style: TextStyle(color: C.muted, fontSize: 15, height: 1.5),
          ),
          const SizedBox(height: 24),
          if (groups.isEmpty)
            const Text('Дубликатов не нашлось.', style: TextStyle(color: C.muted)),
          for (final g in groups) ...[
            Padding(
              padding: const EdgeInsets.only(top: 18, bottom: 6),
              child: Text('${g.first.displayArtist} — ${g.first.title}',
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
            ),
            for (final t in g)
              Container(
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: C.line))),
                child: Row(children: [
                  CoverImage(track: t, size: 36, radius: 4),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(t.displayAlbum, maxLines: 1, overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 2),
                      Text(
                        '${(t.size / (1024 * 1024)).toStringAsFixed(1)} МБ, '
                        'в «${lib.data.sources.where((s) => s.id == t.source).map((s) => s.name).firstOrNull ?? 'папке'}»',
                        style: const TextStyle(color: C.faint, fontSize: 12),
                      ),
                    ]),
                  ),
                  FriendTag(t.by),
                  const SizedBox(width: 12),
                  TextButton(onPressed: () => app.player.playTracks([t], 0), child: const Text('Послушать')),
                  TextButton(
                    style: TextButton.styleFrom(foregroundColor: C.muted),
                    onPressed: () => lib.hideTrack(t.id, true),
                    child: const Text('Скрыть'),
                  ),
                  if (t.by == lib.me)
                    TextButton(
                      style: TextButton.styleFrom(foregroundColor: C.danger),
                      onPressed: () async {
                        final ok = await confirm(context,
                            title: 'Удалить файл?',
                            text: '«${t.title}» уйдёт в корзину вашего Google Диска и пропадёт из библиотеки у всех.',
                            action: 'В корзину');
                        if (!ok) return;
                        try {
                          await lib.trashTrack(t);
                        } catch (e) {
                          lib.messages.add('Не получилось удалить: $e');
                        }
                      },
                      child: const Text('В корзину'),
                    ),
                ]),
              ),
          ],
          if (lib.data.hidden.isNotEmpty) ...[
            const SizedBox(height: 32),
            Text('Скрытые треки: ${lib.data.hidden.length}', style: const TextStyle(color: C.muted)),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () {
                  for (final id in List.of(lib.data.hidden)) {
                    lib.hideTrack(id, false);
                  }
                },
                child: const Text('Вернуть все скрытые'),
              ),
            ),
          ],
        ]);
      },
    );
  }

}

// ---------- загрузка ----------

const _audioExtensions = ['mp3', 'flac', 'ogg', 'oga', 'opus', 'm4a', 'mp4', 'aac', 'wav', 'webm', 'weba', 'mka', 'wma', 'aif', 'aiff', 'ape', 'wv'];

/// Кнопка «Загрузить»: выбор файлов на компьютере
Future<void> pickAndUpload(BuildContext context) async {
  final files = await openFiles(acceptedTypeGroups: [
    const XTypeGroup(label: 'Музыка', extensions: _audioExtensions),
  ]);
  if (files.isEmpty || !context.mounted) return;
  await uploadPaths(context, [for (final f in files) f.path]);
}

/// Загружает файлы и папки (их содержимое) в выбранную папку библиотеки
Future<void> uploadPaths(BuildContext context, List<String> paths) async {
  final app = Services.of(context);
  final lib = app.lib;
  final all = <String>[];
  for (final p in paths) {
    if (FileSystemEntity.isDirectorySync(p)) {
      try {
        for (final e in Directory(p).listSync(recursive: true)) {
          if (e is File) all.add(e.path);
        }
      } catch (_) {}
    } else {
      all.add(p);
    }
  }
  final audio = all.where((p) => audioExt.hasMatch(p)).toList();
  if (audio.isEmpty) {
    lib.messages.add('Среди этих файлов нет музыки');
    return;
  }
  final sources = lib.data.sources;
  if (sources.isEmpty) {
    lib.messages.add('Сначала добавьте папку с музыкой');
    return;
  }
  String? target = sources.length == 1 ? sources.first.id : null;
  if (target == null) {
    target = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('Куда загрузить ${countTracks(audio.length)}?', style: display(18)),
        children: [
          for (final s in sources)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, s.id),
              child: Row(children: [
                Icon(Icons.folder_rounded, color: friendColor(s.addedBy), size: 20),
                const SizedBox(width: 12),
                Expanded(child: Text(s.id == app.settings.hubId ? '${s.name} (общая папка)' : s.name)),
              ]),
            ),
        ],
      ),
    );
  }
  if (target == null) return;
  await lib.uploadFiles(audio, target);
}

/// Полоска загрузки в боковой панели
class UploadLine extends StatelessWidget {
  final bool compact;
  const UploadLine({super.key, required this.compact});

  @override
  Widget build(BuildContext context) {
    final lib = Services.of(context).lib;
    final u = lib.upload;
    if (!u.running) return const SizedBox.shrink();
    final overall = u.total == 0 ? null : (u.done + u.failed + u.fileProgress) / u.total;
    if (compact) {
      return Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Center(
          child: Tooltip(
            message: 'Загружаю ${u.done + u.failed + 1} из ${u.total}',
            child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2, value: overall)),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 10, 16, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Загружаю ${u.done + u.failed + 1} из ${u.total}', style: const TextStyle(fontSize: 12, color: C.muted)),
        Text(u.current, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: C.faint)),
        const SizedBox(height: 6),
        LinearProgressIndicator(value: overall),
      ]),
    );
  }
}

// ---------- правка тегов ----------

Future<void> editTrackDialog(BuildContext context, Track t) async {
  final lib = Services.of(context).lib;
  final title = TextEditingController(text: t.title);
  final artist = TextEditingController(text: t.artist);
  final album = TextEditingController(text: t.album);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Изменить трек', style: display(18)),
      content: SizedBox(
        width: 400,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Название', style: TextStyle(color: C.muted, fontSize: 13)),
          const SizedBox(height: 6),
          TextField(controller: title, autofocus: true),
          const SizedBox(height: 14),
          const Text('Исполнитель', style: TextStyle(color: C.muted, fontSize: 13)),
          const SizedBox(height: 6),
          TextField(controller: artist),
          const SizedBox(height: 14),
          const Text('Альбом', style: TextStyle(color: C.muted, fontSize: 13)),
          const SizedBox(height: 6),
          TextField(controller: album),
          const SizedBox(height: 14),
          const Text('Изменения увидят все друзья. Сам файл на Диске не меняется.',
              style: TextStyle(color: C.faint, fontSize: 12, height: 1.4)),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена', style: TextStyle(color: C.muted))),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Сохранить')),
      ],
    ),
  );
  if (ok != true) return;
  if (title.text.trim().isEmpty) {
    lib.messages.add('Название не может быть пустым');
    return;
  }
  lib.editTrack(t.id, title: title.text.trim(), artist: artist.text.trim(), album: album.text.trim());
}
