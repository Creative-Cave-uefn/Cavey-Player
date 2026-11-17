import 'dart:async' show unawaited;
import 'dart:io' show File;
import 'dart:math' show max, min;

import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';

import '../app.dart';
import '../core/library.dart' show LibraryController;
import '../core/album_order.dart';
import '../core/models.dart';
import '../core/pin_order.dart';
import '../core/track_tags.dart';
import 'tags_ui.dart';
import 'ambient.dart';
import 'delete_dialog.dart';
import 'library_tabs.dart';
import 'library_views.dart';
import 'shell.dart';
import 'share_dialog.dart';
import 'collection_menu.dart' show collectionShareSubject;
import 'album_edit.dart';
import 'accounts_view.dart' show GlassSelect;
import 'album_missing.dart';
import 'playlists_view.dart' show PlaylistCover;
import 'device_export_ui.dart';
import 'uploader_filter.dart';
import 'theme.dart';
import 'wave_view.dart';
import 'widgets.dart';
import 'glass_popup.dart';

/// Ctrl+F: каждое увеличение просит открытый список треков поставить курсор в поиск
final searchRequests = ValueNotifier<int>(0);

/// Открыта панель группового выбора треков: уведомления поднимаются выше неё
final selectionBarOpen = ValueNotifier<bool>(false);

class AllTracksPage extends StatelessWidget {
  final bool compact;
  final String title;
  const AllTracksPage({super.key, required this.compact, this.title = 'Песни'});

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    return ListenableBuilder(
      listenable: app.lib,
      builder: (context, _) {
        final lib = app.lib;
        final tracks = lib.allTracks;
        final albums = lib.albums.length;
        return TracksPage(
          title: title,
          // В «Медиатеке» итог уже написан под заголовком раздела
          subtitle: tracks.isEmpty || LibraryFrame.on(context)
              ? null
              : '${countTracks(tracks.length)} в $albums ${plural(albums, 'альбоме', 'альбомах', 'альбомах')}',
          tracks: tracks,
          compact: compact,
          actions: libraryActions(context),
          // Поиск по трекам — под шапкой, на месте прежней плашки «Перетащите сюда файлы»
          searchInBanner: true,
          mineFilter: true,
          empty: lib.scan.running
              ? EmptyState(
                  icon: Icons.downloading_rounded,
                  title: 'Собираю библиотеку',
                  text: lib.scan.total > 0 ? '${lib.scan.text}: ${lib.scan.done} из ${lib.scan.total}' : lib.scan.text,
                )
              : EmptyState(
                  icon: Icons.folder_open_rounded,
                  title: 'Здесь будет вся ваша музыка',
                  text: lib.data.sources.isEmpty
                      ? 'Добавьте папку с музыкой с Google Диска — свою или ту, которой поделился друг.'
                      : 'В добавленных папках пока нет аудиофайлов. Загрузите музыку на Диск и обновите библиотеку.',
                  action: FilledButton(
                    onPressed: () => NavScope.of(context).go(const Nav('accounts', 'library')),
                    child: Text(lib.data.sources.isEmpty ? 'Добавить папку' : 'Открыть папки'),
                  ),
                ),
        );
      },
    );
  }
}

/// Кнопки библиотеки: скачать по ссылке, загрузить файлы, проверить папки
List<Widget> libraryActions(BuildContext context) {
  final lib = Services.of(context).lib;
  return [
            OutlinedButton.icon(
              onPressed: () => NavScope.of(context).go(const Nav('download')),
              icon: const Icon(Icons.cloud_download_outlined, size: 18),
              label: const Text('Скачать по ссылке'),
            ),
            OutlinedButton.icon(
              onPressed: lib.data.sources.isEmpty || lib.upload.running ? null : () => pickAndUpload(context),
              icon: const Icon(Icons.upload_rounded, size: 18),
              label: const Text('Загрузить'),
            ),
            Tooltip(
              message: lib.scan.running
                  ? (lib.scan.total > 0 ? '${lib.scan.text}: ${lib.scan.done} из ${lib.scan.total}' : lib.scan.text)
                  : 'Проверить папки на новые треки',
              child: OutlinedButton.icon(
                onPressed: lib.scan.running || lib.data.sources.isEmpty ? null : () => lib.scanAll(),
                icon: lib.scan.running
                    ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.sync_rounded, size: 18),
                label: Text(lib.scan.running ? 'Обновляю…' : 'Обновить'),
              ),
            ),
          ];
}

class LikedPage extends StatelessWidget {
  final bool compact;
  const LikedPage({super.key, required this.compact});

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([app.lib, app.cache]),
      builder: (context, _) {
        final tracks = app.lib.liked;
        return TracksPage(
          title: 'Любимое',
          subtitle: tracks.isEmpty ? null : countTracks(tracks.length),
          heroColor: const Color(0xFFB3261E),
          heroLeft: true,
          defaultSort: 'liked',
          tracks: tracks,
          compact: compact,
          actions: [
            OfflineButton(
              on: app.settings.offlineLiked,
              tracks: tracks,
              onChanged: app.cache.setLikedOffline,
            ),
          ],
          empty: const EmptyState(
            icon: Icons.favorite_border_rounded,
            title: 'Пока ничего',
            text: 'Нажимайте на сердечко у треков. Друзья увидят, что вам понравилось.',
          ),
        );
      },
    );
  }
}

class AlbumPage extends StatelessWidget {
  final String albumKey;
  final bool compact;
  const AlbumPage({super.key, required this.albumKey, required this.compact});

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([app.lib, app.cache]),
      builder: (context, _) {
        final album = app.lib.album(albumKey);
        if (album == null) {
          return const EmptyState(icon: Icons.album_outlined, title: 'Альбом пропал', text: 'Его треки удалили с Диска.');
        }
        final tail = [if (album.year.isNotEmpty) album.year, countTracks(album.tracks.length)];
        final nav = NavScope.of(context);
        // Все причастные к альбому исполнители — ссылками, самые частые первыми
        final artistParts = <LinkPart>[];
        final names = album.artists.isEmpty ? splitArtists(album.artist) : album.artists;
        const shown = 6;
        for (var i = 0; i < names.length && i < shown; i++) {
          if (i > 0) artistParts.add(const LinkPart(', '));
          final key = names[i].toLowerCase();
          artistParts.add(LinkPart(names[i], () => nav.go(Nav('artist', key))));
        }
        if (names.length > shown) artistParts.add(LinkPart(' и ещё ${names.length - shown}'));
        return TracksPage(
          title: album.title,
          // Исполнитель альбома — ссылка на его страницу
          subtitleWidget: Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
            Links(parts: artistParts, style: const TextStyle(color: C.muted, fontSize: 15)),
            Text(', ${tail.join(', ')}', style: const TextStyle(color: C.muted, fontSize: 15)),
          ]),
          tracks: album.tracks,
          cover: album.coverTrack,
          numbered: true,
          compact: compact,
          onEditCover: () => editAlbumDialog(context, album),
          editCoverTooltip: 'Изменить альбом',
          footer: MissingAlbumTracks(album: album),
          onReorder: (track, after) => app.lib.moveAlbumTrack(albumKey, track.id, after?.id),
          actions: [
            OfflineButton(
              on: app.cache.isAlbumOffline(albumKey),
              tracks: album.tracks,
              onChanged: (v) => app.cache.setAlbumOffline(albumKey, v),
            ),
            FavButton(
              on: app.lib.isFavAlbum(album),
              what: 'альбом',
              onTap: () => app.lib.toggleFavAlbum(album),
            ),
            GlassMenuButton<String>(
              tooltip: 'Ещё',
              icon: const Icon(Icons.more_horiz_rounded),
              onSelected: (v) {
                if (v == 'edit') editAlbumDialog(context, album);
                if (v == 'share') showShareSubjectDialog(context, collectionShareSubject(album: album));
                if (v == 'order') app.lib.resetAlbumOrder(albumKey);
                if (v == 'deezerSort') {
                  sortAlbumByDeezer(app.lib, app.web, album).then((r) {
                    app.lib.messages.add(switch (r) {
                      DeezerSort.done => 'Треки расставлены в порядке Deezer',
                      DeezerSort.alreadySorted => 'Треки уже стоят в порядке Deezer',
                      DeezerSort.notFound => 'Не нашёл этот альбом в Deezer',
                    });
                  }).catchError((Object e) {
                    app.lib.messages.add('Не получилось рассортировать: $e');
                  });
                }
                if (v == 'export') exportToDevice(context, List<Track>.of(album.tracks), folderName: album.title, withArtist: false);
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'edit', child: Text('Редактировать…')),
                const PopupMenuItem(value: 'share', child: Text('Поделиться…')),
                const PopupMenuItem(value: 'export', child: Text('Скачать альбом на устройство')),
                const PopupMenuItem(value: 'deezerSort', child: Text('Рассортировать треки по Deezer')),
                if (app.lib.hasAlbumOrder(albumKey)) const PopupMenuItem(value: 'order', child: Text('Вернуть порядок по номерам')),
              ],
            ),
          ],
          empty: const SizedBox.shrink(),
        );
      },
    );
  }
}

