import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config.dart';
import '../core/library.dart';
import '../core/models.dart';
import '../core/player.dart' show RepeatSetting;
import '../core/social.dart' show Member;
import '../mobile_main.dart';
import '../ui/theme.dart';
import 'mobile_ambient.dart';
import 'mobile_lyrics.dart';
import 'mobile_pages.dart';
import 'mobile_social.dart';
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
        // На телефоне нужна видимая реакция на касание, в десктопной теме её нет
        theme: buildTheme().copyWith(splashFactory: InkRipple.splashFactory, splashColor: C.pressOverlay),
        builder: (ctx, child) {
          final mq = MediaQuery.of(ctx);
          // Очень крупный системный шрифт ломает вёрстку плеера: ограничиваем
          return MediaQuery(
            data: mq.copyWith(textScaler: mq.textScaler.clamp(maxScaleFactor: 1.2)),
            child: Backdrop(services: services, child: child ?? const SizedBox.shrink()),
          );
        },
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
  const Backdrop({super.key, required this.services, required this.child, this.track});
  final MobileServices services;
  final Widget child;
  final Track? track;

  @override
  Widget build(BuildContext context) => Stack(fit: StackFit.expand, children: [
        MobileAmbient(services: services, track: track),
        child,
      ]);
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

  /// Нижняя панель свёрнута: при прокрутке вниз остаются кнопка активной вкладки, плеер и поиск
  bool dockCollapsed = false;
  final Set<int> visited = {0};

  /// Чип «Медиатеки»: 0 Обзор, 1 Песни, 2 Альбомы, 3 Исполнители, 4 Плейлисты
  int section = 0;

  /// Чип «Коллекций»: 0 Плейлисты, 1 Мои, 2 Общие
  int plFilter = 0;
  bool webSearch = false;
  String query = '';
  final TextEditingController searchCtl = TextEditingController();

  /// Какие вкладки стоят на нижней панели и в каком порядке (настраивается, хранится на телефоне)
  List<int> hotbar = const [0, 1, 3, 4];

  static const defaultHotbar = [0, 1, 3, 4];

  static const tabMeta = <int, (String, IconData, IconData)>{
    0: ('Медиатека', Icons.library_music_outlined, Icons.library_music_rounded),
    1: ('Волна', Icons.waves_rounded, Icons.waves_rounded),
    3: ('Коллекции', Icons.folder_outlined, Icons.folder_rounded),
    4: ('Компания', Icons.groups_outlined, Icons.groups_rounded),
    5: ('Любимое', Icons.favorite_border_rounded, Icons.favorite_rounded),
    6: ('Скачано', Icons.download_outlined, Icons.download_done_rounded),
  };

  @override
  void initState() {
    super.initState();
    _loadHotbar();
  }

  @override
  void dispose() {
    searchCtl.dispose();
    super.dispose();
  }

  Future<void> _loadHotbar() async {
    try {
      final j = await s.store.readJson('hotbar.json');
      if (j is List) {
        final v = <int>[for (final x in j) if (x is int && tabMeta.containsKey(x)) x].toSet().take(4).toList();
        if (v.isNotEmpty && mounted) setState(() => hotbar = v);
      }
    } catch (_) {}
  }

  Future<void> saveHotbar(List<int> v) async {
    setState(() => hotbar = v);
    try {
      await s.store.writeJson('hotbar.json', v);
    } catch (_) {}
  }

  void openHotbar() => Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => HotbarSettingsPage(services: s, current: hotbar, onChanged: saveHotbar)));

  void openProfile() => Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => SubPage(services: s, title: 'Профиль и настройки', child: Builder(builder: (_) => more()))));

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

  Widget tabPage(int i) {
    if (!visited.contains(i)) return const SizedBox.shrink();
    switch (i) {
      case 0:
        return libraryPage();
      case 1:
        return WaveTab(services: s);
      case 2:
        return search();
      case 3:
        return collectionsPage();
      case 4:
        return CompanyView(services: s, embedded: true);
      case 5:
        return Column(children: [
          pageTitle('Любимое', '${s.library.liked.length} ${plural(s.library.liked.length, 'песня', 'песни', 'песен')}'),
          const SizedBox(height: 8),
          Expanded(child: TrackList(services: s, tracks: s.library.liked, onPlay: play, onToast: toast)),
        ]);
      default:
        return Column(children: [
          pageTitle('Скачано', ''),
          const SizedBox(height: 4),
          Expanded(child: downloads()),
        ]);
    }
  }

  void selectTab(int i) {
    if (i == tab) return;
    HapticFeedback.selectionClick();
    setState(() {
      tab = i;
      dockCollapsed = false;
      visited.add(i);
    });
  }

  Widget signInStrip() => Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
        child: Glass(
          radius: 14,
          color: C.surface,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
            child: Row(children: [
              Icon(Icons.info_outline_rounded, color: C.accent, size: 20),
              const SizedBox(width: 10),
              const Expanded(child: Text('Google просит войти заново', style: TextStyle(fontSize: 13))),
              TextButton(
                onPressed: () async {
                  try {
                    await s.accounts.signIn();
                    unawaited(s.library.reload());
                  } catch (e) {
                    toast(e.toString());
                  }
                },
                child: Text('Войти', style: TextStyle(color: C.accent, fontWeight: FontWeight.w700)),
              ),
            ]),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: tab == 0,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) selectTab(0);
        },
        child: AnimatedBuilder(
        animation: Listenable.merge([s.library, s.player, s.updater, s.cache, s.accounts]),
        builder: (_, __) => Scaffold(
          extendBody: true,
          body: SafeArea(
            bottom: false,
            child: Column(children: [
              if (s.accounts.primary?.needsSignIn == true) signInStrip(),
              Expanded(
                child: NotificationListener<ScrollNotification>(
                  onNotification: (n) {
                    if (n.depth != 0 || n.metrics.axis != Axis.vertical) return false;
                    // Вниз по списку — сворачиваем панель, вернулись к самому верху — разворачиваем
                    if (n is ScrollUpdateNotification) {
                      final dy = n.scrollDelta ?? 0;
                      if (!dockCollapsed && n.metrics.pixels > 60 && dy > 2) {
                        setState(() => dockCollapsed = true);
                      } else if (dockCollapsed && n.metrics.pixels <= 4) {
                        setState(() => dockCollapsed = false);
                      }
                    }
                    return false;
                  },
                  child: IndexedStack(index: tab, children: [
                    for (var i = 0; i < 7; i++) tabPage(i),
                  ]),
                ),
              ),
            ]),
          ),
          bottomNavigationBar: dock(),
        ),
        ),
      );

  Widget roundButton(Widget icon, VoidCallback onTap, {double size = 56, bool on = false}) => Glass(
        radius: size / 2,
        color: on ? const Color(0x663C341E) : const Color(0x9E1A1A24),
        child: InkWell(
          onTap: onTap,
          child: SizedBox(width: size, height: size, child: Center(child: icon)),
        ),
      );

  /// Плавающая нижняя панель как в Apple Music: вкладки и поиск, над ними плеер.
  /// При прокрутке сворачивается: слева кнопка активной вкладки, справа поиск, между ними плеер.
  Widget dock() {
    final hasMini = s.player.current != null;
    final Widget body;
    if (dockCollapsed) {
      final shown = tabMeta[tab] ?? tabMeta[hotbar.first]!;
      body = Row(key: const ValueKey('collapsed'), children: [
        roundButton(Icon(shown.$3, size: 25, color: C.accent), () => setState(() => dockCollapsed = false)),
        const SizedBox(width: 8),
        Expanded(
          child: hasMini
              ? MiniPlayer(services: s, compact: true, margin: EdgeInsets.zero, onOpen: () => showPlayer(context, s))
              : const SizedBox(height: 56),
        ),
        const SizedBox(width: 8),
        roundButton(Icon(Icons.search_rounded, size: 26, color: tab == 2 ? C.accent : const Color(0xD1FFFFFF)), () => selectTab(2), on: tab == 2),
      ]);
    } else {
      body = Column(key: const ValueKey('expanded'), mainAxisSize: MainAxisSize.min, children: [
        if (hasMini) ...[
          MiniPlayer(services: s, margin: EdgeInsets.zero, onOpen: () => showPlayer(context, s)),
          const SizedBox(height: 10),
        ],
        Row(children: [
          Expanded(
            child: Glass(
              radius: 32,
              color: const Color(0x9E1A1A24),
              child: SizedBox(
                height: 64,
                child: Padding(
                  padding: const EdgeInsets.all(5),
                  child: Row(children: [for (final i in hotbar) navItem(i)]),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          roundButton(Icon(Icons.search_rounded, size: 27, color: tab == 2 ? C.accent : const Color(0xD1FFFFFF)), () => selectTab(2), size: 64, on: tab == 2),
        ]),
      ]);
    }
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0x000E1122), Color(0xEB0E1122)], stops: [0, 0.7]),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 14, 12, 8),
          child: AnimatedSize(
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOutCubic,
            alignment: Alignment.bottomCenter,
            child: AnimatedSwitcher(duration: const Duration(milliseconds: 200), child: body),
          ),
        ),
      ),
    );
  }

  Widget navItem(int i) {
    final m = tabMeta[i]!;
    final on = tab == i;
    final badge = i == 4 && s.social.notices.isNotEmpty;
    return Expanded(
      child: GestureDetector(
        onLongPress: openHotbar,
        child: InkWell(
          customBorder: RoundedRectangleBorder(borderRadius: BorderRadius.circular(27)),
          onTap: () => selectTab(i),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            decoration: BoxDecoration(color: on ? const Color(0x2EFFFFFF) : Colors.transparent, borderRadius: BorderRadius.circular(27)),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Badge(
                isLabelVisible: badge,
                smallSize: 8,
                backgroundColor: C.accent,
                child: Icon(on ? m.$3 : m.$2, size: 23, color: on ? C.accent : const Color(0xD1FFFFFF)),
              ),
              const SizedBox(height: 3),
              Text(m.$1, maxLines: 1, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: on ? C.accent : const Color(0xD1FFFFFF))),
            ]),
          ),
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

  String greeting() {
    final h = DateTime.now().hour;
    final word = h < 5 ? 'Доброй ночи' : (h < 12 ? 'Доброе утро' : (h < 18 ? 'Добрый день' : 'Добрый вечер'));
    final name = (s.accounts.primary?.name ?? '').trim().split(' ').first;
    return name.isEmpty || name.contains('@') ? word : '$word, $name';
  }

  Widget pageTitle(String title, String sub, {Widget? trailing}) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: display(34)),
              if (sub.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Text(sub, style: const TextStyle(fontSize: 14.5, color: C.muted))),
            ]),
          ),
          if (trailing != null) trailing,
        ]),
      );

  Widget chips(List<String> labels, int selected, ValueChanged<int> onSelect) => SizedBox(
        height: 40,
        child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 20), children: [
          for (var i = 0; i < labels.length; i++)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Material(
                color: selected == i ? C.accent : const Color(0x1FFFFFFF),
                shape: StadiumBorder(side: BorderSide(color: selected == i ? Colors.transparent : const Color(0x2EFFFFFF))),
                child: InkWell(
                  customBorder: const StadiumBorder(),
                  onTap: () => onSelect(i),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Center(
                      child: Text(labels[i],
                          style: TextStyle(fontSize: 14, fontWeight: selected == i ? FontWeight.w600 : FontWeight.w500, color: selected == i ? C.accentInk : C.text)),
                    ),
                  ),
                ),
              ),
            ),
        ]),
      );

  /// «Медиатека» как в макете: логотип и профиль, заголовок со счётчиками, чипы разделов
  Widget libraryPage() {
    const labels = ['Обзор', 'Песни', 'Альбомы', 'Исполнители', 'Плейлисты'];
    final lib = s.library;
    final albums = lib.albums;
    final artists = lib.artists;
    final all = lib.allTracks;
    final me = lib.me ?? '';
    final playlists = lib.visiblePlaylists;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
        child: Row(children: [
          Image.asset('assets/logo.png', width: 32, height: 32),
          const SizedBox(width: 10),
          Text('Cavey', style: brand(20)),
          const Spacer(),
          GestureDetector(
            onTap: openProfile,
            child: Badge(
              isLabelVisible: s.updater.available != null,
              smallSize: 10,
              backgroundColor: C.accent,
              child: Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: const Color(0x47FFFFFF), width: 2)),
                child: ClipOval(child: me.isEmpty ? const SizedBox.shrink() : MobileAvatar(services: s, email: me, size: 34)),
              ),
            ),
          ),
        ]),
      ),
      pageTitle('Медиатека',
          '${all.length} ${plural(all.length, 'песня', 'песни', 'песен')} · ${albums.length} ${plural(albums.length, 'альбом', 'альбома', 'альбомов')} · ${artists.length} ${plural(artists.length, 'исполнитель', 'исполнителя', 'исполнителей')}'),
      const SizedBox(height: 12),
      chips(labels, section, (i) => setState(() => section = i)),
      const SizedBox(height: 6),
      Expanded(
        child: switch (section) {
          0 => overview(),
          1 => TrackList(services: s, tracks: all, onPlay: play, onToast: toast),
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
                  leading: TrackCover(services: s, track: a.coverTrack, size: 56, radius: 28),
                  title: Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text('${a.albums} ${plural(a.albums, 'альбом', 'альбома', 'альбомов')} · ${a.tracks.length} ${plural(a.tracks.length, 'песня', 'песни', 'песен')}',
                      style: const TextStyle(color: C.muted)),
                  trailing: const Icon(Icons.chevron_right_rounded, color: Color(0x80FFFFFF)),
                  onTap: () => openTracks(a.name, a.tracks, cover: a.coverTrack),
                );
              }),
          _ => ListView(padding: const EdgeInsets.fromLTRB(20, 4, 20, 12), children: [
              if (playlists.isEmpty) const Padding(padding: EdgeInsets.all(30), child: Center(child: Text('Плейлистов пока нет', style: TextStyle(color: C.muted)))),
              for (final p in playlists) playlistRow(p),
            ]),
        },
      ),
    ]);
  }

  Widget overview() {
    final lib = s.library;
    final recentAlbums = <Album>[];
    final seen = <String>{};
    for (final t in lib.recent) {
      final a = lib.albumOf(t);
      if (a != null && seen.add(a.key)) {
        recentAlbums.add(a);
        if (recentAlbums.length >= 14) break;
      }
    }
    final albums = lib.albums.take(24).toList();
    final artists = lib.artists.take(20).toList();
    final now = s.social.listeningNow;
    Widget albumCard(Album a) {
      final year = a.tracks.map((t) => t.year).firstWhere((y) => y.isNotEmpty, orElse: () => '');
      final meta = [if (year.isNotEmpty) year, '${a.tracks.length} ${plural(a.tracks.length, 'песня', 'песни', 'песен')}'].join(' · ');
      return SizedBox(
        width: 128,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => openTracks(a.title, a.tracks, cover: a.coverTrack),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            DecoratedBox(
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), boxShadow: const [BoxShadow(color: Color(0x59000000), blurRadius: 20, offset: Offset(0, 8))]),
              child: TrackCover(services: s, track: a.coverTrack, size: 128, radius: 14),
            ),
            const SizedBox(height: 8),
            Text(a.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            Text(a.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, color: C.muted)),
            Text(meta, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: Color(0x99FFFFFF))),
          ]),
        ),
      );
    }

    Widget shelfTitle(String title, {VoidCallback? onMore}) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
          child: InkWell(
            onTap: onMore,
            child: Row(children: [
              Text(title, style: display(20)),
              if (onMore != null) const Icon(Icons.chevron_right_rounded, size: 24, color: C.text),
            ]),
          ),
        );

    return RefreshIndicator(
      color: C.accent,
      onRefresh: refresh,
      child: ListView(padding: const EdgeInsets.only(top: 6), children: [
        if (s.updater.available != null) UpdateBanner(updater: s.updater, onToast: toast),
        HandoffCard(services: s),
        if (now.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
            child: Glass(
              radius: 20,
              color: const Color(0x8C1A1A24),
              child: InkWell(
                onTap: () => selectTab(4),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  child: Row(children: [
                    SizedBox(
                      width: 34 + (math.min(now.length, 2) - 1) * 20.0,
                      height: 34,
                      child: Stack(children: [
                        for (final (i, m) in now.take(2).indexed)
                          Positioned(
                            left: i * 20.0,
                            child: Container(
                              padding: const EdgeInsets.all(2),
                              decoration: const BoxDecoration(color: Color(0xFF1B1B26), shape: BoxShape.circle),
                              child: MobileAvatar(services: s, email: m.email, size: 30),
                            ),
                          ),
                      ]),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(
                            '${now.take(2).map((m) => lib.firstNameOf(m.email)).join(' и ')} ${now.length > 1 ? 'слушают' : 'слушает'} сейчас',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                        if (now.first.now != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text('${now.first.now!.artist} — ${now.first.now!.title}',
                                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, color: C.muted)),
                          ),
                      ]),
                    ),
                    Container(width: 8, height: 8, decoration: BoxDecoration(color: C.accent, shape: BoxShape.circle)),
                    const SizedBox(width: 8),
                    const Icon(Icons.chevron_right_rounded, size: 22, color: Color(0x80FFFFFF)),
                  ]),
                ),
              ),
            ),
          ),
        if (recentAlbums.isNotEmpty) shelfTitle('Недавно добавленное', onMore: () => setState(() => section = 2)),
        if (recentAlbums.isNotEmpty)
          SizedBox(
            height: 204,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
              itemCount: recentAlbums.length,
              separatorBuilder: (_, __) => const SizedBox(width: 14),
              itemBuilder: (_, i) => albumCard(recentAlbums[i]),
            ),
          ),
        if (albums.isNotEmpty) shelfTitle('Альбомы', onMore: () => setState(() => section = 2)),
        if (albums.isNotEmpty)
          SizedBox(
            height: 204,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
              itemCount: albums.length,
              separatorBuilder: (_, __) => const SizedBox(width: 14),
              itemBuilder: (_, i) => albumCard(albums[i]),
            ),
          ),
        if (artists.isNotEmpty) shelfTitle('Исполнители', onMore: () => setState(() => section = 3)),
        if (artists.isNotEmpty)
          SizedBox(
            height: 150,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
              itemCount: artists.length,
              separatorBuilder: (_, __) => const SizedBox(width: 14),
              itemBuilder: (_, i) {
                final a = artists[i];
                return InkWell(
                  borderRadius: BorderRadius.circular(46),
                  onTap: () => openTracks(a.name, a.tracks, cover: a.coverTrack),
                  child: SizedBox(
                    width: 92,
                    child: Column(children: [
                      DecoratedBox(
                        decoration: const BoxDecoration(shape: BoxShape.circle, boxShadow: [BoxShadow(color: Color(0x59000000), blurRadius: 20, offset: Offset(0, 8))]),
                        child: TrackCover(services: s, track: a.coverTrack, size: 92, radius: 46),
                      ),
                      const SizedBox(height: 7),
                      Text(a.name, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                      Text('${a.albums} ${plural(a.albums, 'альбом', 'альбома', 'альбомов')}', style: const TextStyle(fontSize: 12, color: Color(0x99FFFFFF))),
                    ]),
                  ),
                );
              },
            ),
          ),
        if (lib.allTracks.isEmpty)
          const Padding(
            padding: EdgeInsets.all(32),
            child: Column(children: [
              Icon(Icons.library_music_outlined, size: 44, color: C.faint),
              SizedBox(height: 10),
              Text('Пока нет треков', style: TextStyle(color: C.muted)),
              Text('Потяните вниз, чтобы обновить', style: TextStyle(color: C.faint, fontSize: 12)),
            ]),
          ),
        const SizedBox(height: 16),
      ]),
    );
  }

  Widget playlistRow(Playlist p) {
    final lib = s.library;
    final me = lib.me ?? '';
    final tracks = p.items.map((id) => lib.data.tracks[id]).whereType<Track>().toList();
    final owner = p.by == me ? 'мой' : lib.firstNameOf(p.by);
    return InkWell(
      onTap: () => openTracks(p.name, tracks, cover: tracks.isEmpty ? null : tracks.first),
      child: Container(
        height: 62,
        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0x12FFFFFF)))),
        child: Row(children: [
          tracks.isEmpty
              ? Container(
                  width: 50,
                  height: 50,
                  decoration: BoxDecoration(color: const Color(0x1FFFFFFF), borderRadius: BorderRadius.circular(9)),
                  child: const Icon(Icons.queue_music_rounded, color: Color(0x99FFFFFF)))
              : TrackCover(services: s, track: tracks.first, size: 50, radius: 9),
          const SizedBox(width: 12),
          Expanded(
            child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600)),
              Text('${tracks.length} ${plural(tracks.length, 'песня', 'песни', 'песен')} · $owner',
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, color: C.muted)),
            ]),
          ),
          const Icon(Icons.chevron_right_rounded, size: 22, color: Color(0x80FFFFFF)),
        ]),
      ),
    );
  }

  /// «Коллекции»: любимое, скачанное и плейлисты
  Widget collectionsPage() {
    final lib = s.library;
    final liked = lib.liked;
    final dl = s.settings.offlineTracks.length;
    final me = lib.me ?? '';
    final lists = [for (final p in lib.visiblePlaylists) if (plFilter == 0 || (plFilter == 1 ? p.by == me : p.by != me)) p];
    Widget hero(IconData icon, Color tint, List<Color> base, String title, String sub, VoidCallback onTap) => Expanded(
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: onTap,
            child: Container(
              height: 96,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0x2EFFFFFF)),
                gradient: LinearGradient(begin: Alignment.topRight, end: Alignment.bottomLeft, colors: base),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Icon(icon, size: 26, color: tint),
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, color: C.muted)),
                ]),
              ]),
            ),
          ),
        );
    return ListView(padding: const EdgeInsets.only(bottom: 12), children: [
      pageTitle('Коллекции', 'Любимое, плейлисты и скачанное',
          trailing: Glass(
            radius: 22,
            color: const Color(0x9E1A1A24),
            child: InkWell(
              onTap: newPlaylist,
              child: SizedBox(width: 44, height: 44, child: Icon(Icons.add_rounded, size: 26, color: C.accent)),
            ),
          )),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
        child: Row(children: [
          hero(Icons.favorite_rounded, C.accent, const [Color(0xFF6B2A55), Color(0xFF2A1230)], 'Любимое',
              '${liked.length} ${plural(liked.length, 'песня', 'песни', 'песен')}', () => openTracks('Любимое', liked)),
          const SizedBox(width: 12),
          hero(Icons.download_done_rounded, const Color(0xFF5FD3B4), const [Color(0xFF1F5A5C), Color(0xFF10222C)], 'Скачано',
              '$dl ${plural(dl, 'песня', 'песни', 'песен')} · ${formatBytes(s.cache.offlineBytes)}', () => openPage(SubPage(
                  services: s,
                  title: 'Скачано',
                  child: AnimatedBuilder(animation: Listenable.merge([s.cache, s.library]), builder: (_, __) => downloads())))),
        ]),
      ),
      const SizedBox(height: 16),
      chips(const ['Плейлисты', 'Мои', 'Общие'], plFilter, (i) => setState(() => plFilter = i)),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
        child: Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
          Expanded(child: Text('Плейлисты', style: display(20))),
          Text('${lists.length} · по дате', style: const TextStyle(fontSize: 13, color: Color(0x99FFFFFF))),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
        child: Column(children: [
          if (lists.isEmpty) const Padding(padding: EdgeInsets.all(30), child: Text('Плейлистов пока нет', style: TextStyle(color: C.muted))),
          for (final p in lists) playlistRow(p),
        ]),
      ),
    ]);
  }

  Future<void> newPlaylist() async {
    final ctl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        backgroundColor: C.panel,
        title: const Text('Новый плейлист'),
        content: TextField(controller: ctl, autofocus: true, decoration: const InputDecoration(hintText: 'Название')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d), child: const Text('Отмена')),
          TextButton(onPressed: () => Navigator.pop(d, ctl.text.trim()), child: Text('Создать', style: TextStyle(color: C.accent))),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) s.library.createPlaylist(name);
  }

  void openPage(Widget page) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

  Widget more() {
    final unread = s.social.notices.length;
    Widget tile(IconData icon, String title, String sub, VoidCallback onTap, {bool dot = false}) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: Glass(
            radius: 16,
            color: C.surface,
            child: ListTile(
              leading: Badge(isLabelVisible: dot, smallSize: 8, backgroundColor: C.accent, child: Icon(icon, color: C.accent, size: 26)),
              title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text(sub, style: const TextStyle(color: C.muted, fontSize: 12)),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: onTap,
            ),
          ),
        );
    return ListView(children: [
      header('Профиль и настройки'),
      tile(Icons.tune_rounded, 'Панель вкладок', 'Какие вкладки показывать внизу и в каком порядке', openHotbar),
      tile(Icons.new_releases_outlined, 'Новинки', 'Свежие релизы ваших исполнителей', () => openPage(NewReleasesPage(services: s))),
      tile(Icons.account_circle_outlined, 'Моя страница', 'Статистика, любимые треки, плейлисты', () => openPage(UserPage(services: s, email: s.library.me ?? ''))),
      tile(Icons.groups_outlined, 'Компания', 'Друзья, чарт недели, лента, уведомления', () => openPage(CompanyPage(services: s)), dot: unread > 0),
      tile(Icons.download_done_rounded, 'Скачано', 'Треки на телефоне, доступны без интернета', () {
        Navigator.of(context).maybePop();
        setState(() {
          tab = 6;
          visited.add(6);
        });
      }),
      tile(Icons.settings_outlined, 'Настройки', 'Аккаунт, обновления, кэш', () => openPage(SubPage(services: s, title: 'Настройки', child: ProfileTab(services: s))),
          dot: s.updater.available != null),
    ]);
  }

  Widget hl(String text, String q, TextStyle base) {
    final i = q.isEmpty ? -1 : text.toLowerCase().indexOf(q);
    if (i < 0) return Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: base);
    return RichText(
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      text: TextSpan(style: base, children: [
        TextSpan(text: text.substring(0, i)),
        TextSpan(text: text.substring(i, i + q.length), style: TextStyle(color: C.accent)),
        TextSpan(text: text.substring(i + q.length)),
      ]),
    );
  }

  Widget search() {
    final q = query.trim().toLowerCase();
    final lib = s.library;
    final tracks = q.isEmpty
        ? <Track>[]
        : lib.allTracks.where((t) => t.title.toLowerCase().contains(q) || t.displayArtist.toLowerCase().contains(q) || t.displayAlbum.toLowerCase().contains(q)).toList();
    final albums = q.isEmpty ? <Album>[] : lib.albums.where((a) => a.title.toLowerCase().contains(q) || a.artist.toLowerCase().contains(q)).take(12).toList();
    final artists = q.isEmpty ? <Artist>[] : lib.artists.where((a) => a.name.toLowerCase().contains(q)).take(6).toList();
    const rowTitle = TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: C.text);
    const rowSub = TextStyle(fontSize: 13, color: C.muted);
    Widget segment(String label, bool on, VoidCallback onTap) => Expanded(
          child: GestureDetector(
            onTap: onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              decoration: BoxDecoration(color: on ? const Color(0x38FFFFFF) : Colors.transparent, borderRadius: BorderRadius.circular(19)),
              child: Center(child: Text(label, style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: on ? C.text : C.muted))),
            ),
          ),
        );
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 14, 12, 0),
        child: Row(children: [
          Expanded(
            child: Container(
              height: 46,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                color: const Color(0x4D1A1A24),
                borderRadius: BorderRadius.circular(23),
                border: Border.all(color: const Color(0x2EFFFFFF)),
              ),
              child: Row(children: [
                const Icon(Icons.search_rounded, size: 22, color: C.muted),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: searchCtl,
                    onChanged: (v) => setState(() => query = v),
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w500),
                    cursorColor: C.accent,
                    decoration: const InputDecoration(
                      isDense: true,
                      filled: false,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      hintText: 'Трек, альбом или исполнитель',
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ),
                if (query.isNotEmpty)
                  GestureDetector(
                    onTap: () => setState(() {
                      query = '';
                      searchCtl.clear();
                    }),
                    child: const Icon(Icons.cancel_rounded, size: 22, color: Color(0x80FFFFFF)),
                  ),
              ]),
            ),
          ),
          TextButton(
            onPressed: () {
              setState(() {
                query = '';
                searchCtl.clear();
              });
              FocusManager.instance.primaryFocus?.unfocus();
              selectTab(hotbar.first);
            },
            child: const Text('Отмена', style: TextStyle(color: C.text, fontSize: 16, fontWeight: FontWeight.w700)),
          ),
        ]),
      ),
      Container(
        height: 46,
        margin: const EdgeInsets.fromLTRB(20, 12, 20, 6),
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: const Color(0x331A1A24),
          borderRadius: BorderRadius.circular(23),
          border: Border.all(color: const Color(0x2EFFFFFF)),
        ),
        child: Row(children: [
          segment('Библиотека', !webSearch, () => setState(() => webSearch = false)),
          segment('Интернет', webSearch, () => setState(() => webSearch = true)),
        ]),
      ),
      Expanded(
        child: webSearch
            ? WebSearchSection(services: s, query: query)
            : q.isEmpty
                ? const Center(child: Text('Поиск по общей библиотеке', style: TextStyle(color: C.muted)))
                : ListView(padding: const EdgeInsets.only(bottom: 12), children: [
                    if (artists.isNotEmpty) ...[
                      const SectionTitle('Исполнители'),
                      for (final a in artists)
                        InkWell(
                          onTap: () => openTracks(a.name, a.tracks, cover: a.coverTrack),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
                            child: Row(children: [
                              TrackCover(services: s, track: a.coverTrack, size: 56, radius: 28),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  hl(a.name, q, rowTitle.copyWith(fontSize: 17)),
                                  Text('${a.albums} ${plural(a.albums, 'альбом', 'альбома', 'альбомов')} · ${a.tracks.length} ${plural(a.tracks.length, 'песня', 'песни', 'песен')}', style: rowSub),
                                ]),
                              ),
                              const Icon(Icons.chevron_right_rounded, size: 22, color: Color(0x80FFFFFF)),
                            ]),
                          ),
                        ),
                    ],
                    if (albums.isNotEmpty) ...[
                      const SectionTitle('Альбомы'),
                      for (final a in albums)
                        InkWell(
                          onTap: () => openTracks(a.title, a.tracks, cover: a.coverTrack),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
                            child: Row(children: [
                              TrackCover(services: s, track: a.coverTrack, size: 50, radius: 9),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  hl(a.title, q, rowTitle),
                                  hl(a.artist, q, rowSub),
                                ]),
                              ),
                            ]),
                          ),
                        ),
                    ],
                    if (tracks.isNotEmpty) const SectionTitle('Песни'),
                    for (var i = 0; i < tracks.length && i < 200; i++) TrackTile(services: s, track: tracks[i], onTap: () => play(tracks, i), onToast: toast),
                    if (tracks.isEmpty && albums.isEmpty && artists.isEmpty)
                      const Padding(padding: EdgeInsets.all(30), child: Center(child: Text('Ничего не найдено', style: TextStyle(color: C.muted)))),
                  ]),
      ),
    ]);
  }

  Widget downloads() {
    final cache = s.cache;
    final ids = s.settings.offlineTracks;
    final tracks = s.library.allTracks.where((t) => ids.contains(t.id)).toList();
    final ready = tracks.where((t) => cache.has(t.id)).length;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 12, 4),
        child: Row(children: [
          Expanded(
            child: Text(
              tracks.isEmpty
                  ? 'Здесь будут треки, скачанные на телефон'
                  : '$ready из ${tracks.length} · ${formatBytes(cache.offlineBytes)}${cache.pending > 0 ? ' · качается ${cache.pending}' : ''}',
              style: const TextStyle(color: C.muted),
            ),
          ),
          if (tracks.isNotEmpty)
            TextButton(
              onPressed: () async {
                final ok = await confirm(context, 'Убрать все загрузки?', 'Треки останутся в общей библиотеке и в кэше, пока хватает места.');
                if (ok) await cache.setTracksOffline(List.of(ids), false);
              },
              child: Text('Убрать все', style: TextStyle(color: C.accent)),
            ),
        ]),
      ),
      Expanded(child: TrackList(services: s, tracks: tracks, onPlay: play, onToast: toast)),
    ]);
  }

}

