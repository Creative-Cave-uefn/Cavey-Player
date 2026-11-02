import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../config.dart';
import '../core/library.dart';
import '../core/models.dart';
import '../core/player.dart' show RepeatSetting;
import '../mobile_main.dart';
import '../ui/theme.dart';
import 'mobile_updater.dart';

/// Android-версия в том же «стеклянном» стиле, что и Windows: тёмная основа, под всем —
/// размытая обложка текущего трека, панели — матовое стекло, жёлтый акцент.
class CaveyAndroid extends StatelessWidget {
  const CaveyAndroid({super.key, required this.services});
  final MobileServices services;

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Cavey Player',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        builder: (_, child) => Backdrop(services: services, child: child ?? const SizedBox.shrink()),
        home: AnimatedBuilder(
          animation: Listenable.merge([services.accounts, services.library]),
          builder: (_, __) {
            if (services.accounts.primary == null) return Login(services: services);
            if (!services.library.hasHub) return JoinLibrary(services: services);
            return MobileShell(services: services);
          },
        ),
      );
}

// ───────────────────────────── фон и стекло ─────────────────────────────

class Backdrop extends StatelessWidget {
  const Backdrop({super.key, required this.services, required this.child});
  final MobileServices services;
  final Widget child;

  @override
  Widget build(BuildContext context) => Stack(fit: StackFit.expand, children: [
        const ColoredBox(color: C.bg),
        AnimatedBuilder(
          animation: services.player,
          builder: (_, __) {
            final t = services.player.current;
            return AnimatedSwitcher(
              duration: const Duration(milliseconds: 700),
              child: t == null
                  ? const SizedBox.expand(key: ValueKey('none'))
                  : _BlurCover(key: ValueKey(t.id), services: services, track: t),
            );
          },
        ),
        child,
      ]);
}

class _BlurCover extends StatefulWidget {
  const _BlurCover({super.key, required this.services, required this.track});
  final MobileServices services;
  final Track track;
  @override
  State<_BlurCover> createState() => _BlurCoverState();
}

class _BlurCoverState extends State<_BlurCover> {
  Uint8List? bytes;

  @override
  void initState() {
    super.initState();
    final c = widget.services.covers;
    bytes = c.peek(widget.track, px: 160);
    if (bytes == null && c.wants(widget.track)) {
      c.forTrack(widget.track, px: 160).then((b) {
        if (mounted && b != null) setState(() => bytes = b);
      }).catchError((_) {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = bytes;
    return RepaintBoundary(
      child: SizedBox.expand(
        child: Stack(fit: StackFit.expand, children: [
          if (b != null)
            ImageFiltered(
              imageFilter: ui.ImageFilter.blur(sigmaX: 30, sigmaY: 30, tileMode: TileMode.mirror),
              child: Image.memory(b, fit: BoxFit.cover, gaplessPlayback: true),
            ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [C.bg.withAlpha(150), C.bg.withAlpha(215)],
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

class Glass extends StatelessWidget {
  const Glass({super.key, required this.child, this.radius = 0, this.color = C.glassLight, this.margin});
  final Widget child;
  final double radius;
  final Color color;
  final EdgeInsets? margin;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(radius);
    return Padding(
      padding: margin ?? EdgeInsets.zero,
      child: ClipRRect(
        borderRadius: r,
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 22, sigmaY: 22),
          child: DecoratedBox(
            decoration: BoxDecoration(color: color, borderRadius: r, border: Border.all(color: C.line, width: 0.6)),
            child: child,
          ),
        ),
      ),
    );
  }
}

// ───────────────────────────── вход ─────────────────────────────

class Login extends StatefulWidget {
  const Login({super.key, required this.services});
  final MobileServices services;
  @override
  State<Login> createState() => _LoginState();
}

class _LoginState extends State<Login> {
  bool busy = false;
  String? error;

  Future<void> login() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.services.accounts.signIn();
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                ClipRRect(
                    borderRadius: BorderRadius.circular(26),
                    child: Image.asset('assets/logo.png', width: 104, height: 104)),
                const SizedBox(height: 22),
                Text('Cavey', style: brand(34)),
                const SizedBox(height: 8),
                const Text('Общая музыка с Google Диска', style: TextStyle(color: C.muted)),
                const SizedBox(height: 32),
                FilledButton.icon(
                  onPressed: busy || !widget.services.accounts.configured ? null : login,
                  icon: const Icon(Icons.account_circle_outlined),
                  label: Text(busy ? 'Подключаем…' : 'Войти через Google'),
                ),
                if (!widget.services.accounts.configured)
                  const Padding(
                      padding: EdgeInsets.all(12),
                      child: Text('Для этой сборки не задан GOOGLE_WEB_CLIENT_ID.', style: TextStyle(color: C.danger))),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: SelectableText(error!, textAlign: TextAlign.center, style: const TextStyle(color: C.danger)),
                  ),
              ]),
            ),
          ),
        ),
      );
}

