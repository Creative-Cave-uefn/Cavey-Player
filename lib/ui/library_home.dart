import 'dart:math' show Random;

import 'package:flutter/material.dart';

import '../app.dart';
import '../core/library.dart';
import '../core/models.dart';
import 'profile_view.dart';
import 'shell.dart';
import 'library_tabs.dart';
import 'theme.dart';
import 'tracks_view.dart';
import 'web_views.dart';
import 'widgets.dart';

// «Медиатека» в духе Apple Music: сверху разделы (песни, альбомы, синглы и EP, исполнители, плейлисты…),
// каждый открывается своей страницей; ниже — полки «Недавно добавленное», «Часто слушаете», «Исполнители».

/// Альбом из 2–6 треков — EP, из одного — сингл. «Без альбома» в эти разделы не входит
bool isShortRelease(Album a) => a.title != 'Без альбома' && a.tracks.length < 7;

/// Полки главной страницы медиатеки. Пока идёт проверка диска, показываем прежний снимок: список не прыгает
/// от каждого найденного трека
class _Shelves {
  final List<Album> recent;
  final List<Album> heavy;
  final List<Artist> artists;
  final List<Album> short;
  _Shelves(this.recent, this.heavy, this.artists, this.short);
}

class LibraryHomePage extends StatefulWidget {
  final bool compact;
  const LibraryHomePage({super.key, required this.compact});

  @override
  State<LibraryHomePage> createState() => _LibraryHomePageState();
}

class _LibraryHomePageState extends State<LibraryHomePage> {
  _Shelves? _frozen;

  /// Список треков, по которому посчитаны полки: пока он тот же, полки не пересчитываются
  /// (ни от статусов друзей, ни от прослушиваний, которые приходят каждые несколько секунд)
  Object? _basis;

  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// Слова запроса: каждое должно встретиться в названии, исполнителе или альбоме
  static List<String> _words(String q) => [for (final w in q.toLowerCase().split(RegExp(r'\s+'))) if (w.isNotEmpty) w];

  static bool _hasAll(String haystack, List<String> words) {
    final h = haystack.toLowerCase();
    return words.every(h.contains);
  }

