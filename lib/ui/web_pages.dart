// Музыка из интернета (Deezer) отдельными страницами, как в Apple Music:
// поиск, исполнитель с разделами «Топ-песни», «Альбомы», «Синглы и EP»,
// «Сборники», «Похожие исполнители», каждый раздел открывается целиком, альбом.
// Везде можно послушать 30-секундный отрывок и скачать в библиотеку.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app.dart';
import '../core/web_info.dart';
import 'profile_view.dart';
import 'shell.dart';
import 'theme.dart';
import 'web_views.dart';
import 'widgets.dart';

// ---------- общие кусочки ----------

Widget netCover(String url, double size, {double radius = 8, bool round = false}) {
  final fallback = Container(
    width: size,
    height: size,
    decoration: BoxDecoration(color: C.raised, borderRadius: round ? null : BorderRadius.circular(radius), shape: round ? BoxShape.circle : BoxShape.rectangle),
    child: Icon(round ? Icons.person_rounded : Icons.album_rounded, color: C.faint, size: size * 0.4),
  );
  if (url.isEmpty) return fallback;
  final img = Image.network(url, width: size, height: size, fit: BoxFit.cover, cacheWidth: (size * 2).round(),
      errorBuilder: (_, __, ___) => fallback);
  return round ? ClipOval(child: img) : ClipRRect(borderRadius: BorderRadius.circular(radius), child: img);
}

/// Отрывок: кнопка с кольцом прогресса
class PreviewButton extends StatelessWidget {
  final WebTrack track;
  const PreviewButton({super.key, required this.track});

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    if (track.preview.isEmpty) return const SizedBox(width: 36);
    return ListenableBuilder(
      listenable: app.preview,
      builder: (context, _) {
        final playing = app.preview.current == track.id;
        return SizedBox.square(
          dimension: 36,
          child: Stack(alignment: Alignment.center, children: [
            if (playing) CircularProgressIndicator(value: app.preview.progress, strokeWidth: 2, color: C.accent),
            IconButton(
              tooltip: playing ? 'Остановить отрывок' : 'Послушать отрывок (30 с)',
              iconSize: 20,
              padding: EdgeInsets.zero,
              onPressed: () => app.preview.toggle(track),
              icon: Icon(playing ? Icons.stop_rounded : Icons.play_arrow_rounded, color: playing ? C.accent : C.muted),
            ),
          ]),
        );
      },
    );
  }
}

/// «Уже есть» или «Скачать» для трека
class TrackGetButton extends StatelessWidget {
  final WebTrack track;
  const TrackGetButton({super.key, required this.track});

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    if (app.web.trackInLibrary(track)) {
      return const Tooltip(
        message: 'Уже есть в библиотеке',
        child: Padding(padding: EdgeInsets.all(8), child: Icon(Icons.check_rounded, size: 18, color: C.faint)),
      );
    }
    return IconButton(
      tooltip: 'Скачать в библиотеку',
      iconSize: 18,
      onPressed: track.link.isEmpty ? null : () => downloadToLibrary(context, track.link, track.title),
      icon: const Icon(Icons.download_rounded, color: C.muted),
    );
  }
}

/// Строка трека: обложка, название, исполнитель и альбом ссылками, отрывок, скачать
class WebTrackLine extends StatelessWidget {
  final WebTrack track;
  final bool showCover;
  const WebTrackLine({super.key, required this.track, this.showCover = true});

  @override
  Widget build(BuildContext context) {
    final nav = NavScope.of(context);
    final app = Services.of(context);
    return ListenableBuilder(
      listenable: app.preview,
      builder: (context, _) {
        final playing = app.preview.current == track.id;
        return InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: track.preview.isEmpty ? null : () => app.preview.toggle(track),
          child: SizedBox(
            height: 58,
            child: Row(children: [
              if (showCover) ...[netCover(track.cover, 44, radius: 5), const SizedBox(width: 12)],
              Expanded(
                child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontWeight: FontWeight.w500, color: playing ? C.accent : C.text)),
                  const SizedBox(height: 3),
                  Row(children: [
                    Flexible(
                      child: InkWell(
                        onTap: track.artistId == 0 ? null : () => nav.go(Nav('webartist', '${track.artistId}')),
                        child: Text(track.artist,
                            maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.muted, fontSize: 13)),
                      ),
                    ),
                    if (track.album.isNotEmpty) ...[
                      const Text('  ·  ', style: TextStyle(color: C.faint, fontSize: 13)),
                      Flexible(
                        child: InkWell(
                          onTap: track.albumId == 0 ? null : () => nav.go(Nav('webalbum', '${track.albumId}')),
                          child: Text(track.album,
                              maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.muted, fontSize: 13)),
                        ),
                      ),
                    ],
                  ]),
                ]),
              ),
              Text(formatDuration(Duration(seconds: track.seconds)), style: const TextStyle(color: C.faint, fontSize: 12)),
              const SizedBox(width: 6),
              PreviewButton(track: track),
              TrackGetButton(track: track),
            ]),
          ),
        );
      },
    );
  }
}