String plural(int n, String one, String few, String many) {
  final m10 = n % 10, m100 = n % 100;
  if (m10 == 1 && m100 != 11) return one;
  if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return few;
  return many;
}

/// Настройка нижней панели: до четырёх вкладок, порядок меняется перетаскиванием
class HotbarSettingsPage extends StatefulWidget {
  const HotbarSettingsPage({super.key, required this.services, required this.current, required this.onChanged});
  final MobileServices services;
  final List<int> current;
  final ValueChanged<List<int>> onChanged;
  @override
  State<HotbarSettingsPage> createState() => _HotbarSettingsPageState();
}

class _HotbarSettingsPageState extends State<HotbarSettingsPage> {
  late List<int> active = List.of(widget.current);
  static const maxTabs = 4;
  static const hints = {5: 'внутри «Коллекций»', 6: 'внутри «Коллекций»'};

  void set(List<int> v) {
    setState(() => active = v);
    widget.onChanged(v);
  }

  Widget iconBox(int id, bool on) => Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(color: on ? const Color(0x1FFFFFFF) : const Color(0x14FFFFFF), borderRadius: BorderRadius.circular(10)),
        child: Icon(_MobileShellState.tabMeta[id]!.$3, size: 20, color: on ? C.accent : const Color(0xB3FFFFFF)),
      );

  @override
  Widget build(BuildContext context) {
    final spare = [for (final k in _MobileShellState.tabMeta.keys) if (!active.contains(k)) k];
    final full = active.length >= maxTabs;
    return Backdrop(
      services: widget.services,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
              child: Row(children: [
                Expanded(child: Text('Панель вкладок', style: display(28))),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: FilledButton.styleFrom(shape: const StadiumBorder(), minimumSize: const Size(0, 38), padding: const EdgeInsets.symmetric(horizontal: 18)),
                  child: const Text('Готово', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                ),
              ]),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Text('Выберите до четырёх вкладок и расставьте по порядку. Поиск и плеер на панели всегда на месте.',
                  style: TextStyle(fontSize: 14, height: 1.35, color: C.muted)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
              child: Row(children: [
                Expanded(child: Text('В панели', style: display(19))),
                Text('${active.length} из $maxTabs', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: C.accent)),
              ]),
            ),
            Container(
              margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              decoration: BoxDecoration(color: const Color(0x331A1A24), borderRadius: BorderRadius.circular(20), border: Border.all(color: const Color(0x2EFFFFFF))),
              child: ReorderableListView(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                buildDefaultDragHandles: false,
                proxyDecorator: (child, _, __) => Material(color: Colors.transparent, child: child),
                onReorder: (from, to) {
                  if (to > from) to--;
                  final v = List.of(active);
                  v.insert(to, v.removeAt(from));
                  set(v);
                },
                children: [
                  for (final (i, id) in active.indexed)
                    Container(
                      key: ValueKey('a$id'),
                      height: 54,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(border: i == active.length - 1 ? null : const Border(bottom: BorderSide(color: Color(0x12FFFFFF)))),
                      child: Row(children: [
                        GestureDetector(
                          onTap: active.length <= 1 ? null : () => set([for (final x in active) if (x != id) x]),
                          child: Container(
                            width: 26,
                            height: 26,
                            decoration: BoxDecoration(shape: BoxShape.circle, color: active.length <= 1 ? const Color(0x33FFFFFF) : const Color(0xFFFF8A80)),
                            child: const Icon(Icons.remove_rounded, size: 16, color: Color(0xFF2B0D0B)),
                          ),
                        ),
                        const SizedBox(width: 12),
                        iconBox(id, true),
                        const SizedBox(width: 12),
                        Expanded(child: Text(_MobileShellState.tabMeta[id]!.$1, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600))),
                        ReorderableDragStartListener(index: i, child: const SizedBox(width: 28, height: 32, child: Icon(Icons.drag_handle_rounded, size: 22, color: Color(0x80FFFFFF)))),
                      ]),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
              child: Row(children: [
                Expanded(child: Text('Можно добавить', style: display(19))),
                if (full) const Text('панель заполнена', style: TextStyle(fontSize: 13, color: Color(0x99FFFFFF))),
              ]),
            ),
            Container(
              margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              decoration: BoxDecoration(color: const Color(0x331A1A24), borderRadius: BorderRadius.circular(20), border: Border.all(color: const Color(0x2EFFFFFF))),
              child: Column(children: [
                if (spare.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('Все вкладки уже на панели', style: TextStyle(color: C.muted))),
                for (final (i, id) in spare.indexed)
                  Container(
                    height: 54,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(border: i == spare.length - 1 ? null : const Border(bottom: BorderSide(color: Color(0x12FFFFFF)))),
                    child: Row(children: [
                      GestureDetector(
                        onTap: full ? null : () => set([...active, id]),
                        child: Container(
                          width: 26,
                          height: 26,
                          decoration: BoxDecoration(shape: BoxShape.circle, color: full ? const Color(0x1FFFFFFF) : const Color(0x2EFFFFFF)),
                          child: Icon(Icons.add_rounded, size: 16, color: full ? const Color(0x59FFFFFF) : const Color(0xB3FFFFFF)),
                        ),
                      ),
                      const SizedBox(width: 12),
                      iconBox(id, false),
                      const SizedBox(width: 12),
                      Expanded(child: Text(_MobileShellState.tabMeta[id]!.$1, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: Color(0xD9FFFFFF)))),
                      if (hints[id] != null) Text(hints[id]!, style: const TextStyle(fontSize: 12.5, color: Color(0x99FFFFFF))),
                    ]),
                  ),
              ]),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 12, 24, 0),
              child: Text('Чтобы добавить вкладку, сначала уберите одну из панели. Вкладки, которых нет на панели, остаются доступны из «Коллекций» и меню профиля.',
                  style: TextStyle(fontSize: 12.5, height: 1.4, color: C.muted)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
              child: Center(
                child: FilledButton.tonal(
                  onPressed: () => set(List.of(_MobileShellState.defaultHotbar)),
                  style: FilledButton.styleFrom(shape: const StadiumBorder(), minimumSize: const Size(0, 44), padding: const EdgeInsets.symmetric(horizontal: 22)),
                  child: const Text('Сбросить по умолчанию', style: TextStyle(fontWeight: FontWeight.w600)),
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 12, 24, 0),
              child: Center(child: Text('Это окно открывается и долгим нажатием на панель', style: TextStyle(fontSize: 12.5, color: Color(0x99FFFFFF)))),
            ),
          ]),
        ),
      ),
    );
  }
}

