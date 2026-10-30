import 'dart:async';

import 'package:flutter/gestures.dart' show kBackMouseButton, kForwardMouseButton;
import 'package:flutter/material.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/services.dart';

import '../app.dart';
import '../core/log.dart';
import '../core/models.dart';
import '../core/updater.dart';
import 'accounts_view.dart';
import 'ambient.dart';
import 'albums_view.dart';
import 'company_view.dart';
import 'download_view.dart';
import 'library_views.dart';
import 'lyrics_panel.dart';
import 'player_bar.dart';
import 'playlists_view.dart';
import 'profile_view.dart';
import 'sources_view.dart';
import 'theme.dart';
import 'tracks_view.dart';
import 'web_pages.dart';
import 'web_views.dart';
import 'wave_view.dart';
import 'widgets.dart';

class Nav {
  final String kind; // all, albums, album, liked, playlist, sources, accounts
  final String? id;
  const Nav(this.kind, [this.id]);
  bool same(Nav o) => o.kind == kind && o.id == id;
}

/// Куда смотрим сейчас и история переходов — как в браузере: назад и вперёд
/// боковыми кнопками мыши, Alt+← / Alt+→ или стрелками над страницей
class NavController extends ValueNotifier<Nav> {
  NavController() : super(const Nav('all'));
  final List<Nav> _back = [];
  final List<Nav> _forward = [];

  bool get canBack => _back.isNotEmpty;
  bool get canForward => _forward.isNotEmpty;

  void go(Nav n) {
    if (n.same(value)) return;
    _back.add(value);
    if (_back.length > 60) _back.removeAt(0);
    _forward.clear();
    value = n;
  }

  void back() {
    if (_back.isEmpty) return;
    _forward.add(value);
    value = _back.removeLast();
  }

  void forward() {
    if (_forward.isEmpty) return;
    _back.add(value);
    value = _forward.removeLast();
  }
}

class NavScope extends InheritedWidget {
  final NavController nav;
  const NavScope({super.key, required this.nav, required super.child});
  static NavController of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<NavScope>()!.nav;
  @override
  bool updateShouldNotify(NavScope oldWidget) => oldWidget.nav != nav;
}