/// «Топ-песни» столбцами по три, как в Apple Music
class WebTrackGrid extends StatelessWidget {
  final List<WebTrack> tracks;
  const WebTrackGrid({super.key, required this.tracks});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final cols = box.maxWidth >= 1150 ? 4 : (box.maxWidth >= 850 ? 3 : (box.maxWidth >= 560 ? 2 : 1));
      final shown = tracks.take(cols * 3).toList();
      return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (var c = 0; c < cols; c++) ...[
          if (c > 0) const SizedBox(width: 24),
          Expanded(
            child: Column(children: [
              for (var r = 0; r < 3; r++)
                c * 3 + r < shown.length
                    ? Container(
                        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: C.line.withValues(alpha: 0.7)))),
                        child: WebTrackLine(track: shown[c * 3 + r]),
                      )
                    : const SizedBox(height: 58),
            ]),
          ),
        ],
      ]);
    });
  }
}

/// Плитка альбома или исполнителя: квадратная (круглая) картинка и подписи
Widget webTile(BuildContext context,
    {required String image, required String title, required String subtitle, required VoidCallback onTap, bool round = false, bool have = false}) {
  return InkWell(
    borderRadius: BorderRadius.circular(10),
    onTap: onTap,
    child: Column(crossAxisAlignment: round ? CrossAxisAlignment.center : CrossAxisAlignment.start, children: [
      AspectRatio(
        aspectRatio: 1,
        child: LayoutBuilder(builder: (context, box) {
          return Stack(children: [
            netCover(image, box.maxWidth, radius: 10, round: round),
            if (have)
              Positioned(
                right: 8,
                bottom: 8,
                child: Tooltip(
                  message: 'Уже есть в библиотеке',
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(color: C.bg.withValues(alpha: 0.8), shape: BoxShape.circle),
                    child: const Icon(Icons.check_rounded, size: 16, color: C.accent),
                  ),
                ),
              ),
          ]);
        }),
      ),
      const SizedBox(height: 10),
      Text(title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: round ? TextAlign.center : TextAlign.start,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
      if (subtitle.isNotEmpty) ...[
        const SizedBox(height: 3),
        Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.muted, fontSize: 13)),
      ],
    ]),
  );
}

Widget albumTile(BuildContext context, WebAlbum a, {bool withArtist = false}) {
  final app = Services.of(context);
  return webTile(
    context,
    image: a.cover,
    title: a.title,
    subtitle: [if (withArtist) a.artist, a.typeLabel, if (a.year.isNotEmpty) a.year].join(' · '),
    have: app.web.inLibrary(a.artist.toLowerCase(), a),
    onTap: () => NavScope.of(context).go(Nav('webalbum', '${a.id}')),
  );
}

Widget artistTile(BuildContext context, WebArtist a) => webTile(
      context,
      image: a.picture,
      title: a.name,
      subtitle: '',
      round: true,
      onTap: () => NavScope.of(context).go(Nav('webartist', '${a.id}')),
    );

/// Сетка плиток на всю ширину (раздел целиком)
class TileGrid extends StatelessWidget {
  final List<Widget> tiles;
  final double tileWidth;
  const TileGrid({super.key, required this.tiles, this.tileWidth = 200});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final cols = (box.maxWidth / (tileWidth + 20)).floor().clamp(1, 12);
      final w = (box.maxWidth - (cols - 1) * 20) / cols;
      return Wrap(spacing: 20, runSpacing: 24, children: [for (final t in tiles) SizedBox(width: w, child: t)]);
    });
  }
}

/// Загрузка с ошибкой и повтором
class _Loading<T> extends StatelessWidget {
  final Future<T>? future;
  final Widget Function(T data) builder;
  final VoidCallback onRetry;
  const _Loading({super.key, required this.future, required this.builder, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<T>(
      future: future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: Padding(padding: EdgeInsets.all(40), child: CircularProgressIndicator()));
        }
        if (snap.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(40),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text('Не получилось загрузить: ${snap.error}', style: const TextStyle(color: C.muted)),
                const SizedBox(height: 12),
                OutlinedButton(onPressed: onRetry, child: const Text('Попробовать снова')),
              ]),
            ),
          );
        }
        return builder(snap.data as T);
      },
    );
  }
}

