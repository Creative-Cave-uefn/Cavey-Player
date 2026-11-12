import 'package:flutter/material.dart';

import '../app.dart';
import '../core/models.dart';
import 'glass_popup.dart';
import 'list_filter.dart';
import 'shell.dart';
import 'library_tabs.dart';
import 'collection_menu.dart';
import 'theme.dart';
import 'uploader_filter.dart';
import 'widgets.dart';

/// Обложка плейлиста: своя, а если её нет — сетка 2×2 из первых четырёх разных обложек (или обложка первого трека)
class PlaylistCover extends StatelessWidget {
  final Playlist playlist;
  final double size;
  final double radius;
  const PlaylistCover({super.key, required this.playlist, required this.size, this.radius = 8});

  @override
  Widget build(BuildContext context) {
    final lib = Services.of(context).lib;
    final tracks = lib.playlistTracks(playlist.id);
    final own = lib.playlistCover(playlist.id);
    if (own == null) {
      final grid = gridCoverTracks(tracks);
      if (grid.length == 4) return CoverGrid(tracks: grid, size: size, radius: radius);
    }
    Track? t;
    for (final x in tracks) {
      if (x.hasCover) {
        t = x;
        break;
      }
    }
    t ??= tracks.isEmpty ? null : tracks.first;
    return CoverImage(track: t, fileId: lib.playlistCover(playlist.id), label: playlist.name, size: size, radius: radius);
  }
}

/// Страница «Плейлисты»: все плейлисты компании обложками или списком
class PlaylistsPage extends StatefulWidget {
  final bool compact;
  const PlaylistsPage({super.key, required this.compact});

  @override
  State<PlaylistsPage> createState() => _PlaylistsPageState();
}

