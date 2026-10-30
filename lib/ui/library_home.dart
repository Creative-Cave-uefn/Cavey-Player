import 'package:flutter/material.dart';

import '../app.dart';
import '../core/library.dart';
import 'download_view.dart';
import 'profile_view.dart';
import 'shell.dart';
import 'theme.dart';
import 'tracks_view.dart';
import 'web_views.dart';
import 'widgets.dart';

// «Медиатека» в духе Apple Music: сверху разделы (песни, альбомы, синглы и EP, исполнители, плейлисты…),
// каждый открывается своей страницей; ниже — полки «Недавно добавленное», «Часто слушаете», «Исполнители».

/// Альбом из 2–6 треков — EP, из одного — сингл. «Без альбома» в эти разделы не входит
bool isShortRelease(Album a) => a.title != 'Без альбома' && a.tracks.length < 7;

class LibraryHomePage extends StatelessWidget {
  final bool compact;
  const LibraryHomePage({super.key, required this.compact});

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([app.lib, app.social]),
      builder: (context, _) {
        final lib = app.lib;
        final tracks = lib.allTracks;
        // Пустая библиотека: подсказки, как добавить музыку, — те же, что на странице песен
        if (tracks.isEmpty) return AllTracksPage(compact: compact, title: 'Медиатека');
        final albums = lib.albums;
        final artists = lib.artists;
        final short = albums.where(isShortRelease).toList();
        final playlists = lib.visiblePlaylists;
        final liked = lib.liked.length;
        final pad = compact ? 20.0 : 36.0;
        final nav = NavScope.of(context);

        // Недавно добавленное: альбомы по самому свежему треку
        final recentAlbums = <Album>[];
        final seen = <String>{};
        final byKey = {for (final a in albums) a.key: a};
        for (final t in lib.recent) {
          if (seen.add(t.albumKey)) {
            final a = byKey[t.albumKey];
            if (a != null) recentAlbums.add(a);
          }
          if (recentAlbums.length >= 18) break;
        }

        // Часто слушаете: мои прослушивания за две недели, по альбомам
        final plays = <String, int>{};
        final me = app.social.members[lib.me];
        if (me != null) {
          for (final day in me.plays.values) {
            day.forEach((id, n) {
              final t = lib.data.tracks[lib.data.resolve(id)];
              if (t != null) plays[t.albumKey] = (plays[t.albumKey] ?? 0) + n;
            });
          }
        }
        final heavy = [for (final k in (plays.keys.toList()..sort((a, b) => plays[b]!.compareTo(plays[a]!)))) if (byKey[k] case final a?) a]
            .take(18)
            .toList();

        final topArtists = List<Artist>.of(artists)..sort((a, b) => b.tracks.length.compareTo(a.tracks.length));

        final categories = <_Category>[
          _Category(Icons.music_note_rounded, 'Песни', tracks.length, const Nav('songs')),
          _Category(Icons.album_outlined, 'Альбомы', albums.length, const Nav('albums')),
          if (short.isNotEmpty) _Category(Icons.radio_button_checked_rounded, 'Синглы и EP', short.length, const Nav('albums', 'ep')),
          _Category(Icons.mic_none_rounded, 'Исполнители', artists.length, const Nav('artists')),
          _Category(Icons.queue_music_rounded, 'Плейлисты', playlists.length, const Nav('playlists')),
          _Category(Icons.favorite_border_rounded, 'Любимое', liked, const Nav('liked')),
          _Category(Icons.schedule_rounded, 'Недавно добавленное', null, const Nav('recent')),
        ];

        return ListView(padding: EdgeInsets.fromLTRB(pad, 34, pad, 40), children: [
          Text('Медиатека', style: display(compact ? 30 : 36, weight: FontWeight.w700)),
          const SizedBox(height: 8),
          Text(
            '${countTracks(tracks.length)} · ${albums.length} ${plural(albums.length, 'альбом', 'альбома', 'альбомов')} · '
            '${artists.length} ${plural(artists.length, 'исполнитель', 'исполнителя', 'исполнителей')}',
            style: const TextStyle(color: C.muted, fontSize: 15),
          ),
          const SizedBox(height: 18),
          Wrap(spacing: 10, runSpacing: 10, children: libraryActions(context)),
          const SizedBox(height: 26),
          LayoutBuilder(builder: (context, box) {
            final cols = box.maxWidth >= 980 ? 3 : (box.maxWidth >= 600 ? 2 : 1);
            final w = (box.maxWidth - (cols - 1) * 10) / cols;
            return Wrap(spacing: 10, runSpacing: 10, children: [
              for (final c in categories) SizedBox(width: w, child: _CategoryTile(c)),
            ]);
          }),
          if (recentAlbums.isNotEmpty) ...[
            const SizedBox(height: 36),
            TileRow(
              title: 'Недавно добавленное',
              onMore: () => nav.go(const Nav('recent')),
              tileWidth: 176,
              height: 236,
              tiles: [for (final a in recentAlbums) _AlbumTile(a)],
            ),
          ],
          if (heavy.isNotEmpty) ...[
            const SizedBox(height: 28),
            TileRow(title: 'Часто слушаете', tileWidth: 176, height: 236, tiles: [for (final a in heavy) _AlbumTile(a)]),
          ],
          if (topArtists.isNotEmpty) ...[
            const SizedBox(height: 28),
            TileRow(
              title: 'Исполнители',
              onMore: () => nav.go(const Nav('artists')),
              tileWidth: 140,
              height: 184,
              tiles: [for (final a in topArtists.take(20)) _ArtistTile(a)],
            ),
          ],
          if (short.length >= 3) ...[
            const SizedBox(height: 28),
            TileRow(
              title: 'Синглы и EP',
              onMore: () => nav.go(const Nav('albums', 'ep')),
              tileWidth: 176,
              height: 236,
              tiles: [for (final a in (List<Album>.of(short)..shuffle()).take(18)) _AlbumTile(a)],
            ),
          ],
          const SizedBox(height: 28),
          const DropHint(),
        ]);
      },
    );
  }
}