// ---------- исполнитель ----------

class _ArtistData {
  final WebArtist artist;
  final List<WebTrack> top;
  final List<WebAlbum> albums;
  final List<WebArtist> related;
  _ArtistData(this.artist, this.top, this.albums, this.related);

  List<WebAlbum> ofKind(String kind) => switch (kind) {
        'album' => [for (final a in albums) if (a.type == 'album') a],
        'single' => [for (final a in albums) if (a.type == 'single' || a.type == 'ep') a],
        'compile' => [for (final a in albums) if (a.type == 'compile') a],
        _ => const [],
      };
}

Future<_ArtistData> _loadArtist(AppServices app, int id) async {
  final artist = await app.web.artistById(id);
  final r = await Future.wait<Object>([
    app.web.top(id).catchError((Object _) => <WebTrack>[]),
    app.web.albumsOf(id, artist.name),
    app.web.related(id).catchError((Object _) => <WebArtist>[]),
  ]);
  return _ArtistData(artist, r[0] as List<WebTrack>, r[1] as List<WebAlbum>, r[2] as List<WebArtist>);
}

const _sectionNames = {
  'top': 'Топ-песни',
  'album': 'Альбомы',
  'single': 'Синглы и EP',
  'compile': 'Сборники',
  'related': 'Похожие исполнители',
};

/// Страница исполнителя из интернета
class WebArtistPage extends StatefulWidget {
  final int artistId;
  final bool compact;
  const WebArtistPage({super.key, required this.artistId, required this.compact});

  @override
  State<WebArtistPage> createState() => _WebArtistPageState();
}

class _WebArtistPageState extends State<WebArtistPage> {
  Future<_ArtistData>? _future;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _future ??= _loadArtist(Services.of(context), widget.artistId);
  }

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final nav = NavScope.of(context);
    final pad = widget.compact ? 20.0 : 40.0;
    return _Loading<_ArtistData>(
      future: _future,
      onRetry: () => setState(() => _future = _loadArtist(app, widget.artistId)),
      builder: (d) {
        final a = d.artist;
        final mine = app.lib.artist(a.name.toLowerCase());
        final photo = widget.compact ? 150.0 : 210.0;
        Widget row(String kind, List<Widget> tiles, {double w = 200, double h = 270}) => tiles.isEmpty
            ? const SizedBox.shrink()
            : Padding(
                padding: const EdgeInsets.only(top: 34),
                child: TileRow(
                  title: _sectionNames[kind]!,
                  tileWidth: w,
                  height: h,
                  tiles: tiles.take(12).toList(),
                  // Больше, чем помещается в ряд, — раздел открывается целиком
                  onMore: tiles.length > 6 ? () => nav.go(Nav('websection', '${a.id}:$kind')) : null,
                ),
              );
        return ListView(padding: EdgeInsets.fromLTRB(pad, 40, pad, 40), children: [
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            netCover(a.picture, photo, round: true),
            const SizedBox(width: 28),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(a.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: display(widget.compact ? 30 : 44, weight: FontWeight.w700)),
                const SizedBox(height: 8),
                Text(
                  [
                    if (a.fans > 0) '${_fans(a.fans)} поклонников на Deezer',
                    if (mine != null) '${countTracks(mine.tracks.length)} в библиотеке',
                  ].join(' · '),
                  style: const TextStyle(color: C.muted),
                ),
                const SizedBox(height: 16),
                Wrap(spacing: 10, runSpacing: 10, children: [
                  if (mine != null)
                    FilledButton.icon(
                      onPressed: () => nav.go(Nav('artist', mine.key)),
                      icon: const Icon(Icons.library_music_rounded, size: 18),
                      label: const Text('В библиотеке'),
                    ),
                  if (a.link.isNotEmpty)
                    OutlinedButton.icon(
                      onPressed: () => launchUrl(Uri.parse(a.link)),
                      icon: const Icon(Icons.open_in_new_rounded, size: 16),
                      label: const Text('Deezer'),
                    ),
                ]),
              ]),
            ),
          ]),
          if (d.top.isNotEmpty) ...[
            const SizedBox(height: 34),
            SectionTitle('Топ-песни', onTap: d.top.length > 12 ? () => nav.go(Nav('websection', '${a.id}:top')) : null),
            WebTrackGrid(tracks: d.top),
          ],
          row('album', [for (final x in d.ofKind('album')) albumTile(context, x)]),
          row('single', [for (final x in d.ofKind('single')) albumTile(context, x)]),
          row('compile', [for (final x in d.ofKind('compile')) albumTile(context, x)]),
          row('related', [for (final x in d.related) artistTile(context, x)], w: 160, h: 200),
        ]);
      },
    );
  }

  static String _fans(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1).replaceAll('.0', '')} млн';
    if (n >= 1000) return '${(n / 1000).round()} тыс.';
    return '$n';
  }
}

