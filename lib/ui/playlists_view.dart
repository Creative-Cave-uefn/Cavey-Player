import 'package:flutter/material.dart';

import '../app.dart';
import '../core/models.dart';
import 'list_filter.dart';
import 'shell.dart';
import 'library_tabs.dart';
import 'theme.dart';
import 'tracks_view.dart';
import 'widgets.dart';

/// Обложка плейлиста: своя, а если её нет — обложка первого трека с картинкой
class PlaylistCover extends StatelessWidget {
  final Playlist playlist;
  final double size;
  final double radius;
  const PlaylistCover({super.key, required this.playlist, required this.size, this.radius = 8});

  @override
  Widget build(BuildContext context) {
    final lib = Services.of(context).lib;
    final tracks = lib.playlistTracks(playlist.id);
    Track? t;
    for (final x in tracks) {
      if (x.hasCover) {
        t = x;
        break;
      }
    }
    t ??= tracks.isEmpty ? null : tracks.first;
    return CoverImage(track: t, fileId: lib.playlistCover(playlist.id), label: playlist.name, size: size, radius: radius);
  }
}

/// Страница «Плейлисты»: все плейлисты компании обложками или списком
class PlaylistsPage extends StatefulWidget {
  final bool compact;
  const PlaylistsPage({super.key, required this.compact});

  @override
  State<PlaylistsPage> createState() => _PlaylistsPageState();
}

class _PlaylistsPageState extends State<PlaylistsPage> {
  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final pad = widget.compact ? 20.0 : 36.0;
    return ListenableBuilder(
      listenable: app.lib,
      builder: (context, _) {
        final lib = app.lib;
        final lists = lib.visiblePlaylists;
        final prefs = ViewPrefs(app.settings, 'playlists', defaultGrid: true, gridDef: 180, listDef: 60, listMin: 48, listMax: 96);
        final header = Padding(
          padding: EdgeInsets.fromLTRB(pad, 34, pad, 22),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (!LibraryFrame.on(context))
              Text('Плейлисты', style: display(36, weight: FontWeight.w700)),
            const SizedBox(height: 10),
            Text('${lists.length} ${plural(lists.length, 'плейлист', 'плейлиста', 'плейлистов')}',
                style: const TextStyle(color: C.muted, fontSize: 15)),
            const SizedBox(height: 18),
            Wrap(spacing: 16, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              FilledButton.icon(
                onPressed: () => newPlaylistFlow(context),
                icon: const Icon(Icons.add_rounded, size: 20),
                label: const Text('Новый плейлист'),
              ),
              ViewControls(prefs: prefs, onChanged: () => setState(() {})),
            ]),
          ]),
        );
        if (lists.isEmpty) {
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            header,
            const Expanded(
              child: EmptyState(
                icon: Icons.queue_music_rounded,
                title: 'Плейлистов пока нет',
                text: 'Создайте первый: его увидят все друзья.',
              ),
            ),
          ]);
        }
        String sub(Playlist p) => '${lib.firstNameOf(p.by)} · ${countTracks(p.items.length)}';
        return CustomScrollView(slivers: [
          SliverToBoxAdapter(child: header),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(pad, 0, pad, 32),
            sliver: prefs.grid
                ? AdaptiveGridSliver(
                    tile: prefs.size,
                    extra: 58,
                    count: lists.length,
                    builder: (context, i) {
                      final p = lists[i];
                      return TileInk(
                        onTap: () => NavScope.of(context).go(Nav('playlist', p.id)),
                        onPlay: () {
                          final app = Services.of(context);
                          final list = app.lib.playlistTracks(p.id);
                          if (list.isNotEmpty) app.player.playTracks(list, 0);
                        },
                        child: LayoutBuilder(
                          builder: (context, box) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            PlaylistCover(playlist: p, size: box.maxWidth, radius: 10),
                            const SizedBox(height: 10),
                            Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                            const SizedBox(height: 3),
                            Text(sub(p), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.muted, fontSize: 13)),
                          ]),
                        ),
                      );
                    },
                  )
                : SliverFixedExtentList(
                    itemExtent: prefs.size,
                    delegate: SliverChildBuilderDelegate(
                      (context, i) {
                        final p = lists[i];
                        return InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: () => NavScope.of(context).go(Nav('playlist', p.id)),
                          child: Padding(
                            padding: const EdgeInsets.all(6),
                            child: Row(children: [
                              PlaylistCover(playlist: p, size: prefs.size - 12, radius: 6),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Text(p.name,
                                    maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                              ),
                              FriendTag(p.by),
                              const SizedBox(width: 16),
                              Text(countTracks(p.items.length), style: const TextStyle(color: C.muted, fontSize: 13)),
                              const SizedBox(width: 8),
                            ]),
                          ),
                        );
                      },
                      childCount: lists.length,
                    ),
                  ),
          ),
        ]);
      },
    );
  }
}