class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  final _nav = NavController();
  StreamSubscription<String>? _msgs;
  bool _dragging = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _msgs ??= Services.of(context).lib.messages.stream.listen((m) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(m), duration: const Duration(seconds: 4)));
    });
  }

  @override
  void dispose() {
    _msgs?.cancel();
    _nav.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    return NavScope(
      nav: _nav,
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (e) {
          if (e.buttons & kBackMouseButton != 0) _nav.back();
          if (e.buttons & kForwardMouseButton != 0) _nav.forward();
        },
        child: Focus(
        onKeyEvent: (node, e) => _onKey(e),
        child: Focus(
          autofocus: true,
          child: DropTarget(
            onDragEntered: (_) => setState(() => _dragging = true),
            onDragExited: (_) => setState(() => _dragging = false),
            onDragDone: (detail) {
              AppLog.info('Перетащили в окно: ${detail.files.length}');
              setState(() => _dragging = false);
              uploadPaths(context, [for (final f in detail.files) f.path]);
            },
            child: Stack(children: [
          const Positioned.fill(child: AmbientBackground()),
          Scaffold(
            backgroundColor: Colors.transparent,
            body: LayoutBuilder(builder: (context, box) {
              final compact = box.maxWidth < 860;
              // Стекло: боковая панель плавает слева, справа содержимое и капсула плеера под ним
              return Row(children: [
                Padding(padding: const EdgeInsets.fromLTRB(12, 12, 0, 12), child: _Sidebar(compact: compact)),
                Expanded(
                  child: Column(children: [
                Expanded(
                  child: Row(children: [
                    Expanded(
                      child: ValueListenableBuilder<Nav>(
                        valueListenable: _nav,
                        builder: (context, nav, _) => Stack(children: [
                          Positioned.fill(child: _content(nav, compact)),
                          Positioned(
                            top: 4,
                            left: compact ? 6 : 14,
                            child: Row(children: [
                              _HistoryButton(
                                icon: Icons.chevron_left_rounded,
                                tooltip: 'Назад (Alt+←)',
                                onPressed: _nav.canBack ? _nav.back : null,
                              ),
                              _HistoryButton(
                                icon: Icons.chevron_right_rounded,
                                tooltip: 'Вперёд (Alt+→)',
                                onPressed: _nav.canForward ? _nav.forward : null,
                              ),
                            ]),
                          ),
                        ]),
                      ),
                    ),
                    ValueListenableBuilder<bool>(
                      valueListenable: app.player.lyricsOpen,
                      builder: (context, open, _) => open ? const LyricsPanel() : const SizedBox.shrink(),
                    ),
                  ]),
                ),
                PlayerBar(compact: compact),
                  ]),
                ),
              ]);
            }),
          ),
              if (_dragging) const Positioned.fill(child: IgnorePointer(child: _DropOverlay())),
            ]),
          ),
        ),
      ),
      ),
    );
  }

  /// Курсор в поле ввода: буквы, пробел и стрелки нужны тексту, а не плееру
  static bool _typing() {
    final ctx = FocusManager.instance.primaryFocus?.context;
    if (ctx == null) return false;
    return ctx.widget is EditableText || ctx.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  KeyEventResult _onKey(KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final app = Services.of(context);
    final p = app.player;
    final k = e.logicalKey;
    final kb = HardwareKeyboard.instance;
    final ctrl = kb.isControlPressed || kb.isMetaPressed;
    final plain = !ctrl && !kb.isAltPressed && !kb.isShiftPressed;
    final repeat = e is KeyRepeatEvent;

    void Function()? action;
    // Медиаклавиши и сочетания с Ctrl работают всегда
    if (k == LogicalKeyboardKey.mediaPlayPause && !repeat) action = p.toggle;
    if (k == LogicalKeyboardKey.mediaTrackNext && !repeat) action = p.next;
    if (k == LogicalKeyboardKey.mediaTrackPrevious && !repeat) action = p.previous;
    if (ctrl && k == LogicalKeyboardKey.arrowRight && !repeat) action = p.next;
    if (ctrl && k == LogicalKeyboardKey.arrowLeft && !repeat) action = p.previous;
    if (ctrl && k == LogicalKeyboardKey.keyF && !repeat) action = () => searchRequests.value++;
    if (kb.isAltPressed && !ctrl && k == LogicalKeyboardKey.arrowLeft && !repeat) action = _nav.back;
    if (kb.isAltPressed && !ctrl && k == LogicalKeyboardKey.arrowRight && !repeat) action = _nav.forward;
    if (k == LogicalKeyboardKey.browserBack && !repeat) action = _nav.back;
    if (k == LogicalKeyboardKey.browserForward && !repeat) action = _nav.forward;

    if (action == null && plain && !_typing()) {
      if (k == LogicalKeyboardKey.space && !repeat) action = p.toggle;
      if (k == LogicalKeyboardKey.arrowRight) action = () => p.seekBy(const Duration(seconds: 10));
      if (k == LogicalKeyboardKey.arrowLeft) action = () => p.seekBy(const Duration(seconds: -10));
      if (k == LogicalKeyboardKey.arrowUp) action = () => p.setVolume(p.volume + 5, save: true);
      if (k == LogicalKeyboardKey.arrowDown) action = () => p.setVolume(p.volume - 5, save: true);
      if (k == LogicalKeyboardKey.keyM && !repeat) action = p.toggleMute;
      if (k == LogicalKeyboardKey.keyL && !repeat) {
        action = () {
          final t = p.current;
          if (t == null) return;
          app.lib.toggleLike(t.id);
          app.lib.messages.add(app.lib.isLiked(t.id) ? '«${t.title}» в любимом' : '«${t.title}» убран из любимого');
        };
      }
    }
    if (action == null) return KeyEventResult.ignored;
    action();
    return KeyEventResult.handled;
  }

  Widget _content(Nav nav, bool compact) {
    switch (nav.kind) {
      case 'playlists':
        return PlaylistsPage(key: const ValueKey('playlists'), compact: compact);
      case 'albums':
        return const AlbumsPage(key: ValueKey('albums'));
      case 'album':
        return AlbumPage(key: ValueKey('album:${nav.id}'), albumKey: nav.id!, compact: compact);
      case 'liked':
        return LikedPage(key: const ValueKey('liked'), compact: compact);
      case 'playlist':
        return PlaylistPage(key: ValueKey('pl:${nav.id}'), playlistId: nav.id!, compact: compact);
      case 'download':
        return DownloadPage(key: const ValueKey('download'), compact: compact);
      case 'company':
        return CompanyPage(key: const ValueKey('company'), compact: compact);
      case 'artists':
        return ArtistsPage(key: const ValueKey('artists'), compact: compact);
      case 'artist':
        return ArtistProfilePage(key: ValueKey('artist:${nav.id}'), artistKey: nav.id!, compact: compact);
      case 'artistTracks':
        return ArtistPage(key: ValueKey('artistTracks:${nav.id}'), artistKey: nav.id!, compact: compact);
      case 'user':
        return UserProfilePage(key: ValueKey('user:${nav.id}'), email: nav.id!, compact: compact);
      case 'userLikes':
      case 'userUploads':
        return UserTracksPage(key: ValueKey('${nav.kind}:${nav.id}'), email: nav.id!, uploads: nav.kind == 'userUploads', compact: compact);
      case 'recent':
        return RecentPage(key: const ValueKey('recent'), compact: compact);
      case 'wave':
        return WavePage(key: const ValueKey('wave'), compact: compact);
      case 'new':
        return NewReleasesPage(key: const ValueKey('new'), compact: compact);
      case 'websearch':
        return WebSearchPage(key: const ValueKey('websearch'), compact: compact);
      case 'webartist':
        return WebArtistPage(key: ValueKey('webartist:${nav.id}'), artistId: int.tryParse(nav.id ?? '') ?? 0, compact: compact);
      case 'webalbum':
        return WebAlbumPage(key: ValueKey('webalbum:${nav.id}'), albumId: int.tryParse(nav.id ?? '') ?? 0, compact: compact);
      case 'websection':
        final parts = (nav.id ?? '').split(':');
        return WebSectionPage(
          key: ValueKey('websection:${nav.id}'),
          artistId: int.tryParse(parts.first) ?? 0,
          kind: parts.length > 1 ? parts[1] : 'album',
          compact: compact,
        );
      case 'duplicates':
        return const DuplicatesPage(key: ValueKey('duplicates'));
      case 'sources':
        return const SourcesPage(key: ValueKey('sources'));
      case 'accounts':
        return const AccountsPage(key: ValueKey('accounts'));
      default:
        return AllTracksPage(key: const ValueKey('all'), compact: compact);
    }
  }
}

