import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../app.dart';
import '../core/library.dart';
import '../core/log.dart';
import '../core/models.dart';
import '../core/tags.dart';
import 'cover_picker.dart';
import 'list_filter.dart';
import 'shell.dart';
import 'theme.dart';
import 'tracks_view.dart';
import 'widgets.dart';

// ---------- исполнители ----------

class ArtistsPage extends StatefulWidget {
  final bool compact;
  const ArtistsPage({super.key, required this.compact});

  @override
  State<ArtistsPage> createState() => _ArtistsPageState();
}

class _ArtistsPageState extends State<ArtistsPage> {
  final _search = TextEditingController();
  final _focus = FocusNode();
  String _query = '';

  @override
  void initState() {
    super.initState();
    searchRequests.addListener(_focusSearch);
  }

  @override
  void dispose() {
    searchRequests.removeListener(_focusSearch);
    _search.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _focusSearch() {
    if (!mounted) return;
    _focus.requestFocus();
    _search.selection = TextSelection(baseOffset: 0, extentOffset: _search.text.length);
  }

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final pad = widget.compact ? 20.0 : 36.0;
    return ListenableBuilder(
      listenable: app.lib,
      builder: (context, _) {
        final all = app.lib.artists;
        final q = foldText(_query.trim());
        final desc = app.settings.artistsDesc;
        final list = q.isEmpty ? List<Artist>.of(all) : all.where((a) => foldText(a.name).contains(q)).toList();
        int cmp(Artist a, Artist b) {
          final ua = a.name == 'Неизвестный исполнитель';
          final ub = b.name == 'Неизвестный исполнитель';
          if (ua != ub) return ua ? 1 : -1; // «неизвестный» всегда внизу
          final r = sortKey(a.name).compareTo(sortKey(b.name));
          return desc ? -r : r;
        }

        list.sort(cmp);
        // Любимые исполнители — вверху, над остальными
        final favs = [for (final a in list) if (app.lib.isFavArtist(a.key)) a];
        final rest = [for (final a in list) if (!app.lib.isFavArtist(a.key)) a];
        final prefs = ViewPrefs(app.settings, 'artists', defaultGrid: false, listDef: 64, listMin: 48, listMax: 96, gridDef: 160);
        final rows = <Object>[
          if (favs.isNotEmpty) 'Любимые',
          if (favs.isNotEmpty) favs,
          if (favs.isNotEmpty && rest.isNotEmpty) 'Все исполнители',
          if (rest.isNotEmpty) rest,
        ];
        return CustomScrollView(slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(pad, 34, pad, 18),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Исполнители', style: display(36, weight: FontWeight.w700)),
                if (all.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(
                    q.isEmpty
                        ? '${all.length} ${plural(all.length, 'исполнитель', 'исполнителя', 'исполнителей')}'
                        : 'Найдено ${list.length} из ${all.length}',
                    style: const TextStyle(color: C.muted, fontSize: 15),
                  ),
                  const SizedBox(height: 18),
                  SearchSortBar(
                    controller: _search,
                    focusNode: _focus,
                    hint: 'Найти исполнителя',
                    desc: desc,
                    onChanged: (v) => setState(() => _query = v),
                    onToggleSort: () {
                      app.settings.artistsDesc = !desc;
                      app.lib.saveSettings();
                      setState(() {});
                    },
                    trailing: ViewControls(prefs: prefs, onChanged: () => setState(() {})),
                  ),
                ],
              ]),
            ),
          ),
          if (all.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: EmptyState(
                icon: Icons.mic_none_rounded,
                title: 'Исполнителей пока нет',
                text: 'Они появятся, когда в библиотеке будут треки.',
              ),
            ),
          if (all.isNotEmpty && list.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: pad, vertical: 12),
                child: Text('Ничего не нашлось по запросу «$_query»', style: const TextStyle(color: C.muted)),
              ),
            ),
          for (final row in rows)
            if (row is String)
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(pad, 14, pad, 6),
                  child: Text(row, style: const TextStyle(color: C.muted, fontSize: 13, fontWeight: FontWeight.w600)),
                ),
              )
            else
              _artistsSliver(context, app, row as List<Artist>, prefs, pad),
          const SliverToBoxAdapter(child: SizedBox(height: 32)),
        ]);
      },
    );
  }
}


