// Сведения из интернета в интерфейсе: фото и описание исполнителя, альбомы,
// которых нет в библиотеке, новинки, отрывки и «Скачать в библиотеку».

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app.dart';
import '../core/library.dart';
import '../core/web_info.dart';
import 'shell.dart';
import 'theme.dart';
import 'widgets.dart';

/// Ставит ссылку в загрузчик: в общую папку или первую из папок с музыкой
void downloadToLibrary(BuildContext context, String link, String label) {
  final app = Services.of(context);
  final sources = app.lib.data.sources;
  final target = sources.any((s) => s.id == app.settings.hubId) ? app.settings.hubId : sources.firstOrNull?.id;
  if (target == null) {
    app.lib.messages.add('Сначала добавьте папку с музыкой');
    return;
  }
  app.downloads.enqueue(link, target);
  app.lib.messages.add('«$label» — в загрузках. Прогресс в разделе «Скачать»');
}

/// Круглое фото исполнителя из Deezer; пока его нет — [fallback]
class ArtistPhoto extends StatefulWidget {
  final String name;
  final double size;
  final Widget fallback;
  const ArtistPhoto({super.key, required this.name, required this.size, required this.fallback});

  @override
  State<ArtistPhoto> createState() => _ArtistPhotoState();
}

class _ArtistPhotoState extends State<ArtistPhoto> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final web = Services.of(context).web;
    if (web.artistCached(widget.name) == null) web.artist(widget.name);
  }

  @override
  Widget build(BuildContext context) {
    final web = Services.of(context).web;
    return ListenableBuilder(
      listenable: web,
      builder: (context, _) {
        final pic = web.artistCached(widget.name)?.picture ?? '';
        if (pic.isEmpty) return widget.fallback;
        return ClipOval(
          child: Image.network(
            pic,
            width: widget.size,
            height: widget.size,
            fit: BoxFit.cover,
            cacheWidth: (widget.size * MediaQuery.devicePixelRatioOf(context)).round(),
            errorBuilder: (_, __, ___) => widget.fallback,
          ),
        );
      },
    );
  }
}

/// Под треками исполнителя: описание и то, чего нет в библиотеке
class ArtistWebSection extends StatefulWidget {
  final Artist artist;
  final bool compact;

  /// Свои поля по бокам (false — когда раздел встроен в страницу, у которой поля уже есть)
  final bool padded;
  const ArtistWebSection({super.key, required this.artist, required this.compact, this.padded = true});

  @override
  State<ArtistWebSection> createState() => _ArtistWebSectionState();
}

class _ArtistWebSectionState extends State<ArtistWebSection> {
  WebArtist? _web;
  WebBio? _bio;
  List<WebAlbum>? _albums;
  String? _error;
  bool _bioOpen = false;
  bool _all = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_albums != null || _error != null) return;
    final web = Services.of(context).web;
    _bio = web.bioCached(widget.artist.name);
    () async {
      try {
        final w = await web.artist(widget.artist.name);
        final bio = _bio ?? await web.bio(widget.artist.name);
        final albums = w == null ? <WebAlbum>[] : await web.albums(w);
        if (!mounted) return;
        setState(() {
          _web = w;
          _bio = bio;
          _albums = albums;
        });
      } catch (e) {
        if (mounted) setState(() => _error = '$e');
      }
    }();
  }

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final pad = !widget.padded ? 0.0 : (widget.compact ? 20.0 : 36.0);
    final albums = _albums;
    final missing = albums == null ? const <WebAlbum>[] : [for (final a in albums) if (!app.web.inLibrary(widget.artist.key, a)) a];
    final shown = _all ? missing : missing.take(8).toList();
    return Padding(
      padding: EdgeInsets.fromLTRB(pad, 8, pad, 40),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (_bio != null) ...[
          Text('Об исполнителе', style: display(20)),
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Text(_bio!.text,
                maxLines: _bioOpen ? null : 4,
                overflow: _bioOpen ? null : TextOverflow.ellipsis,
                style: const TextStyle(color: C.muted, height: 1.5)),
          ),
          Row(children: [
            TextButton(onPressed: () => setState(() => _bioOpen = !_bioOpen), child: Text(_bioOpen ? 'Свернуть' : 'Читать дальше')),
            if (_bio!.url.isNotEmpty)
              TextButton(onPressed: () => launchUrl(Uri.parse(_bio!.url)), child: const Text('Википедия')),
          ]),
          const SizedBox(height: 16),
        ],
        if (albums == null && _error == null)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Row(children: [
              SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              SizedBox(width: 12),
              Text('Ищу альбомы в интернете…', style: TextStyle(color: C.faint)),
            ]),
          )
        else if (_error != null)
          Text('Не получилось загрузить сведения из интернета: $_error', style: const TextStyle(color: C.faint, fontSize: 13))
        else if (_web == null)
          const Text('В Deezer такого исполнителя не нашлось.', style: TextStyle(color: C.faint, fontSize: 13))
        else ...[
          Row(children: [
            Text('Нет в библиотеке', style: display(20)),
            const SizedBox(width: 10),
            if (missing.isNotEmpty) Text('${missing.length}', style: const TextStyle(color: C.faint)),
            const Spacer(),
            if (_web!.link.isNotEmpty)
              TextButton.icon(
                onPressed: () => launchUrl(Uri.parse(_web!.link)),
                icon: const Icon(Icons.open_in_new_rounded, size: 16),
                label: const Text('Deezer'),
              ),
          ]),
          const SizedBox(height: 6),
          if (missing.isEmpty)
            const Text('Всё, что есть у исполнителя на Deezer, уже есть у вас.', style: TextStyle(color: C.faint, fontSize: 13))
          else ...[
            for (final a in shown) WebAlbumTile(album: a),
            if (missing.length > shown.length)
              TextButton(onPressed: () => setState(() => _all = true), child: Text('Показать все (${missing.length})')),
          ],
        ],
      ]),
    );
  }
}

