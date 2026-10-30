import 'dart:math' show max, min;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app.dart';
import '../core/models.dart';
import 'albums_view.dart';
import 'cover_picker.dart';
import 'download_view.dart';
import 'library_views.dart';
import 'shell.dart';
import 'theme.dart';
import 'widgets.dart';

/// Ctrl+F: каждое увеличение просит открытый список треков поставить курсор в поиск
final searchRequests = ValueNotifier<int>(0);

class AllTracksPage extends StatelessWidget {
  final bool compact;
  const AllTracksPage({super.key, required this.compact});

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
          title: 'Все треки',
          subtitle: tracks.isEmpty
              ? null
              : '${countTracks(tracks.length)} в $albums ${plural(albums, 'альбоме', 'альбомах', 'альбомах')}',
          tracks: tracks,
          compact: compact,
          actions: [
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
          ],
          banner: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(spacing: 10, runSpacing: 10, children: [
              _SectionChip(icon: Icons.album_outlined, label: 'Альбомы', target: const Nav('albums')),
              _SectionChip(icon: Icons.mic_none_rounded, label: 'Исполнители', target: const Nav('artists')),
              _SectionChip(icon: Icons.schedule_rounded, label: 'Недавно добавленное', target: const Nav('recent')),
            ]),
            const SizedBox(height: 12),
            const DropHint(),
          ]),
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
                    onPressed: () => NavScope.of(context).go(const Nav('sources')),
                    child: Text(lib.data.sources.isEmpty ? 'Добавить папку' : 'Открыть папки'),
                  ),
                ),
        );
      },
    );
  }
}