class _Sidebar extends StatelessWidget {
  final bool compact;
  const _Sidebar({required this.compact});

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final nav = NavScope.of(context);
    return Container(
      width: compact ? 72 : 240,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(24), border: Border.all(color: C.line)),
      child: ListenableBuilder(
        listenable: Listenable.merge([app.lib, nav, app.downloads, app.social]),
        builder: (context, _) {
          final lib = app.lib;
          final cur = nav.value;
          Widget item(IconData icon, String label, Nav target, {Widget? trailing}) => _NavItem(
                icon: icon,
                label: label,
                compact: compact,
                selected: cur.same(target),
                trailing: trailing,
                onTap: () => nav.go(target),
              );

          final mode = app.settings.viewOf('sidebar.playlists', 'list'); // list | covers | both
          final head = <Widget>[
            Padding(
              padding: EdgeInsets.fromLTRB(compact ? 0 : 22, 26, 0, 22),
              child: compact
                  ? Center(child: Text('C', style: brand(24, color: C.accent)))
                  : const Align(alignment: Alignment.centerLeft, child: Wordmark()),
            ),
            item(Icons.waves_rounded, 'Моя волна', const Nav('wave'), trailing: waveSidebarMark(context)),
            item(Icons.library_music_outlined, 'Все треки', const Nav('all')),
            item(Icons.album_outlined, 'Альбомы', const Nav('albums')),
            item(Icons.mic_none_rounded, 'Исполнители', const Nav('artists')),
            item(Icons.schedule_rounded, 'Недавно добавленные', const Nav('recent')),
            item(Icons.new_releases_outlined, 'Новинки', const Nav('new')),
            item(Icons.travel_explore_rounded, 'Поиск в интернете', const Nav('websearch')),
            item(Icons.cloud_download_outlined, 'Скачать', const Nav('download'),
                trailing: app.downloads.busy
                    ? const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2))
                    : null),
            item(Icons.favorite_border_rounded, 'Любимое', const Nav('liked')),
            item(Icons.groups_outlined, 'Компания', const Nav('company')),
            if (lib.me != null) item(Icons.person_outline_rounded, 'Моя страница', Nav('user', lib.me)),
            NowListeningSidebar(compact: compact),
            const SizedBox(height: 18),
            _PlaylistsHeader(compact: compact, selected: cur.same(const Nav('playlists')), mode: mode),
          ];