/// Альбом или сингл из интернета: обложка, раскрывающийся список треков с отрывками, «Скачать»
class WebAlbumTile extends StatefulWidget {
  final WebAlbum album;

  /// Показать исполнителя ссылкой (на странице «Новинки»)
  final String? artistKey;
  const WebAlbumTile({super.key, required this.album, this.artistKey});

  @override
  State<WebAlbumTile> createState() => _WebAlbumTileState();
}

class _WebAlbumTileState extends State<WebAlbumTile> {
  bool _open = false;
  Future<List<WebTrack>>? _tracks;

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final a = widget.album;
    final when = a.released;
    final fresh = when != null && DateTime.now().difference(when).inDays <= 30;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(border: Border.all(color: C.line), borderRadius: BorderRadius.circular(10)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => setState(() {
            _open = !_open;
            _tracks ??= app.web.albumTracks(a.id);
          }),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: a.cover.isEmpty
                    ? Container(width: 56, height: 56, color: C.raised)
                    : Image.network(a.cover, width: 56, height: 56, fit: BoxFit.cover, cacheWidth: 112,
                        errorBuilder: (_, __, ___) => Container(width: 56, height: 56, color: C.raised)),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Flexible(
                      child: Text(a.title,
                          maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                    ),
                    if (fresh) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(color: C.accent.withValues(alpha: 0.18), borderRadius: BorderRadius.circular(4)),
                        child: const Text('новое', style: TextStyle(color: C.accent, fontSize: 11)),
                      ),
                    ],
                  ]),
                  const SizedBox(height: 3),
                  Row(children: [
                    if (widget.artistKey != null) ...[
                      Flexible(
                        child: InkWell(
                          onTap: () => NavScope.of(context).go(Nav('artist', widget.artistKey)),
                          child: Text(a.artist,
                              maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.muted, fontSize: 13)),
                        ),
                      ),
                      const Text('  ·  ', style: TextStyle(color: C.faint, fontSize: 13)),
                    ],
                    Text('${a.typeLabel}${a.date.isEmpty ? '' : ', ${_date(a.date)}'}',
                        style: const TextStyle(color: C.faint, fontSize: 13)),
                  ]),
                ]),
              ),
              IconButton(
                tooltip: 'Скачать в библиотеку',
                onPressed: a.link.isEmpty ? null : () => downloadToLibrary(context, a.link, a.title),
                icon: const Icon(Icons.download_rounded),
              ),
              Icon(_open ? Icons.expand_less_rounded : Icons.expand_more_rounded, color: C.faint),
            ]),
          ),
        ),
        if (_open)
          FutureBuilder<List<WebTrack>>(
            future: _tracks,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Padding(padding: EdgeInsets.all(12), child: LinearProgressIndicator());
              }
              if (snap.hasError) {
                return Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text('Не получилось загрузить треки: ${snap.error}', style: const TextStyle(color: C.faint, fontSize: 13)),
                );
              }
              final tracks = snap.data ?? const <WebTrack>[];
              return Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                child: Column(children: [for (var i = 0; i < tracks.length; i++) WebTrackRow(track: tracks[i], n: i + 1)]),
              );
            },
          ),
      ]),
    );
  }

  static String _date(String d) {
    final p = d.split('-');
    return p.length == 3 ? '${p[2]}.${p[1]}.${p[0]}' : d;
  }
}