String formatBytes(int b) {
  if (b < 1024 * 1024) return '${(b / 1024).round()} КБ';
  if (b < 1024 * 1024 * 1024) return '${(b / 1024 / 1024).toStringAsFixed(b < 100 * 1024 * 1024 ? 1 : 0)} МБ';
  return '${(b / 1024 / 1024 / 1024).toStringAsFixed(2)} ГБ';
}

Future<bool> confirm(BuildContext context, String title, String text) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (d) => AlertDialog(
      backgroundColor: C.panel,
      title: Text(title),
      content: Text(text, style: const TextStyle(color: C.muted)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Отмена')),
        TextButton(onPressed: () => Navigator.pop(d, true), child: Text('Да', style: TextStyle(color: C.accent))),
      ],
    ),
  );
  return r == true;
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
          itemBuilder: (_, i) => TrackTile(services: services, track: tracks[i], index: i + 1, onTap: () => onPlay(tracks, i), onToast: onToast),
        );
}

class TrackTile extends StatelessWidget {
  const TrackTile({super.key, required this.services, required this.track, required this.onTap, this.onToast, this.index});
  final MobileServices services;
  final Track track;
  final VoidCallback onTap;
  final void Function(String)? onToast;

  /// Номер в списке. Как на ПК: на месте номера у играющего трека значок эквалайзера (на паузе — пауза)
  final int? index;