/// Плашка-переход под заголовком «Все треки»
class _SectionChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Nav target;
  const _SectionChip({required this.icon, required this.label, required this.target});

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      avatar: Icon(icon, size: 18, color: C.accent),
      label: Text(label),
      onPressed: () => NavScope.of(context).go(target),
      backgroundColor: C.surface,
      side: const BorderSide(color: C.line),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    );
  }
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
      listenable: app.lib,
      builder: (context, _) {
        final album = app.lib.album(albumKey);
        if (album == null) {
          return const EmptyState(icon: Icons.album_outlined, title: 'Альбом пропал', text: 'Его треки удалили с Диска.');
        }
        final bits = [album.artist, if (album.year.isNotEmpty) album.year, countTracks(album.tracks.length)];
        return TracksPage(
          title: album.title,
          subtitle: bits.join(', '),
          tracks: album.tracks,
          cover: album.coverTrack,
          numbered: true,
          compact: compact,
          actions: [
            PopupMenuButton<String>(
              tooltip: 'Ещё',
              icon: const Icon(Icons.more_horiz_rounded),
              onSelected: (v) {
                if (v == 'cover') changeAlbumCover(context, album);
                if (v == 'reset') app.lib.setAlbumCover(album.key, '');
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'cover', child: Text('Изменить обложку…')),
                if (app.lib.albumCover(album.key) != null)
                  const PopupMenuItem(value: 'reset', child: Text('Вернуть обложку из файлов')),
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
          subtitleWidget: Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
            const Text('Собирает ', style: TextStyle(color: C.muted, fontSize: 15)),
            if (p.by.isEmpty) const Text('кто-то', style: TextStyle(color: C.muted, fontSize: 15)) else UserLink(p.by),
            if (tracks.isNotEmpty) Text(', ${countTracks(tracks.length)}', style: const TextStyle(color: C.muted, fontSize: 15)),
          ]),
          tracks: tracks,
          playlistId: playlistId,
          compact: compact,
          onReorder: (track, after) => lib.movePlaylistItem(playlistId, track.id, after?.id),
          actions: [
            OfflineButton(
              on: app.cache.isPlaylistOffline(playlistId),
              tracks: tracks,
              onChanged: (v) => app.cache.setPlaylistOffline(playlistId, v),
            ),
            PopupMenuButton<String>(
              tooltip: 'Ещё',
              icon: const Icon(Icons.more_horiz_rounded),
              onSelected: (v) async {
                if (v == 'rename') {
                  final name = await askText(context, title: 'Название плейлиста', action: 'Сохранить', initial: p.name);
                  if (name != null && name.isNotEmpty) lib.renamePlaylist(p.id, name);
                } else if (v == 'cover') {
                  final cv = await coverDialog(
                    context,
                    title: 'Обложка плейлиста',
                    current: CoverImage(track: coverTrack, fileId: ownCover, label: p.name, size: 120, radius: 0),
                    canReset: ownCover != null,
                    note: 'Её увидят все друзья.',
                  );
                  if (cv != null) lib.setPlaylistCover(p.id, cv);
                } else if (v == 'cover_reset') {
                  lib.setPlaylistCover(p.id, '');
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
                const PopupMenuItem(value: 'rename', child: Text('Переименовать')),
                const PopupMenuItem(value: 'cover', child: Text('Изменить обложку…')),
                if (ownCover != null) const PopupMenuItem(value: 'cover_reset', child: Text('Убрать свою обложку')),
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
    this.playlistId,
    this.numbered = false,
    this.actions = const [],
    this.banner,
    this.onReorder,
    this.image,
    this.footer,
    this.heroColor,
  });

  @override
  State<TracksPage> createState() => _TracksPageState();
}

class _TracksPageState extends State<TracksPage> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  String _query = '';

  // Групповое выделение: Shift + клик по треку включает режим
  bool _selecting = false;
  final Set<String> _sel = {};
  String? _anchor; // от него считается диапазон по Shift
  List<Track> _visibleNow = const [];

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
          color: C.raised,
          elevation: 10,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
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
              IconButton(tooltip: 'Готово (Esc)', onPressed: _exitSelection, icon: const Icon(Icons.close_rounded, size: 20)),
            ]),
          ),
        ),
      ),
    );
  }
  String _sort = ''; // пусто — порядок как есть
  bool _desc = false;

  List<Track> _visible(String Function(String) nameOf, Map<String, int>? addedAt) {
    final q = _query.trim().toLowerCase();
    var list = q.isEmpty
        ? widget.tracks
        : widget.tracks
            .where((t) =>
                t.title.toLowerCase().contains(q) || t.artist.toLowerCase().contains(q) || t.album.toLowerCase().contains(q))
            .toList();
    if (_sort.isEmpty) return list;
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
      _ => (Track a, Track b) => when(a).compareTo(when(b)),
    };
    list = List.of(list)..sort(cmp);
    return _desc ? list.reversed.toList() : list;
  }

  void _setSort(String key) => setState(() {
        if (_sort == key) {
          if (_desc == (key == 'added' || key == 'padded')) {
            _desc = !_desc;
          } else {
            _sort = ''; // третий клик — вернуть исходный порядок
            _desc = false;
          }
        } else {
          _sort = key;
          _desc = key == 'added' || key == 'padded'; // новые сверху
        }
      });

  /// «Название / Исполнитель»: 1–2 клика — по названию (↑, ↓), 3–4 — по исполнителю (↑, ↓), 5-й сбрасывает
  void _setTitleArtist() => setState(() {
        if (_sort != 'title' && _sort != 'artist') {
          _sort = 'title';
          _desc = false;
        } else if (!_desc) {
          _desc = true;
        } else if (_sort == 'title') {
          _sort = 'artist';
          _desc = false;
        } else {
          _sort = '';
          _desc = false;
        }
      });

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

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: C.line))),
      height: 32,
      child: Row(children: [
        const SizedBox(width: 28, child: Text('#', style: TextStyle(fontSize: 12, color: C.faint))),
        const SizedBox(width: 62),
        Expanded(
          flex: 5,
          child: Align(alignment: Alignment.centerLeft, child: _titleArtistLabel()),
        ),
        if (!compact) ...[
          const SizedBox(width: 16),
          Expanded(flex: 3, child: Align(alignment: Alignment.centerLeft, child: label('album', 'Альбом'))),
          const SizedBox(width: 16),
          Expanded(flex: 2, child: Align(alignment: Alignment.centerLeft, child: label('by', 'Загрузил(а)'))),
        ],
        if (widget.playlistId != null && !compact)
          SizedBox(width: 120, child: Align(alignment: Alignment.centerLeft, child: label('padded', 'Дата добавления'))),
        SizedBox(
            width: 88,
            child: widget.playlistId != null ? null : Align(alignment: Alignment.centerRight, child: label('added', 'Новые'))),
        SizedBox(width: 60, child: Align(alignment: Alignment.centerRight, child: label('dur', 'Длительность', icon: Icons.schedule_rounded))),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final pl = widget.playlistId == null ? null : app.lib.playlist(widget.playlistId!);
    final addedAt = pl == null ? null : {for (final t in widget.tracks) t.id: app.lib.playlistAddedAt(pl, t.id)};
    final visible = _visible(app.lib.firstNameOf, addedAt);
    _visibleNow = visible;
    final pad = widget.compact ? 20.0 : 36.0;
    if (_selecting) {
      final present = {for (final t in widget.tracks) t.id};
      _sel.retainAll(present);
    }

    Widget buttons(WrapAlignment align) => Wrap(
          spacing: 12,
          runSpacing: 10,
          alignment: align,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            FilledButton.icon(
              onPressed: visible.isEmpty
                  ? null
                  : () {
                      if (app.player.shuffle) app.player.toggleShuffle();
                      app.player.playTracks(visible, 0);
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
        );

    final hero = widget.heroColor;
    final heroHeader = hero == null
        ? null
        : Stack(children: [
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [hero.withValues(alpha: 0.85), C.bg],
                    stops: const [0.0, 1.0],
                  ),
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(pad, widget.compact ? 72 : 96, pad, 36),
              child: Column(children: [
                Text(widget.title, textAlign: TextAlign.center, style: display(widget.compact ? 30 : 44, weight: FontWeight.w700)),
                if (widget.subtitle != null) ...[
                  const SizedBox(height: 10),
                  Text(widget.subtitle!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70, fontSize: 15)),
                ],
                if (widget.tracks.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  buttons(WrapAlignment.center),
                ] else if (widget.actions.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  Wrap(spacing: 12, alignment: WrapAlignment.center, children: widget.actions),
                ],
                if (widget.tracks.length > 8) ...[
                  const SizedBox(height: 22),
                  SizedBox(
                    width: 320,
                    child: TextField(
                      controller: _search,
                      focusNode: _searchFocus,
                      onChanged: (v) => setState(() => _query = v),
                      decoration: InputDecoration(
                        hintText: 'Найти трек или исполнителя',
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
                ],
              ]),
            ),
          ]);

    final header = heroHeader ?? Padding(
      padding: EdgeInsets.fromLTRB(pad, 34, pad, 18),
      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        if (widget.image != null) ...[
          widget.image!,
          const SizedBox(width: 28),
        ] else if (widget.cover != null || widget.coverFileId != null) ...[
          CoverImage(
              track: widget.cover,
              fileId: widget.coverFileId,
              label: widget.coverLabel,
              size: widget.compact ? 120 : 176,
              radius: 12),
          const SizedBox(width: 28),
        ],
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(widget.title,
                maxLines: 2, overflow: TextOverflow.ellipsis, style: display(widget.compact ? 26 : 36, weight: FontWeight.w700)),
            if (widget.subtitleWidget != null) ...[
              const SizedBox(height: 10),
              widget.subtitleWidget!,
            ] else if (widget.subtitle != null) ...[
              const SizedBox(height: 10),
              Text(widget.subtitle!, style: const TextStyle(color: C.muted, fontSize: 15)),
            ],
            if (widget.tracks.isNotEmpty) ...[
              const SizedBox(height: 22),
              buttons(WrapAlignment.start),
            ] else if (widget.actions.isNotEmpty) ...[
              const SizedBox(height: 16),
              Row(children: widget.actions),
            ],
          ]),
        ),
        if (widget.tracks.length > 8 && !widget.compact) ...[
          const SizedBox(width: 20),
          SizedBox(
            width: 240,
            child: TextField(
              controller: _search,
              focusNode: _searchFocus,
              onChanged: (v) => setState(() => _query = v),
              decoration: InputDecoration(
                hintText: 'Найти трек или исполнителя',
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
        ],
      ]),
    );

    final banner = widget.banner == null
        ? null
        : Padding(padding: EdgeInsets.fromLTRB(pad, 0, pad, 14), child: Align(alignment: Alignment.centerLeft, child: widget.banner));
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
      listenable: Listenable.merge([app.player, app.cache]),
      builder: (context, _) {
        final currentId = app.player.current?.id;
        Widget row(BuildContext context, int i) => TrackRow(
              track: visible[i],
              index: i,
              numbered: widget.numbered,
              current: visible[i].id == currentId,
              playing: app.player.playing,
              compact: widget.compact,
              playlistId: widget.playlistId,
              cached: app.cache.has(visible[i].id),
              onPlay: () => app.player.playTracks(visible, i),
              selecting: _selecting,
              selected: _sel.contains(visible[i].id),
              onSelect: (shift) => _onSelect(visible, i, shift),
              addedAt: addedAt?[visible[i].id],
            );
        final list = CustomScrollView(
            // Вернулись назад — список на том же месте
            key: PageStorageKey('tracks:${widget.title}:${widget.playlistId ?? ''}'),
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
                    proxyDecorator: (child, i, anim) => Material(
                      color: C.raised,
                      elevation: 6,
                      borderRadius: BorderRadius.circular(8),
                      child: child,
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
  final bool numbered;
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

  /// Когда трек добавлен в этот плейлист (мс); есть только на страницах плейлистов
  final int? addedAt;

  const TrackRow({
    super.key,
    required this.track,
    required this.index,
    required this.numbered,
    required this.current,
    required this.playing,
    required this.compact,
    required this.onPlay,
    this.cached = false,
    this.playlistId,
    this.selecting = false,
    this.selected = false,
    this.onSelect,
    this.addedAt,
  });

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
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
          onSelect: onSelect == null ? null : () => onSelect!(false), selected: selected),
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
            child: current
                ? Icon(playing ? Icons.graphic_eq_rounded : Icons.pause_rounded, size: 18, color: C.accent)
                : Text(numbered && track.no != null ? '${track.no}' : '${index + 1}',
                    style: const TextStyle(color: C.faint, fontSize: 13, fontFeatures: [FontFeature.tabularFigures()])),
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
            const SizedBox(width: 16),
            Expanded(
              flex: 3,
              child: Links(
                parts: [LinkPart(track.displayAlbum, () => NavScope.of(context).go(Nav('album', track.albumKey)))],
                style: const TextStyle(color: C.muted, fontSize: 13),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(flex: 2, child: Align(alignment: Alignment.centerLeft, child: FriendTag(track.by))),
          ],
          if (addedAt != null && !compact)
            SizedBox(
              width: 120,
              child: Text(formatAddedDate(addedAt!), maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: C.muted, fontSize: 13)),
            ),
          LikeButton(track: track),
          TrackMenu(
              track: track, playlistId: playlistId, onSelect: onSelect == null ? null : () => onSelect!(false), selected: selected),
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

/// Сердечко + цветные точки друзей, которым трек тоже нравится
class LikeButton extends StatelessWidget {
  final Track track;
  final double size;
  const LikeButton({super.key, required this.track, this.size = 18});

  @override
  Widget build(BuildContext context) {
    final lib = Services.of(context).lib;
    final liked = lib.isLiked(track.id);
    final others = (lib.data.likes[track.id] ?? const <String>{}).where((e) => e != lib.me).toList();
    return Row(mainAxisSize: MainAxisSize.min, children: [
      if (others.isNotEmpty)
        Tooltip(
          message: 'Нравится: ${others.map(lib.firstNameOf).join(', ')}',
          child: SizedBox(
            width: (8 + ((others.length > 3 ? 3 : others.length) - 1) * 6).toDouble(),
            height: 10,
            child: Stack(children: [
              for (var i = 0; i < others.length && i < 3; i++)
                Positioned(
                  left: i * 6.0,
                  top: 1,
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: friendColor(others[i]),
                      shape: BoxShape.circle,
                      border: Border.all(color: C.bg, width: 1),
                    ),
                  ),
                ),
            ]),
          ),
        ),
      IconButton(
        tooltip: liked ? 'Убрать из любимого' : 'В любимое',
        iconSize: size,
        visualDensity: VisualDensity.compact,
        onPressed: () => lib.toggleLike(track.id),
        icon: Icon(liked ? Icons.favorite_rounded : Icons.favorite_border_rounded, color: liked ? C.accent : C.faint),
      ),
    ]);
  }
}

class TrackMenu extends StatelessWidget {
  final Track track;
  final String? playlistId;

  /// Включает групповое выделение с этим треком (пункт «Выбрать»); null — пункта нет
  final VoidCallback? onSelect;
  final bool selected;
  const TrackMenu({super.key, required this.track, this.playlistId, this.onSelect, this.selected = false});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'Действия',
      icon: const Icon(Icons.more_horiz_rounded, size: 20),
      onSelected: (v) => onTrackMenu(context, v, track, playlistId, onSelect: onSelect),
      itemBuilder: (ctx) => trackMenuItems(ctx, track, playlistId, canSelect: onSelect != null, selected: selected),
    );
  }
}

