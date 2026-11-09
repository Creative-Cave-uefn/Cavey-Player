import 'package:flutter/material.dart';

import '../app.dart';
import '../core/library.dart';
import '../core/models.dart';
import 'library_tabs.dart';
import 'playlists_view.dart';
import 'profile_view.dart';
import 'shell.dart';
import 'theme.dart';
import 'web_views.dart';
import 'widgets.dart';

/// Вкладка «Коллекция» в медиатеке: свои плейлисты и всё, что отмечено сердечком, — плейлисты друзей,
/// альбомы и исполнители. То же самое, что в одноимённом разделе боковой панели, но на всю страницу
class CollectionPage extends StatelessWidget {
  final bool compact;
  const CollectionPage({super.key, required this.compact});

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final pad = compact ? 20.0 : 36.0;
    return ListenableBuilder(
      listenable: app.lib,
      builder: (context, _) {
        final lib = app.lib;
        final me = lib.me;
        final favs = me == null ? null : lib.favoritesOf(me);
        final lists = [
          for (final p in lib.visiblePlaylists)
            if (p.by.isEmpty || p.by == me || lib.isFavPlaylist(p.id)) p
        ];
        final albums = favs?.albums ?? const <Album>[];
        final artists = favs?.artists ?? const <Artist>[];
        if (lists.isEmpty && albums.isEmpty && artists.isEmpty) {
          return const EmptyState(
            icon: Icons.favorite_border_rounded,
            title: 'В коллекции пока пусто',
            text: 'Здесь будут ваши плейлисты и всё, что вы отметили сердечком: плейлисты друзей, альбомы и исполнители.',
          );
        }
        final nav = NavScope.of(context);
        Widget grid(List<Widget> tiles, double w) => Wrap(spacing: 20, runSpacing: 24, children: [for (final t in tiles) SizedBox(width: w, child: t)]);
        return ListView(padding: EdgeInsets.fromLTRB(pad, 22, pad, 40), children: [
          if (!LibraryFrame.on(context)) Text('Коллекция', style: display(compact ? 30 : 36, weight: FontWeight.w700)),
          if (lists.isNotEmpty) ...[
            SectionTitle('Плейлисты', trailing: TextButton.icon(
              onPressed: () => newPlaylistFlow(context),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Новый плейлист'),
            )),
            grid([
              for (final p in lists)
                _Tile(
                  cover: (s) => PlaylistCover(playlist: p, size: s, radius: 10),
                  title: p.name,
                  subtitle: '${lib.firstNameOf(p.by)} · ${countTracks(p.items.length)}',
                  onTap: () => nav.go(Nav('playlist', p.id)),
                  onPlay: () {
                    final list = lib.playlistTracks(p.id);
                    if (list.isNotEmpty) app.player.playTracks(list, 0);
                  },
                ),
            ], 176),
            const SizedBox(height: 30),
          ],
          if (albums.isNotEmpty) ...[
            const SectionTitle('Альбомы'),
            grid([
              for (final a in albums)
                _Tile(
                  cover: (s) => CoverImage(track: a.coverTrack, size: s, radius: 10),
                  title: a.title,
                  subtitle: a.artist,
                  onTap: () => nav.go(Nav('album', a.key)),
                  onPlay: () => app.player.playTracks(a.tracks, 0, inOrder: true),
                ),
            ], 176),
            const SizedBox(height: 30),
          ],
          if (artists.isNotEmpty) ...[
            const SectionTitle('Исполнители'),
            grid([
              for (final a in artists)
                _Tile(
                  round: true,
                  cover: (s) => ArtistPhoto(
                    name: a.name,
                    size: s,
                    fallback: ClipOval(child: CoverImage(track: a.coverTrack, size: s, radius: 0)),
                  ),
                  title: a.name,
                  subtitle: '',
                  onTap: () => nav.go(Nav('artist', a.key)),
                  onPlay: () => app.player.playTracks(topTracksOf(app, a), 0),
                ),
            ], 150),
          ],
        ]);
      },
    );
  }
}

class _Tile extends StatelessWidget {
  final Widget Function(double size) cover;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool round;
  final VoidCallback? onPlay;
  const _Tile({required this.cover, required this.title, required this.subtitle, required this.onTap, this.round = false, this.onPlay});

  @override
  Widget build(BuildContext context) => TileInk(
        onTap: onTap,
        onPlay: onPlay,
        child: LayoutBuilder(
          builder: (context, box) => Column(crossAxisAlignment: round ? CrossAxisAlignment.center : CrossAxisAlignment.start, children: [
            cover(box.maxWidth),
            const SizedBox(height: 9),
            Text(title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: round ? TextAlign.center : TextAlign.start,
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
            if (subtitle.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.muted, fontSize: 13)),
            ],
          ]),
        ),
      );
}