class PlaylistPage extends StatelessWidget {
  final String playlistId;
  final bool compact;
  const PlaylistPage({super.key, required this.playlistId, required this.compact});

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([app.lib, app.cache]),
      builder: (context, _) {
        final lib = app.lib;
        final p = lib.playlist(playlistId);
        if (p == null) {
          return const EmptyState(icon: Icons.queue_music_rounded, title: 'Плейлист удалён', text: 'Кто-то из друзей его удалил.');
        }
        final tracks = lib.playlistTracks(playlistId);
        // Своя обложка, а если её нет — обложка первого трека с картинкой
        Track? coverTrack;
        for (final t in tracks) {
          if (t.hasCover) {
            coverTrack = t;
            break;
          }
        }
        coverTrack ??= tracks.isEmpty ? null : tracks.first;
        final ownCover = lib.playlistCover(playlistId);
        return TracksPage(
          title: p.name,
          cover: coverTrack,
          coverFileId: ownCover,
          coverLabel: p.name,
          coverGrid: ownCover == null ? gridCoverTracks(tracks) : const [],
          subtitleWidget: Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
            const Text('Собирает ', style: TextStyle(color: C.muted, fontSize: 15)),
            if (p.by.isEmpty) const Text('кто-то', style: TextStyle(color: C.muted, fontSize: 15)) else UserLink(p.by),
            if (tracks.isNotEmpty) Text(', ${countTracks(tracks.length)}', style: const TextStyle(color: C.muted, fontSize: 15)),
            Text(lib.isPlaylistPublic(p.id) ? ' · открытый' : ' · приватный',
                style: TextStyle(color: lib.isPlaylistPublic(p.id) ? C.accent : C.faint, fontSize: 15)),
          ]),
          tracks: tracks,
          playlistId: playlistId,
          compact: compact,
          onEditCover: () => editPlaylistDialog(context, p, coverTrack: coverTrack),
          editCoverTooltip: 'Изменить плейлист',
          onReorder: (track, after) => lib.movePlaylistItem(playlistId, track.id, after?.id),
          actions: [
            // Свои плейлисты и так всегда в «Коллекции»; сердечко — для плейлистов друзей
            if (p.by.isNotEmpty && p.by != lib.me)
              FavButton(on: lib.isFavPlaylist(p.id), what: 'плейлист', onTap: () => lib.toggleFavPlaylist(p.id)),
            OfflineButton(
              on: app.cache.isPlaylistOffline(playlistId),
              tracks: tracks,
              onChanged: (v) => app.cache.setPlaylistOffline(playlistId, v),
            ),
            GlassMenuButton<String>(
              tooltip: 'Ещё',
              icon: const Icon(Icons.more_horiz_rounded),
              onSelected: (v) async {
                if (v == 'edit') {
                  await editPlaylistDialog(context, p, coverTrack: coverTrack);
                } else if (v == 'share') {
                  await showShareSubjectDialog(context, collectionShareSubject(playlist: p));
                } else if (v == 'export') {
                  await exportToDevice(context, List<Track>.of(tracks), folderName: p.name);
                } else if (v == 'public') {
                  lib.setPlaylistPublic(p.id, true);
                  lib.messages.add('Плейлист «${p.name}» теперь видят все друзья');
                } else if (v == 'private') {
                  lib.setPlaylistPublic(p.id, false);
                  lib.messages.add('Плейлист «${p.name}» виден только вам');
                } else if (v == 'delete') {
                  final nav = NavScope.of(context);
                  final ok = await confirm(context,
                      title: 'Удалить «${p.name}»?',
                      text: 'Плейлист пропадёт у всех друзей. Сами треки останутся в библиотеке.',
                      action: 'Удалить');
                  if (ok) {
                    nav.go(const Nav('all'));
                    lib.deletePlaylist(p.id);
                  }
                }
              },
              itemBuilder: (_) => [
                if (p.by == lib.me || p.by.isEmpty)
                  lib.isPlaylistPublic(p.id)
                      ? const PopupMenuItem(value: 'private', child: Text('Сделать приватным'))
                      : const PopupMenuItem(value: 'public', child: Text('Сделать открытым')),
                const PopupMenuItem(value: 'edit', child: Text('Редактировать…')),
                const PopupMenuItem(value: 'share', child: Text('Поделиться…')),
                const PopupMenuItem(value: 'export', child: Text('Скачать плейлист на устройство')),
                const PopupMenuItem(value: 'delete', child: Text('Удалить плейлист')),
              ],
            ),
          ],
          empty: const EmptyState(
            icon: Icons.playlist_add_rounded,
            title: 'Добавьте первые треки',
            text: 'В списке треков откройте меню «…» у песни и выберите «Добавить в плейлист».',
          ),
        );
      },
    );
  }
}

/// Общий экран списка треков: шапка, поиск, строки
class TracksPage extends StatefulWidget {
  final String title;
  final String? subtitle;

  /// Вместо строки подзаголовка: например, с именем автора, которое открывает его страницу
  final Widget? subtitleWidget;
  final List<Track> tracks;
  final Track? cover;

  /// Загруженная обложка (например, плейлиста): показывается вместо обложки трека
  final String? coverFileId;
  final String? coverLabel;
  final List<Track> coverGrid;
  final String? playlistId;
  final bool numbered;
  final bool compact;
  final List<Widget> actions;
  final Widget empty;

  /// Плашка под шапкой (например, «перетащите сюда файлы»)
  final Widget? banner;

  /// Перестановка перетаскиванием (в плейлистах): трек и тот, за которым он теперь стоит
  final void Function(Track track, Track? after)? onReorder;

  /// Своя картинка в шапке вместо обложки (например, фото исполнителя)
  final Widget? image;

  /// Блок под списком треков (например, то, чего нет в библиотеке)
  final Widget? footer;

  /// Шапка как в профилях: цветной градиент сверху, заголовок и кнопки по центру
  final Color? heroColor;

  /// Карандаш на обложке в шапке (появляется при наведении): правка альбома или плейлиста
  final VoidCallback? onEditCover;
  final String editCoverTooltip;

  const TracksPage({
    super.key,
    required this.title,
    required this.tracks,
    required this.compact,
    required this.empty,
    this.subtitle,
    this.subtitleWidget,
    this.cover,
    this.coverFileId,
    this.coverLabel,
    this.coverGrid = const [],
    this.playlistId,
    this.numbered = false,
    this.actions = const [],
    this.banner,
    this.onReorder,
    this.image,
    this.footer,
    this.heroColor,
    this.onEditCover,
    this.editCoverTooltip = 'Изменить',
    this.searchInBanner = false,
    this.heroLeft = false,
    this.defaultSort,
    this.mineFilter = false,
  });

  /// Показывать переключатель «Мои загрузки» (только треки, которые загрузил я с любого из своих аккаунтов)
  final bool mineFilter;

  /// Сортировка, с которой открывается страница, пока человек не выбрал свою (например, 'liked' — свежие любимые сверху)
  final String? defaultSort;

  /// Поиск по трекам в одном ряду с кнопками «Слушать…», слева от них, а не справа от шапки
  final bool searchInBanner;

  /// Шапка с цветным свечением, но всё выровнено по левой стороне, как у остальных списков
  final bool heroLeft;

  @override
  State<TracksPage> createState() => _TracksPageState();
}

class _TracksPageState extends State<TracksPage> {
  static const _addedColW = 120.0;
  static const _uploadColW = 110.0;

  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  String _query = '';

  // Сортировка и фильтрация нескольких тысяч треков — O(n log n).
  // Повторные build без изменений библиотеки используют прежний результат.
  List<Track>? _memoTracks;
  List<Track>? _memoVisible;
  String _memoQuery = '';
  String _memoSort = '';
  bool _memoDesc = false;
  bool _memoMine = false;
  int _memoRevision = -1;

  /// Включён фильтр «Мои загрузки»
  bool _mineOnly = false;

  /// Выбранные в «Кто загрузил» (почты в нижнем регистре); пусто — фильтра нет
  Set<String> _by = {};
  String _memoBy = '';
  List<Track>? _uploadersFor;
  int _uploadersRev = -1;
  List<Uploader> _uploaders = const [];

  List<Track> _rememberVisible(List<Track> tracks, LibraryController lib) {
    _memoTracks = widget.tracks;
    _memoVisible = tracks;
    _memoQuery = _query;
    _memoSort = _sort;
    _memoDesc = _desc;
    _memoMine = _mineOnly;
    _memoBy = encodeUploaders(_by);
    _memoRevision = lib.revision;
    return tracks;
  }

  // Групповое выделение: Shift + клик по треку включает режим
  bool _selecting = false;
  final Set<String> _sel = {};
  String? _anchor; // от него считается диапазон по Shift
  List<Track> _visibleNow = const [];

  /// Какой странице принадлежит список: по названию ключ не годится — у исполнителя и его одноимённого альбома
  /// (или у альбома и плейлиста с тем же названием) он совпадал, и страницы затирали положение прокрутки друг друга
  String? _storageId;