class JoinLibrary extends StatefulWidget {
  const JoinLibrary({super.key, required this.services});
  final MobileServices services;
  @override
  State<JoinLibrary> createState() => _JoinLibraryState();
}

class _JoinLibraryState extends State<JoinLibrary> {
  final link = TextEditingController();
  bool busy = false;
  String? error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => autoJoin());
  }

  @override
  void dispose() {
    link.dispose();
    super.dispose();
  }

  Future<void> run(Future<void> Function() task) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await task();
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> autoJoin() => run(() async {
        if (!await widget.services.library.autoJoin(manual: true) && mounted) {
          setState(() => error = 'Библиотека не найдена. Вставьте ссылку на общую папку.');
        }
      });

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: ListView(padding: const EdgeInsets.all(24), children: [
            const SizedBox(height: 30),
            Icon(Icons.library_music_outlined, color: C.accent, size: 72),
            const SizedBox(height: 18),
            Text('Подключи музыку', style: display(26)),
            const SizedBox(height: 12),
            const Text('Cavey ищет папку Cave Player на твоём Google Диске. Можно вставить ссылку на общую папку вручную.',
                style: TextStyle(color: C.muted)),
            const SizedBox(height: 24),
            TextField(controller: link, decoration: const InputDecoration(hintText: 'Ссылка на папку Google Диска')),
            const SizedBox(height: 14),
            FilledButton(
                onPressed: busy ? null : () => run(() => widget.services.library.joinHub(link.text.trim())),
                child: const Text('Подключить')),
            const SizedBox(height: 8),
            OutlinedButton(onPressed: busy ? null : autoJoin, child: const Text('Найти автоматически')),
            if (busy) const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator())),
            if (error != null)
              Padding(padding: const EdgeInsets.all(14), child: SelectableText(error!, style: const TextStyle(color: C.danger))),
          ]),
        ),
      );
}

// ───────────────────────────── оболочка ─────────────────────────────

class MobileShell extends StatefulWidget {
  const MobileShell({super.key, required this.services});
  final MobileServices services;
  @override
  State<MobileShell> createState() => _MobileShellState();
}

class _MobileShellState extends State<MobileShell> {
  int tab = 0;
  int section = 0;
  String query = '';
  MobileServices get s => widget.services;

  Future<void> refresh() async {
    try {
      await s.library.reload();
    } catch (e) {
      toast(e.toString());
    }
  }

  void toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> play(List<Track> tracks, int index) => playTracks(context, s, tracks, index);