/// Меню трека по правому клику, в точке клика
Future<void> showTrackMenu(BuildContext context, Track track, String? playlistId, Offset at,
    {VoidCallback? onSelect, bool selected = false}) async {
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  final v = await showMenu<String>(
    context: context,
    position: RelativeRect.fromRect(at & const Size(1, 1), Offset.zero & overlay.size),
    items: trackMenuItems(context, track, playlistId, canSelect: onSelect != null, selected: selected),
  );
  if (v != null && context.mounted) await onTrackMenu(context, v, track, playlistId, onSelect: onSelect);
}

List<PopupMenuEntry<String>> trackMenuItems(BuildContext context, Track track, String? playlistId,
    {bool canSelect = false, bool selected = false}) {
  final names = track.artists;
  final liked = Services.of(context).lib.isLiked(track.id);
  return [
    const PopupMenuItem(value: 'next', child: Text('Играть следующим')),
    const PopupMenuItem(value: 'queue', child: Text('В конец очереди')),
    PopupMenuItem(value: 'like', child: Text(liked ? 'Убрать из любимого' : 'Добавить в любимое')),
    if (canSelect) PopupMenuItem(value: 'select', child: Text(selected ? 'Снять выбор' : 'Выбрать')),
    const PopupMenuItem(value: 'playlist', child: Text('Добавить в плейлист…')),
    if (playlistId != null) const PopupMenuItem(value: 'remove', child: Text('Убрать из этого плейлиста')),
    const PopupMenuItem(value: 'album', child: Text('Открыть альбом')),
    if (names.length == 1)
      const PopupMenuItem(value: 'artist:0', child: Text('Открыть исполнителя'))
    else
      for (var i = 0; i < names.length && i < 5; i++)
        PopupMenuItem(value: 'artist:$i', child: Text('Открыть: ${names[i]}', overflow: TextOverflow.ellipsis)),
    const PopupMenuDivider(),
    const PopupMenuItem(value: 'edit', child: Text('Изменить название…')),
    const PopupMenuItem(value: 'hide', child: Text('Скрыть из библиотеки')),
    const PopupMenuItem(value: 'delete', child: Text('Удалить с Диска…', style: TextStyle(color: C.danger))),
  ];
}