  @override
  void initState() {
    super.initState();
    searchRequests.addListener(_focusSearch);
    // В альбоме и плейлисте чаще всего включают первые треки — готовим их заранее
    if (widget.numbered || widget.playlistId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final player = Services.of(context).player;
        for (final t in widget.tracks.take(2)) {
          player.warmUp(t);
        }
      });
    }
  }

  @override
  void dispose() {
    searchRequests.removeListener(_focusSearch);
    HardwareKeyboard.instance.removeHandler(_selectionKey);
    if (_selecting) WidgetsBinding.instance.addPostFrameCallback((_) => selectionBarOpen.value = false);
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _focusSearch() {
    if (!mounted) return;
    _searchFocus.requestFocus();
    _search.selection = TextSelection(baseOffset: 0, extentOffset: _search.text.length);
  }

  /// Перетаскивать можно, когда виден весь плейлист в своём порядке
  bool get _canReorder => widget.onReorder != null && _sort.isEmpty && _query.trim().isEmpty && !_selecting;

  /// Порядок менять нельзя только из-за сортировки или поиска — об этом подсказка над списком

  static bool _typing() {
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx == null) return false;
    return ctx.widget is EditableText || ctx.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  /// В режиме выделения: Esc выходит, Ctrl+A выделяет всё видимое
  bool _selectionKey(KeyEvent e) {
    if (!_selecting || e is! KeyDownEvent) return false;
    if (e.logicalKey == LogicalKeyboardKey.escape) {
      _exitSelection();
      return true;
    }
    final kb = HardwareKeyboard.instance;
    if (e.logicalKey == LogicalKeyboardKey.keyA && (kb.isControlPressed || kb.isMetaPressed) && !_typing()) {
      setState(() => _sel.addAll(_visibleNow.map((t) => t.id)));
      return true;
    }
    return false;
  }

  void _exitSelection() {
    selectionBarOpen.value = false;
    HardwareKeyboard.instance.removeHandler(_selectionKey);
    if (!mounted) return;
    setState(() {
      _selecting = false;
      _sel.clear();
      _anchor = null;
    });
  }

  void _onSelect(List<Track> visible, int i, bool shift) {
    final id = visible[i].id;
    setState(() {
      if (!_selecting) {
        _selecting = true;
        _sel
          ..clear()
          ..add(id);
        _anchor = id;
        selectionBarOpen.value = true;
        HardwareKeyboard.instance.addHandler(_selectionKey);
        return;
      }
      if (shift && _anchor != null) {
        final a = visible.indexWhere((t) => t.id == _anchor);
        if (a >= 0) {
          // Диапазон от якоря до этого трека; якорь остаётся прежним, как в проводнике
          for (var k = min(a, i); k <= max(a, i); k++) {
            _sel.add(visible[k].id);
          }
          return;
        }
      }
      if (!_sel.remove(id)) _sel.add(id);
      _anchor = id;
      if (_sel.isEmpty) {
        // Сняли отметку с последнего трека — выделение отменяется, клик снова включает трек
        HardwareKeyboard.instance.removeHandler(_selectionKey);
        selectionBarOpen.value = false;
        _selecting = false;
        _anchor = null;
      }
    });
  }

  Widget _selectionBar(AppServices app, List<Track> visible, double pad) {
    final picked = [for (final t in visible) if (_sel.contains(t.id)) t];
    final ids = [for (final t in picked) t.id];
    final none = picked.isEmpty;
    return Positioned(
      left: pad,
      right: pad,
      bottom: 14,
      child: Center(
        child: Material(
          type: MaterialType.transparency,
          child: GlassPanel(
            radius: 16,
            tint: C.glassLight,
            blur: 32,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Wrap(spacing: 4, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Text('Выбрано: ${picked.length}', style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () => setState(() => _sel.addAll(visible.map((t) => t.id))),
                child: const Text('Выбрать все'),
              ),
              TextButton.icon(
                onPressed: none ? null : () => app.player.playTracks(picked, 0),
                icon: const Icon(Icons.play_arrow_rounded, size: 18),
                label: const Text('Играть'),
              ),
              TextButton.icon(
                onPressed: none
                    ? null
                    : () {
                        for (final t in picked) {
                          app.player.addToQueue(t);
                        }
                        app.lib.messages.add('В очередь добавлено: ${countTracks(picked.length)}');
                      },
                icon: const Icon(Icons.queue_music_rounded, size: 18),
                label: const Text('В очередь'),
              ),
              Builder(builder: (_) {
                final allLiked = !none && picked.every((t) => app.lib.isLiked(t.id));
                return TextButton.icon(
                  onPressed: none
                      ? null
                      : () {
                          app.lib.setLikes(ids, !allLiked);
                          app.lib.messages.add(allLiked
                              ? 'Убрано из любимого: ${countTracks(ids.length)}'
                              : 'В любимое добавлено: ${countTracks(ids.length)}');
                        },
                  icon: Icon(allLiked ? Icons.favorite_rounded : Icons.favorite_border_rounded, size: 18),
                  label: Text(allLiked ? 'Убрать из любимого' : 'В любимое'),
                );
              }),
              FilledButton.icon(
                onPressed: none
                    ? null
                    : () async {
                        if (await addToPlaylistDialog(context, ids)) _exitSelection();
                      },
                icon: const Icon(Icons.playlist_add_rounded, size: 18),
                label: const Text('В плейлист…'),
              ),
              OutlinedButton.icon(
                onPressed: none ? null : () => showTagsDialog(context, picked),
                icon: const Icon(Icons.tag_rounded, size: 18),
                label: const Text('Теги…'),
              ),
              OutlinedButton.icon(
                onPressed: none
                    ? null
                    : () async {
                        if (await editTracksDialog(context, picked)) _exitSelection();
                      },
                icon: const Icon(Icons.edit_outlined, size: 18),
                label: const Text('Изменить…'),
              ),
              if (widget.playlistId != null)
                TextButton.icon(
                  onPressed: none
                      ? null
                      : () {
                          for (final id in ids) {
                            app.lib.removeFromPlaylist(widget.playlistId!, id);
                          }
                          _exitSelection();
                        },
                  icon: const Icon(Icons.remove_circle_outline_rounded, size: 18),
                  label: const Text('Убрать из плейлиста'),
                ),
              TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: C.danger),
                onPressed: none
                    ? null
                    : () async {
                        final foreign = picked.where((t) => t.by.isNotEmpty && !app.lib.isMyAccount(t.by)).length;
                        final choice = await askDeleteReason(
                          context,
                          title: 'Удалить выбранное: ${countTracks(picked.length)}?',
                          text: 'Треки пропадут из библиотеки у всех, а файлы уйдут в корзину Google Диска (их можно вернуть оттуда).'
                              '${foreign > 0 ? '\n\nЧужих файлов среди них: $foreign. Их удаляет тот, кто загрузил, поэтому в корзину они уйдут, '
                                  'когда он откроет Cavey и подтвердит удаление. Выбранную причину он увидит.' : ''}',
                        );
                        if (choice == null) return;
                        app.lib.deleteTracks(picked, reason: choice.reason, note: choice.note);
                        app.lib.messages.add('Удалено: ${countTracks(picked.length)}');
                        _exitSelection();
                      },
                icon: const Icon(Icons.delete_outline_rounded, size: 18),
                label: const Text('Удалить выбранное'),
              ),
              IconButton(tooltip: 'Готово (Esc)', onPressed: _exitSelection, icon: const Icon(Icons.close_rounded, size: 20)),
            ]),
          ),
        ),
      ),
    );
  }
  String _sort = ''; // пусто — порядок как есть
  bool _desc = false;
  bool _sortLoaded = false;

  /// Ключ в настройках, под которым страница помнит свою сортировку: у каждого плейлиста и страницы свой
  String get _pageKey => widget.playlistId != null ? 'pl:${widget.playlistId}' : widget.title;
  String get _sortKey => 'sort.$_pageKey';

  void _setMine(bool v) {
    setState(() => _mineOnly = v);
    final app = Services.of(context);
    if (v) {
      app.settings.view['filter.mine.$_pageKey'] = '1';
    } else {
      app.settings.view.remove('filter.mine.$_pageKey');
    }
    app.lib.viewChanged();
  }

  void _setBy(Set<String> v) {
    setState(() => _by = v);
    saveUploaderFilter(Services.of(context), _pageKey, v);
  }

  /// Кто из людей загрузил треки этой страницы (для окошка «Кто загрузил»)
  List<Uploader> _uploadersNow(LibraryController lib) {
    if (!identical(_uploadersFor, widget.tracks) || _uploadersRev != lib.revision) {
      _uploadersFor = widget.tracks;
      _uploadersRev = lib.revision;
      _uploaders = uploadersOf(widget.tracks);
    }
    return _uploaders;
  }

  bool get _isDefaultSort => _sort == (widget.defaultSort ?? '') && _desc == (widget.defaultSort != null);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_storageId == null) {
      final nav = context.getInheritedWidgetOfExactType<NavScope>()?.nav.value;
      _storageId = nav == null ? '' : '${nav.kind}/${nav.id ?? ''}';
    }
    if (_sortLoaded) return;
    _sortLoaded = true;
    final settings = Services.of(context).settings;
    if (widget.mineFilter) {
      _mineOnly = settings.view['filter.mine.$_pageKey'] == '1';
      _by = loadUploaderFilter(settings, _pageKey);
    }
    final saved = settings.view[_sortKey];
    if (saved != null) {
      final i = saved.lastIndexOf('|');
      _sort = i < 0 ? saved : saved.substring(0, i);
      _desc = i >= 0 && saved.substring(i + 1) == '1';
    } else {
      _sort = widget.defaultSort ?? '';
      _desc = widget.defaultSort != null;
    }
  }

  /// Запоминает выбор: при следующем открытии этой страницы сортировка та же
  void _rememberSort() {
    final app = Services.of(context);
    if (_isDefaultSort) {
      app.settings.view.remove(_sortKey);
    } else {
      app.settings.view[_sortKey] = '$_sort|${_desc ? 1 : 0}';
    }
    app.lib.saveSettings();
  }

  List<Track> _visible(LibraryController lib, String Function(String) nameOf, Map<String, int>? addedAt) {
    if (identical(_memoTracks, widget.tracks) && _memoVisible != null &&
        _memoQuery == _query && _memoSort == _sort && _memoDesc == _desc && _memoMine == _mineOnly && _memoBy == encodeUploaders(_by) &&
        _memoRevision == lib.revision) {
      return _memoVisible!;
    }
    // «#рок #вечер nirvana»: теги отбирают треки, остальной текст ищется по названию, исполнителю и альбому
    final tq = parseTagQuery(_query);
    final q = tq.text.trim().toLowerCase();
    final tagOk = tagFilterFor(lib.myTags, tq);
    final filterMine = _mineOnly && widget.mineFilter;
    final filterBy = _by.isNotEmpty && widget.mineFilter;
    final base = filterMine || filterBy || tagOk != null
        ? [
            for (final t in widget.tracks)
              if ((!filterMine || lib.isMyAccount(t.by)) && (!filterBy || passesUploaders(_by, t.by)) && (tagOk == null || tagOk(t))) t
          ]
        : widget.tracks;
    var list = q.isEmpty
        ? base
        : base
            .where((t) =>
                t.title.toLowerCase().contains(q) || t.artist.toLowerCase().contains(q) || t.album.toLowerCase().contains(q))
            .toList();
    if (_sort.isEmpty) return _rememberVisible(list, lib);
    int byText(String a, String b) => a.toLowerCase().compareTo(b.toLowerCase());
    int byNo(Track a, Track b) => (a.no ?? 9999).compareTo(b.no ?? 9999);
    String when(Track t) => t.added.isNotEmpty ? t.added : t.modified;
    final pos = _sort == 'padded' ? {for (var i = 0; i < widget.tracks.length; i++) widget.tracks[i].id: i} : const <String, int>{};
    final cmp = switch (_sort) {
      'title' => (Track a, Track b) => byText(a.title, b.title),
      'artist' => (Track a, Track b) {
          final r = byText(a.displayArtist, b.displayArtist);
          if (r != 0) return r;
          final r2 = byText(a.displayAlbum, b.displayAlbum);
          return r2 != 0 ? r2 : byNo(a, b);
        },
      'album' => (Track a, Track b) {
          final r = byText(a.displayAlbum, b.displayAlbum);
          return r != 0 ? r : byNo(a, b);
        },
      'by' => (Track a, Track b) => byText(nameOf(a.by), nameOf(b.by)),
      'dur' => (Track a, Track b) => (a.durationMs ?? 0).compareTo(b.durationMs ?? 0),
      'padded' => (Track a, Track b) {
          // Дата добавления в плейлист; у одной даты (например, при создании) ниже стоит то, что добавлено позже
          final r = (addedAt?[a.id] ?? 0).compareTo(addedAt?[b.id] ?? 0);
          return r != 0 ? r : (pos[a.id] ?? 0).compareTo(pos[b.id] ?? 0);
        },
      'liked' => (Track a, Track b) => lib.likedAtOf(a).compareTo(lib.likedAtOf(b)),
      _ => (Track a, Track b) => when(a).compareTo(when(b)),
    };
    // Равные по ключу не должны менять места от перерисовки к перерисовке: добавляем название и id
    int stable(Track a, Track b) {
      final r = cmp(a, b);
      if (r != 0) return r;
      final t = byText(a.title, b.title);
      return t != 0 ? t : a.id.compareTo(b.id);
    }

    list = List.of(list)..sort(stable);
    return _rememberVisible(_desc ? list.reversed.toList() : list, lib);
  }

  void _setSort(String key) {
    setState(() {
      if (_sort == key) {
        if (_desc == (key == 'added' || key == 'padded')) {
          _desc = !_desc;
        } else {
          _resetSort(); // третий клик — вернуть исходный порядок
        }
      } else {
        _sort = key;
        _desc = key == 'added' || key == 'padded'; // новые сверху
      }
    });
    _rememberSort();
  }

  void _resetSort() {
    _sort = widget.defaultSort ?? '';
    _desc = widget.defaultSort != null;
  }

  /// «Название / Исполнитель»: 1–2 клика — по названию (↑, ↓), 3–4 — по исполнителю (↑, ↓), 5-й сбрасывает
  void _setTitleArtist() {
    setState(() {
      if (_sort != 'title' && _sort != 'artist') {
        _sort = 'title';
        _desc = false;
      } else if (!_desc) {
        _desc = true;
      } else if (_sort == 'title') {
        _sort = 'artist';
        _desc = false;
      } else {
        _resetSort();
      }
    });
    _rememberSort();
  }

  Widget _titleArtistLabel() {
    Widget part(String text, bool active) => Text(text,
        style: TextStyle(fontSize: 12, color: active ? C.text : C.faint, fontWeight: FontWeight.w500));
    final arrow = Icon(_desc ? Icons.arrow_downward_rounded : Icons.arrow_upward_rounded, size: 13, color: C.accent);
    return InkWell(
      borderRadius: BorderRadius.circular(4),
      onTap: _setTitleArtist,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          part('Название', _sort == 'title'),
          if (_sort == 'title') arrow,
          part(' / ', false),
          part('Исполнитель', _sort == 'artist'),
          if (_sort == 'artist') arrow,
        ]),
      ),
    );
  }

  Widget _sortHeader(bool compact) {
    Widget label(String key, String text, {IconData? icon}) {
      final active = _sort == key;
      return InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: () => _setSort(key),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (icon != null)
              Icon(icon, size: 15, color: active ? C.text : C.faint)
            else
              Text(text, style: TextStyle(fontSize: 12, color: active ? C.text : C.faint, fontWeight: FontWeight.w500)),
            if (active)
              Icon(_desc ? Icons.arrow_downward_rounded : Icons.arrow_upward_rounded, size: 13, color: C.accent),
          ]),
        ),
      );
    }

    TrackColumns.ensure(Services.of(context));
    final show = TrackColumns.shows;
    return GestureDetector(
      // ПКМ по шапке — какие столбцы показывать
      onSecondaryTapUp: (d) => TrackColumns.menu(context, d.globalPosition),
      child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: C.divider))),
      height: 32,
      child: Row(children: [
        const SizedBox(width: 28, child: Text('#', style: TextStyle(fontSize: 12, color: C.faint))),
        const SizedBox(width: 62),
        Expanded(
          flex: 5,
          child: Align(alignment: Alignment.centerLeft, child: _titleArtistLabel()),
        ),
        if (!compact) ...[
          if (TrackColumns.tagsVisible(Services.of(context).lib)) ...[
            const SizedBox(width: 16),
            const SizedBox(width: kTagsColW, child: Text('Теги', style: TextStyle(fontSize: 12, color: C.faint, fontWeight: FontWeight.w500))),
          ],
          if (show('album')) ...[
            const SizedBox(width: 16),
            Expanded(flex: 3, child: Align(alignment: Alignment.centerLeft, child: label('album', 'Альбом'))),
          ],
          if (show('by')) ...[
            const SizedBox(width: 16),
            Expanded(flex: 2, child: Align(alignment: Alignment.centerLeft, child: label('by', 'Загрузил(а)'))),
          ],
        ],
        if (widget.playlistId != null && !compact && show('padded'))
          SizedBox(width: _addedColW, child: Align(alignment: Alignment.centerLeft, child: label('padded', 'Дата добавления'))),
        if (!compact && show('added')) SizedBox(width: _uploadColW, child: Align(alignment: Alignment.centerLeft, child: label('added', 'Дата загрузки'))),
        // Ровно столько же занимают сердечко с аватарками и «…» в строке: столбцы шапки и строк совпадают
        SizedBox(width: show('likes') ? kRowActionsW : 40),
        SizedBox(width: 60, child: Align(alignment: Alignment.centerRight, child: label('dur', 'Длительность', icon: Icons.schedule_rounded))),
      ]),
    ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final pl = widget.playlistId == null ? null : app.lib.playlist(widget.playlistId!);
    final addedAt = pl == null ? null : {for (final t in widget.tracks) t.id: app.lib.playlistAddedAt(pl, t.id)};
    final visible = _visible(app.lib, app.lib.firstNameOf, addedAt);
    _visibleNow = visible;
    final pad = widget.compact ? 20.0 : 36.0;
    if (_selecting) {
      final present = {for (final t in widget.tracks) t.id};
      _sel.retainAll(present);
    }

    // Поле поиска одной высоты с кнопками рядом
    // Когда у человека есть теги, подсказка в поле напоминает про «#»
    String withTags(String hint) => app.lib.myTags.isEmpty ? hint : '$hint · #тег';
    Widget searchBox(String hint, {double width = 300}) => RowSearchField(
          controller: _search,
          focusNode: _searchFocus,
          hint: withTags(hint),
          width: width,
          tagSuggest: true,
          onChanged: (v) => setState(() => _query = v),
          onClear: () => setState(() {
            _search.clear();
            _query = '';
          }),
        );

    Widget buttons(WrapAlignment align, {Widget? leading}) {
      final leftRow = uniformControls(context, Wrap(
          spacing: 12,
          runSpacing: 10,
          alignment: align,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (leading != null) leading,
            FilledButton.icon(
              onPressed: visible.isEmpty
                  ? null
                  : () {
                      if (app.player.shuffle && !(widget.numbered && widget.playlistId == null)) app.player.toggleShuffle();
                      app.player.playTracks(visible, 0, inOrder: widget.numbered && widget.playlistId == null);
                    },
              icon: const Icon(Icons.play_arrow_rounded, size: 20),
              label: const Text('Слушать'),
            ),
            OutlinedButton.icon(
              onPressed: visible.isEmpty
                  ? null
                  : () {
                      if (!app.player.shuffle) app.player.toggleShuffle();
                      app.player.playTracks(visible, (DateTime.now().microsecond) % visible.length);
                    },
              icon: const Icon(Icons.shuffle_rounded, size: 18),
              label: const Text('Вперемешку'),
            ),
            ...widget.actions,
          ],
        ));
        // Фильтры загрузок — у правого края ряда, левые кнопки при нехватке места переносятся
        if (!widget.mineFilter || widget.tracks.isEmpty) return leftRow;
        final right = Wrap(spacing: 12, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
          UploaderFilterButton(people: _uploadersNow(app.lib), chosen: _by, onChanged: _setBy),
          ToggleOutlineButton(
            icon: Icons.person_outline_rounded,
            label: 'Мои загрузки',
            on: _mineOnly,
            onPressed: () => _setMine(!_mineOnly),
          ),
        ]);
        return uniformControls(context, Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: leftRow),
          const SizedBox(width: 12),
          right,
        ]));
      }

    final hero = widget.heroColor;
    final left = widget.heroLeft;
    final heroHeader = hero == null
        ? null
        : Stack(children: [
            // Свечение цветом шапки: плавно уходит в прозрачность и медленно «дышит»
            AmbientGlow(color: hero.withValues(alpha: 0.45)),
            SizedBox(
              width: double.infinity,
              child: Padding(
              padding: EdgeInsets.fromLTRB(pad, widget.compact ? 72 : (left ? 72 : 96), pad, left ? 28 : 36),
              // Заголовок и число треков всегда по центру; кнопки и поиск у «Любимого» остаются слева
              child: Column(crossAxisAlignment: left ? CrossAxisAlignment.stretch : CrossAxisAlignment.center, children: [
                SelectionArea(
                  child: Text(widget.title, textAlign: TextAlign.center, style: display(widget.compact ? 34 : 44, weight: FontWeight.w700)),
                ),
                if (widget.subtitle != null) ...[
                  SizedBox(height: left ? 14 : 10),
                  SelectionArea(
                    child: Text(widget.subtitle!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70, fontSize: 16)),
                  ),
                ],
                if (widget.tracks.isNotEmpty) ...[
                  SizedBox(height: left ? 32 : 24),
                  buttons(left ? WrapAlignment.start : WrapAlignment.center,
                      leading: widget.tracks.length > 8 ? searchBox('Найти трек или исполнителя', width: 340) : null),
                ] else if (widget.actions.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  Wrap(spacing: 12, alignment: left ? WrapAlignment.start : WrapAlignment.center, children: widget.actions),
                ],
              ]),
              ),
            ),
          ]);

    final header = heroHeader ?? Padding(
      padding: EdgeInsets.fromLTRB(pad, pageTop(context), pad, 18),
      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        if (widget.image != null) ...[
          widget.image!,
          const SizedBox(width: 28),
        ] else if (widget.cover != null || widget.coverFileId != null) ...[
          HeaderCover(
            track: widget.cover,
            fileId: widget.coverFileId,
            label: widget.coverLabel,
            grid: widget.coverGrid,
            size: widget.compact ? 120 : 176,
            onEdit: widget.onEditCover,
            editTooltip: widget.editCoverTooltip,
          ),
          const SizedBox(width: 28),
        ],
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            // Внутри «Медиатеки» общий заголовок уже сверху — своё название страницы не дублируем
            if (!LibraryFrame.on(context))
              SelectionArea(
                child: Text(widget.title,
                    maxLines: 2, overflow: TextOverflow.ellipsis, style: display(widget.compact ? 26 : 36, weight: FontWeight.w700)),
              ),
            if (widget.subtitleWidget != null) ...[
              const SizedBox(height: 10),
              SelectionArea(child: widget.subtitleWidget!),
            ] else if (widget.subtitle != null) ...[
              const SizedBox(height: 10),
              SelectionArea(child: Text(widget.subtitle!, style: const TextStyle(color: C.muted, fontSize: 15))),
            ],
            if (widget.tracks.isNotEmpty) ...[
              // Внутри «Медиатеки» заголовка и подписи нет — ряд кнопок сразу под вкладками, без лишнего зазора
              if (!LibraryFrame.on(context) || widget.subtitle != null || widget.subtitleWidget != null) const SizedBox(height: 22),
              buttons(WrapAlignment.start,
                  leading: widget.searchInBanner ? searchBox('Найти трек, исполнителя или альбом', width: 400) : null),
            ] else if (widget.actions.isNotEmpty) ...[
              const SizedBox(height: 16),
              Row(children: widget.actions),
            ],
          ]),
        ),
        if (widget.tracks.length > 8 && !widget.compact && !widget.searchInBanner) ...[
          const SizedBox(width: 20),
          SizedBox(
            width: 240,
            child: TagSuggest(
              controller: _search,
              focusNode: _searchFocus,
              onChanged: (v) => setState(() => _query = v),
              child: TextField(
              controller: _search,
              focusNode: _searchFocus,
              onChanged: (v) => setState(() => _query = v),
              decoration: InputDecoration(
                hintText: withTags('Найти трек или исполнителя'),
                prefixIcon: const Icon(Icons.search_rounded, size: 18),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close_rounded, size: 16),
                        onPressed: () => setState(() {
                          _search.clear();
                          _query = '';
                        }),
                      ),
              ),
            ),
            ),
          ),
        ],
      ]),
    );

    final Widget? bannerChild = widget.banner;
    final banner = bannerChild == null
        ? null
        : Padding(padding: EdgeInsets.fromLTRB(pad, 0, pad, 14), child: Align(alignment: Alignment.centerLeft, child: bannerChild));
    if (widget.tracks.isEmpty) {
      if (widget.footer != null) {
        return ListView(children: [header, if (banner != null) banner, widget.footer!]);
      }
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        header,
        if (banner != null) banner,
        Expanded(child: widget.empty),
      ]);
    }

    return ListenableBuilder(
      listenable: Listenable.merge([app.player, app.cache, TrackColumns.hidden]),
      builder: (context, _) {
        final currentId = app.player.current?.id;
        // Перетаскиваемая строка рисуется в Overlay навигатора, выше страницы, где живёт NavScope: передаём его вручную,
        // иначе строка не строится (trackLinks берёт NavScope сразу) и в сборке без отладки заливается серым
        final navScope = NavScope.of(context);
        // Галочка — только у треков, сохранённых офлайн: из «Любимого», плейлиста или альбома с кнопкой «Сохранить офлайн»
        final pinned = app.cache.pinnedIds;
        Widget row(BuildContext context, int i) => TrackRow(
              track: visible[i],
              index: i,
              current: visible[i].id == currentId,
              playing: app.player.playing,
              compact: widget.compact,
              playlistId: widget.playlistId,
              cached: pinned.contains(visible[i].id) && app.cache.has(visible[i].id),
              onPlay: () => app.player.playTracks(visible, i, playlistId: widget.playlistId, inOrder: widget.numbered && widget.playlistId == null),
              selecting: _selecting,
              selected: _sel.contains(visible[i].id),
              onSelect: (shift) => _onSelect(visible, i, shift),
              group: () => [for (final t in _visibleNow) if (_sel.contains(t.id)) t],
              addedAt: addedAt?[visible[i].id],
              dragIndex: _canReorder ? i : null,
            );
        final list = CustomScrollView(
            // Вернулись назад — список на том же месте
            key: PageStorageKey('tracks:${_storageId ?? ''}:${widget.title}:${widget.playlistId ?? ''}'),
            slivers: [
          SliverToBoxAdapter(child: header),
          if (banner != null) SliverToBoxAdapter(child: banner),
          if (visible.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: pad, vertical: 24),
                child: Text('Ничего не нашлось по запросу «$_query»', style: const TextStyle(color: C.muted)),
              ),
            ),
          if (visible.isNotEmpty)
            SliverPadding(
              padding: EdgeInsets.fromLTRB(pad - 12, 0, pad - 12, 4),
              sliver: SliverToBoxAdapter(child: _sortHeader(widget.compact)),
            ),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(pad - 12, 0, pad - 12, 24),
            sliver: _canReorder
                ? SliverReorderableList(
                    itemCount: visible.length,
                    itemExtent: 58,
                    proxyDecorator: (child, i, anim) => AnimatedBuilder(
                      animation: anim,
                      builder: (context, child) {
                        final k = Curves.easeOut.transform(anim.value);
                        return Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(10),
                            boxShadow: [BoxShadow(color: Color.fromRGBO(0, 0, 0, 0.28 * k), blurRadius: 14 * k, offset: Offset(0, 4 * k))],
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            // Лишь слегка осветляем строку: содержимое остаётся видно
                            child: ColoredBox(color: Color.fromRGBO(255, 255, 255, 0.09 * k), child: child),
                          ),
                        );
                      },
                      child: NavScope(nav: navScope, child: Material(type: MaterialType.transparency, child: child)),
                    ),
                    onReorder: (from, to) {
                      if (to > from) to--;
                      if (from == to) return;
                      final rest = List.of(visible)..removeAt(from);
                      widget.onReorder!(visible[from], to == 0 ? null : rest[to - 1]);
                    },
                    itemBuilder: (context, i) => ReorderableDelayedDragStartListener(
                      key: ValueKey(visible[i].id),
                      index: i,
                      child: SizedBox(height: 58, child: row(context, i)),
                    ),
                  )
                : SliverFixedExtentList(
                    itemExtent: 58,
                    delegate: SliverChildBuilderDelegate(row, childCount: visible.length),
                  ),
          ),
          if (widget.footer != null) SliverToBoxAdapter(child: widget.footer!),
          // Место под панель действий, чтобы она не закрывала последние треки
          if (_selecting) const SliverToBoxAdapter(child: SizedBox(height: 70)),
        ]);
        // Структура не меняется при входе в режим, поэтому список не прыгает
        return Stack(children: [Positioned.fill(child: list), if (_selecting) _selectionBar(app, visible, pad)]);
      },
    );
  }
}