  void openTracks(String title, List<Track> tracks, {Track? cover}) => Navigator.of(context)
      .push(MaterialPageRoute<void>(builder: (_) => CollectionPage(services: s, title: title, tracks: tracks, cover: cover)));

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: Listenable.merge([s.library, s.player, s.updater]),
        builder: (_, __) => Scaffold(
          body: SafeArea(
            bottom: false,
            child: IndexedStack(index: tab, children: [home(), search(), library(), ProfileTab(services: s)]),
          ),
          bottomNavigationBar: Column(mainAxisSize: MainAxisSize.min, children: [
            if (s.player.current != null)
              MiniPlayer(services: s, onOpen: () => showPlayer(context, s)),
            Glass(
              color: C.glass,
              child: SafeArea(
                top: false,
                child: Row(children: [
                  navItem(0, Icons.home_outlined, Icons.home_rounded, 'Главная'),
                  navItem(1, Icons.search_rounded, Icons.search_rounded, 'Поиск'),
                  navItem(2, Icons.library_music_outlined, Icons.library_music_rounded, 'Медиатека'),
                  navItem(3, Icons.person_outline_rounded, Icons.person_rounded, 'Профиль', badge: s.updater.available != null),
                ]),
              ),
            ),
          ]),
        ),
      );

  Widget navItem(int i, IconData icon, IconData active, String label, {bool badge = false}) {
    final on = tab == i;
    return Expanded(
      child: InkWell(
        onTap: () => setState(() => tab = i),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 9),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Badge(
              isLabelVisible: badge,
              smallSize: 8,
              backgroundColor: C.accent,
              child: Icon(on ? active : icon, size: 24, color: on ? C.accent : C.muted),
            ),
            const SizedBox(height: 3),
            Text(label,
                style: TextStyle(fontSize: 11, fontWeight: on ? FontWeight.w600 : FontWeight.w500, color: on ? C.accent : C.muted)),
          ]),
        ),
      ),
    );
  }

  Widget header(String title, {Widget? trailing}) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 12, 8),
        child: Row(children: [
          Expanded(child: Text(title, style: display(30))),
          if (trailing != null) trailing,
        ]),
      );

  Widget home() {
    final recent = s.library.recent.take(30).toList();
    final albums = s.library.albums.take(24).toList();
    final all = s.library.allTracks;
    final liked = s.library.liked;
    return RefreshIndicator(
      color: C.accent,
      onRefresh: refresh,
      child: ListView(children: [
        header('Главная',
            trailing: IconButton(onPressed: refresh, tooltip: 'Обновить', icon: const Icon(Icons.refresh_rounded, size: 24))),
        if (s.updater.available != null) UpdateBanner(updater: s.updater, onToast: toast),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(children: [
            Expanded(
                child: ActionTile(
                    icon: Icons.favorite_rounded,
                    title: 'Любимые',
                    subtitle: '${liked.length} треков',
                    onTap: liked.isEmpty ? null : () => openTracks('Любимые', liked))),
            const SizedBox(width: 12),
            Expanded(
                child: ActionTile(
                    icon: Icons.shuffle_rounded,
                    title: 'Перемешать',
                    subtitle: 'вся библиотека',
                    onTap: all.isEmpty
                        ? null
                        : () {
                            if (!s.player.shuffle) s.player.toggleShuffle();
                            play(all, math.Random().nextInt(all.length));
                          })),
          ]),
        ),
        if (albums.isNotEmpty) SectionTitle('Альбомы', onMore: () => setState(() {
              tab = 2;
              section = 2;
            })),
        SizedBox(
          height: 204,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            itemCount: albums.length,
            itemBuilder: (_, i) => AlbumCard(
                services: s, album: albums[i], width: 140, onTap: () => openTracks(albums[i].title, albums[i].tracks, cover: albums[i].coverTrack)),
          ),
        ),
        const SectionTitle('Недавно добавленные'),
        for (var i = 0; i < recent.length; i++) TrackTile(services: s, track: recent[i], onTap: () => play(recent, i), onToast: toast),
        if (recent.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('Пока нет треков', style: TextStyle(color: C.muted))),
        const SizedBox(height: 12),
      ]),
    );
  }

  Widget search() {
    final q = query.trim().toLowerCase();
    final tracks = q.isEmpty
        ? <Track>[]
        : s.library.allTracks
            .where((t) => t.title.toLowerCase().contains(q) || t.displayArtist.toLowerCase().contains(q) || t.displayAlbum.toLowerCase().contains(q))
            .toList();
    final albums = q.isEmpty
        ? <Album>[]
        : s.library.albums.where((a) => a.title.toLowerCase().contains(q) || a.artist.toLowerCase().contains(q)).take(12).toList();
    return Column(children: [
      header('Поиск'),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
        child: TextField(
          onChanged: (v) => setState(() => query = v),
          decoration: const InputDecoration(prefixIcon: Icon(Icons.search_rounded), hintText: 'Трек, альбом или исполнитель'),
        ),
      ),
      Expanded(
        child: q.isEmpty
            ? const Center(child: Text('Поиск по общей библиотеке', style: TextStyle(color: C.muted)))
            : ListView(children: [
                if (albums.isNotEmpty) ...[
                  const SectionTitle('Альбомы'),
                  SizedBox(
                    height: 204,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      itemCount: albums.length,
                      itemBuilder: (_, i) => AlbumCard(
                          services: s, album: albums[i], width: 140, onTap: () => openTracks(albums[i].title, albums[i].tracks, cover: albums[i].coverTrack)),
                    ),
                  ),
                ],
                if (tracks.isNotEmpty) const SectionTitle('Треки'),
                for (var i = 0; i < tracks.length && i < 200; i++)
                  TrackTile(services: s, track: tracks[i], onTap: () => play(tracks, i), onToast: toast),
                if (tracks.isEmpty && albums.isEmpty)
                  const Padding(padding: EdgeInsets.all(30), child: Center(child: Text('Ничего не найдено', style: TextStyle(color: C.muted)))),
              ]),
      ),
    ]);
  }

  Widget library() {
    const labels = ['Все', 'Любимые', 'Альбомы', 'Исполнители', 'Плейлисты'];
    final albums = s.library.albums;
    final artists = s.library.artists;
    final playlists = s.library.visiblePlaylists;
    return Column(children: [
      header('Медиатека'),
      SizedBox(
        height: 46,
        child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 14), children: [
          for (var i = 0; i < labels.length; i++)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(labels[i]),
                selected: section == i,
                labelStyle: TextStyle(color: section == i ? C.accentInk : C.text, fontWeight: FontWeight.w600),
                onSelected: (_) => setState(() => section = i),
              ),
            ),
        ]),
      ),
      const SizedBox(height: 6),
      Expanded(
        child: switch (section) {
          0 => TrackList(services: s, tracks: s.library.allTracks, onPlay: play, onToast: toast),
          1 => TrackList(services: s, tracks: s.library.liked, onPlay: play, onToast: toast),
          2 => GridView.builder(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 200, mainAxisExtent: 224, crossAxisSpacing: 12),
              itemCount: albums.length,
              itemBuilder: (_, i) => AlbumCard(
                  services: s, album: albums[i], onTap: () => openTracks(albums[i].title, albums[i].tracks, cover: albums[i].coverTrack)),
            ),
          3 => ListView.builder(
              itemCount: artists.length,
              itemBuilder: (_, i) {
                final a = artists[i];
                return ListTile(
                  leading: TrackCover(services: s, track: a.coverTrack, size: 52, radius: 26),
                  title: Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text('${a.tracks.length} треков', style: const TextStyle(color: C.muted)),
                  onTap: () => openTracks(a.name, a.tracks, cover: a.coverTrack),
                );
              }),
          _ => playlists.isEmpty
              ? const Center(child: Text('Плейлистов пока нет', style: TextStyle(color: C.muted)))
              : ListView.builder(
                  itemCount: playlists.length,
                  itemBuilder: (_, i) {
                    final p = playlists[i];
                    final tracks = p.items.map((id) => s.library.data.tracks[id]).whereType<Track>().toList();
                    return ListTile(
                      leading: tracks.isEmpty
                          ? Container(
                              width: 52,
                              height: 52,
                              decoration: BoxDecoration(color: C.raised, borderRadius: BorderRadius.circular(10)),
                              child: const Icon(Icons.queue_music_rounded))
                          : TrackCover(services: s, track: tracks.first, size: 52),
                      title: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text('${tracks.length} треков', style: const TextStyle(color: C.muted)),
                      onTap: () => openTracks(p.name, tracks, cover: tracks.isEmpty ? null : tracks.first),
                    );
                  }),
        },
      ),
    ]);
  }
}