  void menu(BuildContext context) => showTrackMenu(context, services, track, onToast: onToast);

  @override
  Widget build(BuildContext context) {
    final liked = services.library.isLiked(track.id);
    final playing = services.player.current?.id == track.id;
    return ListTile(
      contentPadding: const EdgeInsets.only(left: 12, right: 4),
      leading: Row(mainAxisSize: MainAxisSize.min, children: [
        if (index != null)
          SizedBox(
            width: 26,
            child: Center(
              child: playing
                  ? Icon(services.player.playing ? Icons.graphic_eq_rounded : Icons.pause_rounded, size: 19, color: C.accent)
                  : Text('$index', style: const TextStyle(color: C.faint, fontSize: 13, fontFeatures: [ui.FontFeature.tabularFigures()])),
            ),
          ),
        TrackCover(services: services, track: track, size: 50),
      ]),
      title: Text(track.title,
          maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w600, color: playing ? C.accent : C.text)),
      subtitle: Row(children: [
        if (services.cache.isTrackOffline(track.id))
          Padding(
            padding: const EdgeInsets.only(right: 5),
            child: services.cache.has(track.id)
                ? Icon(Icons.download_done_rounded, size: 15, color: C.accent)
                : const SizedBox.square(dimension: 12, child: CircularProgressIndicator(strokeWidth: 2)),
          ),
        Expanded(
            child: Text(track.displayArtist, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.muted, fontSize: 13))),
      ]),
      onTap: onTap,
      onLongPress: () => menu(context),
      trailing: IconButton(
        tooltip: 'Ещё',
        onPressed: () => menu(context),
        icon: const Icon(Icons.more_horiz_rounded, color: Color(0xBFFFFFFF), size: 22),
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
    // На весь экран оригинал грузится дольше: пока он идёт, показываем уже готовую копию поменьше
    if (bytes == null && widget.fullscreen) bytes = svc.peek(t, px: 640) ?? svc.peek(t, px: 160);
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

/// Обложка на всю ширину: снизу растворяется в фон, как в Apple Music
class FadeCover extends StatelessWidget {
  const FadeCover({super.key, required this.services, required this.track, required this.width, required this.height});
  final MobileServices services;
  final Track track;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final side = math.max(width, height);
    return ClipRect(
      child: SizedBox(
        width: width,
        height: height,
        child: ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (r) => const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.black, Colors.black, Colors.transparent],
            stops: [0, 0.58, 1],
          ).createShader(r),
          child: OverflowBox(
            alignment: Alignment.topCenter,
            minWidth: 0,
            minHeight: 0,
            maxWidth: side,
            maxHeight: side,
            child: TrackCover(services: services, track: track, size: side, radius: 0, fullscreen: true),
          ),
        ),
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

// ───────────────────────────── скачка ─────────────────────────────

/// «Скачать всё» для альбома, плейлиста или любого списка: ручная скачка, кэш её не вытесняет
class DownloadButton extends StatelessWidget {
  const DownloadButton({super.key, required this.services, required this.tracks});
  final MobileServices services;
  final List<Track> tracks;

  @override
  Widget build(BuildContext context) {
    final cache = services.cache;
    final ids = [for (final t in tracks) t.id];
    final marked = ids.where(cache.isTrackOffline).length;
    final ready = ids.where((id) => cache.isTrackOffline(id) && cache.has(id)).length;
    final all = ids.isNotEmpty && marked == ids.length;
    final busy = all && ready < ids.length;
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: ids.isEmpty
            ? null
            : () {
                cache.setTracksOffline(ids, !all);
                ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(all ? 'Убрано из загрузок' : 'Скачиваем ${ids.length} треков')));
              },
        icon: busy
            ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
            : Icon(all ? Icons.download_done_rounded : Icons.download_rounded),
        label: Text(busy ? 'Скачано $ready из ${ids.length}' : (all ? 'Скачано · убрать' : (marked > 0 ? 'Докачать ($marked из ${ids.length})' : 'Скачать на телефон'))),
      ),
    );
  }
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

  Album? get _album {
    if (tracks.isEmpty) return null;
    final al = services.library.albumOf(tracks.first);
    return al != null && al.title == title ? al : null;
  }

  Artist? get _artist => _album != null ? null : services.library.artist(title.toLowerCase());

  @override
  Widget build(BuildContext context) {
    final lib = services.library;
    final c = cover ?? (tracks.isEmpty ? null : tracks.first);
    final width = MediaQuery.sizeOf(context).width;
    final top = MediaQuery.paddingOf(context).top;
    // Как в макете: обложка 1,13 ширины, нижняя часть растворяется, название лежит на переходе
    final coverH = width * 1.13;
    final heroH = coverH + 42 + 50 + 12;
    var totalMs = 0;
    for (final t in tracks) {
      totalMs += t.durationMs ?? 0;
    }
    final artists = {for (final t in tracks) t.albumArtist.isNotEmpty ? t.albumArtist : t.artist};
    final sub = _album != null && artists.length == 1 && artists.first.isNotEmpty ? artists.first : '';
    final year = tracks.map((t) => t.year).firstWhere((y) => y.isNotEmpty, orElse: () => '');
    final meta = [
      if (year.isNotEmpty) year,
      '${tracks.length} ${QueueSheet._tracksWord(tracks.length)}',
      if (totalMs > 0) QueueSheet.span(totalMs),
    ].join(' · ');
    return Backdrop(
      services: services,
      track: c,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: AnimatedBuilder(
          animation: Listenable.merge([services.cache, services.library, services.player]),
          builder: (context, _) {
            final al = _album;
            final ar = _artist;
            final fav = al != null ? lib.isFavAlbum(al) : (ar != null ? lib.isFavArtist(ar.key) : false);
            return CustomScrollView(slivers: [
              SliverToBoxAdapter(
                child: SizedBox(
                  height: heroH,
                  child: Stack(children: [
                    if (c != null) Positioned(top: 0, left: 0, right: 0, height: coverH, child: FadeCover(services: services, track: c, width: width, height: coverH)),
                    Positioned(
                      left: 18,
                      top: top + 6,
                      child: Glass(
                        radius: 23,
                        color: C.glassLight,
                        child: InkWell(
                          onTap: () => Navigator.of(context).maybePop(),
                          child: const SizedBox(width: 46, height: 46, child: Icon(Icons.chevron_left_rounded, size: 30, color: Colors.white)),
                        ),
                      ),
                    ),
                    Positioned(
                      right: 18,
                      top: top + 6,
                      child: Glass(
                        radius: 23,
                        color: C.glassLight,
                        child: SizedBox(
                          height: 46,
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            const SizedBox(width: 4),
                            SizedBox(
                              width: 52,
                              child: IconButton(
                                  tooltip: 'Поделиться',
                                  onPressed: () {
                                    Clipboard.setData(ClipboardData(text: sub.isEmpty ? title : '$sub — $title'));
                                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Название скопировано')));
                                  },
                                  icon: const Icon(Icons.ios_share_rounded, size: 22, color: Colors.white)),
                            ),
                            SizedBox(
                              width: 52,
                              child: IconButton(
                                  tooltip: 'Ещё',
                                  onPressed: () => _more(context),
                                  icon: const Icon(Icons.more_horiz_rounded, size: 24, color: Colors.white)),
                            ),
                            const SizedBox(width: 4),
                          ]),
                        ),
                      ),
                    ),
                    Positioned(
                      left: 20,
                      right: 20,
                      top: coverH - 52,
                      child: Column(children: [
                        Text(title, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis, style: display(26)),
                        if (sub.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 3),
                            child: Text(sub,
                                textAlign: TextAlign.center,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w400, color: Color(0xE0FFFFFF))),
                          ),
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(meta, style: const TextStyle(color: C.muted, fontSize: 13)),
                        ),
                      ]),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      top: coverH + 42,
                      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                        _CircleBtn(onTap: tracks.isEmpty ? null : () => play(context, shuffle: true), icon: Icons.shuffle_rounded, tooltip: 'Перемешать'),
                        const SizedBox(width: 12),
                        SizedBox(
                          width: 200,
                          height: 50,
                          child: FilledButton.icon(
                            style: FilledButton.styleFrom(shape: const StadiumBorder(), textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                            onPressed: tracks.isEmpty ? null : () => play(context),
                            icon: const Icon(Icons.play_arrow_rounded, size: 26),
                            label: const Text('Воспроизвести'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        _CircleBtn(
                          tooltip: 'В любимое',
                          icon: fav ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                          color: fav ? C.accent : C.text,
                          onTap: al == null && ar == null
                              ? null
                              : () {
                                  HapticFeedback.lightImpact();
                                  if (al != null) {
                                    lib.toggleFavAlbum(al);
                                  } else {
                                    lib.toggleFavArtist(ar!.key);
                                  }
                                },
                        ),
                      ]),
                    ),
                  ]),
                ),
              ),
              SliverToBoxAdapter(
                child: Container(margin: const EdgeInsets.symmetric(horizontal: 18), height: 1, color: const Color(0x1AFFFFFF)),
              ),
              SliverList.builder(
                itemCount: tracks.length,
                itemBuilder: (_, i) => _AlbumRow(
                  services: services,
                  track: tracks[i],
                  index: i + 1,
                  onTap: () => playTracks(context, services, tracks, i),
                  onToast: (m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m))),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 120)),
            ]);
          },
        ),
        bottomNavigationBar: AnimatedBuilder(
          animation: services.player,
          builder: (_, __) => services.player.current == null
              ? const SizedBox.shrink()
              : SafeArea(top: false, child: MiniPlayer(services: services, onOpen: () => showPlayer(context, services))),
        ),
      ),
    );
  }

  void _more(BuildContext context) {
    final p = services.player;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: C.panel,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (sheet) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.playlist_play_rounded),
            title: const Text('Играть следующим'),
            onTap: () {
              for (final t in tracks.reversed) {
                p.playNext(t);
              }
              Navigator.pop(sheet);
            },
          ),
          ListTile(
            leading: const Icon(Icons.queue_music_rounded),
            title: const Text('В конец очереди'),
            onTap: () {
              for (final t in tracks) {
                p.addToQueue(t);
              }
              Navigator.pop(sheet);
            },
          ),
          Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 12), child: DownloadButton(services: services, tracks: tracks)),
        ]),
      ),
    );
  }
}