class TrackRow extends StatelessWidget {
  final Track track;
  final int index;
  final bool current;
  final bool playing;
  final bool compact;
  final String? playlistId;
  final VoidCallback onPlay;
  final bool cached;

  /// Режим группового выделения: вместо номера — галочка, клик выделяет, а не включает
  final bool selecting;
  final bool selected;
  final void Function(bool shift)? onSelect;

  /// Выбранные сейчас треки: теги из меню и «+» в столбце получит весь выбор, если эта строка в нём
  final List<Track> Function()? group;

  /// Когда трек добавлен в этот плейлист (мс); есть только на страницах плейлистов
  final int? addedAt;

  const TrackRow({
    super.key,
    required this.track,
    required this.index,
    required this.current,
    required this.playing,
    required this.compact,
    required this.onPlay,
    this.cached = false,
    this.playlistId,
    this.selecting = false,
    this.selected = false,
    this.onSelect,
    this.group,
    this.addedAt,
    this.dragIndex,
  });

  /// Номер в списке, который можно перетаскивать: у строки появляется ручка (при наведении вместо номера)
  final int? dragIndex;

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    TrackColumns.ensure(app);
    final titleColor = current ? C.accent : C.text;
    return InkWell(
      onTap: () {
        // Shift + клик включает выделение, в самом режиме клик выделяет трек
        final shift = HardwareKeyboard.instance.isShiftPressed;
        if (onSelect != null && (selecting || shift)) {
          onSelect!(shift);
          return;
        }
        if (current) {
          app.player.toggle();
        } else {
          onPlay();
        }
      },
      onHover: (inside) => app.player.hover(track, inside),
      // Правый клик — то же меню, что под «…»
      onSecondaryTapUp: (d) => showTrackMenu(context, track, playlistId, d.globalPosition,
          onSelect: onSelect == null ? null : () => onSelect!(false), selected: selected, group: selecting && selected ? group : null),
      borderRadius: BorderRadius.circular(8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: selected ? C.accent.withValues(alpha: 0.14) : null,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
        padding: const EdgeInsets.only(right: 12),
        child: Row(children: [
          _EdgeZone(
            selecting: selecting,
            selected: selected,
            // У играющего трека на месте значка тоже появляется ручка: его можно перетаскивать, как и остальные
            child: _NumberOrHandle(
              number: current
                  ? Icon(playing ? Icons.graphic_eq_rounded : Icons.pause_rounded, size: 18, color: C.accent)
                  // номер по порядку в этом списке, а не номер из тегов трека
                  : Text('${index + 1}',
                      style: const TextStyle(color: C.faint, fontSize: 13, fontFeatures: [FontFeature.tabularFigures()])),
              dragIndex: dragIndex,
            ),
          ),
          const SizedBox(width: 8),
          CoverImage(track: track, size: 40, radius: 5),
          const SizedBox(width: 14),
          Expanded(
            flex: 5,
            child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(
                  child: Text(track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: titleColor, fontSize: 15, fontWeight: FontWeight.w500)),
                ),
                if (cached)
                  const Padding(
                    padding: EdgeInsets.only(left: 6),
                    child: Tooltip(
                      message: 'Сохранён на компьютере, играет без интернета',
                      child: Icon(Icons.download_done_rounded, size: 14, color: C.faint),
                    ),
                  ),
              ]),
              const SizedBox(height: 3),
              Links(
                parts: trackLinks(context, track, album: compact),
                style: const TextStyle(color: C.muted, fontSize: 13),
              ),
            ]),
          ),
          if (!compact) ...[
            if (TrackColumns.tagsVisible(app.lib)) ...[
              const SizedBox(width: 16),
              TrackTagsCell(track: track, group: selecting && selected ? group : null),
            ],
            if (TrackColumns.shows('album')) ...[
              const SizedBox(width: 16),
              Expanded(
                flex: 3,
                child: Links(
                  parts: [LinkPart(track.displayAlbum, () => NavScope.of(context).go(Nav('album', track.albumKey)))],
                  style: const TextStyle(color: C.muted, fontSize: 13),
                ),
              ),
            ],
            if (TrackColumns.shows('by')) ...[
              const SizedBox(width: 16),
              Expanded(flex: 2, child: Align(alignment: Alignment.centerLeft, child: FriendTag(track.by))),
            ],
          ],
          if (addedAt != null && !compact && TrackColumns.shows('padded'))
            SizedBox(
              width: 120,
              child: Text(formatAddedDate(addedAt!), maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: C.muted, fontSize: 13)),
            ),
          if (!compact && TrackColumns.shows('added'))
            SizedBox(
              width: 110,
              child: Text(formatUploadDate(track.added.isNotEmpty ? track.added : track.modified),
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.muted, fontSize: 13)),
            ),
          // Сердечко с аватарками друзей и «…» занимают всегда одну и ту же ширину [kRowActionsW]
          if (TrackColumns.shows('likes')) LikeButton(track: track, slot: true),
          SizedBox(
            width: 40,
            child: Center(
              child: TrackMenu(
                  track: track,
                  playlistId: playlistId,
                  onSelect: onSelect == null ? null : () => onSelect!(false),
                  selected: selected,
                  group: selecting && selected ? group : null),
            ),
          ),
          // Длительность — в самом правом столбце, правее кнопки «…»
          SizedBox(
            width: 60,
            child: Align(
              alignment: Alignment.centerRight,
              child: Text(
                (track.durationMs ?? 0) > 0 ? formatDuration(Duration(milliseconds: track.durationMs!)) : '',
                style: const TextStyle(color: C.muted, fontSize: 13, fontFeatures: [FontFeature.tabularFigures()]),
              ),
            ),
          ),
        ]),
        ),
      ),
    );
  }
}