Future<void> playTracks(BuildContext context, MobileServices s, List<Track> tracks, int index) async {
  try {
    await s.player.playTracks(tracks, index);
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Ошибка воспроизведения: $e')));
    }
  }
}

// ───────────────────────────── общие виджеты ─────────────────────────────

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.title, {super.key, this.onMore});
  final String title;
  final VoidCallback? onMore;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 22, 12, 10),
        child: Row(children: [
          Expanded(child: Text(title, style: display(20))),
          if (onMore != null) TextButton(onPressed: onMore, child: Text('Все', style: TextStyle(color: C.accent))),
        ]),
      );
}

class ActionTile extends StatelessWidget {
  const ActionTile({super.key, required this.icon, required this.title, required this.subtitle, this.onTap});
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Opacity(
        opacity: onTap == null ? 0.5 : 1,
        child: Glass(
          radius: 16,
          color: C.surface,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(children: [
                Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(color: C.accent, borderRadius: BorderRadius.circular(12)),
                    child: Icon(icon, color: C.accentInk, size: 22)),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
                    Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.muted, fontSize: 12)),
                  ]),
                ),
              ]),
            ),
          ),
        ),
      );
}

class AlbumCard extends StatelessWidget {
  const AlbumCard({super.key, required this.services, required this.album, required this.onTap, this.width});
  final MobileServices services;
  final Album album;
  final VoidCallback onTap;
  final double? width;
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
        final w = width ?? (c.maxWidth.isFinite ? c.maxWidth : 140.0);
        final side = w - 10;
        return SizedBox(
          width: width,
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                TrackCover(services: services, track: album.coverTrack, size: side, radius: 14),
                const SizedBox(height: 8),
                Text(album.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                Text(album.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.muted, fontSize: 12)),
              ]),
            ),
          ),
        );
      });
}

