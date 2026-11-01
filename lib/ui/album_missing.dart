import 'package:flutter/material.dart';

import '../app.dart';
import '../core/library.dart';
import '../core/web_info.dart';
import 'theme.dart';
import 'web_pages.dart';
import 'web_views.dart';
import 'widgets.dart';

/// Какие треки альбома из интернета ещё не скачаны: сравнение по названию трека
/// (без скобок вроде «(Remastered)» и feat.), а также по всей библиотеке — вдруг трек лежит в другом альбоме
List<WebTrack> missingAlbumTracks(AppServices app, Album album, List<WebTrack> web) {
  final have = {for (final t in album.tracks) WebInfoService.trackTitleKey(t.title)};
  return [
    for (final w in web)
      if (!have.contains(WebInfoService.trackTitleKey(w.title)) && !app.web.trackInLibrary(w)) w
  ];
}

/// Панель «Можно докачать» под списком треков альбома: альбом ищется в Deezer, и всё,
/// чего нет в библиотеке, можно послушать отрывком и скачать
class MissingAlbumTracks extends StatefulWidget {
  final Album album;
  const MissingAlbumTracks({super.key, required this.album});

  @override
  State<MissingAlbumTracks> createState() => _MissingAlbumTracksState();
}

class _MissingAlbumTracksState extends State<MissingAlbumTracks> {
  Future<(WebAlbum, List<WebTrack>)?>? _future;
  String? _for;

  Future<(WebAlbum, List<WebTrack>)?> _load(AppServices app) async {
    final a = widget.album;
    final artists = a.artist == 'Разные исполнители' ? a.artists : [a.artist, ...a.artists.where((n) => n != a.artist)];
    final found = await app.web.findAlbum(a.title, artists, haveTitles: [for (final t in a.tracks) t.title]);
    if (found == null) return null;
    return app.web.albumById(found.id);
  }

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final id = '${widget.album.key}|${widget.album.title}';
    if (_for != id) {
      _for = id;
      _future = _load(app).catchError((Object _) => null);
    }
    final pad = MediaQuery.sizeOf(context).width < 860 ? 20.0 : 36.0;
    return FutureBuilder<(WebAlbum, List<WebTrack>)?>(
      future: _future,
      builder: (context, snap) {
        final d = snap.data;
        if (d == null) return const SizedBox(height: 24);
        final (web, tracks) = d;
        return ListenableBuilder(
          listenable: app.lib,
          builder: (context, _) {
            final missing = missingAlbumTracks(app, widget.album, tracks);
            if (missing.isEmpty) return const SizedBox(height: 24);
            return Padding(
              padding: EdgeInsets.fromLTRB(pad, 28, pad, 32),
              // Без своего фона и рамки: панель продолжает список треков
              child: Container(
                padding: const EdgeInsets.fromLTRB(0, 4, 0, 10),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Icon(Icons.cloud_download_outlined, color: C.accent),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text('Можно докачать · ${countTracks(missing.length)}', style: display(18)),
                    ),
                    FilledButton.icon(
                      onPressed: web.link.isEmpty ? null : () => downloadToLibrary(context, web.link, web.title),
                      icon: const Icon(Icons.download_rounded, size: 18),
                      label: const Text('Докачать всё'),
                    ),
                  ]),
                  const SizedBox(height: 4),
                  Text(
                    'В интернете в «${web.title}» ${countTracks(tracks.length)}, у вас ${countTracks(widget.album.tracks.length)}. '
                    'Уже скачанные треки повторно не качаются.',
                    style: const TextStyle(color: C.faint, fontSize: 13, height: 1.4),
                  ),
                  const SizedBox(height: 10),
                  ...webAlbumRows(missing),
                ]),
              ),
            );
          },
        );
      },
    );
  }
}