/// Какие столбцы списка треков показывать. Настройка личная и общая для всех списков; меняется по ПКМ на шапке.
/// «#», «Название / Исполнитель» и длительность скрыть нельзя
class TrackColumns {
  static const optional = [
    ('tags', 'Теги'),
    ('album', 'Альбом'),
    ('by', 'Загрузил(а)'),
    ('padded', 'Дата добавления (в плейлистах)'),
    ('added', 'Дата загрузки'),
    ('likes', 'Нравится (сердечко и друзья)'),
  ];
  static final ValueNotifier<Set<String>> hidden = ValueNotifier(const {});
  static bool _loaded = false;

  static void ensure(AppServices app) {
    if (_loaded) return;
    _loaded = true;
    hidden.value = {for (final x in app.settings.viewOf('cols.hidden', '').split(',')) if (x.isNotEmpty) x};
  }

  static bool shows(String key) => !hidden.value.contains(key);

  /// Столбец «Теги» показывается, когда он включён и у человека есть хотя бы один тег
  static bool tagsVisible(LibraryController lib) => shows('tags') && !lib.myTags.isEmpty;

  static void toggle(AppServices app, String key) {
    final next = {...hidden.value};
    if (!next.remove(key)) next.add(key);
    hidden.value = next;
    if (next.isEmpty) {
      app.settings.view.remove('cols.hidden');
    } else {
      app.settings.view['cols.hidden'] = next.join(',');
    }
    app.lib.viewChanged();
  }