class _Category {
  final IconData icon;
  final String label;
  final int? count;
  final Nav target;
  const _Category(this.icon, this.label, this.count, this.target);
}

/// Строка раздела: стекло, значок, название, число и «›»
class _CategoryTile extends StatelessWidget {
  final _Category c;
  const _CategoryTile(this.c);

  @override
  Widget build(BuildContext context) => Material(
        color: C.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: const BorderSide(color: C.line)),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => NavScope.of(context).go(c.target),
          child: SizedBox(
            height: 56,
            child: Row(children: [
              const SizedBox(width: 16),
              Icon(c.icon, size: 22, color: C.accent),
              const SizedBox(width: 14),
              Expanded(child: Text(c.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600))),
              if (c.count != null) Text('${c.count}', style: const TextStyle(color: C.faint, fontSize: 13)),
              const SizedBox(width: 6),
              const Icon(Icons.chevron_right_rounded, color: C.muted),
              const SizedBox(width: 10),
            ]),
          ),
        ),
      );
}

class _AlbumTile extends StatelessWidget {
  final Album a;
  const _AlbumTile(this.a);

  @override
  Widget build(BuildContext context) => InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => NavScope.of(context).go(Nav('album', a.key)),
        child: LayoutBuilder(
          builder: (context, box) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            CoverImage(track: a.coverTrack, size: box.maxWidth, radius: 10),
            const SizedBox(height: 9),
            Text(a.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
            const SizedBox(height: 2),
            Text(a.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.muted, fontSize: 13)),
          ]),
        ),
      );
}

class _ArtistTile extends StatelessWidget {
  final Artist a;
  const _ArtistTile(this.a);

  @override
  Widget build(BuildContext context) => InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => NavScope.of(context).go(Nav('artist', a.key)),
        child: LayoutBuilder(
          builder: (context, box) => Column(children: [
            ArtistPhoto(
              name: a.name,
              size: box.maxWidth,
              fallback: ClipOval(child: CoverImage(track: a.coverTrack, size: box.maxWidth, radius: 0)),
            ),
            const SizedBox(height: 9),
            Text(a.name,
                maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
          ]),
        ),
      );
}
