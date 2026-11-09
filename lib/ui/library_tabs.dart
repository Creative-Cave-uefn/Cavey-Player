import 'package:flutter/material.dart';

import '../app.dart';
import 'shell.dart';
import 'theme.dart';
import 'widgets.dart';

/// Вкладки «Медиатеки»: заголовок остаётся на месте, меняется только содержимое под ним
const libraryTabs = <(String, Nav)>[
  ('Главная', Nav('all')),
  ('Все песни', Nav('songs')),
  ('Альбомы', Nav('albums')),
  ('Синглы и EP', Nav('albums', 'ep')),
  ('Исполнители', Nav('artists')),
  ('Плейлисты', Nav('playlists')),
  ('Коллекция', Nav('collection')),
  ('Недавно добавленное', Nav('recent')),
];

/// Страница — одна из вкладок медиатеки
bool isLibraryTab(Nav n) => libraryTabs.any((t) => t.$2.same(n)) || (n.kind == 'albums' && n.id == null);

/// Сообщает страницам, что они внутри «Медиатеки»: свой большой заголовок им не нужен
class LibraryFrame extends InheritedWidget {
  const LibraryFrame({super.key, required super.child});

  static bool on(BuildContext context) => context.dependOnInheritedWidgetOfExactType<LibraryFrame>() != null;

  @override
  bool updateShouldNotify(LibraryFrame oldWidget) => false;
}

/// «Медиатека» сверху и ряд вкладок под ней, под ними — выбранная страница
class LibraryTabsPage extends StatelessWidget {
  final Nav current;
  final bool compact;
  final Widget child;
  const LibraryTabsPage({super.key, required this.current, required this.compact, required this.child});

  @override
  Widget build(BuildContext context) {
    final nav = NavScope.of(context);
    final pad = compact ? 20.0 : 36.0;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: EdgeInsets.fromLTRB(pad, 18, pad, 0),
        child: Text('Медиатека', style: display(compact ? 30 : 36, weight: FontWeight.w700)),
      ),
      // Сколько в библиотеке: сразу под заголовком, а ниже уже вкладки
      Padding(
        padding: EdgeInsets.fromLTRB(pad, 8, pad, 0),
        child: ListenableBuilder(
          listenable: Services.of(context).lib,
          builder: (context, _) {
            final lib = Services.of(context).lib;
            final tracks = lib.allTracks;
            if (tracks.isEmpty) return const SizedBox.shrink();
            final albums = lib.albums.length;
            final artists = lib.artists.length;
            return Text(
              '${countTracks(tracks.length)} · $albums ${plural(albums, 'альбом', 'альбома', 'альбомов')} · '
              '$artists ${plural(artists, 'исполнитель', 'исполнителя', 'исполнителей')}',
              style: const TextStyle(color: C.muted, fontSize: 15),
            );
          },
        ),
      ),
      const SizedBox(height: 14),
      SizedBox(
        height: 38,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: EdgeInsets.symmetric(horizontal: pad),
          children: [
            for (final (label, target) in libraryTabs)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: _Tab(
                  label: label,
                  selected: target.same(current),
                  onTap: () => nav.go(target),
                ),
              ),
          ],
        ),
      ),
      Expanded(
        // Страница обрезается по верхнему краю: при прокрутке не наезжает на вкладки.
        // Свой слой подсветки внутри обрезки: иначе подсветка плитки, ушедшей под вкладки, рисуется поверх заголовка
        child: ClipRect(child: Material(type: MaterialType.transparency, child: LibraryFrame(child: child))),
      ),
    ]);
  }
}

class _Tab extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _Tab({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? C.text : C.raised,
      shape: StadiumBorder(side: BorderSide(color: selected ? C.text : C.line)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: selected ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? C.bg : C.text,
              fontSize: 14,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}