  /// Меню по ПКМ на шапке: галочки у столбцов; основные столбцы показаны, но выключить их нельзя
  static Future<void> menu(BuildContext context, Offset at) async {
    final app = Services.of(context);
    ensure(app);
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final v = await showGlassMenu<String>(
      context: context,
      position: RelativeRect.fromRect(at & const Size(1, 1), Offset.zero & overlay.size),
      items: [
        const CheckedPopupMenuItem(value: '', checked: true, enabled: false, child: Text('Номер')),
        const CheckedPopupMenuItem(value: '', checked: true, enabled: false, child: Text('Название / Исполнитель')),
        for (final (key, label) in optional) CheckedPopupMenuItem(value: key, checked: shows(key), child: Text(label)),
        const CheckedPopupMenuItem(value: '', checked: true, enabled: false, child: Text('Длительность')),
      ],
    );
    if (v == null || v.isEmpty) return;
    toggle(app, v);
  }
}

/// Ширина блока справа в строке трека: аватарки друзей, сердечко и «…». Шапка списка резервирует столько же
const kRowActionsW = 52.0 + 40 + 40;

/// Сердечко + маленькие аватарки друзей, которым трек тоже нравится (до трёх внахлёст, дальше «+N»)
class LikeButton extends StatelessWidget {
  final Track track;
  final double size;

  /// В строках списков: под аватарки всегда отведено одно и то же место, чтобы столбцы не плавали
  final bool slot;
  const LikeButton({super.key, required this.track, this.size = 18, this.slot = false});

  @override
  Widget build(BuildContext context) {
    final lib = Services.of(context).lib;
    final liked = lib.isLiked(track.id);
    final others = (lib.data.likes[track.id] ?? const <String>{}).where((e) => e != lib.me).toList();
    const face = 18.0;
    const step = 10.0;
    final shown = others.length > 3 ? 3 : others.length;
    final extra = others.length - shown;
    final friends = others.isEmpty
        ? null
        : Tooltip(
            message: 'Нравится: ${others.map(lib.firstNameOf).join(', ')}',
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              SizedBox(
                width: face + (shown - 1) * step,
                height: face,
                child: Stack(children: [
                  for (var i = 0; i < shown; i++)
                    Positioned(
                      left: i * step,
                      top: 0,
                      child: Container(
                        padding: const EdgeInsets.all(1),
                        decoration: BoxDecoration(color: C.bg, shape: BoxShape.circle),
                        child: Avatar(email: others[i], name: lib.nameOf(others[i]), size: face - 2),
                      ),
                    ),
                ]),
              ),
              if (extra > 0)
                Padding(
                  padding: const EdgeInsets.only(left: 3),
                  child: Text('+$extra', style: TextStyle(color: C.muted, fontSize: 11, fontWeight: FontWeight.w600)),
                ),
            ]),
          );
    final heart = IconButton(
      tooltip: liked ? 'Убрать из любимого' : 'В любимое',
      iconSize: size,
      visualDensity: VisualDensity.compact,
      onPressed: () => lib.toggleLike(track.id),
      icon: Icon(liked ? Icons.favorite_rounded : Icons.favorite_border_rounded, color: liked ? C.accent : C.faint),
    );
    return Row(mainAxisSize: MainAxisSize.min, children: [
      if (slot)
        SizedBox(width: kRowActionsW - 80, child: Align(alignment: Alignment.centerRight, child: friends))
      else if (friends != null)
        friends,
      slot ? SizedBox(width: 40, child: heart) : heart,
    ]);
  }
}

/// Номер строки; когда список можно перетаскивать, при наведении вместо него — ручка
class _NumberOrHandle extends StatefulWidget {
  final Widget number;
  final int? dragIndex;
  const _NumberOrHandle({required this.number, required this.dragIndex});

  @override
  State<_NumberOrHandle> createState() => _NumberOrHandleState();
}

class _NumberOrHandleState extends State<_NumberOrHandle> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final i = widget.dragIndex;
    if (i == null) return widget.number;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: SizedBox(
        width: 24,
        height: 40,
        child: Center(
          child: _hover
              ? ReorderableDragStartListener(
                  index: i,
                  child: Tooltip(
                    message: 'Перетащите, чтобы изменить порядок',
                    child: MouseRegion(
                      cursor: SystemMouseCursors.grab,
                      child: Icon(Icons.drag_indicator_rounded, size: 20, color: C.muted),
                    ),
                  ),
                )
              : widget.number,
        ),
      ),
    );
  }
}

class TrackMenu extends StatelessWidget {
  final Track track;
  final String? playlistId;

  /// Включает групповое выделение с этим треком (пункт «Выбрать»); null — пункта нет
  final VoidCallback? onSelect;
  final bool selected;

  /// Плейлист, из которого играет трек: даёт пункт «Перейти в плейлист»
  final String? openPlaylist;

  /// Весь групповой выбор, если трек в нём: «Теги…» применится ко всем
  final List<Track> Function()? group;
  const TrackMenu({super.key, required this.track, this.playlistId, this.onSelect, this.selected = false, this.openPlaylist, this.group});

  @override
  Widget build(BuildContext context) {
    return GlassMenuButton<String>(
      tooltip: 'Действия',
      icon: const Icon(Icons.more_horiz_rounded, size: 20),
      onSelected: (v) => onTrackMenu(context, v, track, playlistId, onSelect: onSelect, group: group),
      itemBuilder: (ctx) =>
          trackMenuItems(ctx, track, playlistId, canSelect: onSelect != null, selected: selected, openPlaylist: openPlaylist, group: group),
    );
  }
}

/// Меню трека по правому клику, в точке клика
Future<void> showTrackMenu(BuildContext context, Track track, String? playlistId, Offset at,
    {VoidCallback? onSelect, bool selected = false, String? openPlaylist, List<Track> Function()? group}) async {
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  final v = await showGlassMenu<String>(
    context: context,
    position: RelativeRect.fromRect(at & const Size(1, 1), Offset.zero & overlay.size),
    items: trackMenuItems(context, track, playlistId, canSelect: onSelect != null, selected: selected, openPlaylist: openPlaylist, group: group),
  );
  if (v != null && context.mounted) await onTrackMenu(context, v, track, playlistId, onSelect: onSelect, group: group);
}

List<PopupMenuEntry<String>> trackMenuItems(BuildContext context, Track track, String? playlistId,
    {bool canSelect = false, bool selected = false, String? openPlaylist, List<Track> Function()? group}) {
  final names = track.artists;
  final groupSize = group?.call().length ?? 1;
  final liked = Services.of(context).lib.isLiked(track.id);
  return [
    PopupMenuItem(value: 'like', child: Text(liked ? 'Убрать из любимого' : 'Добавить в любимое')),
    const PopupMenuItem(value: 'queue', child: Text('Добавить в очередь')),
    const PopupMenuItem(value: 'wave', child: Text('Моя волна по треку')),
    const PopupMenuItem(value: 'playlist', child: Text('Добавить в плейлист…')),
    PopupMenuItem(value: 'tags', child: Text(groupSize > 1 ? 'Теги… (выбрано: $groupSize)' : 'Теги…')),
    if (playlistId != null) const PopupMenuItem(value: 'remove', child: Text('Убрать из этого плейлиста')),
    const PopupMenuDivider(),
    if (openPlaylist != null && Services.of(context).lib.playlist(openPlaylist) != null)
      PopupMenuItem(value: 'toplaylist:$openPlaylist', child: const Text('Перейти в плейлист')),
    const PopupMenuItem(value: 'album', child: Text('К альбому')),
    if (names.length == 1)
      const PopupMenuItem(value: 'artist:0', child: Text('К исполнителю'))
    else
      ArtistsMenuEntry(names.take(12).toList()),
    const PopupMenuItem(value: 'copy', child: Text('Копировать название')),
    const PopupMenuItem(value: 'share', child: Text('Поделиться…')),
    const PopupMenuItem(value: 'plays', child: Text('Прослушивания…')),
    const PopupMenuDivider(),
    if (canSelect) PopupMenuItem(value: 'select', child: Text(selected ? 'Снять выбор' : 'Выбрать')),
    const PopupMenuItem(value: 'export', child: Text('Скачать на устройство')),
    if (Services.of(context).cache.has(track.id)) const PopupMenuItem(value: 'reveal', child: Text('Показать на устройстве')),
    const PopupMenuItem(value: 'redownload', child: Text('Перекачать трек…')),
    const PopupMenuItem(value: 'edit', child: Text('Изменить метаданные…')),
    const PopupMenuItem(value: 'hide', child: Text('Скрыть из библиотеки')),
    const PopupMenuItem(value: 'delete', child: Text('Удалить с Диска…', style: TextStyle(color: C.danger))),
  ];
}