class _PlaylistsPageState extends State<PlaylistsPage> {
  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final pad = widget.compact ? 20.0 : 36.0;
    return ListenableBuilder(
      listenable: app.lib,
      builder: (context, _) {
        final lib = app.lib;
        final all = lib.visiblePlaylists;
        // Фильтр по авторам и сортировка запоминаются на этом компьютере
        final chosenAuthors = loadUploaderFilter(app.settings, 'playlists');
        final sort = ListSort.read(app.settings, 'playlists');
        int by(Playlist a, Playlist b) {
          final c = switch (sort.mode) {
            'count' => a.items.length.compareTo(b.items.length),
            'date' => a.createdAt.compareTo(b.createdAt),
            'author' => lib.firstNameOf(a.by).toLowerCase().compareTo(lib.firstNameOf(b.by).toLowerCase()),
            _ => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          };
          final r = c != 0 ? c : a.name.toLowerCase().compareTo(b.name.toLowerCase());
          final d = sort.desc ? -r : r;
          return d != 0 ? d : a.id.compareTo(b.id);
        }

        final lists = [for (final p in all) if (passesUploaders(chosenAuthors, p.by)) p]..sort(by);
        final authorCounts = <String, int>{};
        for (final p in all) {
          final who = p.by.trim().toLowerCase();
          if (who.isNotEmpty) authorCounts[who] = (authorCounts[who] ?? 0) + 1;
        }
        final authors = [
          for (final e in authorCounts.entries) Uploader(e.key, e.value),
        ]..sort((a, b) => b.count != a.count ? b.count.compareTo(a.count) : a.email.compareTo(b.email));
        void save() {
          app.lib.saveSettings();
          setState(() {});
        }

        final prefs = ViewPrefs(app.settings, 'playlists', defaultGrid: true, gridDef: 180, listDef: 60, listMin: 48, listMax: 96);
        final header = Padding(
          padding: EdgeInsets.fromLTRB(pad, pageTop(context), pad, 18),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (!LibraryFrame.on(context)) ...[
              Text('Плейлисты', style: display(36, weight: FontWeight.w700)),
              const SizedBox(height: 10),
              Text('${lists.length} ${plural(lists.length, 'плейлист', 'плейлиста', 'плейлистов')}',
                  style: const TextStyle(color: C.muted, fontSize: 15)),
              const SizedBox(height: 18),
            ],
            // Кнопки той же высоты и с теми же отступами, что и во вкладке «Все песни»; «Автор» — справа у края
            uniformControls(
              context,
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: Wrap(spacing: 12, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    FilledButton.icon(
                      onPressed: () => newPlaylistFlow(context),
                      icon: const Icon(Icons.add_rounded, size: 20),
                      label: const Text('Новый плейлист'),
                    ),
                    GlassMenuButton<String>(
                      tooltip: 'Сортировка',
                      icon: const Icon(Icons.sort_rounded, size: 20),
                      onSelected: (m) {
                        ListSort(m, ListSort.defaultDesc(m)).write(app.settings, 'playlists');
                        save();
                      },
                      itemBuilder: (_) => [
                        for (final (id, label) in const [
                          ('name', 'По названию'),
                          ('count', 'По числу треков'),
                          ('date', 'По дате создания'),
                          ('author', 'По автору'),
                        ])
                          PopupMenuItem(
                            value: id,
                            child: Row(children: [
                              SizedBox(width: 22, child: sort.mode == id ? Icon(Icons.check_rounded, size: 16, color: C.accent) : null),
                              Text(label),
                            ]),
                          ),
                      ],
                    ),
                    OutlinedButton.icon(
                      onPressed: () {
                        ListSort(sort.mode, !sort.desc).write(app.settings, 'playlists');
                        save();
                      },
                      icon: Icon(sort.desc ? Icons.arrow_downward_rounded : Icons.arrow_upward_rounded, size: 16),
                      label: Text(switch (sort.mode) {
                        'count' => sort.desc ? 'Больше' : 'Меньше',
                        'date' => sort.desc ? 'Новые' : 'Старые',
                        _ => sort.desc ? 'Я–А' : 'А–Я',
                      }),
                    ),
                    ViewControls(prefs: prefs, onChanged: () => setState(() {})),
                  ]),
                ),
                if (authors.length > 1) ...[
                  const SizedBox(width: 12),
                  UploaderFilterButton(
                    title: 'Автор',
                    people: authors,
                    chosen: chosenAuthors,
                    onChanged: (v) {
                      saveUploaderFilter(app, 'playlists', v);
                      setState(() {});
                    },
                  ),
                ],
              ]),
            ),
          ]),
        );
        if (lists.isEmpty) {
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            header,
            const Expanded(
              child: EmptyState(
                icon: Icons.queue_music_rounded,
                title: 'Плейлистов пока нет',
                text: 'Создайте первый: его увидят все друзья.',
              ),
            ),
          ]);
        }
        String sub(Playlist p) => '${lib.firstNameOf(p.by)} · ${countTracks(p.items.length)}';
        return CustomScrollView(key: const PageStorageKey('library:playlists'), slivers: [
          SliverToBoxAdapter(child: header),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(pad, 0, pad, 32),
            sliver: prefs.grid
                ? AdaptiveGridSliver(
                    tile: prefs.size,
                    extra: 58,
                    count: lists.length,
                    builder: (context, i) {
                      final p = lists[i];
                      return TileInk(
                        onTap: () => NavScope.of(context).go(Nav('playlist', p.id)),
                        onPlay: () {
                          final app = Services.of(context);
                          final list = app.lib.playlistTracks(p.id);
                          if (list.isNotEmpty) app.player.playTracks(list, 0);
                        },
                        onSecondaryTapUp: (d) => showCollectionMenu(context, d.globalPosition, playlist: p),
                        child: LayoutBuilder(
                          builder: (context, box) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            PlaylistCover(playlist: p, size: box.maxWidth, radius: 10),
                            const SizedBox(height: 10),
                            Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                            const SizedBox(height: 3),
                            Text(sub(p), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.muted, fontSize: 13)),
                          ]),
                        ),
                      );
                    },
                  )
                : SliverFixedExtentList(
                    itemExtent: prefs.size,
                    delegate: SliverChildBuilderDelegate(
                      (context, i) {
                        final p = lists[i];
                        return InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: () => NavScope.of(context).go(Nav('playlist', p.id)),
                          onSecondaryTapUp: (d) => showCollectionMenu(context, d.globalPosition, playlist: p),
                          child: Padding(
                            padding: const EdgeInsets.all(6),
                            child: Row(children: [
                              PlaylistCover(playlist: p, size: prefs.size - 12, radius: 6),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Text(p.name,
                                    maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                              ),
                              FriendTag(p.by),
                              const SizedBox(width: 16),
                              Text(countTracks(p.items.length), style: const TextStyle(color: C.muted, fontSize: 13)),
                              const SizedBox(width: 8),
                            ]),
                          ),
                        );
                      },
                      childCount: lists.length,
                    ),
                  ),
          ),
        ]);
      },
    );
  }
}