/// Исполнители сеткой (круглое фото, имя под ним) или списком; сердечко кладёт в «Любимые»
Widget _artistsSliver(BuildContext context, AppServices app, List<Artist> items, ViewPrefs prefs, double pad) {
  Widget heart(Artist a, {double size = 20}) {
    final fav = app.lib.isFavArtist(a.key);
    return IconButton(
      tooltip: fav ? 'Убрать из любимых исполнителей' : 'В любимые исполнители',
      onPressed: () => app.lib.toggleFavArtist(a.key),
      icon: Icon(fav ? Icons.favorite_rounded : Icons.favorite_border_rounded, size: size, color: fav ? C.accent : C.faint),
    );
  }

  if (prefs.grid) {
    return SliverPadding(
      padding: EdgeInsets.symmetric(horizontal: pad),
      sliver: AdaptiveGridSliver(
        tile: prefs.size,
        extra: 62,
        count: items.length,
        builder: (context, i) {
          final a = items[i];
          return InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => NavScope.of(context).go(Nav('artist', a.key)),
            child: LayoutBuilder(
              builder: (context, box) => Column(crossAxisAlignment: CrossAxisAlignment.center, children: [
                Stack(children: [
                  ClipOval(child: CoverImage(track: a.coverTrack, size: box.maxWidth, radius: 0)),
                  Positioned(
                    right: 2,
                    top: 2,
                    child: DecoratedBox(
                      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.45), shape: BoxShape.circle),
                      child: SizedBox.square(dimension: 34, child: heart(a, size: 18)),
                    ),
                  ),
                ]),
                const SizedBox(height: 10),
                Text(a.name,
                    maxLines: 1,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                const SizedBox(height: 3),
                Text(countTracks(a.tracks.length),
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.muted, fontSize: 12)),
              ]),
            ),
          );
        },
      ),
    );
  }
  return SliverPadding(
    padding: EdgeInsets.symmetric(horizontal: pad - 12),
    sliver: SliverFixedExtentList(
      itemExtent: prefs.size,
      delegate: SliverChildBuilderDelegate(
        (context, i) {
          final a = items[i];
          return InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => NavScope.of(context).go(Nav('artist', a.key)),
            child: Padding(
              padding: const EdgeInsets.only(left: 12),
              child: Row(children: [
                ClipOval(child: CoverImage(track: a.coverTrack, size: prefs.size - 20, radius: 0)),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
                ),
                Text(
                  '${countTracks(a.tracks.length)}, ${a.albums} ${plural(a.albums, 'альбом', 'альбома', 'альбомов')}',
                  style: const TextStyle(color: C.muted, fontSize: 13),
                ),
                heart(a),
              ]),
            ),
          );
        },
        childCount: items.length,
      ),
    ),
  );
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

class DuplicatesPage extends StatefulWidget {
  const DuplicatesPage({super.key});
  @override
  State<DuplicatesPage> createState() => _DuplicatesPageState();
}

class _DuplicatesPageState extends State<DuplicatesPage> {
  /// Какую копию оставить в каждой группе (ключ — id первой копии группы)
  final Map<String, String> _keep = {};

  String _keepOf(List<Track> g) {
    final chosen = _keep[g.first.id];
    if (chosen != null && g.any((t) => t.id == chosen)) return chosen;
    return LibraryController.bestOf(g).id;
  }