          final playlists = <Widget>[
            if (mode == 'covers')
              _PlaylistTiles(compact: compact, current: cur)
            else
              for (final p in lib.data.playlists)
                _PlaylistRow(
                  playlist: p,
                  compact: compact,
                  selected: cur.same(Nav('playlist', p.id)),
                  withCover: mode == 'both',
                  onTap: () => nav.go(Nav('playlist', p.id)),
                ),
            if (lib.data.playlists.isEmpty && !compact)
              const Padding(
                padding: EdgeInsets.fromLTRB(22, 4, 16, 0),
                child: Text('Пока пусто. Плейлисты видят все друзья.', style: TextStyle(color: C.faint, fontSize: 13, height: 1.4)),
              ),
          ];

          final foot = <Widget>[
            const Divider(height: 1),
            const SizedBox(height: 8),
            item(Icons.folder_shared_outlined, 'Папки с музыкой', const Nav('sources'),
                trailing: lib.scan.running
                    ? const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2))
                    : null),
            item(Icons.settings_outlined, 'Настройки', const Nav('accounts'),
                trailing: app.accounts.accounts.any((a) => a.needsSignIn)
                    ? const Icon(Icons.error_outline_rounded, size: 16, color: C.danger)
                    : null),
            _SyncLine(compact: compact),
            UploadLine(compact: compact),
            _UpdateLine(compact: compact),
            const SizedBox(height: 10),
          ];

          return LayoutBuilder(builder: (context, box) {
            // Сколько места нужно, чтобы верх и низ панели стояли на месте, а прокручивались только плейлисты.
            // Оценка с запасом; если места меньше, прокручивается вся панель целиком
            final live = app.social.friends.where((m) => m.live).length.clamp(0, 5);
            final need = 864 + (live > 0 ? 40 + 44 * live : 0) + (app.social.following != null ? 36 : 0);
            if (box.maxHeight >= need) {
              return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                ...head,
                Expanded(child: ListView(padding: EdgeInsets.zero, children: playlists)),
                ...foot,
              ]);
            }
            return SingleChildScrollView(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [...head, ...playlists, const SizedBox(height: 12), ...foot]),
            );
          });
        },
      ),
    );
  }
}

Future<void> newPlaylistFlow(BuildContext context) async {
  final app = Services.of(context);
  final nav = NavScope.of(context);
  final name = await askText(context, title: 'Новый плейлист', action: 'Создать', hint: 'Название');
  if (name == null || name.isEmpty) return;
  final id = app.lib.createPlaylist(name);
  nav.go(Nav('playlist', id));
}

/// «Плейлисты»: заголовок — ссылка на страницу со всеми плейлистами; рядом выбор вида и «+»
class _PlaylistsHeader extends StatelessWidget {
  final bool compact;
  final bool selected;
  final String mode;
  const _PlaylistsHeader({required this.compact, required this.selected, required this.mode});

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final nav = NavScope.of(context);
    if (compact) {
      return Column(children: [
        IconButton(
          tooltip: 'Все плейлисты',
          icon: Icon(Icons.queue_music_rounded, color: selected ? C.accent : C.muted),
          onPressed: () => nav.go(const Nav('playlists')),
        ),
        IconButton(
          tooltip: 'Новый плейлист',
          icon: const Icon(Icons.playlist_add_rounded),
          onPressed: () => newPlaylistFlow(context),
        ),
      ]);
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 4, 4),
      child: Row(children: [
        Expanded(
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => nav.go(const Nav('playlists')),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
              child: Row(children: [
                Text('Плейлисты',
                    style: TextStyle(color: selected ? C.text : C.muted, fontSize: 13, fontWeight: selected ? FontWeight.w600 : FontWeight.w400)),
                const SizedBox(width: 2),
                Icon(Icons.chevron_right_rounded, size: 18, color: selected ? C.accent : C.faint),
              ]),
            ),
          ),
        ),
        PopupMenuButton<String>(
          tooltip: 'Вид плейлистов',
          icon: Icon(
            switch (mode) { 'covers' => Icons.grid_view_rounded, 'both' => Icons.view_agenda_outlined, _ => Icons.view_list_rounded },
            size: 18,
          ),
          onSelected: (v) {
            app.settings.view['sidebar.playlists'] = v;
            app.lib.viewChanged();
          },
          itemBuilder: (_) => [
            for (final o in const [('list', 'Списком'), ('covers', 'Обложками'), ('both', 'Обложки и названия')])
              CheckedPopupMenuItem(value: o.$1, checked: mode == o.$1, child: Text(o.$2)),
          ],
        ),
        IconButton(
          tooltip: 'Новый плейлист',
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.add_rounded, size: 20),
          onPressed: () => newPlaylistFlow(context),
        ),
      ]),
    );
  }
}