/// Трек из интернета: отрывок, есть ли уже в библиотеке, «Скачать»
class WebTrackRow extends StatelessWidget {
  final WebTrack track;
  final int n;
  const WebTrackRow({super.key, required this.track, required this.n});

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final have = app.web.trackInLibrary(track);
    return ListenableBuilder(
      listenable: app.preview,
      builder: (context, _) {
        final playing = app.preview.current == track.id;
        return SizedBox(
          height: 44,
          child: Row(children: [
            SizedBox(width: 28, child: Text('$n', style: const TextStyle(color: C.faint, fontSize: 13))),
            SizedBox.square(
              dimension: 36,
              child: track.preview.isEmpty
                  ? const SizedBox.shrink()
                  : Stack(alignment: Alignment.center, children: [
                      if (playing)
                        CircularProgressIndicator(value: app.preview.progress, strokeWidth: 2, color: C.accent),
                      IconButton(
                        tooltip: playing ? 'Остановить отрывок' : 'Послушать отрывок (30 с)',
                        iconSize: 20,
                        padding: EdgeInsets.zero,
                        onPressed: () => app.preview.toggle(track),
                        icon: Icon(playing ? Icons.stop_rounded : Icons.play_arrow_rounded, color: playing ? C.accent : C.muted),
                      ),
                    ]),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(track.title,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: playing ? C.accent : C.text)),
            ),
            Text(formatDuration(Duration(seconds: track.seconds)), style: const TextStyle(color: C.faint, fontSize: 12)),
            const SizedBox(width: 8),
            if (have)
              const Tooltip(
                message: 'Уже есть в библиотеке',
                child: Padding(padding: EdgeInsets.all(8), child: Icon(Icons.check_rounded, size: 18, color: C.faint)),
              )
            else
              IconButton(
                tooltip: 'Скачать трек в библиотеку',
                iconSize: 18,
                onPressed: track.link.isEmpty ? null : () => downloadToLibrary(context, track.link, track.title),
                icon: const Icon(Icons.download_rounded, color: C.muted),
              ),
          ]),
        );
      },
    );
  }
}

/// «Новинки»: свежие релизы исполнителей из библиотеки, которых у вас ещё нет
class NewReleasesPage extends StatefulWidget {
  final bool compact;
  const NewReleasesPage({super.key, required this.compact});

  @override
  State<NewReleasesPage> createState() => _NewReleasesPageState();
}

class _NewReleasesPageState extends State<NewReleasesPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Services.of(context).web.loadReleases();
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final web = app.web;
    final pad = widget.compact ? 20.0 : 36.0;
    return ListenableBuilder(
      listenable: Listenable.merge([web, app.lib]),
      builder: (context, _) {
        final list = [for (final r in web.releases) if (!web.inLibrary(r.artistKey, r.album)) r];
        return ListView(padding: EdgeInsets.fromLTRB(pad, 34, pad, 40), children: [
          Row(children: [
            Expanded(child: Text('Новинки', style: display(36, weight: FontWeight.w700))),
            IconButton(
              tooltip: 'Проверить ещё раз',
              onPressed: web.loadingReleases ? null : () => web.loadReleases(force: true),
              icon: const Icon(Icons.refresh_rounded),
            ),
          ]),
          const SizedBox(height: 10),
          const Text(
            'Альбомы и синглы за последние четыре месяца у исполнителей из вашей библиотеки, которых у вас ещё нет. '
            'Можно послушать отрывки и скачать в библиотеку. Сведения — из Deezer.',
            style: TextStyle(color: C.muted, fontSize: 15, height: 1.5),
          ),
          const SizedBox(height: 18),
          if (web.loadingReleases) ...[
            Text('Проверяю исполнителей: ${web.releasesDone} из ${web.releasesTotal}', style: const TextStyle(color: C.faint)),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: web.releasesTotal == 0 ? null : web.releasesDone / web.releasesTotal),
            const SizedBox(height: 18),
          ],
          if (!web.loadingReleases && list.isEmpty)
            const EmptyState(
              icon: Icons.new_releases_outlined,
              title: 'Новинок нет',
              text: 'У ваших исполнителей за последние месяцы ничего не вышло — или всё уже в библиотеке.',
            ),
          for (final r in list) WebAlbumTile(album: r.album, artistKey: r.artistKey),
        ]);
      },
    );
  }
}