class _CircleBtn extends StatelessWidget {
  const _CircleBtn({required this.onTap, required this.icon, this.tooltip, this.color = C.text});
  final VoidCallback? onTap;
  final IconData icon;
  final String? tooltip;
  final Color color;
  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip ?? '',
        child: Material(
          color: const Color(0x1FFFFFFF),
          shape: const CircleBorder(side: BorderSide(color: Color(0x2EFFFFFF))),
          child: InkWell(customBorder: const CircleBorder(), onTap: onTap, child: SizedBox(width: 50, height: 50, child: Icon(icon, size: 23, color: color))),
        ),
      );
}

/// Строка трека на странице альбома, как в макете: номер или значок эквалайзера, название, скачивание, «ещё»
class _AlbumRow extends StatelessWidget {
  const _AlbumRow({required this.services, required this.track, required this.index, required this.onTap, required this.onToast});
  final MobileServices services;
  final Track track;
  final int index;
  final VoidCallback onTap;
  final void Function(String) onToast;

  @override
  Widget build(BuildContext context) {
    final playing = services.player.current?.id == track.id;
    final cache = services.cache;
    final marked = cache.isTrackOffline(track.id);
    final ready = marked && cache.has(track.id);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18),
        child: SizedBox(
          height: 48,
          child: Row(children: [
            SizedBox(
              width: 30,
              child: playing
                  ? Icon(services.player.playing ? Icons.graphic_eq_rounded : Icons.pause_rounded, size: 20, color: C.accent)
                  : Text('$index', style: const TextStyle(fontSize: 15, color: Color(0x8CFFFFFF), fontFeatures: [ui.FontFeature.tabularFigures()])),
            ),
            Expanded(
              child: Container(
                height: 48,
                decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0x1AFFFFFF)))),
                child: Row(children: [
                  Expanded(
                    child: Text(track.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 16.5, fontWeight: FontWeight.w500, color: playing ? C.accent : C.text)),
                  ),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      final on = !marked;
                      cache.setTracksOffline([track.id], on);
                      onToast(on ? 'Скачиваем «${track.title}»' : 'Убрано из загрузок');
                    },
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
                      child: Container(
                        width: 20,
                        height: 20,
                        decoration: BoxDecoration(shape: BoxShape.circle, color: ready ? C.accent : const Color(0x33FFFFFF)),
                        child: marked && !ready
                            ? const Padding(padding: EdgeInsets.all(4), child: CircularProgressIndicator(strokeWidth: 2))
                            : Icon(ready ? Icons.check_rounded : Icons.arrow_downward_rounded, size: 13, color: ready ? C.accentInk : const Color(0xBFFFFFFF)),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 30,
                    height: 32,
                    child: IconButton(
                        padding: EdgeInsets.zero,
                        tooltip: 'Ещё',
                        onPressed: () => showTrackMenu(context, services, track, onToast: onToast),
                        icon: const Icon(Icons.more_horiz_rounded, size: 22, color: Color(0xBFFFFFFF))),
                  ),
                ]),
              ),
            ),
          ]),
        ),
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

class StorageCard extends StatelessWidget {
  const StorageCard({super.key, required this.services});
  final MobileServices services;

  @override
  Widget build(BuildContext context) {
    final cache = services.cache;
    const limits = [512, 1024, 2048, 4096, 8192, 16384];
    return AnimatedBuilder(
      animation: cache,
      builder: (_, __) {
        final manual = cache.offlineBytes;
        final auto = (cache.sizeBytes - manual).clamp(0, 1 << 40);
        final limit = services.settings.cacheLimitMb;
        return Glass(
          radius: 16,
          color: C.surface,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Память', style: TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 10),
              Row(children: [
                const Expanded(child: Text('Скачано вручную', style: TextStyle(color: C.muted))),
                Text(formatBytes(manual)),
              ]),
              const SizedBox(height: 4),
              Row(children: [
                const Expanded(child: Text('Кэш прослушанного', style: TextStyle(color: C.muted))),
                Text(formatBytes(auto)),
              ]),
              const SizedBox(height: 12),
              const Text('Лимит кэша (ручные загрузки в него не входят)', style: TextStyle(color: C.muted, fontSize: 12)),
              const SizedBox(height: 6),
              Wrap(spacing: 8, children: [
                for (final mb in limits)
                  ChoiceChip(
                    label: Text(mb >= 1024 ? '${mb ~/ 1024} ГБ' : '$mb МБ'),
                    selected: limit == mb,
                    labelStyle: TextStyle(color: limit == mb ? C.accentInk : C.text, fontWeight: FontWeight.w600),
                    onSelected: (_) => cache.setLimit(mb),
                  ),
              ]),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: () async {
                  if (await confirm(context, 'Очистить кэш?', 'Скачанные вручную треки останутся.')) await cache.clear();
                },
                icon: const Icon(Icons.cleaning_services_rounded),
                label: const Text('Очистить кэш'),
              ),
            ]),
          ),
        );
      },
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
        StorageCard(services: s),
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
    barrierColor: null,
    transitionDuration: const Duration(milliseconds: 340),
    // Закрытие анимирует сама шторка (она едет за пальцем), поэтому у маршрута оно мгновенное
    reverseTransitionDuration: Duration.zero,
    pageBuilder: (_, anim, __) => PlayerSheet(services: services, anim: anim),
    transitionsBuilder: (_, __, ___, child) => child,
  ));
}

/// Плеер — шторка: выезжает снизу, закруглённые углы, тянется за пальцем и уезжает вниз.
/// Позади видно предыдущий экран, он затемняется.
class PlayerSheet extends StatefulWidget {
  const PlayerSheet({super.key, required this.services, required this.anim});
  final MobileServices services;
  final Animation<double> anim;
  @override
  State<PlayerSheet> createState() => _PlayerSheetState();
}