  /// Результаты поиска по всей библиотеке: исполнители, альбомы и треки
  List<Widget> _results(BuildContext context, AppServices app, List<Track> tracks, List<Album> albums, List<Artist> artists, bool compact) {
    final words = _words(_query);
    final foundArtists = artists.where((a) => _hasAll(a.name, words)).toList()
      ..sort((a, b) {
        final r = b.tracks.length.compareTo(a.tracks.length);
        return r != 0 ? r : a.key.compareTo(b.key);
      });
    final foundAlbums = albums.where((a) => _hasAll('${a.title} ${a.artist}', words)).toList()
      ..sort((a, b) {
        // Сначала те, у кого запрос в названии, потом по числу треков
        final ta = _hasAll(a.title, words) ? 0 : 1, tb = _hasAll(b.title, words) ? 0 : 1;
        if (ta != tb) return ta.compareTo(tb);
        final r = b.tracks.length.compareTo(a.tracks.length);
        return r != 0 ? r : a.key.compareTo(b.key);
      });
    final foundTracks = tracks.where((t) => _hasAll('${t.title} ${t.artist} ${t.album}', words)).toList();
    if (foundArtists.isEmpty && foundAlbums.isEmpty && foundTracks.isEmpty) {
      return [
        const SizedBox(height: 40),
        Text('Ничего не нашлось по запросу «${_query.trim()}»', style: const TextStyle(color: C.muted, fontSize: 15)),
      ];
    }
    const maxTracks = 50;
    final shown = foundTracks.take(maxTracks).toList();
    final currentId = app.player.current?.id;
    return [
      if (foundArtists.isNotEmpty) ...[
        const SizedBox(height: 32),
        TileRow(title: 'Исполнители', tileWidth: 140, height: 184, tiles: [for (final a in foundArtists.take(30)) _ArtistTile(a)]),
      ],
      if (foundAlbums.isNotEmpty) ...[
        const SizedBox(height: 28),
        TileRow(title: 'Альбомы', tileWidth: 176, height: 236, tiles: [for (final a in foundAlbums.take(40)) _AlbumTile(a)]),
      ],
      if (shown.isNotEmpty) ...[
        const SizedBox(height: 28),
        Text('Треки · ${foundTracks.length}', style: display(20, weight: FontWeight.w700)),
        const SizedBox(height: 10),
        for (var i = 0; i < shown.length; i++)
          // Строка рассчитана на фиксированную высоту, как в списке «Все песни» (itemExtent: 58): без неё в ListView не рисуется
          SizedBox(
            key: ValueKey('hs:${shown[i].id}'),
            height: 58,
            child: TrackRow(
              track: shown[i],
              index: i,
              current: shown[i].id == currentId,
              playing: app.player.playing,
              compact: compact,
              cached: false,
              onPlay: () => app.player.playTracks(shown, i),
            ),
          ),
        if (foundTracks.length > maxTracks)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text('Показаны первые $maxTracks. Уточните запрос, чтобы увидеть остальные.',
                style: const TextStyle(color: C.muted, fontSize: 13)),
          ),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final compact = widget.compact;
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
        final updating = lib.scan.running && _frozen != null;
        final pad = compact ? 20.0 : 36.0;
        final nav = NavScope.of(context);

        _Shelves compute() {
          final short = albums.where(isShortRelease).toList();
          // Недавно добавленное: альбомы по самому свежему треку
          final recentAlbums = <Album>[];
          final seen = <String>{};
          final byKey = {for (final a in albums) a.key: a};
          for (final t in lib.recent) {
            final a = lib.album(t.albumKey);
            if (a != null && seen.add(a.key)) recentAlbums.add(a);
            if (recentAlbums.length >= 18) break;
          }

          // Часто слушаете: мои прослушивания, по альбомам (с этой версии — только реально проигранные)
          final plays = <String, int>{};
          final me = app.social.members[lib.me];
          if (me != null) {
            for (final day in me.plays.values) {
              day.forEach((id, n) {
                final t = lib.data.tracks[lib.data.resolve(id)];
                final k = t == null ? null : lib.album(t.albumKey)?.key;
                if (k != null) plays[k] = (plays[k] ?? 0) + n;
              });
            }
          }
          // Равные по числу прослушиваний идут по ключу: порядок не меняется от перерисовки к перерисовке
          int byPlays(String a, String b) {
            final r = plays[b]!.compareTo(plays[a]!);
            return r != 0 ? r : a.compareTo(b);
          }

          final heavy = [for (final k in (plays.keys.toList()..sort(byPlays))) if (byKey[k] case final a?) a]
              .take(18)
              .toList();
          final topArtists = List<Artist>.of(artists)
            ..sort((a, b) {
              final r = b.tracks.length.compareTo(a.tracks.length);
              return r != 0 ? r : a.key.compareTo(b.key);
            });
          // «Синглы и EP» перемешаны, но одинаково в течение суток: не мелькают при каждой перерисовке
          final now = DateTime.now();
          final seed = now.year * 1000 + now.difference(DateTime(now.year)).inDays;
          return _Shelves(recentAlbums, heavy, topArtists,
              short.length >= 3 ? (List<Album>.of(short)..shuffle(Random(seed))).take(18).toList() : const []);
        }

        // Считаем при первом показе и когда сменилась сама библиотека (после проверки диска)
        if (_frozen == null || (!updating && !identical(_basis, tracks))) {
          _frozen = compute();
          _basis = tracks;
        }
        final shelves = _frozen!;
        final recentAlbums = shelves.recent;
        final heavy = shelves.heavy;
        final topArtists = shelves.artists;
        final shortShelf = shelves.short;

        return ListView(padding: EdgeInsets.fromLTRB(pad, 34, pad, 40), children: [
          if (!LibraryFrame.on(context))
            Text('Медиатека', style: display(compact ? 30 : 36, weight: FontWeight.w700)),
          const SizedBox(height: 8),
          Text(
            '${countTracks(tracks.length)} · ${albums.length} ${plural(albums.length, 'альбом', 'альбома', 'альбомов')} · '
            '${artists.length} ${plural(artists.length, 'исполнитель', 'исполнителя', 'исполнителей')}',
            style: const TextStyle(color: C.muted, fontSize: 15),
          ),
          const SizedBox(height: 18),
          // Поиск и кнопки в одной строке, у всех один центр по вертикали
          uniformControls(
            context,
            Wrap(spacing: 12, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
              RowSearchField(
                controller: _search,
                hint: 'Найти исполнителя, альбом или трек',
                width: compact ? 300 : 400,
                onChanged: (v) => setState(() => _query = v),
                onClear: () => setState(() {
                  _search.clear();
                  _query = '';
                }),
              ),
              ...libraryActions(context),
            ]),
          ),

          if (_query.trim().isNotEmpty)
            ..._results(context, app, tracks, albums, artists, compact)
          else ...[
          if (recentAlbums.isNotEmpty) ...[
            const SizedBox(height: 36),
            TileRow(
              updating: updating,
              title: 'Недавно добавленное',
              onMore: () => nav.go(const Nav('recent')),
              tileWidth: 176,
              height: 236,
              tiles: [for (final a in recentAlbums) _AlbumTile(a)],
            ),
          ],
          if (heavy.isNotEmpty) ...[
            const SizedBox(height: 28),
            TileRow(updating: updating, title: 'Часто слушаете', tileWidth: 176, height: 236, tiles: [for (final a in heavy) _AlbumTile(a)]),
          ],
          if (topArtists.isNotEmpty) ...[
            const SizedBox(height: 28),
            TileRow(
              updating: updating,
              title: 'Исполнители',
              onMore: () => nav.go(const Nav('artists')),
              tileWidth: 140,
              height: 184,
              tiles: [for (final a in topArtists.take(20)) _ArtistTile(a)],
            ),
          ],
          if (shortShelf.isNotEmpty) ...[
            const SizedBox(height: 28),
            TileRow(
              updating: updating,
              title: 'Синглы и EP',
              onMore: () => nav.go(const Nav('albums', 'ep')),
              tileWidth: 176,
              height: 236,
              tiles: [for (final a in shortShelf) _AlbumTile(a)],
            ),
          ],
          ],
        ]);
      },
    );
  }
}

class _AlbumTile extends StatelessWidget {
  final Album a;
  const _AlbumTile(this.a);

  @override
  Widget build(BuildContext context) => TileInk(
        onTap: () => NavScope.of(context).go(Nav('album', a.key)),
        onPlay: () => Services.of(context).player.playTracks(a.tracks, 0, inOrder: true),
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
  Widget build(BuildContext context) => TileInk(
        onTap: () => NavScope.of(context).go(Nav('artist', a.key)),
        onPlay: () {
          final app = Services.of(context);
          app.player.playTracks(topTracksOf(app, a), 0);
        },
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