/// Строка плейлиста в боковой панели; с миниатюрой обложки или со значком
class _PlaylistRow extends StatelessWidget {
  final Playlist playlist;
  final bool compact;
  final bool selected;
  final bool withCover;
  final VoidCallback onTap;
  const _PlaylistRow({required this.playlist, required this.compact, required this.selected, required this.withCover, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = playlist;
    if (!withCover) {
      return _NavItem(
        icon: Icons.queue_music_rounded,
        label: p.name,
        compact: compact,
        selected: selected,
        leading: FriendDot(p.by, size: 7),
        onTap: onTap,
      );
    }
    final color = selected ? C.text : C.muted;
    final body = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        height: 46,
        padding: EdgeInsets.symmetric(horizontal: compact ? 0 : 8),
        decoration: BoxDecoration(color: selected ? C.raised : null, borderRadius: BorderRadius.circular(8)),
        child: Row(
          mainAxisAlignment: compact ? MainAxisAlignment.center : MainAxisAlignment.start,
          children: [
            PlaylistCover(playlist: p, size: 34, radius: 5),
            if (!compact) ...[
              const SizedBox(width: 12),
              Expanded(
                child: Text(p.name,
                    overflow: TextOverflow.ellipsis, style: TextStyle(color: color, fontWeight: selected ? FontWeight.w600 : FontWeight.w400)),
              ),
              FriendDot(p.by, size: 7),
              const SizedBox(width: 4),
            ],
          ],
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
      child: compact ? Tooltip(message: p.name, child: body) : body,
    );
  }
}

/// Плейлисты плитками из обложек: по две в ряд, в узкой панели по одной
class _PlaylistTiles extends StatelessWidget {
  final bool compact;
  final Nav current;
  const _PlaylistTiles({required this.compact, required this.current});

  @override
  Widget build(BuildContext context) {
    final lib = Services.of(context).lib;
    final nav = NavScope.of(context);
    final lists = lib.data.playlists;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: compact ? 14 : 14, vertical: 2),
      child: LayoutBuilder(builder: (context, box) {
        final cols = compact ? 1 : 2;
        const gap = 10.0;
        final w = (box.maxWidth - gap * (cols - 1)) / cols;
        return Wrap(spacing: gap, runSpacing: 10, children: [
          for (final p in lists)
            SizedBox(
              width: w,
              child: Tooltip(
                message: p.name,
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => nav.go(Nav('playlist', p.id)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    DecoratedBox(
                      position: DecorationPosition.foreground,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        border: current.same(Nav('playlist', p.id)) ? Border.all(color: C.accent, width: 2) : null,
                      ),
                      child: PlaylistCover(playlist: p, size: w, radius: 8),
                    ),
                    if (!compact) ...[
                      const SizedBox(height: 4),
                      Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.muted, fontSize: 12)),
                    ],
                  ]),
                ),
              ),
            ),
        ]);
      }),
    );
  }
}

/// Готовое обновление: жёлтая плашка внизу боковой панели
class _UpdateLine extends StatelessWidget {
  final bool compact;
  const _UpdateLine({required this.compact});