class _PlayerSheetState extends State<PlayerSheet> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 260));
  double _dy = 0;
  double _from = 0;
  double _to = 0;
  bool _closing = false;
  double _h = 800;

  @override
  void initState() {
    super.initState();
    _c.addListener(() => setState(() => _dy = _from + (_to - _from) * Curves.easeOutCubic.transform(_c.value)));
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Future<void> close() async {
    if (_closing) return;
    _closing = true;
    final nav = Navigator.of(context, rootNavigator: true);
    _from = _dy;
    _to = _h;
    await _c.forward(from: 0);
    if (nav.mounted) nav.pop();
  }

  void _end(double v) {
    if (_closing) return;
    if (v > 700 || _dy > _h * 0.25) {
      close();
    } else {
      _from = _dy;
      _to = 0;
      _c.forward(from: 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    _h = MediaQuery.sizeOf(context).height;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) close();
      },
      child: AnimatedBuilder(
        animation: widget.anim,
        builder: (context, _) {
          final open = Curves.easeOutCubic.transform(widget.anim.value);
          final shown = (1 - _dy / _h).clamp(0.0, 1.0);
          return Stack(children: [
            Positioned.fill(child: ColoredBox(color: Color.fromRGBO(0, 0, 0, 0.6 * open * shown))),
            Positioned.fill(
              child: Transform.translate(
              offset: Offset(0, (1 - open) * _h + _dy),
              child: GestureDetector(
                onVerticalDragUpdate: (d) {
                  if (_closing) return;
                  _c.stop();
                  setState(() => _dy = (_dy + d.delta.dy).clamp(0.0, _h));
                },
                onVerticalDragEnd: (d) => _end(d.primaryVelocity ?? 0),
                child: ClipRRect(
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(38)),
                  child: ColoredBox(
                    color: C.bg,
                    child: Backdrop(services: widget.services, child: FullPlayer(services: widget.services, onClose: close)),
                  ),
                ),
              ),
            )),
          ]);
        },
      ),
    );
  }
}

/// Куда перейти из плеера
class _GoTarget {
  _GoTarget(this.title, this.tracks, this.cover);
  final String title;
  final List<Track> tracks;
  final Track? cover;
}

/// Плашка «Перейти к артисту / к альбому» под названием трека
class _GoMenu extends StatelessWidget {
  const _GoMenu({required this.rect, required this.track, required this.library});
  final Rect rect;
  final Track track;
  final LibraryController library;

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    final rows = <Widget>[];
    Widget row(IconData icon, String title, String sub, _GoTarget target) => InkWell(
          onTap: () => Navigator.of(context).pop(target),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            child: Row(children: [
              Icon(icon, size: 24, color: C.text),
              const SizedBox(width: 16),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                  Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, color: C.muted)),
                ]),
              ),
            ]),
          ),
        );
    for (final name in track.artists) {
      final a = library.artist(name.toLowerCase());
      if (a != null) rows.add(row(Icons.mic_external_on_rounded, 'Перейти к артисту', a.name, _GoTarget(a.name, a.tracks, a.coverTrack)));
    }
    final al = library.albumOf(track);
    if (al != null && track.album.isNotEmpty) {
      rows.add(row(Icons.album_rounded, 'Перейти к альбому', al.title, _GoTarget(al.title, al.tracks, al.coverTrack)));
    }
    if (rows.isEmpty) return const SizedBox.shrink();
    return Stack(children: [
      Positioned(
        left: math.min(rect.left + 36, w - 316),
        top: rect.bottom + 6,
        width: 300,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(28),
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 24, sigmaY: 24),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xD9261C22),
                borderRadius: BorderRadius.circular(28),
                border: Border.all(color: C.line),
              ),
              child: Material(type: MaterialType.transparency, child: Column(mainAxisSize: MainAxisSize.min, children: rows)),
            ),
          ),
        ),
      ),
    ]);
  }
}

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key, required this.services, required this.onOpen, this.compact = false, this.margin = const EdgeInsets.fromLTRB(10, 0, 10, 8)});
  final MobileServices services;
  final VoidCallback onOpen;

  /// Свёрнутая нижняя панель: плеер зажат между круглыми кнопками, остаётся только пауза
  final bool compact;
  final EdgeInsets margin;

  @override
  Widget build(BuildContext context) {
    final p = services.player;
    final t = p.current;
    if (t == null) return const SizedBox.shrink();
    final h = compact ? 56.0 : 60.0;
    final coverW = compact ? 88.0 : 108.0;
    return Glass(
      radius: 30,
      color: C.glass,
      margin: margin,
      child: SizedBox(
        height: h,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onOpen,
          // Свайп влево/вправо — следующий/предыдущий трек, вверх — открыть плеер
          onHorizontalDragEnd: (d) {
            final v = d.primaryVelocity ?? 0;
            if (v < -300) {
              HapticFeedback.selectionClick();
              p.next();
            } else if (v > 300) {
              HapticFeedback.selectionClick();
              p.previous();
            }
          },
          onVerticalDragEnd: (d) {
            if ((d.primaryVelocity ?? 0) < -300) onOpen();
          },
          child: Stack(children: [
            // Фон-подсветка цвета акцента слева, под обложкой
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: [C.accent.withValues(alpha: 0.16), Colors.transparent], stops: const [0, 0.7]),
                ),
              ),
            ),
            // Обложка во всю высоту, справа растворяется в капсулу, как на ПК
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: coverW,
              child: ShaderMask(
                blendMode: BlendMode.dstIn,
                shaderCallback: (r) => const LinearGradient(colors: [Colors.black, Colors.black, Colors.transparent], stops: [0, 0.5, 1]).createShader(r),
                child: ClipRect(
                  child: OverflowBox(
                    alignment: Alignment.center,
                    minWidth: 0,
                    minHeight: 0,
                    maxWidth: coverW,
                    maxHeight: coverW,
                    child: TrackCover(services: services, track: t, size: coverW, radius: 0),
                  ),
                ),
              ),
            ),
            Row(children: [
              SizedBox(width: coverW - 26),
              Expanded(
                child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16, color: Colors.white)),
                  const SizedBox(height: 1),
                  Text(t.displayArtist, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, color: Color(0xB8FFFFFF))),
                ]),
              ),
              SizedBox(
                  width: 46,
                  height: 46,
                  child: IconButton(
                      padding: EdgeInsets.zero,
                      onPressed: p.toggle,
                      icon: Icon(p.playing ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 30, color: Colors.white))),
              if (!compact)
                SizedBox(
                    width: 46,
                    height: 46,
                    child: IconButton(padding: EdgeInsets.zero, onPressed: p.next, icon: const Icon(Icons.fast_forward_rounded, size: 32, color: Colors.white))),
              SizedBox(width: compact ? 8 : 10),
            ]),
            Positioned(
              left: 26,
              right: 26,
              bottom: 0,
              child: ValueListenableBuilder<Duration>(
                valueListenable: p.position,
                builder: (_, pos, __) => LinearProgressIndicator(
                  value: p.duration.inMilliseconds <= 0 ? 0 : (pos.inMilliseconds / p.duration.inMilliseconds).clamp(0.0, 1.0).toDouble(),
                  minHeight: 2,
                  color: C.accent,
                  backgroundColor: Colors.transparent,
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

class FullPlayer extends StatefulWidget {
  const FullPlayer({super.key, required this.services, required this.onClose});
  final MobileServices services;
  final Future<void> Function() onClose;
  @override
  State<FullPlayer> createState() => _FullPlayerState();
}

class _FullPlayerState extends State<FullPlayer> {
  MobileServices get services => widget.services;
  bool lyrics = false;
  final GlobalKey _nameKey = GlobalKey();

  /// Нажатие на название/артиста: плашка перехода к артисту или альбому
  Future<void> goMenu(Track t) async {
    final box = _nameKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    final nav = Navigator.of(context, rootNavigator: true);
    final pick = await showGeneralDialog<_GoTarget>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Закрыть',
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 160),
      pageBuilder: (_, __, ___) => _GoMenu(rect: rect, track: t, library: services.library),
      transitionBuilder: (_, a, __, child) => FadeTransition(
        opacity: a,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.92, end: 1).animate(CurvedAnimation(parent: a, curve: Curves.easeOut)),
          alignment: Alignment.topLeft,
          child: child,
        ),
      ),
    );
    if (pick == null) return;
    await widget.onClose();
    nav.push(MaterialPageRoute<void>(
        builder: (_) => CollectionPage(services: services, title: pick.title, tracks: pick.tracks, cover: pick.cover)));
  }

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
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(38))),
      clipBehavior: Clip.antiAlias,
      builder: (_) => FractionallySizedBox(heightFactor: 0.94, child: QueueSheet(services: services)),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.transparent,
        body: GestureDetector(
          child: AnimatedBuilder(
            animation: Listenable.merge([services.player, services.library, services.cache, services.wave]),
            builder: (context, __) {
              final p = services.player;
              final t = p.current;
              if (t == null) return const Center(child: Text('Ничего не играет'));
              final size = MediaQuery.sizeOf(context);
              final heroH = size.height * 0.59;
              final topPad = MediaQuery.paddingOf(context).top;
              final heroSpace = math.max(120.0, heroH - topPad - 56 - 78);
              final body = SafeArea(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 30),
                  child: Column(children: [
                    if (lyrics) ...[
                      const SizedBox(height: 22),
                      // Текст песни: сверху маленькая обложка; нажатие на неё возвращает к большой обложке
                      Row(children: [
                        GestureDetector(
                          onTap: () => setState(() => lyrics = false),
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                              boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 18, offset: Offset(0, 8))],
                            ),
                            child: TrackCover(services: services, track: t, size: 66, radius: 12),
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => goMenu(t),
                            child: Column(key: _nameKey, crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
                              const SizedBox(height: 2),
                              Text(t.displayArtist, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.muted, fontSize: 15)),
                            ]),
                          ),
                        ),
                        const SizedBox(width: 8),
                        _RoundBtn(
                            onTap: () => services.library.toggleLike(t.id),
                            icon: Icon(services.library.isLiked(t.id) ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                                size: 21, color: services.library.isLiked(t.id) ? C.accent : Colors.white)),
                        const SizedBox(width: 8),
                        _RoundBtn(
                            onTap: () => showTrackMenu(context, services, t, onToast: (m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)))),
                            icon: const Icon(Icons.more_horiz_rounded, size: 22, color: Colors.white)),
                      ]),
                      const SizedBox(height: 8),
                      Expanded(child: LyricsView(services: services, track: t)),
                    ] else ...[
                      const Spacer(),
                      // Название, исполнитель, «любимое» и «ещё» — как в макете
                      Row(children: [
                        Expanded(
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => goMenu(t),
                            child: Column(key: _nameKey, crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(t.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 23, fontWeight: FontWeight.w600, letterSpacing: -0.3, color: Colors.white)),
                              const SizedBox(height: 2),
                              Text(t.displayArtist,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w400, color: Color(0x9EFFFFFF))),
                            ]),
                          ),
                        ),
                        if (services.wave.active) ...[
                          const SizedBox(width: 8),
                          _RoundBtn(
                              onTap: services.wave.dislike,
                              icon: const Icon(Icons.thumb_down_alt_outlined, size: 21, color: Colors.white)),
                          const SizedBox(width: 8),
                          _RoundBtn(
                              onTap: services.wave.upvote,
                              icon: Icon(services.wave.isUpvoted(t.id) ? Icons.thumb_up_alt_rounded : Icons.thumb_up_alt_outlined,
                                  size: 21, color: services.wave.isUpvoted(t.id) ? C.accent : Colors.white)),
                        ],
                        const SizedBox(width: 12),
                        _RoundBtn(
                            onTap: () {
                              HapticFeedback.lightImpact();
                              services.library.toggleLike(t.id);
                            },
                            icon: Icon(services.library.isLiked(t.id) ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                                size: 22, color: services.library.isLiked(t.id) ? C.accent : Colors.white)),
                        const SizedBox(width: 12),
                        _RoundBtn(
                            onTap: () => showTrackMenu(context, services, t, onToast: (m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)))),
                            icon: const Icon(Icons.more_horiz_rounded, size: 24, color: Colors.white)),
                      ]),
                      const SizedBox(height: 22),
                      ValueListenableBuilder<Duration>(
                        valueListenable: p.position,
                        builder: (_, position, __) {
                          final max = p.duration.inMilliseconds.toDouble();
                          final value = max <= 0 ? 0.0 : position.inMilliseconds.toDouble().clamp(0.0, max).toDouble();
                          final ms = t.durationMs ?? p.duration.inMilliseconds;
                          final kbps = ms > 0 && t.size > 0 ? (t.size * 8 / ms).round() : 0;
                          return Column(children: [
                            _FlatBar(
                              value: max <= 0 ? 0 : value / max,
                              onChanged: max <= 0 ? null : (v) => p.seek(Duration(milliseconds: (v * max).round())),
                            ),
                            const SizedBox(height: 9),
                            Stack(alignment: Alignment.center, children: [
                              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                                Text(time(position), style: const TextStyle(color: Color(0x8CFFFFFF), fontSize: 12.5, fontWeight: FontWeight.w500)),
                                Text('−${time(p.duration - position < Duration.zero ? Duration.zero : p.duration - position)}',
                                    style: const TextStyle(color: Color(0x8CFFFFFF), fontSize: 12.5, fontWeight: FontWeight.w500)),
                              ]),
                              if (kbps > 0)
                                Text('$kbps кбит/с', style: const TextStyle(color: Color(0x99FFFFFF), fontSize: 12.5, fontWeight: FontWeight.w600)),
                            ]),
                          ]);
                        },
                      ),
                      const SizedBox(height: 21),
                      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                        SizedBox(
                          width: 64,
                          height: 64,
                          child: IconButton(
                              padding: EdgeInsets.zero,
                              onPressed: p.previous,
                              icon: const Icon(Icons.fast_rewind_rounded, size: 48, color: Colors.white)),
                        ),
                        DecoratedBox(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: C.accent,
                            boxShadow: [BoxShadow(color: C.accent.withValues(alpha: 0.28), blurRadius: 30, offset: const Offset(0, 12))],
                          ),
                          child: Material(
                            color: Colors.transparent,
                            shape: const CircleBorder(),
                            child: InkWell(
                              customBorder: const CircleBorder(),
                              onTap: p.toggle,
                              child: SizedBox(
                                  width: 82,
                                  height: 82,
                                  child: Icon(p.playing ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 46, color: C.accentInk)),
                            ),
                          ),
                        ),
                        SizedBox(
                          width: 64,
                          height: 64,
                          child: IconButton(
                              padding: EdgeInsets.zero,
                              onPressed: p.next,
                              icon: const Icon(Icons.fast_forward_rounded, size: 48, color: Colors.white)),
                        ),
                      ]),
                      const SizedBox(height: 36),
                      Row(children: [
                        const Icon(Icons.volume_mute_rounded, size: 20, color: Color(0x99FFFFFF)),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _FlatBar(
                            value: (p.volume / 100).clamp(0.0, 1.0),
                            onChanged: (v) => p.setVolume(v * 100, save: true),
                          ),
                        ),
                        const SizedBox(width: 12),
                        const Icon(Icons.volume_up_rounded, size: 24, color: Color(0x99FFFFFF)),
                      ]),
                      const SizedBox(height: 20),
                      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                        SizedBox(
                          width: 50,
                          height: 50,
                          child: IconButton(
                              tooltip: 'Текст песни',
                              onPressed: () => setState(() => lyrics = true),
                              icon: const Icon(Icons.lyrics_outlined, size: 26, color: Color(0xBFFFFFFF))),
                        ),
                        const _OutputPill(),
                        SizedBox(
                          width: 50,
                          height: 50,
                          child: Stack(alignment: Alignment.center, children: [
                            IconButton(
                                tooltip: 'Очередь',
                                onPressed: () => queue(context),
                                icon: const Icon(Icons.queue_music_rounded, size: 26, color: Color(0xBFFFFFFF))),
                            Positioned(
                              right: 2,
                              top: -2,
                              child: Container(
                                width: 20,
                                height: 20,
                                decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0x33FFFFFF)),
                                child: Icon(p.repeat == RepeatSetting.one ? Icons.repeat_one_rounded : Icons.repeat_rounded,
                                    size: 12, color: p.repeat == RepeatSetting.off ? const Color(0x99FFFFFF) : C.accent),
                              ),
                            ),
                          ]),
                        ),
                      ]),
                      const SizedBox(height: 8),
                    ],
                  ]),
                ),
              );
              return Stack(children: [
                if (!lyrics)
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    height: heroH,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onHorizontalDragEnd: (d) {
                        final v = d.primaryVelocity ?? 0;
                        if (v < -300) {
                          HapticFeedback.selectionClick();
                          p.next();
                        } else if (v > 300) {
                          HapticFeedback.selectionClick();
                          p.previous();
                        }
                      },
                      child: FadeCover(services: services, track: t, width: size.width, height: heroH),
                    ),
                  ),
                body,
                // Ручка шторки: потянуть вниз или нажать — закрыть
                Positioned(
                  top: topPad + 6,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: widget.onClose,
                      child: const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 40, vertical: 8),
                        child: SizedBox(width: 54, height: 5, child: DecoratedBox(decoration: BoxDecoration(color: Color(0x73FFFFFF), borderRadius: BorderRadius.all(Radius.circular(3))))),
                      ),
                    ),
                  ),
                ),
              ]);
            },
          ),
        ),
      );
}