class TrackList extends StatelessWidget {
  const TrackList({super.key, required this.services, required this.tracks, required this.onPlay, this.onToast});
  final MobileServices services;
  final List<Track> tracks;
  final Future<void> Function(List<Track>, int) onPlay;
  final void Function(String)? onToast;
  @override
  Widget build(BuildContext context) => tracks.isEmpty
      ? const Center(child: Text('Здесь пока пусто', style: TextStyle(color: C.muted)))
      : ListView.builder(
          itemCount: tracks.length,
          itemBuilder: (_, i) => TrackTile(services: services, track: tracks[i], onTap: () => onPlay(tracks, i), onToast: onToast),
        );
}

class TrackTile extends StatelessWidget {
  const TrackTile({super.key, required this.services, required this.track, required this.onTap, this.onToast});
  final MobileServices services;
  final Track track;
  final VoidCallback onTap;
  final void Function(String)? onToast;

  void menu(BuildContext context) {
    final p = services.player;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: C.panel,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (sheet) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: TrackCover(services: services, track: track, size: 44),
            title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(track.displayArtist, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.playlist_play_rounded),
            title: const Text('Играть следующим'),
            onTap: () {
              p.playNext(track);
              Navigator.pop(sheet);
              onToast?.call('Сыграет следующим');
            },
          ),
          ListTile(
            leading: const Icon(Icons.queue_music_rounded),
            title: const Text('В конец очереди'),
            onTap: () {
              p.addToQueue(track);
              Navigator.pop(sheet);
              onToast?.call('Добавлено в очередь');
            },
          ),
          ListTile(
            leading: Icon(services.library.isLiked(track.id) ? Icons.favorite_border_rounded : Icons.favorite_rounded),
            title: Text(services.library.isLiked(track.id) ? 'Убрать из любимых' : 'В любимые'),
            onTap: () {
              services.library.toggleLike(track.id);
              Navigator.pop(sheet);
            },
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final liked = services.library.isLiked(track.id);
    final playing = services.player.current?.id == track.id;
    return ListTile(
      contentPadding: const EdgeInsets.only(left: 16, right: 4),
      leading: TrackCover(services: services, track: track, size: 50),
      title: Text(track.title,
          maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w600, color: playing ? C.accent : C.text)),
      subtitle: Text(track.displayArtist, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.muted, fontSize: 13)),
      onTap: onTap,
      onLongPress: () => menu(context),
      trailing: IconButton(
        onPressed: () => services.library.toggleLike(track.id),
        icon: Icon(liked ? Icons.favorite_rounded : Icons.favorite_border_rounded, color: liked ? C.accent : C.faint, size: 22),
      ),
    );
  }
}

class TrackCover extends StatefulWidget {
  const TrackCover({super.key, required this.services, required this.track, required this.size, this.radius = 10, this.fullscreen = false});
  final MobileServices services;
  final Track track;
  final double size;
  final double radius;

  /// Обложка на весь экран: оригинал, а не уменьшенная копия
  final bool fullscreen;
  @override
  State<TrackCover> createState() => _TrackCoverState();
}

class _TrackCoverState extends State<TrackCover> {
  Uint8List? bytes;
  int gen = 0;
  bool first = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (first) {
      first = false;
      load();
    }
  }

  @override
  void didUpdateWidget(TrackCover old) {
    super.didUpdateWidget(old);
    if (old.track.id != widget.track.id || old.size != widget.size || old.fullscreen != widget.fullscreen) load();
  }

  void load() {
    final svc = widget.services.covers;
    final t = widget.track;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final px = widget.fullscreen ? 1000 : (widget.size * dpr).round();
    final g = ++gen;
    bytes = svc.peek(t, px: px);
    if ((bytes == null || widget.fullscreen) && svc.wants(t)) {
      svc.forTrack(t, px: px, fullscreen: widget.fullscreen).then((b) {
        if (mounted && g == gen && b != null) setState(() => bytes = b);
      }).catchError((_) {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final b = bytes;
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.radius),
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: b != null
            ? Image.memory(b,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                filterQuality: widget.fullscreen ? FilterQuality.high : FilterQuality.low,
                errorBuilder: (_, __, ___) => const _CoverPlaceholder())
            : const _CoverPlaceholder(),
      ),
    );
  }
}

class _CoverPlaceholder extends StatelessWidget {
  const _CoverPlaceholder();
  @override
  Widget build(BuildContext context) => const DecoratedBox(
        decoration: BoxDecoration(color: C.raised),
        child: Center(child: Icon(Icons.music_note_rounded, color: C.faint)),
      );
}

// ───────────────────────────── страница альбома / списка ─────────────────────────────

class CollectionPage extends StatelessWidget {
  const CollectionPage({super.key, required this.services, required this.title, required this.tracks, this.cover});
  final MobileServices services;
  final String title;
  final List<Track> tracks;
  final Track? cover;