Future<void> onTrackMenu(BuildContext context, String v, Track track, String? playlistId,
    {VoidCallback? onSelect, List<Track> Function()? group}) async {
  final app = Services.of(context);
  if (v.startsWith('artist:')) {
    final i = int.tryParse(v.substring(7)) ?? 0;
    final names = track.artists;
    NavScope.of(context).go(Nav('artist', names[i < names.length ? i : 0].toLowerCase()));
    return;
  }
  if (v.startsWith('toplaylist:')) {
    NavScope.of(context).go(Nav('playlist', v.substring(11)));
    return;
  }
  switch (v) {
    case 'wave':
      startWaveFrom(context, track);
    case 'queue':
      app.player.addToQueue(track);
      app.lib.messages.add('«${track.title}» добавлен в очередь');
    case 'like':
      final was = app.lib.isLiked(track.id);
      app.lib.toggleLike(track.id);
      app.lib.messages.add(was ? '«${track.title}» убран из любимого' : '«${track.title}» в любимом');
    case 'select':
      onSelect?.call();
    case 'copy':
      await Clipboard.setData(ClipboardData(text: '${track.title} — ${track.displayArtist}'));
      app.lib.messages.add('Название скопировано');
    case 'share':
      await showShareDialog(context, track);
    case 'plays':
      await showPlaysDialog(context, track);
    case 'playlist':
      await addToPlaylistDialog(context, [track.id]);
    case 'tags':
      await showTagsDialog(context, group?.call() ?? [track]);
    case 'remove':
      app.lib.removeFromPlaylist(playlistId!, track.id);
    case 'album':
      NavScope.of(context).go(Nav('album', track.albumKey));
    case 'export':
      await exportToDevice(context, [track], title: track.title);
    case 'reveal':
      if (!await app.exporter.reveal(track)) app.lib.messages.add('Не удалось открыть Проводник');
    case 'redownload':
      await redownloadTrack(context, track);
    case 'edit':
      await editTrackDialog(context, track);
    case 'delete':
      final mine = app.lib.isMyAccount(track.by) || track.by.isEmpty;
      final choice = await askDeleteReason(
        context,
        title: 'Удалить «${track.title}» с Диска?',
        text: 'Трек пропадёт из библиотеки у всех, а файл уйдёт в корзину Google Диска (30 дней можно вернуть).'
            '${mine ? '' : '\n\nЭтот трек загрузил(а) ${app.lib.firstNameOf(track.by)}: с Диска он удалится, когда '
                '${app.lib.firstNameOf(track.by)} откроет Cavey и подтвердит. Выбранную причину он(а) увидит.'}',
      );
      if (choice == null) return;
      app.lib.deleteTracks([track], reason: choice.reason, note: choice.note);
      app.lib.messages.add('«${track.title}» удалён');
    case 'hide':
      app.lib.hideTrack(track.id, true);
      app.lib.messages.add('«${track.title}» скрыт из библиотеки у всех. Вернуть можно в разделе «Дубликаты».');
  }
}

/// Пункт «К исполнителю» с раскрывающимся списком всех участников трека
class ArtistsMenuEntry extends PopupMenuEntry<String> {
  final List<String> names;
  const ArtistsMenuEntry(this.names, {super.key});

  @override
  double get height => 38;

  @override
  bool represents(String? value) => false;

  @override
  State<ArtistsMenuEntry> createState() => _ArtistsMenuEntryState();
}

class _ArtistsMenuEntryState extends State<ArtistsMenuEntry> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    Widget tile({required VoidCallback onTap, required Widget child, double left = 12}) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            hoverColor: C.hoverOverlay,
            onTap: onTap,
            child: Container(
              constraints: const BoxConstraints(minHeight: 38),
              padding: EdgeInsets.only(left: left, right: 12),
              alignment: Alignment.centerLeft,
              child: DefaultTextStyle.merge(
                style: const TextStyle(color: C.text, fontSize: 14),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                child: child,
              ),
            ),
          ),
        );
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      tile(
        onTap: () => setState(() => _open = !_open),
        child: Row(children: [
          const Expanded(child: Text('К исполнителю')),
          AnimatedRotation(
            turns: _open ? 0.25 : 0,
            duration: const Duration(milliseconds: 160),
            child: const Icon(Icons.chevron_right_rounded, size: 18, color: C.muted),
          ),
        ]),
      ),
      AnimatedSize(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        alignment: Alignment.topCenter,
        child: _open
            ? Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                for (var i = 0; i < widget.names.length; i++)
                  tile(
                    left: 28,
                    onTap: () => Navigator.of(context).pop('artist:$i'),
                    child: Text(widget.names[i]),
                  ),
              ])
            : const SizedBox(width: double.infinity),
      ),
    ]);
  }
}

/// true, если треки добавлены (в существующий или новый плейлист)
Future<bool> addToPlaylistDialog(BuildContext context, List<String> trackIds) async {
  final app = Services.of(context);
  final lib = app.lib;
  // Порядок как в боковой панели: закреплённые первыми, затем остальные. Свои отдельно от чужих;
  // совместные плейлисты (без владельца) считаются плейлистами друзей
  final pins = lib.pinned;
  final ordered = (() {
    final split = splitPinned<Playlist>(lib.visiblePlaylists, (p) => [LibraryController.playlistPin(p.id)], pins);
    return [...split.pinned, ...split.rest];
  })();
  final mine = [for (final p in ordered) if (lib.me != null && p.by == lib.me) p];
  final others = [for (final p in ordered) if (!(lib.me != null && p.by == lib.me)) p];
  final choice = await showGlassDialog<String>(
    context: context,
    builder: (ctx) {
      final size = MediaQuery.sizeOf(ctx);
      final w = (size.width - 80).clamp(320.0, 720.0);
      final cols = w >= 600 ? 4 : (w >= 440 ? 3 : 2);
      Widget tile({required Widget cover, required String title, String? sub, required VoidCallback onTap}) => InkWell(
            borderRadius: BorderRadius.circular(12),
            hoverColor: C.hoverOverlay,
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                AspectRatio(aspectRatio: 1, child: cover),
                const SizedBox(height: 8),
                Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                if (sub != null) Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.muted, fontSize: 12)),
              ]),
            ),
          );
      Widget newTile() => tile(
            title: 'Новый плейлист',
            onTap: () => Navigator.pop(ctx, '+new'),
            cover: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                color: C.hoverOverlay,
                border: Border.all(color: C.accent.withOpacity(0.5), width: 1.5),
              ),
              child: Icon(Icons.add_rounded, size: 40, color: C.accent),
            ),
          );
      Widget listTile(Playlist p) {
        final there = trackIds.length == 1 && p.items.contains(trackIds.first);
        return tile(
          title: p.name,
          sub: p.by.isEmpty ? 'Совместный' : lib.firstNameOf(p.by),
          onTap: () => Navigator.pop(ctx, p.id),
          cover: LayoutBuilder(
            builder: (context, box) => Stack(children: [
              PlaylistCover(playlist: p, size: box.maxWidth, radius: 10),
              if (there)
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(color: const Color(0x99000000), borderRadius: BorderRadius.circular(10)),
                    child: const Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                      Icon(Icons.check_circle_rounded, size: 30, color: Colors.white),
                      SizedBox(height: 4),
                      Text('уже там', style: TextStyle(color: Colors.white, fontSize: 12)),
                    ]),
                  ),
                ),
            ]),
          ),
        );
      }

      SliverGridDelegate grid() =>
          SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: cols, childAspectRatio: 0.78, mainAxisSpacing: 4, crossAxisSpacing: 4);
      Widget header(String text) => Padding(
            padding: const EdgeInsets.fromLTRB(6, 6, 6, 8),
            child: Text(text, style: const TextStyle(color: C.muted, fontSize: 13, fontWeight: FontWeight.w600)),
          );
      return Dialog(
        backgroundColor: C.glassLight,
        insetPadding: const EdgeInsets.all(24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: SizedBox(
          width: w,
          height: (size.height - 120).clamp(320.0, 620.0),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 20, 18, 14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(padding: const EdgeInsets.only(left: 6, bottom: 12), child: Text('В плейлист', style: display(20))),
              Expanded(
                child: CustomScrollView(slivers: [
                  SliverToBoxAdapter(child: header('Ваши плейлисты')),
                  SliverGrid(
                    gridDelegate: grid(),
                    delegate: SliverChildBuilderDelegate(
                      (context, i) => i == 0 ? newTile() : listTile(mine[i - 1]),
                      childCount: mine.length + 1,
                    ),
                  ),
                  if (others.isNotEmpty) ...[
                    SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.only(top: 10), child: header('Плейлисты друзей'))),
                    SliverGrid(
                      gridDelegate: grid(),
                      delegate: SliverChildBuilderDelegate((context, i) => listTile(others[i]), childCount: others.length),
                    ),
                  ],
                ]),
              ),
            ]),
          ),
        ),
      );
    },
  );
  if (choice == null || !context.mounted) return false;
  if (choice == '+new') {
    final name = await askText(context, title: 'Новый плейлист', action: 'Создать', hint: 'Название');
    if (name == null || name.isEmpty) return false;
    lib.createPlaylist(name, trackIds);
    lib.messages.add('Создан плейлист «$name»');
  } else {
    lib.addToPlaylist(choice, trackIds);
    lib.messages.add('Добавлено в «${lib.playlist(choice)?.name ?? 'плейлист'}»');
  }
  return true;
}

