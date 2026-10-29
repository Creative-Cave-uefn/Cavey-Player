import 'package:flutter/material.dart';

import '../app.dart';
import 'shell.dart';
import 'theme.dart';
import 'widgets.dart';

class AlbumsPage extends StatelessWidget {
  const AlbumsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    return ListenableBuilder(
      listenable: app.lib,
      builder: (context, _) {
        final albums = app.lib.albums;
        final pad = MediaQuery.sizeOf(context).width < 860 ? 20.0 : 36.0;
        final header = Padding(
          padding: EdgeInsets.fromLTRB(pad, 34, pad, 22),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Альбомы', style: display(36, weight: FontWeight.w700)),
            if (albums.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text('${albums.length} ${plural(albums.length, 'альбом', 'альбома', 'альбомов')}',
                  style: const TextStyle(color: C.muted, fontSize: 15)),
            ],
          ]),
        );
        if (albums.isEmpty) {
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
          SliverPadding(
            padding: EdgeInsets.fromLTRB(pad, 0, pad, 32),
            sliver: SliverGrid(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 200,
                mainAxisSpacing: 22,
                crossAxisSpacing: 20,
                childAspectRatio: 0.74,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, i) {
                  final a = albums[i];
                  return InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => NavScope.of(context).go(Nav('album', a.key)),
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
                childCount: albums.length,
              ),
            ),
          ),
        ]);
      },
    );
  }
}