  Future<void> _merge(List<List<Track>> groups) async {
    final app = Services.of(context);
    final lib = app.lib;
    final mine = <Track>[];
    for (final g in groups) {
      final keep = _keepOf(g);
      mine.addAll(g.where((t) => t.id != keep && t.by == lib.me));
    }
    var trash = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(groups.length == 1 ? 'Объединить копии?' : 'Объединить ${groups.length} групп?', style: display(18)),
          content: SizedBox(
            width: 420,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text(
                'Останется выбранная копия. Лайки всех друзей и места в плейлистах перейдут на неё, '
                'прослушивания будут считаться вместе. Остальные копии скроются из библиотеки у всех, '
                'их можно вернуть ниже.',
                style: TextStyle(color: C.muted, height: 1.45),
              ),
              if (mine.isNotEmpty) ...[
                const SizedBox(height: 12),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: trash,
                  onChanged: (v) => setD(() => trash = v ?? false),
                  title: Text('Отправить мои лишние копии в корзину Диска (${mine.length})'),
                  subtitle: const Text('Освободит место; из корзины можно восстановить 30 дней',
                      style: TextStyle(color: C.faint, fontSize: 12)),
                ),
              ],
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Объединить')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    for (final g in groups) {
      final keep = _keepOf(g);
      lib.mergeTracks(keep, g.map((t) => t.id));
    }
    var trashed = 0;
    if (trash) {
      for (final t in mine) {
        try {
          await lib.trashTrack(t);
          trashed++;
        } catch (e) {
          AppLog.warn('Не получилось удалить копию «${t.title}»', e);
        }
      }
    }
    lib.messages.add(trashed > 0 ? 'Объединено, в корзину: $trashed' : 'Объединено');
  }

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    return ListenableBuilder(
      listenable: app.lib,
      builder: (context, _) {
        final lib = app.lib;
        final groups = lib.duplicates;
        final merged = [
          for (final e in lib.data.merged.entries)
            if (lib.data.tracks[e.key] != null && lib.data.hidden.contains(e.key)) e.key
        ];
        String folder(Track t) => lib.data.sources.where((s) => s.id == t.source).map((s) => s.name).firstOrNull ?? 'папке';
        int inPlaylists(Track t) => lib.data.playlists.where((p) => p.items.contains(t.id)).length;
        return ListView(padding: const EdgeInsets.fromLTRB(36, 34, 36, 40), children: [
          Text('Дубликаты', style: display(36, weight: FontWeight.w700)),
          const SizedBox(height: 10),
          const Text(
            'Одна и та же песня в нескольких копиях. Выберите, какую оставить, и объедините: '
            'лайки и плейлисты перейдут на неё, ничего не потеряется. Одинаковые файлы в разных папках '
            'объединяются сами. Песни, которые уже есть в библиотеке, загрузчик и загрузка с компьютера пропускают.',
            style: TextStyle(color: C.muted, fontSize: 15, height: 1.5),
          ),
          const SizedBox(height: 18),
          if (groups.isEmpty)
            const Text('Дубликатов не нашлось.', style: TextStyle(color: C.muted))
          else
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                onPressed: () => _merge(groups),
                icon: const Icon(Icons.merge_rounded, size: 18),
                label: Text('Объединить все (${groups.length})'),
              ),
            ),
          for (final g in groups) ...[
            Padding(
              padding: const EdgeInsets.only(top: 22, bottom: 6),
              child: Row(children: [
                Expanded(
                  child: Text('${g.first.displayArtist} — ${g.first.title}',
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                ),
                TextButton.icon(
                  onPressed: () => _merge([g]),
                  icon: const Icon(Icons.merge_rounded, size: 18),
                  label: const Text('Объединить'),
                ),
              ]),
            ),
            for (final t in g)
              Container(
                padding: const EdgeInsets.symmetric(vertical: 6),
                decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: C.line))),
                child: Row(children: [
                  Radio<String>(
                    value: t.id,
                    groupValue: _keepOf(g),
                    onChanged: (v) => setState(() => _keep[g.first.id] = v!),
                  ),
                  CoverImage(track: t, size: 36, radius: 4),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(
                        '${t.displayAlbum}${t.id == _keepOf(g) ? '  · останется' : ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: t.id == _keepOf(g) ? C.accent : C.text),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        [
                          '${(t.size / (1024 * 1024)).toStringAsFixed(1)} МБ',
                          'в «${folder(t)}»',
                          if ((lib.data.likes[t.id]?.length ?? 0) > 0) 'лайков: ${lib.data.likes[t.id]!.length}',
                          if (inPlaylists(t) > 0) 'в плейлистах: ${inPlaylists(t)}',
                        ].join(', '),
                        style: const TextStyle(color: C.faint, fontSize: 12),
                      ),
                    ]),
                  ),
                  FriendTag(t.by),
                  const SizedBox(width: 12),
                  TextButton(onPressed: () => app.player.playTracks([t], 0), child: const Text('Послушать')),
                ]),
              ),
          ],
          if (merged.isNotEmpty) ...[
            const SizedBox(height: 36),
            Text('Объединённые копии: ${merged.length}', style: display(17)),
            const SizedBox(height: 6),
            const Text('Скрыты из библиотеки, их лайки и плейлисты перешли на оставшуюся копию.',
                style: TextStyle(color: C.faint, fontSize: 13)),
            const SizedBox(height: 8),
            for (final id in merged.take(200))
              Builder(builder: (context) {
                final t = lib.data.tracks[id]!;
                final into = lib.data.tracks[lib.data.resolve(id)];
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(children: [
                    Expanded(
                      child: Text(
                        '${t.displayArtist} — ${t.title}  ·  ${(t.size / (1024 * 1024)).toStringAsFixed(1)} МБ в «${folder(t)}»'
                        '${into == null ? '' : '  →  ${(into.size / (1024 * 1024)).toStringAsFixed(1)} МБ в «${folder(into)}»'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: C.muted, fontSize: 13),
                      ),
                    ),
                    TextButton(onPressed: () => lib.unmergeTrack(id), child: const Text('Вернуть отдельно')),
                  ]),
                );
              }),
          ],
          if (lib.data.hidden.length > merged.length) ...[
            const SizedBox(height: 32),
            Text('Скрытые треки: ${lib.data.hidden.length - merged.length}', style: const TextStyle(color: C.muted)),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () {
                  for (final id in List.of(lib.data.hidden)) {
                    if (!lib.data.merged.containsKey(id)) lib.hideTrack(id, false);
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
  final choice = CoverChoice();
  final albumHasOwn = lib.albumCover(t.albumKey) != null;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Изменить трек', style: display(18)),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            CoverEditorView(
              choice: choice,
              current: CoverImage(track: t, size: 120, radius: 0),
              canReset: t.customCover != null,
              note: albumHasOwn ? 'У альбома своя обложка, она показывается поверх обложек его треков.' : null,
            ),
            const SizedBox(height: 18),
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
  final cover = context.mounted ? await choice.commit(context) : null;
  lib.editTrack(t.id, title: title.text.trim(), artist: artist.text.trim(), album: album.text.trim(), cover: cover);
}

/// Правка сразу нескольких треков: исполнитель, альбом и обложка. Меняется только то, что тронули.
/// Возвращает true, если правки сохранены.
Future<bool> editTracksDialog(BuildContext context, List<Track> tracks) async {
  if (tracks.isEmpty) return false;
  final app = Services.of(context);
  final lib = app.lib;
  String common(String Function(Track) f) {
    final first = f(tracks.first);
    return tracks.every((t) => f(t) == first) ? first : '';
  }

  final artist = TextEditingController(text: common((t) => t.artist));
  final album = TextEditingController(text: common((t) => t.album));
  final artistMixed = artist.text.isEmpty && tracks.any((t) => t.artist.isNotEmpty);
  final albumMixed = album.text.isEmpty && tracks.any((t) => t.album.isNotEmpty);
  var artistDirty = false;
  var albumDirty = false;
  final choice = CoverChoice();
  final sameCover = tracks.map(app.covers.keyOf).toSet().length == 1;
  final anyAlbumOwn = tracks.any((t) => lib.albumCover(t.albumKey) != null);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Изменить ${countTracks(tracks.length)}', style: display(18)),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            CoverEditorView(
              choice: choice,
              current: sameCover
                  ? CoverImage(track: tracks.first, size: 120, radius: 0)
                  : Container(
                      color: C.raised,
                      alignment: Alignment.center,
                      padding: const EdgeInsets.all(10),
                      child: const Text('У треков разные обложки',
                          textAlign: TextAlign.center, style: TextStyle(color: C.muted, fontSize: 12)),
                    ),
              canReset: tracks.any((t) => t.customCover != null),
              note: anyAlbumOwn ? 'У части альбомов своя обложка, она показывается поверх обложек треков.' : null,
            ),
            const SizedBox(height: 18),
            const Text('Исполнитель', style: TextStyle(color: C.muted, fontSize: 13)),
            const SizedBox(height: 6),
            TextField(
              controller: artist,
              onChanged: (_) => artistDirty = true,
              decoration: InputDecoration(hintText: artistMixed ? 'Разные: оставить как есть' : null),
            ),
            const SizedBox(height: 14),
            const Text('Альбом', style: TextStyle(color: C.muted, fontSize: 13)),
            const SizedBox(height: 6),
            TextField(
              controller: album,
              onChanged: (_) => albumDirty = true,
              decoration: InputDecoration(hintText: albumMixed ? 'Разные: оставить как есть' : null),
            ),
            const SizedBox(height: 14),
            const Text('Меняются только те поля, которые вы тронули. Изменения увидят все друзья, файлы на Диске не меняются.',
                style: TextStyle(color: C.faint, fontSize: 12, height: 1.4)),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена', style: TextStyle(color: C.muted))),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Сохранить')),
      ],
    ),
  );
  if (ok != true) return false;
  final fields = <String, String>{
    if (artistDirty) 'a': artist.text.trim(),
    if (albumDirty) 'al': album.text.trim(),
  };
  if (choice.changed) {
    final cv = context.mounted ? await choice.commit(context) : null;
    if (cv != null) fields['cv'] = cv;
  }
  if (fields.isEmpty) return false;
  lib.editTracks([for (final t in tracks) t.id], fields);
  lib.messages.add('Изменено: ${countTracks(tracks.length)}');
  return true;
}