  void play(BuildContext context, {bool shuffle = false}) {
    if (tracks.isEmpty) return;
    final p = services.player;
    if (p.shuffle != shuffle) p.toggleShuffle();
    playTracks(context, services, tracks, shuffle ? math.Random().nextInt(tracks.length) : 0);
  }

  @override
  Widget build(BuildContext context) {
    final c = cover ?? (tracks.isEmpty ? null : tracks.first);
    final width = MediaQuery.sizeOf(context).width;
    final side = math.min(width - 96, 260.0);
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: CustomScrollView(slivers: [
          SliverAppBar(
            backgroundColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            pinned: true,
            title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: display(18)),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 6, 24, 8),
              child: Column(children: [
                if (c != null) TrackCover(services: services, track: c, size: side, radius: 18),
                const SizedBox(height: 14),
                Text(title, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis, style: display(22)),
                const SizedBox(height: 4),
                Text('${tracks.length} треков', style: const TextStyle(color: C.muted)),
                const SizedBox(height: 14),
                Row(children: [
                  Expanded(
                      child: FilledButton.icon(
                          onPressed: tracks.isEmpty ? null : () => play(context),
                          icon: const Icon(Icons.play_arrow_rounded),
                          label: const Text('Играть'))),
                  const SizedBox(width: 12),
                  Expanded(
                      child: OutlinedButton.icon(
                          onPressed: tracks.isEmpty ? null : () => play(context, shuffle: true),
                          icon: const Icon(Icons.shuffle_rounded),
                          label: const Text('Вперемешку'))),
                ]),
              ]),
            ),
          ),
          SliverList.builder(
            itemCount: tracks.length,
            itemBuilder: (_, i) => TrackTile(
              services: services,
              track: tracks[i],
              onTap: () => playTracks(context, services, tracks, i),
              onToast: (m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m))),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 12)),
        ]),
      ),
      bottomNavigationBar: AnimatedBuilder(
        animation: services.player,
        builder: (_, __) => services.player.current == null
            ? const SizedBox.shrink()
            : MiniPlayer(services: services, onOpen: () => showPlayer(context, services)),
      ),
    );
  }
}

// ───────────────────────────── профиль и обновления ─────────────────────────────

class UpdateBanner extends StatelessWidget {
  const UpdateBanner({super.key, required this.updater, required this.onToast});
  final MobileUpdater updater;
  final void Function(String) onToast;
  @override
  Widget build(BuildContext context) {
    final u = updater;
    final b = u.available;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      child: Glass(
        radius: 16,
        color: C.surface,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(children: [
            Icon(Icons.system_update_rounded, color: C.accent),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Доступна версия ${b?.version ?? ''}', style: const TextStyle(fontWeight: FontWeight.w700)),
                Text(u.progress != null ? 'Скачиваем… ${((u.progress ?? 0) * 100).round()}%' : 'Сейчас стоит $kAppVersion',
                    style: const TextStyle(color: C.muted, fontSize: 12)),
              ]),
            ),
            FilledButton(
              onPressed: u.progress != null
                  ? null
                  : () async {
                      final ok = await u.install();
                      if (!ok) {
                        onToast(u.error ?? 'Разрешите установку из этого приложения и нажмите ещё раз');
                      }
                    },
              child: const Text('Обновить'),
            ),
          ]),
        ),
      ),
    );
  }
}

class ProfileTab extends StatelessWidget {
  const ProfileTab({super.key, required this.services});
  final MobileServices services;