  @override
  Widget build(BuildContext context) {
    final up = Services.of(context).updater;
    return ListenableBuilder(
      listenable: up,
      builder: (context, _) {
        if (up.state == UpdateState.downloading && !compact) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(22, 10, 16, 0),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Скачиваю версию ${up.latest ?? ''}', style: const TextStyle(fontSize: 12, color: C.faint)),
              const SizedBox(height: 6),
              LinearProgressIndicator(value: up.progress),
            ]),
          );
        }
        if (up.state != UpdateState.ready) return const SizedBox.shrink();
        final button = FilledButton(
          style: FilledButton.styleFrom(
            padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 14, vertical: 10),
            textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          onPressed: up.installNow,
          child: compact ? const Icon(Icons.system_update_alt_rounded, size: 18) : Text('Обновить до ${up.latest}'),
        );
        return Padding(
          padding: EdgeInsets.fromLTRB(compact ? 10 : 16, 12, compact ? 10 : 16, 0),
          child: Tooltip(message: 'Перезапустить Cave Player с новой версией', child: button),
        );
      },
    );
  }
}

class _SyncLine extends StatelessWidget {
  final bool compact;
  const _SyncLine({required this.compact});

  @override
  Widget build(BuildContext context) {
    final lib = Services.of(context).lib;
    final err = lib.syncError;
    if (err == null && !lib.hasUnsavedChanges) return const SizedBox.shrink();
    final text = err != null ? 'Нет связи с Диском' : 'Сохраняю на Диск…';
    final icon = err != null ? Icons.cloud_off_rounded : Icons.cloud_upload_outlined;
    return Tooltip(
      message: err ?? text,
      child: Padding(
        padding: EdgeInsets.fromLTRB(compact ? 0 : 22, 8, 12, 0),
        child: Row(
          mainAxisAlignment: compact ? MainAxisAlignment.center : MainAxisAlignment.start,
          children: [
            Icon(icon, size: 16, color: err != null ? C.danger : C.faint),
            if (!compact) ...[
              const SizedBox(width: 10),
              Text(text, style: TextStyle(fontSize: 12, color: err != null ? C.danger : C.faint)),
            ],
          ],
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final bool compact;
  final VoidCallback onTap;
  final Widget? trailing;
  final Widget? leading;

  const _NavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.compact,
    required this.onTap,
    this.trailing,
    this.leading,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected ? C.text : C.muted;
    final body = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        height: 40,
        padding: EdgeInsets.symmetric(horizontal: compact ? 0 : 12),
        decoration: BoxDecoration(
          color: selected ? C.hover : null,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisAlignment: compact ? MainAxisAlignment.center : MainAxisAlignment.start,
          children: [
            Stack(clipBehavior: Clip.none, children: [
              Icon(icon, size: 20, color: selected ? C.accent : color),
              if (compact && trailing != null) Positioned(right: -8, top: -6, child: trailing!),
            ]),
            if (!compact) ...[
              const SizedBox(width: 14),
              Expanded(
                child: Text(label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: color, fontWeight: selected ? FontWeight.w600 : FontWeight.w400)),
              ),
              if (leading != null) ...[leading!, const SizedBox(width: 4)],
              if (trailing != null) trailing!,
            ],
          ],
        ),
      ),
    );
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: compact ? 10 : 10, vertical: 1),
      child: compact ? Tooltip(message: label, child: body) : body,
    );
  }
}

/// Подсказка, когда над окном тащат файлы
class _DropOverlay extends StatelessWidget {
  const _DropOverlay();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: C.bg.withValues(alpha: 0.86),
      alignment: Alignment.center,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 40),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: C.accent, width: 2),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.upload_rounded, size: 44, color: C.accent),
          const SizedBox(height: 16),
          Text('Отпустите, чтобы загрузить', style: display(22)),
          const SizedBox(height: 8),
          const Text('Музыка уйдёт на Google Диск и появится в библиотеке у всех',
              style: TextStyle(color: C.muted)),
        ]),
      ),
    );
  }
}

/// Маленькая стрелка «назад» / «вперёд» над страницей
class _HistoryButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  const _HistoryButton({required this.icon, required this.tooltip, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      visualDensity: VisualDensity.compact,
      iconSize: 22,
      color: C.muted,
      disabledColor: C.line,
      icon: Icon(icon),
    );
  }
}
