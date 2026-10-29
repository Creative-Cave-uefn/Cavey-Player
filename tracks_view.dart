import 'package:flutter/material.dart';

import '../app.dart';
import '../core/models.dart';
import 'shell.dart';
import 'theme.dart';
import 'widgets.dart';

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

class LikedPage extends StatelessWidget {
  final bool compact;
  const LikedPage({super.key, required this.compact});

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    return ListenableBuilder(
      listenable: app.lib,
      builder: (context, _) {
        final tracks = app.lib.liked;
        return TracksPage(
          title: 'Любимое',
          subtitle: tracks.isEmpty ? null : countTracks(tracks.length),
          tracks: tracks,
          compact: compact,
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
      listenable: app.lib,
      builder: (context, _) {
        final lib = app.lib;
        final p = lib.playlist(playlistId);
        if (p == null) {
          return const EmptyState(icon: Icons.queue_music_rounded, title: 'Плейлист удалён', text: 'Кто-то из друзей его удалил.');
        }
        final tracks = lib.playlistTracks(playlistId);
        return TracksPage(
          title: p.name,
          subtitle: 'Собирает ${lib.firstNameOf(p.by)}${tracks.isEmpty ? '' : ', ${countTracks(tracks.length)}'}',
          tracks: tracks,
          playlistId: playlistId,
          compact: compact,
          actions: [
            PopupMenuButton<String>(
              tooltip: 'Ещё',
              icon: const Icon(Icons.more_horiz_rounded),
              onSelected: (v) async {
                if (v == 'rename') {
                  final name = await askText(context, title: 'Название плейлиста', action: 'Сохранить', initial: p.name);
                  if (name != null && name.isNotEmpty) lib.renamePlaylist(p.id, name);
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
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'rename', child: Text('Переименовать')),
                PopupMenuItem(value: 'delete', child: Text('Удалить плейлист')),
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
  final List<Track> tracks;
  final Track? cover;
  final String? playlistId;
  final bool numbered;
  final bool compact;
  final List<Widget> actions;
  final Widget empty;

  const TracksPage({
    super.key,
    required this.title,
    required this.tracks,
    required this.compact,
    required this.empty,
    this.subtitle,
    this.cover,
    this.playlistId,
    this.numbered = false,
    this.actions = const [],
  });

  @override
  State<TracksPage> createState() => _TracksPageState();
}

class _TracksPageState extends State<TracksPage> {
  final _search = TextEditingController();
  String _query = '';

  List<Track> get _visible {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return widget.tracks;
    return widget.tracks
        .where((t) =>
            t.title.toLowerCase().contains(q) || t.artist.toLowerCase().contains(q) || t.album.toLowerCase().contains(q))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final visible = _visible;
    final pad = widget.compact ? 20.0 : 36.0;

    final header = Padding(
      padding: EdgeInsets.fromLTRB(pad, 34, pad, 18),
      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        if (widget.cover != null) ...[
          CoverImage(track: widget.cover, size: widget.compact ? 120 : 176, radius: 12),
          const SizedBox(width: 28),
        ],
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(widget.title,
                maxLines: 2, overflow: TextOverflow.ellipsis, style: display(widget.compact ? 26 : 36, weight: FontWeight.w700)),
            if (widget.subtitle != null) ...[
              const SizedBox(height: 10),
              Text(widget.subtitle!, style: const TextStyle(color: C.muted, fontSize: 15)),
            ],
            if (widget.tracks.isNotEmpty) ...[
              const SizedBox(height: 22),
              Wrap(spacing: 12, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
                FilledButton.icon(
                  onPressed: visible.isEmpty ? null : () {
                    if (app.player.shuffle) app.player.toggleShuffle();
                    app.player.playTracks(visible, 0);
                  },
                  icon: const Icon(Icons.play_arrow_rounded, size: 20),
                  label: const Text('Слушать'),
                ),
                OutlinedButton.icon(
                  onPressed: visible.isEmpty ? null : () {
                    if (!app.player.shuffle) app.player.toggleShuffle();
                    app.player.playTracks(visible, (DateTime.now().microsecond) % visible.length);
                  },
                  icon: const Icon(Icons.shuffle_rounded, size: 18),
                  label: const Text('Вперемешку'),
                ),
                ...widget.actions,
              ]),
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

    if (widget.tracks.isEmpty) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [header, Expanded(child: widget.empty)]);
    }

    return ListenableBuilder(
      listenable: app.player,
      builder: (context, _) {
        final currentId = app.player.current?.id;
        return CustomScrollView(slivers: [
          SliverToBoxAdapter(child: header),
          if (visible.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: pad, vertical: 24),
                child: Text('Ничего не нашлось по запросу «$_query»', style: const TextStyle(color: C.muted)),
              ),
            ),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(pad - 12, 0, pad - 12, 24),
            sliver: SliverFixedExtentList(
              itemExtent: 58,
              delegate: SliverChildBuilderDelegate(
                (context, i) => TrackRow(
                  track: visible[i],
                  index: i,
                  numbered: widget.numbered,
                  current: visible[i].id == currentId,
                  playing: app.player.playing,
                  compact: widget.compact,
                  playlistId: widget.playlistId,
                  onPlay: () => app.player.playTracks(visible, i),
                ),
                childCount: visible.length,
              ),
            ),
          ),
        ]);
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

  const TrackRow({
    super.key,
    required this.track,
    required this.index,
    required this.numbered,
    required this.current,
    required this.playing,
    required this.compact,
    required this.onPlay,
    this.playlistId,
  });

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final titleColor = current ? C.accent : C.text;
    return InkWell(
      onTap: current ? app.player.toggle : onPlay,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(children: [
          SizedBox(
            width: 28,
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
              Text(track.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: titleColor, fontSize: 15, fontWeight: FontWeight.w500)),
              const SizedBox(height: 3),
              Text(track.displayArtist,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.muted, fontSize: 13)),
            ]),
          ),
          if (!compact) ...[
            const SizedBox(width: 16),
            Expanded(
              flex: 3,
              child: InkWell(
                onTap: () => NavScope.of(context).go(Nav('album', track.albumKey)),
                child: Text(track.displayAlbum,
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.muted, fontSize: 13)),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(flex: 2, child: Align(alignment: Alignment.centerLeft, child: FriendTag(track.by))),
          ],
          LikeButton(track: track),
          TrackMenu(track: track, playlistId: playlistId),
        ]),
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
  const TrackMenu({super.key, required this.track, this.playlistId});

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    return PopupMenuButton<String>(
      tooltip: 'Действия',
      icon: const Icon(Icons.more_horiz_rounded, size: 20),
      onSelected: (v) async {
        switch (v) {
          case 'next':
            app.player.playNext(track);
            app.lib.messages.add('«${track.title}» заиграет следующим');
          case 'playlist':
            await addToPlaylistDialog(context, [track.id]);
          case 'remove':
            app.lib.removeFromPlaylist(playlistId!, track.id);
          case 'album':
            NavScope.of(context).go(Nav('album', track.albumKey));
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'next', child: Text('Играть следующим')),
        const PopupMenuItem(value: 'playlist', child: Text('Добавить в плейлист…')),
        if (playlistId != null) const PopupMenuItem(value: 'remove', child: Text('Убрать из этого плейлиста')),
        const PopupMenuItem(value: 'album', child: Text('Открыть альбом')),
      ],
    );
  }
}

Future<void> addToPlaylistDialog(BuildContext context, List<String> trackIds) async {
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
  if (choice == null || !context.mounted) return;
  if (choice == '+new') {
    final name = await askText(context, title: 'Новый плейлист', action: 'Создать', hint: 'Название');
    if (name == null || name.isEmpty) return;
    lib.createPlaylist(name, trackIds);
    lib.messages.add('Создан плейлист «$name»');
  } else {
    lib.addToPlaylist(choice, trackIds);
    lib.messages.add('Добавлено в «${lib.playlist(choice)?.name ?? 'плейлист'}»');
  }
}