  @override
  Widget build(BuildContext context) {
    final s = services;
    final u = s.updater;
    final email = s.accounts.primary?.email ?? '';
    final b = u.available;
    return AnimatedBuilder(
      animation: u,
      builder: (_, __) => ListView(padding: const EdgeInsets.fromLTRB(16, 18, 16, 24), children: [
        Padding(padding: const EdgeInsets.fromLTRB(4, 0, 4, 14), child: Text('Профиль', style: display(30))),
        Glass(
          radius: 16,
          color: C.surface,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: friendColor(email),
                child: Text(email.isEmpty ? '?' : email[0].toUpperCase(),
                    style: const TextStyle(color: Color(0xFF14141B), fontWeight: FontWeight.w700, fontSize: 20)),
              ),
              const SizedBox(width: 14),
              Expanded(
                  child: Text(email, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600))),
            ]),
          ),
        ),
        const SizedBox(height: 14),
        Glass(
          radius: 16,
          color: C.surface,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                const Expanded(child: Text('Версия приложения', style: TextStyle(fontWeight: FontWeight.w700))),
                Text(kAppVersion.isEmpty ? 'dev' : kAppVersion, style: const TextStyle(color: C.muted)),
              ]),
              const SizedBox(height: 10),
              if (b != null) ...[
                Text('Доступна ${b.version}', style: TextStyle(color: C.accent, fontWeight: FontWeight.w700)),
                if (b.notes.isNotEmpty)
                  Padding(padding: const EdgeInsets.only(top: 6), child: Text(b.notes, style: const TextStyle(color: C.muted, fontSize: 13))),
                const SizedBox(height: 12),
                if (u.progress != null)
                  LinearProgressIndicator(value: u.progress, color: C.accent, backgroundColor: C.raised)
                else
                  FilledButton.icon(
                    onPressed: () async {
                      final ok = await u.install();
                      if (!ok && context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                            content: Text(u.error ?? 'Разрешите установку из этого приложения и нажмите ещё раз')));
                      }
                    },
                    icon: const Icon(Icons.download_rounded),
                    label: const Text('Скачать и установить'),
                  ),
              ] else
                Text(
                  u.checking
                      ? 'Проверяем…'
                      : (u.error ?? (u.upToDate ? 'Установлена последняя версия' : (u.enabled ? '' : 'Автообновление работает в релизных сборках'))),
                  style: const TextStyle(color: C.muted),
                ),
              if (b == null && u.enabled) ...[
                const SizedBox(height: 8),
                OutlinedButton(onPressed: u.checking ? null : () => u.check(manual: true), child: const Text('Проверить обновления')),
              ],
            ]),
          ),
        ),
        const SizedBox(height: 14),
        OutlinedButton.icon(
          onPressed: () async {
            if (email.isNotEmpty) await s.accounts.remove(email);
          },
          icon: const Icon(Icons.logout_rounded),
          label: const Text('Выйти из Google'),
        ),
      ]),
    );
  }
}

// ───────────────────────────── плеер ─────────────────────────────

void showPlayer(BuildContext context, MobileServices services) {
  Navigator.of(context, rootNavigator: true).push(PageRouteBuilder<void>(
    opaque: false,
    transitionDuration: const Duration(milliseconds: 320),
    reverseTransitionDuration: const Duration(milliseconds: 260),
    pageBuilder: (_, __, ___) => FullPlayer(services: services),
    transitionsBuilder: (_, anim, __, child) => SlideTransition(
      position: Tween(begin: const Offset(0, 1), end: Offset.zero).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
      child: child,
    ),
  ));
}

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key, required this.services, required this.onOpen});
  final MobileServices services;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final p = services.player;
    final t = p.current;
    if (t == null) return const SizedBox.shrink();
    return Glass(
      radius: 18,
      color: C.glass,
      margin: const EdgeInsets.fromLTRB(10, 0, 10, 8),
      child: InkWell(
        onTap: onOpen,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 4, 6),
            child: Row(children: [
              TrackCover(services: services, track: t, size: 44),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
                  Text(t.displayArtist, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: C.muted)),
                ]),
              ),
              IconButton(onPressed: p.toggle, icon: Icon(p.playing ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 30, color: C.text)),
              IconButton(onPressed: p.next, icon: const Icon(Icons.skip_next_rounded, size: 28, color: C.text)),
            ]),
          ),
          ValueListenableBuilder<Duration>(
            valueListenable: p.position,
            builder: (_, pos, __) => LinearProgressIndicator(
              value: p.duration.inMilliseconds <= 0 ? 0 : (pos.inMilliseconds / p.duration.inMilliseconds).clamp(0.0, 1.0).toDouble(),
              minHeight: 2,
              color: C.accent,
              backgroundColor: Colors.transparent,
            ),
          ),
        ]),
      ),
    );
  }
}

class FullPlayer extends StatelessWidget {
  const FullPlayer({super.key, required this.services});
  final MobileServices services;