/// Круглая стеклянная кнопка плеера (44 px)
class _RoundBtn extends StatelessWidget {
  const _RoundBtn({required this.onTap, required this.icon});
  final VoidCallback onTap;
  final Widget icon;
  @override
  Widget build(BuildContext context) => Material(
        color: const Color(0x24FFFFFF),
        shape: const CircleBorder(),
        child: InkWell(customBorder: const CircleBorder(), onTap: onTap, child: SizedBox(width: 44, height: 44, child: Center(child: icon))),
      );
}

/// Плоский ползунок из макета: 6 px, без бегунка, белый на светлом фоне
class _FlatBar extends StatelessWidget {
  const _FlatBar({required this.value, required this.onChanged});
  final double value;
  final ValueChanged<double>? onChanged;
  @override
  Widget build(BuildContext context) => SizedBox(
        height: 22,
        child: SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 6,
            activeTrackColor: const Color(0xB8FFFFFF),
            inactiveTrackColor: const Color(0x33FFFFFF),
            disabledActiveTrackColor: const Color(0xB8FFFFFF),
            disabledInactiveTrackColor: const Color(0x33FFFFFF),
            thumbShape: SliderComponentShape.noThumb,
            overlayShape: SliderComponentShape.noOverlay,
            trackShape: const RoundedRectSliderTrackShape(),
          ),
          child: Slider(value: value.clamp(0.0, 1.0), onChanged: onChanged),
        ),
      );
}

/// Куда сейчас идёт звук: наушники, колонка или динамик телефона
class _OutputPill extends StatefulWidget {
  const _OutputPill();
  @override
  State<_OutputPill> createState() => _OutputPillState();
}

class _OutputPillState extends State<_OutputPill> {
  String name = 'Телефон';
  bool external = false;
  StreamSubscription<void>? sub;

  @override
  void initState() {
    super.initState();
    _read();
    AudioSession.instance.then((s) {
      if (!mounted) return;
      sub = s.devicesChangedEventStream.listen((_) => _read());
    }).catchError((_) {});
  }

  @override
  void dispose() {
    sub?.cancel();
    super.dispose();
  }

  Future<void> _read() async {
    try {
      final s = await AudioSession.instance;
      final out = (await s.getDevices(includeInputs: false)).where((d) => d.isOutput).toList();
      AudioDevice? ext;
      for (final d in out) {
        final k = d.type.toString().toLowerCase();
        if (!k.contains('builtin')) {
          ext = d;
          break;
        }
      }
      if (!mounted) return;
      setState(() {
        external = ext != null;
        name = ext != null && ext.name.trim().isNotEmpty ? ext.name.trim() : 'Телефон';
      });
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) => Container(
        height: 40,
        constraints: const BoxConstraints(maxWidth: 190),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(color: const Color(0x1FFFFFFF), borderRadius: BorderRadius.circular(20)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(external ? Icons.headphones_rounded : Icons.smartphone_rounded, size: 18, color: C.accent),
          const SizedBox(width: 8),
          Flexible(
            child: Text(name,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: Color(0xE0FFFFFF))),
          ),
        ]),
      );
}

/// Меню трека как в макете: размытый фон, строка с треком, быстрые действия и список
Future<void> showTrackMenu(BuildContext context, MobileServices services, Track track, {void Function(String)? onToast}) {
  final nav = Navigator.of(context, rootNavigator: true);
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Закрыть',
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (ctx, _, __) => _TrackMenu(services: services, track: track, onToast: onToast, nav: nav),
    transitionBuilder: (_, a, __, child) => FadeTransition(opacity: a, child: child),
  );
}

class _TrackMenu extends StatelessWidget {
  const _TrackMenu({required this.services, required this.track, required this.nav, this.onToast});
  final MobileServices services;
  final Track track;
  final NavigatorState nav;
  final void Function(String)? onToast;