/// «Сохранить офлайн» для Любимого и плейлистов: показывает, сколько уже скачано
class OfflineButton extends StatelessWidget {
  final bool on;
  final List<Track> tracks;
  final ValueChanged<bool> onChanged;
  const OfflineButton({super.key, required this.on, required this.tracks, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final cache = Services.of(context).cache;
    return ListenableBuilder(
      listenable: cache,
      builder: (context, _) {
        final done = cache.countCached(tracks);
        final all = tracks.length;
        final label = !on
            ? 'Сохранить офлайн'
            : (done < all ? 'Сохраняю офлайн: $done из $all' : 'Сохранено офлайн');
        return Tooltip(
          message: on ? 'Нажмите, чтобы не хранить эти треки на компьютере' : 'Треки скачаются и будут играть без интернета',
          child: OutlinedButton.icon(
            style: on ? OutlinedButton.styleFrom(foregroundColor: C.accent, side: BorderSide(color: C.accent)) : null,
            onPressed: () => onChanged(!on),
            icon: Icon(on ? Icons.download_done_rounded : Icons.download_rounded, size: 18),
            label: Text(label),
          ),
        );
      },
    );
  }
}

// ---------- ссылки на исполнителей и альбом ----------

/// Кусок строки: обычный текст или ссылка
class LinkPart {
  final String text;
  final VoidCallback? onTap;
  const LinkPart(this.text, [this.onTap]);
}

/// Строка из ссылок: каждая подчёркивается при наведении и открывается по клику.
/// Остаётся одной строкой: длинные куски обрезаются многоточием.
class Links extends StatelessWidget {
  final List<LinkPart> parts;
  final TextStyle style;
  const Links({super.key, required this.parts, required this.style});

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      for (final p in parts)
        p.onTap == null
            ? Text(p.text, maxLines: 1, style: style)
            : Flexible(child: _Link(text: p.text, onTap: p.onTap!, style: style)),
    ]);
  }
}

/// Одна ссылка. Своё состояние наведения: перерисовывается только она сама,
/// а область под мышью и обработчик клика при этом не пересоздаются
class _Link extends StatefulWidget {
  final String text;
  final VoidCallback onTap;
  final TextStyle style;
  const _Link({required this.text, required this.onTap, required this.style});

  @override
  State<_Link> createState() => _LinkState();
}

class _LinkState extends State<_Link> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Text(
          widget.text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: _hover ? widget.style.copyWith(decoration: TextDecoration.underline, color: C.text) : widget.style,
        ),
      ),
    );
  }
}

/// Исполнители трека ссылками на их страницы; с [album] — ещё и альбом через « · »
List<LinkPart> trackLinks(BuildContext context, Track t, {bool album = false}) {
  final nav = NavScope.of(context);
  final parts = <LinkPart>[];
  final names = t.artists;
  for (var i = 0; i < names.length; i++) {
    if (i > 0) parts.add(const LinkPart(', '));
    final key = names[i].toLowerCase();
    parts.add(LinkPart(names[i], () => nav.go(Nav('artist', key))));
  }
  if (album) {
    parts.add(const LinkPart('  ·  '));
    parts.add(LinkPart(t.displayAlbum, () => nav.go(Nav('album', t.albumKey))));
  }
  return parts;
}

/// Дата появления файла на Диске: «12 окт. 2026» (в этом году без года). Пусто, если даты нет
String formatUploadDate(String iso) {
  final d = DateTime.tryParse(iso)?.toLocal();
  if (d == null) return '';
  const months = ['янв.', 'февр.', 'марта', 'апр.', 'мая', 'июня', 'июля', 'авг.', 'сент.', 'окт.', 'нояб.', 'дек.'];
  return '${d.day} ${months[d.month - 1]}${d.year == DateTime.now().year ? '' : ' ${d.year}'}';
}

/// «сегодня», «вчера», «3 дн. назад», дальше дата
String formatAddedDate(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  final now = DateTime.now();
  final days = DateTime(now.year, now.month, now.day).difference(DateTime(d.year, d.month, d.day)).inDays;
  if (days <= 0) return 'сегодня';
  if (days == 1) return 'вчера';
  if (days < 7) return '$days дн. назад';
  const months = ['янв.', 'февр.', 'марта', 'апр.', 'мая', 'июня', 'июля', 'авг.', 'сент.', 'окт.', 'нояб.', 'дек.'];
  return '${d.day} ${months[d.month - 1]}${d.year == now.year ? '' : ' ${d.year}'}';
}

/// Левый столбец строки трека: номер или значок «играет». В режиме выделения вместо него кружок-галочка;
/// включается режим Shift+кликом или пунктом «Выбрать» в меню трека.
class _EdgeZone extends StatelessWidget {
  final bool selecting;
  final bool selected;
  final Widget child;
  const _EdgeZone({required this.selecting, required this.selected, required this.child});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 40,
      height: double.infinity,
      child: Stack(children: [
        if (selected)
          Positioned(
            left: 0,
            top: 6,
            bottom: 6,
            width: 3,
            child: DecoratedBox(
              decoration: BoxDecoration(color: C.accent, borderRadius: BorderRadius.horizontal(right: Radius.circular(3))),
            ),
          ),
        Positioned.fill(
          child: Padding(
            padding: const EdgeInsets.only(left: 12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: selecting
                  ? Icon(selected ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                      size: 20, color: selected ? C.accent : C.faint)
                  : child,
            ),
          ),
        ),
      ]),
    );
  }
}

/// Сердечко в шапке альбома или плейлиста: «в коллекцию» — появится в боковой панели и в профиле
class FavButton extends StatelessWidget {
  final bool on;
  final String what;
  final VoidCallback onTap;
  const FavButton({super.key, required this.on, required this.what, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: on ? 'Убрать $what из любимого' : 'В любимое: $what появится в боковой панели и в профиле',
      onPressed: onTap,
      icon: Icon(on ? Icons.favorite_rounded : Icons.favorite_border_rounded, color: on ? C.accent : C.text),
    );
  }
}

/// Кто и сколько раз слушал трек (счётчики из личных файлов участников)
Future<void> showPlaysDialog(BuildContext context, Track track) {
  final app = Services.of(context);
  final by = app.social.playsByUser(track.id).entries.toList()..sort((a, b) => b.value.compareTo(a.value));
  final total = by.fold<int>(0, (a, e) => a + e.value);
  return showGlassDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Прослушивания', style: display(18)),
      content: SizedBox(
        width: 380,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${track.title} — ${track.displayArtist}', maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text(total == 0 ? 'Пока никто не слушал' : 'Слушали: $total ${plural(total, 'раз', 'раза', 'раз')}',
              style: const TextStyle(color: C.muted)),
          const SizedBox(height: 12),
          for (final e in by)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(children: [
                Avatar(email: e.key, name: app.lib.nameOf(e.key), size: 28),
                const SizedBox(width: 12),
                Expanded(child: Text(app.lib.nameOf(e.key), overflow: TextOverflow.ellipsis)),
                Text('${e.value}', style: const TextStyle(color: C.muted, fontFeatures: [FontFeature.tabularFigures()])),
              ]),
            ),
          const SizedBox(height: 8),
          const Text('Засчитывается, если трек играл хотя бы 30 секунд.', style: TextStyle(color: C.faint, fontSize: 12)),
        ]),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Закрыть'))],
    ),
  );
}


/// «Перекачать трек»: на выбор — заменить аудио файлом с компьютера или найти новую версию через загрузчик Cavey
Future<void> redownloadTrack(BuildContext context, Track track) async {
  final app = Services.of(context);
  final link = TextEditingController();
  // Загрузчик для вставленной ссылки: по умолчанию тот, что выбран у пользователя, но его можно сменить для этого трека
  var provider = app.settings.downloadProvider;
  final choice = await showGlassDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Перекачать «${track.title}»', style: display(18)),
      content: SizedBox(
        width: 400,
        child: StatefulBuilder(
          builder: (ctx, setInner) => Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text(
              'Метаданные сохраняются.\n\nОткуда взять новое аудио?',
              style: TextStyle(color: C.muted, height: 1.45),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: link,
              decoration: const InputDecoration(
                hintText: 'Ссылка на трек (для загрузчика)',
                prefixIcon: Icon(Icons.link_rounded, size: 18),
              ),
            ),
            const SizedBox(height: 14),
            Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
              const Expanded(child: Text('Источник музыки', style: TextStyle(fontSize: 15))),
              const SizedBox(width: 12),
              GlassSelect<String>(
                value: provider,
                width: 220,
                options: const [
                  ('youtube', 'YouTube'),
                  ('deezer', 'Deezer'),
                  ('full', 'Универсальный поиск и ссылки'),
                  ('sockseek', 'Soulseek / Sockseek'),
                  ('bandcamp', 'Bandcamp'),
                ],
                onChanged: (v) => setInner(() => provider = v),
              ),
            ]),
          ]),
        ),
      ),
      actionsOverflowButtonSpacing: 8,
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена', style: TextStyle(color: C.muted))),
        OutlinedButton.icon(
          onPressed: () => Navigator.pop(ctx, 'file'),
          icon: const Icon(Icons.folder_open_rounded, size: 18),
          label: const Text('Из своего файла'),
        ),
        FilledButton.icon(
          onPressed: () => Navigator.pop(ctx, 'search'),
          icon: const Icon(Icons.search_rounded, size: 18),
          label: const Text('Найти через загрузчик'),
        ),
      ],
    ),
  );
  final url = link.text.trim();
  if (choice == null || !context.mounted) return;
  if (choice == 'search') {
    if (url.isNotEmpty && !RegExp(r'^https?://\S+$', caseSensitive: false).hasMatch(url)) {
      app.lib.messages.add('Ссылка должна начинаться с http:// или https://');
      return;
    }
    final job = app.downloads.enqueueReplacement(track, url: url, provider: provider);
    app.lib.messages.add(job == null
        ? 'Этот трек уже перекачивается или у него не указаны исполнитель и название.'
        : 'Перекачивание «${track.title}» добавлено в очередь загрузок');
    return;
  }
  final f = await openFile(acceptedTypeGroups: const [
    XTypeGroup(label: 'Аудио', extensions: ['mp3', 'flac', 'm4a', 'aac', 'ogg', 'opus', 'wav', 'wma']),
  ]);
  if (f == null) return;
  // Замена идёт в фоне: загрузка файла на Диск может занять время, интерфейс при этом не блокируется
  unawaited(app.downloads.replaceFromFile(track, File(f.path)));
}