  static String time(Duration d) {
    final seconds = d.inSeconds.clamp(0, 999999);
    return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  void queue(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: C.panel,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => FractionallySizedBox(heightFactor: 0.8, child: QueueSheet(services: services)),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: C.bg.withAlpha(120),
        body: GestureDetector(
          onVerticalDragEnd: (d) {
            if ((d.primaryVelocity ?? 0) > 700) Navigator.pop(context);
          },
          child: AnimatedBuilder(
            animation: Listenable.merge([services.player, services.library]),
            builder: (context, __) {
              final p = services.player;
              final t = p.current;
              if (t == null) return const Center(child: Text('Ничего не играет'));
              final size = MediaQuery.sizeOf(context);
              final cover = math.min(size.width - 48, size.height * 0.42);
              return SafeArea(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(children: [
                    Row(children: [
                      IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 34, color: C.text)),
                      const Expanded(
                          child: Text('Сейчас играет', textAlign: TextAlign.center, style: TextStyle(color: C.muted, fontWeight: FontWeight.w600))),
                      IconButton(onPressed: () => queue(context), icon: const Icon(Icons.queue_music_rounded, size: 26, color: C.text)),
                    ]),
                    const Spacer(),
                    DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(22),
                        boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 36, offset: Offset(0, 16))],
                      ),
                      child: TrackCover(services: services, track: t, size: cover, radius: 22, fullscreen: true),
                    ),
                    const Spacer(),
                    Row(children: [
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(t.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: display(23)),
                          const SizedBox(height: 4),
                          Text(t.displayArtist, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.muted, fontSize: 15)),
                        ]),
                      ),
                      IconButton(
                        onPressed: () => services.library.toggleLike(t.id),
                        icon: Icon(services.library.isLiked(t.id) ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                            color: services.library.isLiked(t.id) ? C.accent : C.muted, size: 28),
                      ),
                    ]),
                    const SizedBox(height: 10),
                    ValueListenableBuilder<Duration>(
                      valueListenable: p.position,
                      builder: (_, position, __) {
                        final max = p.duration.inMilliseconds.toDouble();
                        final value = max <= 0 ? 0.0 : position.inMilliseconds.toDouble().clamp(0.0, max).toDouble();
                        return Column(children: [
                          SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              trackHeight: 4,
                              activeTrackColor: C.accent,
                              inactiveTrackColor: C.raised,
                              thumbColor: C.accent,
                              overlayShape: SliderComponentShape.noOverlay,
                              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                            ),
                            child: Slider(
                                value: value,
                                max: max <= 0 ? 1 : max,
                                onChanged: max <= 0 ? null : (v) => p.seek(Duration(milliseconds: v.round()))),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                              Text(time(position), style: const TextStyle(color: C.muted, fontSize: 12)),
                              Text(time(p.duration), style: const TextStyle(color: C.muted, fontSize: 12)),
                            ]),
                          ),
                        ]);
                      },
                    ),
                    const SizedBox(height: 8),
                    Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                      IconButton(
                          onPressed: p.toggleShuffle,
                          icon: Icon(Icons.shuffle_rounded, size: 26, color: p.shuffle ? C.accent : C.muted)),
                      IconButton(onPressed: p.previous, icon: const Icon(Icons.skip_previous_rounded, size: 42, color: C.text)),
                      Material(
                        color: C.accent,
                        shape: const CircleBorder(),
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: p.toggle,
                          child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Icon(p.playing ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 40, color: C.accentInk)),
                        ),
                      ),
                      IconButton(onPressed: p.next, icon: const Icon(Icons.skip_next_rounded, size: 42, color: C.text)),
                      IconButton(
                          onPressed: p.cycleRepeat,
                          icon: Icon(p.repeat == RepeatSetting.one ? Icons.repeat_one_rounded : Icons.repeat_rounded,
                              size: 26, color: p.repeat == RepeatSetting.off ? C.muted : C.accent)),
                    ]),
                    const SizedBox(height: 18),
                  ]),
                ),
              );
            },
          ),
        ),
      );
}

class QueueSheet extends StatelessWidget {
  const QueueSheet({super.key, required this.services});
  final MobileServices services;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: services.player,
        builder: (_, __) {
          final p = services.player;
          final ids = p.queue;
          return Column(children: [
            const SizedBox(height: 10),
            Container(width: 38, height: 4, decoration: BoxDecoration(color: C.line, borderRadius: BorderRadius.circular(2))),
            Padding(padding: const EdgeInsets.all(14), child: Text('Очередь · ${ids.length}', style: display(18))),
            Expanded(
              child: ListView.builder(
                itemCount: ids.length,
                itemBuilder: (_, i) {
                  final t = services.library.data.tracks[ids[i]];
                  if (t == null) return const SizedBox.shrink();
                  final now = i == p.index;
                  return ListTile(
                    leading: TrackCover(services: services, track: t, size: 44),
                    title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: now ? C.accent : C.text, fontWeight: FontWeight.w600)),
                    subtitle: Text(t.displayArtist, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.muted)),
                    onTap: () => p.jumpTo(i),
                  );
                },
              ),
            ),
          ]);
        },
      );
}
