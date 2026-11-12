import 'package:flutter/material.dart';

import '../app.dart';
import '../core/store.dart' show Settings;
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

String _tabCode(Nav n) => '${n.kind}|${n.id ?? ''}';

/// Вкладка «Медиатеки», открытая в прошлый раз (хранится в настройках на этом компьютере)
Nav lastLibraryTab(Settings settings) {
  final raw = settings.view['library.tab'];
  if (raw != null) {
    for (final (_, nav) in libraryTabs) {
      if (_tabCode(nav) == raw) return nav;
    }
  }
  return const Nav('all');
}

/// Запоминает вкладку, на которую перешли; false — вкладка не менялась
bool rememberLibraryTab(Settings settings, Nav n) {
  if (!libraryTabs.any((t) => t.$2.same(n))) return false;
  final code = _tabCode(n);
  if (settings.view['library.tab'] == code) return false;
  settings.view['library.tab'] = code;
  return true;
}

/// Страница — одна из вкладок медиатеки
bool isLibraryTab(Nav n) => libraryTabs.any((t) => t.$2.same(n)) || (n.kind == 'albums' && n.id == null);

/// Верхний отступ страницы: у вкладки «Медиатеки» — 18 под рядом вкладок, у отдельной страницы — 34 от верха окна
double pageTop(BuildContext context) => LibraryFrame.on(context) ? 18 : 34;

/// Сообщает страницам, что они внутри «Медиатеки»: свой большой заголовок им не нужен
class LibraryFrame extends InheritedWidget {
  const LibraryFrame({super.key, required super.child});

  static bool on(BuildContext context) => context.dependOnInheritedWidgetOfExactType<LibraryFrame>() != null;

  @override
  bool updateShouldNotify(LibraryFrame oldWidget) => false;
}

/// «Медиатека» сверху и ряд вкладок под ней, под ними — выбранная страница
class LibraryTabsPage extends StatefulWidget {
  final Nav current;
  final bool compact;
  final Widget child;
  const LibraryTabsPage({super.key, required this.current, required this.compact, required this.child});

  @override
  State<LibraryTabsPage> createState() => _LibraryTabsPageState();
}

class _LibraryTabsPageState extends State<LibraryTabsPage> {
  final _body = GlobalKey();

  /// Повторный клик по открытой вкладке: список плавно возвращается к началу
  void _toTop() {
    final root = _body.currentContext;
    if (root == null) return;
    void visit(Element e) {
      if (e.widget is Scrollable) {
        final st = (e as StatefulElement).state as ScrollableState;
        final pos = st.position;
        final vertical = st.axisDirection == AxisDirection.down || st.axisDirection == AxisDirection.up;
        if (vertical && pos.pixels > pos.minScrollExtent + 1) {
          final far = (pos.pixels - pos.minScrollExtent).abs();
          pos.animateTo(pos.minScrollExtent,
              duration: Duration(milliseconds: (220 + far / 6).clamp(220, 650).round()), curve: Curves.easeOutCubic);
        }
      }
      e.visitChildren(visit);
    }

    (root as Element).visitChildren(visit);
  }

  @override
  Widget build(BuildContext context) {
    final current = widget.current, compact = widget.compact, child = widget.child;
    final nav = NavScope.of(context);
    final pad = compact ? 20.0 : 36.0;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: EdgeInsets.fromLTRB(pad, 34, pad, 0),
        child: Text('Медиатека', style: display(36, weight: FontWeight.w700)),
      ),
      // Сколько в библиотеке: сразу под заголовком, а ниже уже вкладки
      Padding(
        padding: EdgeInsets.fromLTRB(pad, 10, pad, 0),
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
      const SizedBox(height: 18),
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
                  onTap: () => target.same(current) ? _toTop() : nav.go(target),
                ),
              ),
          ],
        ),
      ),
      Expanded(
        // Страница обрезается по верхнему краю: при прокрутке не наезжает на вкладки.
        // Свой слой подсветки внутри обрезки: иначе подсветка плитки, ушедшей под вкладки, рисуется поверх заголовка
        child: ClipRect(key: _body, child: Material(type: MaterialType.transparency, child: LibraryFrame(child: child))),
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
        onTap: onTap,
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
