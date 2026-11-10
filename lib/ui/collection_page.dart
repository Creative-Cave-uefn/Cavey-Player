import 'package:flutter/material.dart';

import '../app.dart';
import '../core/library.dart';
import '../core/models.dart';
import '../core/pin_order.dart';
import 'collection_menu.dart';
import 'library_tabs.dart';
import 'list_filter.dart' show AnimatedTileGrid;
import 'pin_drag.dart';
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

        // Все пункты одним списком: закреплённые уходят в свой раздел наверху
        final all = <_Item>[
          for (final p in lists)
            _Item(
              kind: 0,
              tokens: [LibraryController.playlistPin(p.id)],
              menu: (c, at) => showCollectionMenu(c, at, playlist: p),
              tile: (pinned, onDrop, token) => _Tile(
                cover: (s) => PlaylistCover(playlist: p, size: s, radius: 10),
                title: p.name,
                subtitle: '${lib.firstNameOf(p.by)} · ${countTracks(p.items.length)}',
                pinned: pinned,
                onTap: () => nav.go(Nav('playlist', p.id)),
                onSecondaryTapUp: (d) => showCollectionMenu(context, d.globalPosition, playlist: p),
                onPlay: () {
                  final list = lib.playlistTracks(p.id);
                  if (list.isNotEmpty) app.player.playTracks(list, 0);
                },
              ),
            ),
          for (final a in albums)
            _Item(
              kind: 1,
              tokens: LibraryController.albumPins(a).toList(),
              menu: (c, at) => showCollectionMenu(c, at, album: a),
              tile: (pinned, onDrop, token) => _Tile(
                cover: (s) => CoverImage(track: a.coverTrack, size: s, radius: 10),
                title: a.title,
                subtitle: a.artist,
                pinned: pinned,
                onTap: () => nav.go(Nav('album', a.key)),
                onSecondaryTapUp: (d) => showCollectionMenu(context, d.globalPosition, album: a),
                onPlay: () => app.player.playTracks(a.tracks, 0, inOrder: true),
              ),
            ),
          for (final a in artists)
            _Item(
              kind: 2,
              tokens: [LibraryController.artistPin(a)],
              menu: (c, at) => showCollectionMenu(c, at, artist: a),
              tile: (pinned, onDrop, token) => _Tile(
                round: true,
                cover: (s) => ArtistPhoto(
                  name: a.name,
                  size: s,
                  fallback: ClipOval(child: CoverImage(track: a.coverTrack, size: s, radius: 0)),
                ),
                title: a.name,
                subtitle: '',
                pinned: pinned,
                onTap: () => nav.go(Nav('artist', a.key)),
                onSecondaryTapUp: (d) => showCollectionMenu(context, d.globalPosition, artist: a),
                onPlay: () => app.player.playTracks(topTracksOf(app, a), 0),
              ),
            ),
        ];
        final pins = lib.pinned;
        final pinSet = pins.toSet();
        final split = splitPinned(all, (e) => e.tokens, pins);
        final rest = split.rest;
        // Показанный порядок для перетаскивания: закреплённые, затем остальные по разделам
        final shown = [...split.pinned, ...rest];
        final shownTokens = [for (final e in shown) e.tokenIn(pinSet)];
        void drop(String dragged, String target) => applyPinDrop(app, shownTokens, split.pinned.length, dragged, target);

        Widget wrap(_Item e) {
          final token = e.tokenIn(pinSet);
          return PinDrag(key: ValueKey('pin:$token'), token: token, onDrop: drop, child: e.tile(pinSet.contains(token), drop, token));
        }

        Widget grid(Iterable<_Item> items, double w) =>
            AnimatedTileGrid(tile: w, extra: 56, children: [for (final e in items) wrap(e)]);
        final restLists = rest.where((e) => e.kind == 0);
        final restAlbums = rest.where((e) => e.kind == 1);
        final restArtists = rest.where((e) => e.kind == 2);
        return ListView(padding: EdgeInsets.fromLTRB(pad, pageTop(context), pad, 40), children: [
          if (!LibraryFrame.on(context)) ...[
            Text('Коллекция', style: display(36, weight: FontWeight.w700)),
            const SizedBox(height: 18),
          ],
          if (split.pinned.isNotEmpty) ...[
            const SectionTitle('Закреплённые'),
            grid(split.pinned, 176),
            const SizedBox(height: 30),
          ],
          if (lists.isNotEmpty) ...[
            SectionTitle('Плейлисты', trailing: TextButton.icon(
              onPressed: () => newPlaylistFlow(context),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Новый плейлист'),
            )),
            grid(restLists, 176),
            const SizedBox(height: 30),
          ],
          if (restAlbums.isNotEmpty) ...[
            const SectionTitle('Альбомы'),
            grid(restAlbums, 176),
            const SizedBox(height: 30),
          ],
          if (restArtists.isNotEmpty) ...[
            const SectionTitle('Исполнители'),
            grid(restArtists, 150),
          ],
        ]);
      },
    );
  }
}

class _Item {
  final int kind; // 0 плейлист, 1 альбом, 2 исполнитель
  final List<String> tokens;
  final Future<void> Function(BuildContext, Offset) menu;
  final Widget Function(bool pinned, void Function(String, String) onDrop, String token) tile;
  const _Item({required this.kind, required this.tokens, required this.menu, required this.tile});

  String tokenIn(Set<String> pins) => tokens.firstWhere(pins.contains, orElse: () => tokens.first);
}

class _Tile extends StatelessWidget {
  final Widget Function(double size) cover;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool round;
  final VoidCallback? onPlay;
  final GestureTapUpCallback? onSecondaryTapUp;
  final bool pinned;
  const _Tile(
      {required this.cover, required this.title, required this.subtitle, required this.onTap, this.round = false, this.onPlay, this.onSecondaryTapUp, this.pinned = false});

  @override
  Widget build(BuildContext context) => TileInk(
        onTap: onTap,
        onPlay: onPlay,
        onSecondaryTapUp: onSecondaryTapUp,
        child: LayoutBuilder(
          builder: (context, box) => Column(crossAxisAlignment: round ? CrossAxisAlignment.center : CrossAxisAlignment.start, children: [
            Stack(children: [
              cover(box.maxWidth),
              if (pinned)
                const Positioned(
                  left: 6,
                  top: 6,
                  child: DecoratedBox(
                      decoration: BoxDecoration(color: Color(0x99000000), shape: BoxShape.circle),
                      child: Padding(padding: EdgeInsets.all(5), child: PinMark(size: 14))),
                ),
            ]),
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
