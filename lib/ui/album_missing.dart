import 'package:flutter/material.dart';

import '../app.dart';
import '../core/album_match.dart';
import '../core/library.dart';
import '../core/models.dart';
import '../core/web_info.dart';
import 'theme.dart';
import 'web_pages.dart';
import 'web_views.dart';
import 'widgets.dart';

/// Какие треки альбома из интернета ещё не скачаны. Трек из интернета считается скачанным, если в альбоме есть:
/// 1) трек с тем же названием (без скобок вроде «(Remastered)» и feat.);
/// 2) иначе трек с тем же номером на том же диске и длительностью в пределах 3 секунд — так находятся песни,
///    записанные в тегах иначе (японское название у вас, английское в Deezer);
/// 3) иначе ещё не сопоставленный трек с такой же длительностью (в пределах 2 секунд).
/// Каждый ваш трек засчитывается не больше одного раза. Остальное ищется по всей библиотеке — вдруг трек лежит в другом альбоме
List<WebTrack> missingAlbumTracks(AppServices app, Album album, List<WebTrack> web) =>
    missingByMatch(album.tracks, web, inLibrary: app.web.trackInLibrary);

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
                      onPressed: web.link.isEmpty ? null : () => downloadToLibrary(context, web.link, web.title, into: widget.album),
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
                  ...webAlbumRows(missing, into: widget.album),
                ]),
              ),
            );
          },
        );
      },
    );
  }
}
