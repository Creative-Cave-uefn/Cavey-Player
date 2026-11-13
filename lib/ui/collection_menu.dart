import 'package:flutter/material.dart';

import '../app.dart';
import '../core/library.dart';
import '../core/models.dart';
import 'album_edit.dart';
import 'device_export_ui.dart';
import 'glass_popup.dart';
import '../core/share_link.dart';
import 'profile_view.dart' show topTracksOf;
import 'share_dialog.dart';

/// Меню по правому клику на плейлисте, альбоме или исполнителе: левая панель, «Коллекция», «Главная» медиатеки.
/// Слушать, вперемешку, правка, закрепление, «Скачать на устройство», приватность плейлиста
Future<void> showCollectionMenu(BuildContext context, Offset at, {Playlist? playlist, Album? album, Artist? artist}) async {
  assert(playlist != null || album != null || artist != null);
  final app = Services.of(context);
  final lib = app.lib;
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  final p = playlist;
  final mine = p != null && (p.by == lib.me || p.by.isEmpty);
  final tokens = p != null ? [LibraryController.playlistPin(p.id)] : album != null ? LibraryController.albumPins(album).toList() : [LibraryController.artistPin(artist!)];
  final pinned = lib.isPinnedToken(tokens);
  final v = await showGlassMenu<String>(
    context: context,
    position: RelativeRect.fromRect(at & const Size(1, 1), Offset.zero & overlay.size),
    items: [
      const PopupMenuItem(value: 'play', child: Text('Слушать')),
      const PopupMenuItem(value: 'shuffle', child: Text('Вперемешку')),
      const PopupMenuDivider(),
      if (p != null || album != null) const PopupMenuItem(value: 'edit', child: Text('Редактировать…')),
      // Исполнителя можно отметить любимым (то же сердечко, что в «Исполнителях» и на плитке)
      if (artist != null)
        PopupMenuItem(
          value: 'fav',
          child: Text(lib.isFavArtist(artist.key) ? 'Убрать из любимых исполнителей' : 'В любимые исполнители'),
        ),
      PopupMenuItem(value: 'pin', child: Text(pinned ? 'Открепить' : 'Закрепить')),
      const PopupMenuItem(value: 'share', child: Text('Поделиться…')),
      const PopupMenuItem(value: 'export', child: Text('Скачать на устройство')),
      if (mine)
        lib.isPlaylistPublic(p.id)
            ? const PopupMenuItem(value: 'private', child: Text('Сделать приватным'))
            : const PopupMenuItem(value: 'public', child: Text('Сделать открытым')),
    ],
  );
  if (v == null || !context.mounted) return;
  List<Track> tracks() {
    if (p != null) return lib.playlistTracks(p.id);
    if (album != null) return album.tracks;
    return topTracksOf(app, artist!);
  }

  switch (v) {
    case 'play':
    case 'shuffle':
      final list = tracks();
      if (list.isEmpty) {
        lib.messages.add('Здесь пока нет треков');
        return;
      }
      final shuffle = v == 'shuffle';
      if (app.player.shuffle != shuffle) app.player.toggleShuffle();
      app.player.playTracks(list, shuffle ? DateTime.now().microsecond % list.length : 0);
    case 'edit':
      if (p != null) {
        final t = lib.playlistTracks(p.id);
        await editPlaylistDialog(context, p, coverTrack: t.isEmpty ? null : t.firstWhere((x) => x.hasCover, orElse: () => t.first));
      } else {
        await editAlbumDialog(context, album!);
      }
    case 'fav':
      lib.toggleFavArtist(artist!.key);
    case 'pin':
      lib.togglePinToken(tokens);
    case 'share':
      await showShareSubjectDialog(context, collectionShareSubject(playlist: p, album: album, artist: artist));
    case 'export':
      if (p != null) {
        await exportToDevice(context, tracks(), folderName: p.name);
      } else if (album != null) {
        await exportToDevice(context, tracks(), folderName: album.title, withArtist: false);
      } else {
        // У исполнителя — все его треки, папка с его именем
        await exportToDevice(context, List<Track>.of(artist!.tracks), folderName: artist.name, numbered: false);
      }
    case 'public':
    case 'private':
      lib.setPlaylistPublic(p!.id, v == 'public');
      lib.messages.add(v == 'public' ? 'Плейлист «${p.name}» теперь видят все друзья' : 'Плейлист «${p.name}» виден только вам');
  }
}

/// Что отправляется по «Поделиться» у плейлиста, альбома или исполнителя
ShareSubject collectionShareSubject({Playlist? playlist, Album? album, Artist? artist}) {
  if (playlist != null) return ShareSubject(ShareKind.playlist, playlist.id, playlist.name);
  if (album != null) return ShareSubject(ShareKind.album, album.key, album.title, album.artist);
  return ShareSubject(ShareKind.artist, artist!.key, artist.name);
}
