import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app.dart';
import '../core/updater.dart';
import 'accounts_view.dart';
import 'albums_view.dart';
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
    final player = app.player;
    return NavScope(
      nav: _nav,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.space): player.toggle,
          const SingleActivator(LogicalKeyboardKey.mediaPlayPause): player.toggle,
          const SingleActivator(LogicalKeyboardKey.mediaTrackNext): player.next,
          const SingleActivator(LogicalKeyboardKey.mediaTrackPrevious): player.previous,
          const SingleActivator(LogicalKeyboardKey.arrowRight, control: true): player.next,
          const SingleActivator(LogicalKeyboardKey.arrowLeft, control: true): player.previous,
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
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
        ),
      ),
    );
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
        listenable: Listenable.merge([app.lib, nav]),
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
            item(Icons.favorite_border_rounded, 'Любимое', const Nav('liked')),
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