/// Раздел исполнителя целиком: все песни, альбомы, синглы, сборники или похожие
class WebSectionPage extends StatefulWidget {
  final int artistId;
  final String kind;
  final bool compact;
  const WebSectionPage({super.key, required this.artistId, required this.kind, required this.compact});

  @override
  State<WebSectionPage> createState() => _WebSectionPageState();
}

class _WebSectionPageState extends State<WebSectionPage> {
  Future<_ArtistData>? _future;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _future ??= _loadArtist(Services.of(context), widget.artistId);
  }

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final pad = widget.compact ? 20.0 : 40.0;
    return _Loading<_ArtistData>(
      future: _future,
      onRetry: () => setState(() => _future = _loadArtist(app, widget.artistId)),
      builder: (d) {
        final title = _sectionNames[widget.kind] ?? '';
        return ListView(padding: EdgeInsets.fromLTRB(pad, 40, pad, 40), children: [
          InkWell(
            onTap: () => NavScope.of(context).go(Nav('webartist', '${d.artist.id}')),
            child: Text(d.artist.name, style: const TextStyle(color: C.muted, fontSize: 15)),
          ),
          const SizedBox(height: 4),
          Text(title, style: display(widget.compact ? 28 : 38, weight: FontWeight.w700)),
          const SizedBox(height: 24),
          if (widget.kind == 'top')
            for (var i = 0; i < d.top.length; i++)
              Container(
                decoration: BoxDecoration(border: Border(bottom: BorderSide(color: C.line.withValues(alpha: 0.6)))),
                child: Row(children: [
                  SizedBox(width: 32, child: Text('${i + 1}', style: const TextStyle(color: C.faint, fontSize: 13))),
                  Expanded(child: WebTrackLine(track: d.top[i])),
                ]),
              )
          else if (widget.kind == 'related')
            TileGrid(tileWidth: 160, tiles: [for (final x in d.related) artistTile(context, x)])
          else
            TileGrid(tiles: [for (final x in d.ofKind(widget.kind)) albumTile(context, x)]),
        ]);
      },
    );
  }
}

// ---------- альбом ----------

class WebAlbumPage extends StatefulWidget {
  final int albumId;
  final bool compact;
  const WebAlbumPage({super.key, required this.albumId, required this.compact});

  @override
  State<WebAlbumPage> createState() => _WebAlbumPageState();
}

class _WebAlbumPageState extends State<WebAlbumPage> {
  Future<(WebAlbum, List<WebTrack>)>? _future;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _future ??= Services.of(context).web.albumById(widget.albumId);
  }

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final nav = NavScope.of(context);
    final pad = widget.compact ? 20.0 : 40.0;
    return _Loading<(WebAlbum, List<WebTrack>)>(
      future: _future,
      onRetry: () => setState(() => _future = app.web.albumById(widget.albumId)),
      builder: (d) {
        final (a, tracks) = d;
        final size = widget.compact ? 150.0 : 230.0;
        final have = app.web.inLibrary(a.artist.toLowerCase(), a);
        return ListView(padding: EdgeInsets.fromLTRB(pad, 40, pad, 40), children: [
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            netCover(a.cover, size, radius: 12),
            const SizedBox(width: 28),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(a.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: display(widget.compact ? 26 : 36, weight: FontWeight.w700)),
                const SizedBox(height: 6),
                InkWell(
                  onTap: a.artistId == 0 ? null : () => nav.go(Nav('webartist', '${a.artistId}')),
                  child: Text(a.artist, style: const TextStyle(color: C.accent, fontSize: 18, fontWeight: FontWeight.w500)),
                ),
                const SizedBox(height: 6),
                Text(
                  [a.typeLabel, if (a.year.isNotEmpty) a.year, countTracks(tracks.length), if (have) 'есть в библиотеке'].join(' · '),
                  style: const TextStyle(color: C.muted),
                ),
                const SizedBox(height: 16),
                Wrap(spacing: 10, runSpacing: 10, children: [
                  FilledButton.icon(
                    onPressed: a.link.isEmpty ? null : () => downloadToLibrary(context, a.link, a.title),
                    icon: const Icon(Icons.download_rounded, size: 18),
                    label: Text(have ? 'Скачать недостающее' : 'Скачать в библиотеку'),
                  ),
                  if (a.link.isNotEmpty)
                    OutlinedButton.icon(
                      onPressed: () => launchUrl(Uri.parse(a.link)),
                      icon: const Icon(Icons.open_in_new_rounded, size: 16),
                      label: const Text('Deezer'),
                    ),
                ]),
              ]),
            ),
          ]),
          const SizedBox(height: 26),
          for (var i = 0; i < tracks.length; i++)
            Container(
              decoration: BoxDecoration(border: Border(bottom: BorderSide(color: C.line.withValues(alpha: 0.6)))),
              child: Row(children: [
                SizedBox(width: 32, child: Text('${i + 1}', style: const TextStyle(color: C.faint, fontSize: 13))),
                Expanded(child: WebTrackLine(track: tracks[i], showCover: false)),
              ]),
            ),
        ]);
      },
    );
  }
}