  @override
  Widget build(BuildContext context) {
    final p = services.player;
    final lib = services.library;
    void close() => Navigator.of(context).pop();
    Future<void> openCollection(String title, List<Track> tracks, Track? cover) async {
      close();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      nav.push(MaterialPageRoute<void>(builder: (_) => CollectionPage(services: services, title: title, tracks: tracks, cover: cover)));
    }

    Widget item(IconData icon, String text, VoidCallback onTap, {Color color = C.text}) => InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: SizedBox(
            height: 46,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(children: [
                Icon(icon, size: 22, color: color),
                const SizedBox(width: 14),
                Expanded(child: Text(text, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: color))),
              ]),
            ),
          ),
        );
    Widget quick(IconData icon, String text, VoidCallback onTap, {Color color = C.text}) => Expanded(
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(0, 12, 0, 10),
              child: Column(children: [
                Icon(icon, size: 24, color: color),
                const SizedBox(height: 6),
                Text(text, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: color)),
              ]),
            ),
          ),
        );
    const sep = Padding(padding: EdgeInsets.symmetric(horizontal: 12, vertical: 5), child: Divider(height: 1, thickness: 1, color: Color(0x24FFFFFF)));

    final liked = lib.isLiked(track.id);
    final offline = services.cache.isTrackOffline(track.id);
    final album = lib.albumOf(track);
    final artist = track.artists.isEmpty ? null : lib.artist(track.artists.first.toLowerCase());

    return Material(
      type: MaterialType.transparency,
      child: Stack(children: [
        Positioned.fill(
          child: GestureDetector(
            onTap: close,
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 7, sigmaY: 7),
              child: const ColoredBox(color: Color(0x800A0A18)),
            ),
          ),
        ),
        SafeArea(
          child: Center(
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Container(
                  height: 58,
                  margin: const EdgeInsets.symmetric(horizontal: 16),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: const Color(0x29FFFFFF),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0x42FFFFFF)),
                    boxShadow: const [BoxShadow(color: Color(0x73000000), blurRadius: 34, offset: Offset(0, 14))],
                  ),
                  child: Row(children: [
                    TrackCover(services: services, track: track, size: 40, radius: 7),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600)),
                        Text('${track.displayArtist}${track.album.isEmpty ? '' : ' · ${track.album}'}',
                            maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, color: Color(0xBFFFFFFF))),
                      ]),
                    ),
                    if ((track.durationMs ?? 0) > 0)
                      Text(_FullPlayerState.time(Duration(milliseconds: track.durationMs!)), style: const TextStyle(fontSize: 13.5, color: Color(0xB8FFFFFF))),
                  ]),
                ),
                const SizedBox(height: 14),
                ClipRRect(
                  borderRadius: BorderRadius.circular(26),
                  child: BackdropFilter(
                    filter: ui.ImageFilter.blur(sigmaX: 34, sigmaY: 34),
                    child: Container(
                      width: 318,
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: const Color(0xB31E1E28),
                        borderRadius: BorderRadius.circular(26),
                        border: Border.all(color: const Color(0x33FFFFFF)),
                      ),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Row(children: [
                          quick(liked ? Icons.favorite_rounded : Icons.favorite_border_rounded, liked ? 'В любимом' : 'В любимое', () {
                            lib.toggleLike(track.id);
                            close();
                          }, color: liked ? C.accent : C.text),
                          quick(offline ? Icons.download_done_rounded : Icons.download_rounded, 'Офлайн', () {
                            final on = !offline;
                            services.cache.setTracksOffline([track.id], on);
                            close();
                            onToast?.call(on ? 'Скачиваем «${track.title}»' : 'Убрано из загрузок');
                          }, color: offline ? C.accent : C.text),
                          quick(Icons.ios_share_rounded, 'Поделиться', () {
                            Clipboard.setData(ClipboardData(text: '${track.displayArtist} — ${track.title}'));
                            close();
                            onToast?.call('Название скопировано');
                          }),
                        ]),
                        sep,
                        item(Icons.playlist_play_rounded, 'Играть следующим', () {
                          p.playNext(track);
                          close();
                          onToast?.call('Сыграет следующим');
                        }),
                        item(Icons.queue_music_rounded, 'В конец очереди', () {
                          p.addToQueue(track);
                          close();
                          onToast?.call('Добавлено в очередь');
                        }),
                        item(Icons.playlist_add_rounded, 'Добавить в плейлист', () async {
                          final lists = lib.visiblePlaylists;
                          close();
                          if (lists.isEmpty) {
                            onToast?.call('Плейлистов пока нет');
                            return;
                          }
                          final ctx = nav.context;
                          final pick = await showModalBottomSheet<Playlist>(
                            context: ctx,
                            backgroundColor: C.panel,
                            shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
                            builder: (sheet) => SafeArea(
                              child: ListView(shrinkWrap: true, children: [
                                const Padding(padding: EdgeInsets.all(16), child: Text('В плейлист', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700))),
                                for (final pl in lists)
                                  ListTile(title: Text(pl.name, maxLines: 1, overflow: TextOverflow.ellipsis), onTap: () => Navigator.pop(sheet, pl)),
                              ]),
                            ),
                          );
                          if (pick != null) {
                            lib.addToPlaylist(pick.id, [track.id]);
                            onToast?.call('Добавлено в «${pick.name}»');
                          }
                        }),
                        if (album != null && track.album.isNotEmpty)
                          item(Icons.album_rounded, 'Открыть альбом', () => openCollection(album.title, album.tracks, album.coverTrack)),
                        if (artist != null)
                          item(Icons.mic_external_on_rounded, 'Страница исполнителя', () => openCollection(artist.name, artist.tracks, artist.coverTrack)),
                      ]),
                    ),
                  ),
                ),
              ]),
            ),
          ),
        ),
      ]),
    );
  }
}

class QueueSheet extends StatelessWidget {
  const QueueSheet({super.key, required this.services});
  final MobileServices services;

  static String span(int ms) {
    final m = (ms / 60000).round();
    return m >= 60 ? '${m ~/ 60} ч ${m % 60} мин' : '$m мин';
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: services.player,
        builder: (_, __) {
          final p = services.player;
          final ids = p.queue;
          final cur = p.index >= 0 && p.index < ids.length ? services.library.data.tracks[ids[p.index]] : null;
          final next = [for (var i = p.index + 1; i < ids.length; i++) i];
          var totalMs = 0;
          for (final i in next) {
            totalMs += services.library.data.tracks[ids[i]]?.durationMs ?? 0;
          }
          Widget pill(String text, IconData icon, bool on, VoidCallback onTap) => Expanded(
                child: Material(
                  color: C.glassLight,
                  shape: const StadiumBorder(side: BorderSide(color: Color(0x2EFFFFFF))),
                  child: InkWell(
                    customBorder: const StadiumBorder(),
                    onTap: onTap,
                    child: SizedBox(
                      height: 44,
                      child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                        Icon(icon, size: 20, color: on ? C.accent : C.text),
                        const SizedBox(width: 8),
                        Text(text, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: on ? C.accent : C.text)),
                      ]),
                    ),
                  ),
                ),
              );
          return DecoratedBox(
            decoration: const BoxDecoration(
              color: C.bg,
              gradient: RadialGradient(center: Alignment(0, -1.1), radius: 1.1, colors: [Color(0x66E0527B), Color(0x00E0527B)]),
            ),
            child: Column(children: [
              const SizedBox(height: 12),
              Container(width: 42, height: 5, decoration: BoxDecoration(color: const Color(0x73FFFFFF), borderRadius: BorderRadius.circular(3))),
              Expanded(
                child: ReorderableListView.builder(
                  buildDefaultDragHandles: false,
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                  itemCount: next.length,
                  proxyDecorator: (child, _, __) => Material(color: Colors.transparent, child: child),
                  onReorder: (from, to) {
                    if (to > from) to--;
                    p.moveInQueue(next[from], next[to]);
                  },
                  header: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 34, 4, 0),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                        Expanded(child: Text('Очередь', style: display(32))),
                        Material(
                          color: C.glassLight,
                          shape: const StadiumBorder(side: BorderSide(color: Color(0x2EFFFFFF))),
                          child: InkWell(
                            customBorder: const StadiumBorder(),
                            onTap: () {
                              for (var i = ids.length - 1; i > p.index; i--) {
                                p.removeAt(i);
                              }
                            },
                            child: const SizedBox(
                                height: 36, child: Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: Center(child: Text('Очистить', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600))))),
                          ),
                        ),
                      ]),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 14, 4, 0),
                      child: Row(children: [
                        pill('Перемешать', Icons.shuffle_rounded, p.shuffle, p.toggleShuffle),
                        const SizedBox(width: 10),
                        pill(p.repeat == RepeatSetting.one ? 'Повтор: один' : 'Повтор', p.repeat == RepeatSetting.one ? Icons.repeat_one_rounded : Icons.repeat_rounded,
                            p.repeat != RepeatSetting.off, p.cycleRepeat),
                      ]),
                    ),
                    if (cur != null) ...[
                      Padding(padding: const EdgeInsets.fromLTRB(4, 22, 4, 0), child: Text('Сейчас играет', style: display(19))),
                      Container(
                        height: 62,
                        margin: const EdgeInsets.only(top: 10),
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        decoration: BoxDecoration(
                          color: C.accent.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: C.accent.withValues(alpha: 0.5)),
                        ),
                        child: Row(children: [
                          TrackCover(services: services, track: cur, size: 44, radius: 8),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(cur.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600, color: C.accent)),
                              Text(cur.displayArtist, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, color: Color(0xB8FFFFFF))),
                            ]),
                          ),
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: Icon(p.playing ? Icons.graphic_eq_rounded : Icons.pause_rounded, size: 22, color: C.accent),
                          ),
                        ]),
                      ),
                    ],
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 22, 4, 6),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
                        Expanded(child: Text('Далее', style: display(19))),
                        Text(next.isEmpty ? 'пусто' : '${next.length} ${_tracksWord(next.length)}${totalMs > 0 ? ' · ${span(totalMs)}' : ''}',
                            style: const TextStyle(fontSize: 13, color: Color(0xB8FFFFFF))),
                      ]),
                    ),
                  ]),
                  itemBuilder: (_, k) {
                    final qi = next[k];
                    final t = services.library.data.tracks[ids[qi]];
                    if (t == null) return SizedBox.shrink(key: ValueKey('q$k${ids[qi]}'));
                    return InkWell(
                      key: ValueKey('q${ids[qi]}$qi'),
                      onTap: () => p.jumpTo(qi),
                      child: Container(
                        height: 60,
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0x12FFFFFF)))),
                        child: Row(children: [
                          TrackCover(services: services, track: t, size: 44, radius: 8),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                              Text(t.displayArtist, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, color: Color(0xB8FFFFFF))),
                            ]),
                          ),
                          if ((t.durationMs ?? 0) > 0)
                            Text(_FullPlayerState.time(Duration(milliseconds: t.durationMs!)), style: const TextStyle(fontSize: 13, color: Color(0x9EFFFFFF))),
                          SizedBox(
                            width: 32,
                            height: 32,
                            child: IconButton(
                                padding: EdgeInsets.zero,
                                tooltip: 'Убрать из очереди',
                                onPressed: () => p.removeAt(qi),
                                icon: const Icon(Icons.close_rounded, size: 20, color: Color(0x99FFFFFF))),
                          ),
                          ReorderableDragStartListener(
                            index: k,
                            child: const SizedBox(width: 28, height: 32, child: Icon(Icons.drag_handle_rounded, size: 22, color: Color(0x8CFFFFFF))),
                          ),
                        ]),
                      ),
                    );
                  },
                ),
              ),
            ]),
          );
        },
      );

  static String _tracksWord(int n) {
    final m10 = n % 10, m100 = n % 100;
    if (m10 == 1 && m100 != 11) return 'трек';
    if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return 'трека';
    return 'треков';
  }
}

/// «Играет на другом устройстве»: тот же аккаунт слушает на ПК или втором телефоне — можно продолжить здесь,
/// с того же трека и того же места
class HandoffCard extends StatelessWidget {
  const HandoffCard({super.key, required this.services});
  final MobileServices services;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: Listenable.merge([services.social, services.player]),
        builder: (context, _) {
          final n = services.social.otherDevice;
          final p = services.player;
          if (n == null) return const SizedBox.shrink();
          final fresh = Member.nowSynced.difference(n.at) < const Duration(minutes: 20);
          final track = services.library.data.tracks[services.library.data.resolve(n.trackId)];
          if (!fresh || track == null || (p.playing && p.current?.id == track.id)) return const SizedBox.shrink();
          final where = n.device.isEmpty ? 'на компьютере' : 'на другом устройстве';
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Glass(
              radius: 18,
              color: C.surface,
              child: InkWell(
                onTap: () async {
                  final at = n.estimate();
                  await playTracks(context, services, [track], 0);
                  // Трек должен успеть открыться, иначе перемотка сбросится
                  await Future<void>.delayed(const Duration(milliseconds: 600));
                  await services.player.seek(at);
                },
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(children: [
                    TrackCover(services: services, track: track, size: 50, radius: 12),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(n.playing ? 'Играет $where' : 'Остановлено $where', style: TextStyle(color: C.accent, fontSize: 12, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 2),
                        Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
                        Text(track.displayArtist, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.muted, fontSize: 13)),
                      ]),
                    ),
                    FilledButton(
                      onPressed: null,
                      style: FilledButton.styleFrom(disabledBackgroundColor: C.accent, disabledForegroundColor: C.accentInk),
                      child: const Text('Продолжить'),
                    ),
                  ]),
                ),
              ),
            ),
          );
        },
      );
}