Future<void> onTrackMenu(BuildContext context, String v, Track track, String? playlistId, {VoidCallback? onSelect}) async {
  final app = Services.of(context);
  if (v.startsWith('artist:')) {
    final i = int.tryParse(v.substring(7)) ?? 0;
    final names = track.artists;
    NavScope.of(context).go(Nav('artist', names[i < names.length ? i : 0].toLowerCase()));
    return;
  }
  switch (v) {
    case 'next':
      app.player.playNext(track);
      app.lib.messages.add('«${track.title}» заиграет следующим');
    case 'queue':
      app.player.addToQueue(track);
      app.lib.messages.add('«${track.title}» добавлен в конец очереди');
    case 'like':
      final was = app.lib.isLiked(track.id);
      app.lib.toggleLike(track.id);
      app.lib.messages.add(was ? '«${track.title}» убран из любимого' : '«${track.title}» в любимом');
    case 'select':
      onSelect?.call();
    case 'playlist':
      await addToPlaylistDialog(context, [track.id]);
    case 'remove':
      app.lib.removeFromPlaylist(playlistId!, track.id);
    case 'album':
      NavScope.of(context).go(Nav('album', track.albumKey));
    case 'edit':
      await editTrackDialog(context, track);
    case 'delete':
      final mine = track.by == app.lib.me || track.by.isEmpty;
      final ok = await confirm(
        context,
        title: 'Удалить «${track.title}» с Диска?',
        text: 'Трек пропадёт из библиотеки у всех, а файл удалится с Google Диска безвозвратно.'
            '${mine ? '' : '\n\nФайл принадлежит ${app.lib.firstNameOf(track.by)}: Google Диск даёт удалить его только '
                'владельцу, поэтому с Диска он удалится, когда ${app.lib.firstNameOf(track.by)} откроет Cave Player.'}',
        action: 'Удалить',
      );
      if (!ok) return;
      app.lib.deleteTracks([track]);
      app.lib.messages.add('«${track.title}» удалён');
    case 'hide':
      app.lib.hideTrack(track.id, true);
      app.lib.messages.add('«${track.title}» скрыт из библиотеки у всех. Вернуть можно в разделе «Дубликаты».');
  }
}

/// true, если треки добавлены (в существующий или новый плейлист)
Future<bool> addToPlaylistDialog(BuildContext context, List<String> trackIds) async {
  final app = Services.of(context);
  final lib = app.lib;
  final choice = await showDialog<String>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: Text('В плейлист', style: display(18)),
      children: [
        for (final p in lib.data.playlists)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, p.id),
            child: Row(children: [
              FriendDot(p.by),
              const SizedBox(width: 12),
              Expanded(child: Text(p.name)),
              if (trackIds.length == 1 && p.items.contains(trackIds.first))
                const Text('уже там', style: TextStyle(color: C.faint, fontSize: 12)),
            ]),
          ),
        SimpleDialogOption(
          onPressed: () => Navigator.pop(ctx, '+new'),
          child: const Row(children: [
            Icon(Icons.add_rounded, size: 18, color: C.accent),
            SizedBox(width: 10),
            Text('Новый плейлист', style: TextStyle(color: C.accent)),
          ]),
        ),
      ],
    ),
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
            style: on ? OutlinedButton.styleFrom(foregroundColor: C.accent, side: const BorderSide(color: C.accent)) : null,
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
            child: const DecoratedBox(
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
