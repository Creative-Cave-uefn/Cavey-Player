import 'dart:async';

import 'package:flutter/material.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/services.dart';

import '../app.dart';
import '../core/log.dart';
import '../core/updater.dart';
import 'accounts_view.dart';
import 'albums_view.dart';
import 'company_view.dart';
import 'download_view.dart';
import 'library_views.dart';
import 'lyrics_panel.dart';
import 'player_bar.dart';
import 'sources_view.dart';
import 'theme.dart';
import 'tracks_view.dart';
import 'widgets.dart';

class Nav {
  final String kind; // all, albums, album, liked, playlist, sources, accounts
  final String? id;
  const Nav(this.kind, [this.id]);
  bool same(Nav o) => o.kind == kind && o.id == id;
}

class NavController extends ValueNotifier<Nav> {
  NavController() : super(const Nav('all'));
  void go(Nav n) => value = n;
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
          Scaffold(
            body: LayoutBuilder(builder: (context, box) {
              final compact = box.maxWidth < 860;
              return Column(children: [
                Expanded(
                  child: Row(children: [
                    _Sidebar(compact: compact),
                    Expanded(
                      child: ValueListenableBuilder<Nav>(
                        valueListenable: _nav,
                        builder: (context, nav, _) => _content(nav, compact),
                      ),
                    ),
                    ValueListenableBuilder<bool>(
                      valueListenable: app.player.lyricsOpen,
                      builder: (context, open, _) => open ? const LyricsPanel() : const SizedBox.shrink(),
                    ),
                  ]),
                ),
                PlayerBar(compact: compact),
              ]);
            }),
          ),
              if (_dragging) const Positioned.fill(child: IgnorePointer(child: _DropOverlay())),
            ]),
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
        return ArtistPage(key: ValueKey('artist:${nav.id}'), artistKey: nav.id!, compact: compact);
      case 'recent':
        return RecentPage(key: const ValueKey('recent'), compact: compact);
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
      width: compact ? 72 : 248,
      decoration: const BoxDecoration(color: C.surface, border: Border(right: BorderSide(color: C.line))),
      child: ListenableBuilder(
        listenable: Listenable.merge([app.lib, nav, app.downloads]),
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
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: EdgeInsets.fromLTRB(compact ? 0 : 22, 26, 0, 22),
              child: compact
                  ? Center(child: Text('C', style: display(24, weight: FontWeight.w700, color: C.accent)))
                  : const Align(alignment: Alignment.centerLeft, child: Wordmark()),
            ),
            item(Icons.library_music_outlined, 'Все треки', const Nav('all')),
            item(Icons.album_outlined, 'Альбомы', const Nav('albums')),
            item(Icons.mic_none_rounded, 'Исполнители', const Nav('artists')),
            item(Icons.schedule_rounded, 'Недавно добавленные', const Nav('recent')),
            item(Icons.cloud_download_outlined, 'Скачать', const Nav('download'),
                trailing: app.downloads.busy
                    ? const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2))
                    : null),
            item(Icons.favorite_border_rounded, 'Любимое', const Nav('liked')),
            item(Icons.groups_outlined, 'Компания', const Nav('company')),
            NowListeningSidebar(compact: compact),
            const SizedBox(height: 18),
            if (!compact)
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 0, 10, 6),
                child: Row(children: [
                  const Expanded(child: Text('Плейлисты', style: TextStyle(color: C.muted, fontSize: 13))),
                  IconButton(
                    tooltip: 'Новый плейлист',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.add_rounded, size: 20),
                    onPressed: () => _newPlaylist(context),
                  ),
                ]),
              )
            else
              IconButton(
                tooltip: 'Новый плейлист',
                icon: const Icon(Icons.playlist_add_rounded),
                onPressed: () => _newPlaylist(context),
              ),
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  for (final p in lib.data.playlists)
                    _NavItem(
                      icon: Icons.queue_music_rounded,
                      label: p.name,
                      compact: compact,
                      selected: cur.same(Nav('playlist', p.id)),
                      leading: FriendDot(p.by, size: 7),
                      onTap: () => nav.go(Nav('playlist', p.id)),
                    ),
                  if (lib.data.playlists.isEmpty && !compact)
                    const Padding(
                      padding: EdgeInsets.fromLTRB(22, 4, 16, 0),
                      child: Text('Пока пусто. Плейлисты видят все друзья.',
                          style: TextStyle(color: C.faint, fontSize: 13, height: 1.4)),
                    ),
                ],
              ),
            ),
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
          ]);
        },
      ),
    );
  }

  Future<void> _newPlaylist(BuildContext context) async {
    final app = Services.of(context);
    final nav = NavScope.of(context);
    final name = await askText(context, title: 'Новый плейлист', action: 'Создать', hint: 'Название');
    if (name == null || name.isEmpty) return;
    final id = app.lib.createPlaylist(name);
    nav.go(Nav('playlist', id));
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
      borderRadius: BorderRadius.circular(8),
      child: Container(
        height: 40,
        padding: EdgeInsets.symmetric(horizontal: compact ? 0 : 12),
        decoration: BoxDecoration(
          color: selected ? C.raised : null,
          borderRadius: BorderRadius.circular(8),
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