// ---------- поиск ----------

class WebSearchPage extends StatefulWidget {
  final bool compact;
  const WebSearchPage({super.key, required this.compact});

  @override
  State<WebSearchPage> createState() => _WebSearchPageState();
}

/// Последний поиск — чтобы вернуться «назад» к тем же результатам
String _lastQuery = '';

class _WebSearchPageState extends State<WebSearchPage> {
  final _input = TextEditingController(text: _lastQuery);
  Timer? _debounce;
  Future<({List<WebTrack> tracks, List<WebAlbum> albums, List<WebArtist> artists})>? _future;

  @override
  void initState() {
    super.initState();
    if (_lastQuery.isNotEmpty) WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _input.dispose();
    super.dispose();
  }

  void _run() {
    if (!mounted) return;
    final q = _input.text.trim();
    _lastQuery = q;
    setState(() => _future = q.isEmpty ? null : Services.of(context).web.search(q));
  }

  @override
  Widget build(BuildContext context) {
    final pad = widget.compact ? 20.0 : 40.0;
    return ListView(padding: EdgeInsets.fromLTRB(pad, 40, pad, 40), children: [
      Text('Поиск в интернете', style: display(widget.compact ? 28 : 38, weight: FontWeight.w700)),
      const SizedBox(height: 8),
      const Text('Треки, альбомы и исполнители из Deezer: послушать отрывок и скачать в библиотеку.',
          style: TextStyle(color: C.muted)),
      const SizedBox(height: 18),
      ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: TextField(
          controller: _input,
          autofocus: true,
          onChanged: (_) {
            _debounce?.cancel();
            _debounce = Timer(const Duration(milliseconds: 450), _run);
          },
          onSubmitted: (_) => _run(),
          decoration: const InputDecoration(
            hintText: 'Название трека, альбома или исполнителя',
            prefixIcon: Icon(Icons.travel_explore_rounded, size: 20),
          ),
        ),
      ),
      if (_future != null)
        FutureBuilder<({List<WebTrack> tracks, List<WebAlbum> albums, List<WebArtist> artists})>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()));
            }
            if (snap.hasError) {
              return Padding(
                padding: const EdgeInsets.only(top: 24),
                child: Text('Не получилось найти: ${snap.error}', style: const TextStyle(color: C.muted)),
              );
            }
            final r = snap.data!;
            if (r.tracks.isEmpty && r.albums.isEmpty && r.artists.isEmpty) {
              return const Padding(padding: EdgeInsets.only(top: 24), child: Text('Ничего не нашлось', style: TextStyle(color: C.muted)));
            }
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (r.artists.isNotEmpty) ...[
                const SizedBox(height: 30),
                TileRow(title: 'Исполнители', tileWidth: 150, height: 190, tiles: [for (final a in r.artists) artistTile(context, a)]),
              ],
              if (r.tracks.isNotEmpty) ...[
                const SizedBox(height: 30),
                const SectionTitle('Треки'),
                for (final t in r.tracks)
                  Container(
                    decoration: BoxDecoration(border: Border(bottom: BorderSide(color: C.line.withValues(alpha: 0.6)))),
                    child: WebTrackLine(track: t),
                  ),
              ],
              if (r.albums.isNotEmpty) ...[
                const SizedBox(height: 30),
                TileRow(
                  title: 'Альбомы',
                  tileWidth: 190,
                  height: 260,
                  tiles: [for (final a in r.albums) albumTile(context, a, withArtist: true)],
                ),
              ],
            ]);
          },
        ),
    ]);
  }
}
