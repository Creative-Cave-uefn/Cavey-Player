import 'package:flutter/material.dart';

import '../app.dart';
import '../core/library.dart';
import 'album_edit.dart';
import 'list_filter.dart';
import 'shell.dart';
import 'library_tabs.dart';
import 'collection_menu.dart';
import 'theme.dart';
import 'tracks_view.dart';
import 'uploader_filter.dart';
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
        final every = ep ? app.lib.albums.where(isShortRelease).toList() : app.lib.albums;
        final q = foldText(_query.trim());
        final sortId = ep ? 'eps' : 'albums';
        // «Кто загрузил»: альбомы, в которых есть треки выбранных людей
        final by = loadUploaderFilter(app.settings, sortId);
        final all = by.isEmpty ? every : [for (final a in every) if (a.tracks.any((t) => passesUploaders(by, t.by))) a];
        final ls = ListSort.read(app.settings, sortId, legacyDesc: app.settings.albumsDesc);
        final desc = ls.desc;
        final firstAt = ls.mode == 'first' ? {for (final a in all) a.key: firstUpload(a.tracks)} : const <String, String>{};
        final albums = q.isEmpty
            ? List<Album>.of(all)
            : all.where((a) => foldText(a.title).contains(q) || foldText(a.artist).contains(q)).toList();
        int cmp(Album a, Album b) {
          final ua = a.title == 'Без альбома';
          final ub = b.title == 'Без альбома';
          if (ua != ub) return ua ? 1 : -1; // «без альбома» всегда внизу
          final byName = sortKey(a.title).compareTo(sortKey(b.title));
          final r = switch (ls.mode) {
            'first' => (firstAt[a.key] ?? '').compareTo(firstAt[b.key] ?? ''),
            'count' => a.tracks.length.compareTo(b.tracks.length),
            _ => byName,
          };
          if (r != 0) return desc ? -r : r;
          // Равные по выбранному признаку всегда по алфавиту и по ключу: порядок не плавает
          if (byName != 0) return byName;
          final byArtist = sortKey(a.artist).compareTo(sortKey(b.artist));
          return byArtist != 0 ? byArtist : a.key.compareTo(b.key);
        }

        albums.sort(cmp);
        final prefs = ViewPrefs(app.settings, ep ? 'eps' : 'albums', defaultGrid: true);
        final pad = MediaQuery.sizeOf(context).width < 860 ? 20.0 : 36.0;
        final header = Padding(
          padding: EdgeInsets.fromLTRB(pad, 34, pad, 22),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (!LibraryFrame.on(context))
              Text(ep ? 'Синглы и EP' : 'Альбомы', style: display(36, weight: FontWeight.w700)),
            if (every.isNotEmpty) ...[
              // В «Медиатеке» общее число уже стоит под заголовком раздела; здесь остаётся лишь итог поиска
              if (!LibraryFrame.on(context) || q.isNotEmpty || by.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  q.isEmpty
                      ? '${all.length} ${plural(all.length, 'альбом', 'альбома', 'альбомов')}'
                      : 'Найдено ${albums.length} из ${all.length}',
                  style: const TextStyle(color: C.muted, fontSize: 15),
                ),
              ],
              const SizedBox(height: 18),
              SearchSortBar(
                controller: _search,
                focusNode: _focus,
                hint: 'Найти альбом или исполнителя',
                desc: desc,
                mode: ls.mode,
                onMode: (m) {
                  if (m == ls.mode) return;
                  ListSort(m, ListSort.defaultDesc(m)).write(app.settings, sortId);
                  app.lib.saveSettings();
                  setState(() {});
                },
                onChanged: (v) => setState(() => _query = v),
                onToggleSort: () {
                  ListSort(ls.mode, !desc).write(app.settings, sortId);
                  app.lib.saveSettings();
                  setState(() {});
                },
                filter: UploaderFilterButton(
                  people: uploadersOf(every.expand((a) => a.tracks)),
                  chosen: by,
                  onChanged: (v) {
                    saveUploaderFilter(app, sortId, v);
                    setState(() {});
                  },
                ),
                trailing: ViewControls(prefs: prefs, onChanged: () => setState(() {})),
              ),
            ],
          ]),
        );
        if (every.isEmpty) {
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
                child: Text(q.isEmpty ? 'Среди выбранных людей альбомов нет' : 'Ничего не нашлось по запросу «$_query»', style: const TextStyle(color: C.muted)),
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
                      return TileInk(
                        onTap: () => NavScope.of(context).go(Nav('album', a.key)),
                        onPlay: () => Services.of(context).player.playTracks(a.tracks, 0, inOrder: true),
                        // Правый клик: меню альбома
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

/// Меню альбома по правому клику, в точке клика
Future<void> showAlbumMenu(BuildContext context, Album a, Offset at) => showCollectionMenu(context, at, album: a);
