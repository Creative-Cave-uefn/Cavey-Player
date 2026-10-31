import 'package:flutter/material.dart';

import '../app.dart';
import '../core/library.dart';
import 'cover_picker.dart';
import 'list_filter.dart';
import 'shell.dart';
import 'theme.dart';
import 'tracks_view.dart';
import 'widgets.dart';
import 'glass_popup.dart';
import 'library_home.dart';

class AlbumsPage extends StatefulWidget {
  /// 'ep' — только синглы и EP (до 6 треков); иначе все альбомы
  final String? kind;
  const AlbumsPage({super.key, this.kind});

  @override
  State<AlbumsPage> createState() => _AlbumsPageState();
}

class _AlbumsPageState extends State<AlbumsPage> {
  final _search = TextEditingController();
  final _focus = FocusNode();
  String _query = '';

  @override
  void initState() {
    super.initState();
    searchRequests.addListener(_focusSearch);
  }

  @override
  void dispose() {
    searchRequests.removeListener(_focusSearch);
    _search.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _focusSearch() {
    if (!mounted) return;
    _focus.requestFocus();
    _search.selection = TextSelection(baseOffset: 0, extentOffset: _search.text.length);
  }

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    return ListenableBuilder(
      listenable: app.lib,
      builder: (context, _) {
        final ep = widget.kind == 'ep';
        final all = ep ? app.lib.albums.where(isShortRelease).toList() : app.lib.albums;
        final q = foldText(_query.trim());
        final desc = app.settings.albumsDesc;
        final albums = q.isEmpty
            ? List<Album>.of(all)
            : all.where((a) => foldText(a.title).contains(q) || foldText(a.artist).contains(q)).toList();
        int cmp(Album a, Album b) {
          final ua = a.title == 'Без альбома';
          final ub = b.title == 'Без альбома';
          if (ua != ub) return ua ? 1 : -1; // «без альбома» всегда внизу
          final r = sortKey(a.title).compareTo(sortKey(b.title));
          if (r != 0) return desc ? -r : r;
          return sortKey(a.artist).compareTo(sortKey(b.artist));
        }

        albums.sort(cmp);
        final prefs = ViewPrefs(app.settings, ep ? 'eps' : 'albums', defaultGrid: true);
        final pad = MediaQuery.sizeOf(context).width < 860 ? 20.0 : 36.0;
        final header = Padding(
          padding: EdgeInsets.fromLTRB(pad, 34, pad, 22),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(ep ? 'Синглы и EP' : 'Альбомы', style: display(36, weight: FontWeight.w700)),
            if (all.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                q.isEmpty
                    ? '${all.length} ${plural(all.length, 'альбом', 'альбома', 'альбомов')}'
                    : 'Найдено ${albums.length} из ${all.length}',
                style: const TextStyle(color: C.muted, fontSize: 15),
              ),
              const SizedBox(height: 18),
              SearchSortBar(
                controller: _search,
                focusNode: _focus,
                hint: 'Найти альбом или исполнителя',
                desc: desc,
                onChanged: (v) => setState(() => _query = v),
                onToggleSort: () {
                  app.settings.albumsDesc = !desc;
                  app.lib.saveSettings();
                  setState(() {});
                },
                trailing: ViewControls(prefs: prefs, onChanged: () => setState(() {})),
              ),
            ],
          ]),
        );
        if (all.isEmpty) {
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            header,
            const Expanded(
              child: EmptyState(
                icon: Icons.album_outlined,
                title: 'Альбомов пока нет',
                text: 'Они появятся, когда в библиотеке будут треки. Альбомы собираются по тегам и по папкам.',
              ),
            ),
          ]);
        }
        return CustomScrollView(slivers: [
          SliverToBoxAdapter(child: header),
          if (albums.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: pad, vertical: 12),
                child: Text('Ничего не нашлось по запросу «$_query»', style: const TextStyle(color: C.muted)),
              ),
            ),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(pad, 0, pad, 32),
            sliver: prefs.grid
                ? AdaptiveGridSliver(
                    tile: prefs.size,
                    extra: 58,
                    count: albums.length,
                    builder: (context, i) {
                      final a = albums[i];
                      return InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: () => NavScope.of(context).go(Nav('album', a.key)),
                        // Правый клик: сменить обложку альбома
                        onSecondaryTapUp: (d) => showAlbumMenu(context, a, d.globalPosition),
                        child: LayoutBuilder(
                          builder: (context, box) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            CoverImage(track: a.coverTrack, size: box.maxWidth, radius: 10),
                            const SizedBox(height: 10),
                            Text(a.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                            const SizedBox(height: 3),
                            Text(a.artist,
                                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.muted, fontSize: 13)),
                          ]),
                        ),
                      );
                    },
                  )
                : SliverFixedExtentList(
                    itemExtent: prefs.size,
                    delegate: SliverChildBuilderDelegate(
                      (context, i) {
                        final a = albums[i];
                        final cover = prefs.size - 12;
                        return InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: () => NavScope.of(context).go(Nav('album', a.key)),
                          onSecondaryTapUp: (d) => showAlbumMenu(context, a, d.globalPosition),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                            child: Row(children: [
                              CoverImage(track: a.coverTrack, size: cover, radius: 6),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Text(a.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                                  const SizedBox(height: 3),
                                  Text(a.artist,
                                      maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.muted, fontSize: 13)),
                                ]),
                              ),
                              Text(
                                '${a.year.isEmpty ? '' : '${a.year} · '}${countTracks(a.tracks.length)}',
                                style: const TextStyle(color: C.muted, fontSize: 13),
                              ),
                              const SizedBox(width: 8),
                            ]),
                          ),
                        );
                      },
                      childCount: albums.length,
                    ),
                  ),
          ),
        ]);
      },
    );
  }
}

/// Окно «Обложка альбома»: загруженная картинка показывается у всех треков альбома
Future<void> changeAlbumCover(BuildContext context, Album a) async {
  final lib = Services.of(context).lib;
  final v = await coverDialog(
    context,
    title: 'Обложка альбома',
    current: CoverImage(track: a.coverTrack, size: 120, radius: 0),
    canReset: lib.albumCover(a.key) != null,
    note: 'Её увидят все друзья, и она показывается у каждого трека этого альбома.',
  );
  if (v != null) lib.setAlbumCover(a.key, v);
}

/// Меню альбома по правому клику, в точке клика
Future<void> showAlbumMenu(BuildContext context, Album a, Offset at) async {
  final lib = Services.of(context).lib;
  final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
  final v = await showGlassMenu<String>(
    context: context,
    position: RelativeRect.fromRect(at & const Size(1, 1), Offset.zero & overlay.size),
    items: [
      const PopupMenuItem(value: 'cover', child: Text('Изменить обложку…')),
      if (lib.albumCover(a.key) != null) const PopupMenuItem(value: 'reset', child: Text('Вернуть обложку из файлов')),
    ],
  );
  if (!context.mounted) return;
  if (v == 'cover') await changeAlbumCover(context, a);
  if (v == 'reset') lib.setAlbumCover(a.key, '');
}
