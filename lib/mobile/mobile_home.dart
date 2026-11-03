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
  int section = 0;
  bool webSearch = false;
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

  Widget tabPage(int i) {
    if (!visited.contains(i)) return const SizedBox.shrink();
    switch (i) {
      case 0:
        return home();
      case 1:
        return WaveTab(services: s);
      case 2:
        return search();
      case 3:
        return library();
      default:
        return more();
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
                    for (var i = 0; i < 5; i++) tabPage(i),
                  ]),
                ),
              ),
            ]),
          ),
          bottomNavigationBar: dock(),
        ),
        ),
      );

  static const _tabIcons = <int, (IconData, IconData)>{
    0: (Icons.home_outlined, Icons.home_rounded),
    1: (Icons.waves_rounded, Icons.waves_rounded),
    2: (Icons.search_rounded, Icons.search_rounded),
    3: (Icons.library_music_outlined, Icons.library_music_rounded),
    4: (Icons.menu_rounded, Icons.menu_rounded),
  };

  Widget roundButton(Widget icon, VoidCallback onTap, {double size = 56, bool on = false}) => Glass(
        radius: size / 2,
        color: on ? C.accent.withValues(alpha: 0.22) : C.glass,
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
      final shown = tab == 2 ? 0 : tab;
      final icons = _tabIcons[shown]!;
      body = Row(key: const ValueKey('collapsed'), children: [
        roundButton(Icon(icons.$2, size: 25, color: C.accent), () => setState(() => dockCollapsed = false)),
        const SizedBox(width: 8),
        Expanded(
          child: hasMini
              ? MiniPlayer(services: s, compact: true, margin: EdgeInsets.zero, onOpen: () => showPlayer(context, s))
              : const SizedBox(height: 56),
        ),
        const SizedBox(width: 8),
        roundButton(Icon(Icons.search_rounded, size: 26, color: tab == 2 ? C.accent : C.text), () => selectTab(2), on: tab == 2),
      ]);
    } else {
      body = Column(key: const ValueKey('expanded'), mainAxisSize: MainAxisSize.min, children: [
        if (hasMini) ...[
          MiniPlayer(services: s, margin: EdgeInsets.zero, onOpen: () => showPlayer(context, s)),
          const SizedBox(height: 8),
        ],
        Row(children: [
          Expanded(
            child: Glass(
              radius: 32,
              color: C.glass,
              child: Row(children: [
                navItem(0, Icons.home_outlined, Icons.home_rounded, 'Главная'),
                navItem(1, Icons.waves_rounded, Icons.waves_rounded, 'Волна'),
                navItem(3, Icons.library_music_outlined, Icons.library_music_rounded, 'Медиатека'),
                navItem(4, Icons.menu_rounded, Icons.menu_rounded, 'Ещё', badge: s.updater.available != null),
              ]),
            ),
          ),
          const SizedBox(width: 8),
          roundButton(Icon(Icons.search_rounded, size: 27, color: tab == 2 ? C.accent : C.text), () => selectTab(2), size: 64, on: tab == 2),
        ]),
      ]);
    }
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        child: AnimatedSize(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          alignment: Alignment.bottomCenter,
          child: AnimatedSwitcher(duration: const Duration(milliseconds: 200), child: body),
        ),
      ),
    );
  }

  Widget navItem(int i, IconData icon, IconData active, String label, {bool badge = false}) {
    final on = tab == i;
    return Expanded(
      child: InkWell(
        onTap: () => selectTab(i),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              width: on ? 58 : 36,
              height: 30,
              decoration: BoxDecoration(
                color: on ? C.accent.withValues(alpha: 0.2) : Colors.transparent,
                borderRadius: BorderRadius.circular(15),
              ),
              child: Center(
                child: Badge(
                  isLabelVisible: badge,
                  smallSize: 8,
                  backgroundColor: C.accent,
                  child: Icon(on ? active : icon, size: 24, color: on ? C.accent : C.muted),
                ),
              ),
            ),
            const SizedBox(height: 2),
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

  String greeting() {
    final h = DateTime.now().hour;
    final word = h < 5 ? 'Доброй ночи' : (h < 12 ? 'Доброе утро' : (h < 18 ? 'Добрый день' : 'Добрый вечер'));
    final name = (s.accounts.primary?.name ?? '').trim().split(' ').first;
    return name.isEmpty || name.contains('@') ? word : '$word, $name';
  }

  Widget home() {
    final recent = s.library.recent.take(30).toList();
    final albums = s.library.albums.take(24).toList();
    final artists = s.library.artists.take(20).toList();
    final all = s.library.allTracks;
    final liked = s.library.liked;
    final offline = s.settings.offlineTracks.length;
    return RefreshIndicator(
      color: C.accent,
      onRefresh: refresh,
      child: ListView(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 8, 4),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(greeting(), style: display(26)),
                const SizedBox(height: 2),
                Text('${all.length} треков в библиотеке', style: const TextStyle(color: C.muted, fontSize: 13)),
              ]),
            ),
            IconButton(onPressed: refresh, tooltip: 'Обновить', icon: const Icon(Icons.refresh_rounded, size: 24)),
          ]),
        ),
        const SizedBox(height: 10),
        if (s.updater.available != null) UpdateBanner(updater: s.updater, onToast: toast),
        HandoffCard(services: s),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(children: [
            Row(children: [
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
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                  child: ActionTile(
                      icon: Icons.waves_rounded,
                      title: 'Моя волна',
                      subtitle: 'подборка по вкусу',
                      onTap: all.isEmpty
                          ? null
                          : () {
                              selectTab(1);
                              s.wave.start();
                            })),
              const SizedBox(width: 12),
              Expanded(
                  child: ActionTile(
                      icon: Icons.download_done_rounded,
                      title: 'Скачано',
                      subtitle: offline == 0 ? 'пока ничего' : '$offline треков',
                      onTap: () => setState(() {
                            tab = 3;
                            section = 5;
                            visited.add(3);
                          }))),
            ]),
          ]),
        ),
        if (albums.isNotEmpty)
          SectionTitle('Альбомы', onMore: () => setState(() {
                tab = 3;
                section = 2;
                visited.add(3);
              })),
        if (albums.isNotEmpty)
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
        if (artists.isNotEmpty)
          SectionTitle('Исполнители', onMore: () => setState(() {
                tab = 3;
                section = 3;
                visited.add(3);
              })),
        if (artists.isNotEmpty)
          SizedBox(
            height: 128,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              itemCount: artists.length,
              itemBuilder: (_, i) {
                final a = artists[i];
                return InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: () => openTracks(a.name, a.tracks, cover: a.coverTrack),
                  child: SizedBox(
                    width: 92,
                    child: Column(children: [
                      TrackCover(services: s, track: a.coverTrack, size: 76, radius: 38),
                      const SizedBox(height: 6),
                      Text(a.name, maxLines: 2, textAlign: TextAlign.center, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                    ]),
                  ),
                );
              },
            ),
          ),
        const SectionTitle('Недавно добавленные'),
        for (var i = 0; i < recent.length; i++) TrackTile(services: s, track: recent[i], onTap: () => play(recent, i), onToast: toast),
        if (recent.isEmpty)
          const Padding(
            padding: EdgeInsets.all(32),
            child: Column(children: [
              Icon(Icons.library_music_outlined, size: 44, color: C.faint),
              SizedBox(height: 10),
              Text('Пока нет треков', style: TextStyle(color: C.muted)),
              Text('Потяните вниз, чтобы обновить', style: TextStyle(color: C.faint, fontSize: 12)),
            ]),
          ),
        const SizedBox(height: 12),
      ]),
    );
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
      header('Ещё'),
      tile(Icons.new_releases_outlined, 'Новинки', 'Свежие релизы ваших исполнителей', () => openPage(NewReleasesPage(services: s))),
      tile(Icons.account_circle_outlined, 'Моя страница', 'Статистика, любимые треки, плейлисты', () => openPage(UserPage(services: s, email: s.library.me ?? ''))),
      tile(Icons.groups_outlined, 'Компания', 'Друзья, чарт недели, лента, уведомления', () => openPage(CompanyPage(services: s)), dot: unread > 0),
      tile(Icons.download_done_rounded, 'Скачано', 'Треки на телефоне, доступны без интернета', () => setState(() {
            tab = 3;
            section = 5;
          })),
      tile(Icons.settings_outlined, 'Настройки', 'Аккаунт, обновления, кэш', () => openPage(SubPage(services: s, title: 'Настройки', child: ProfileTab(services: s))),
          dot: s.updater.available != null),
    ]);
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
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
        child: Row(children: [
          for (final (label, web) in const [('Библиотека', false), ('Интернет', true)])
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(label),
                selected: webSearch == web,
                labelStyle: TextStyle(color: webSearch == web ? C.accentInk : C.text, fontWeight: FontWeight.w600),
                onSelected: (_) => setState(() => webSearch = web),
              ),
            ),
        ]),
      ),
      Expanded(
        child: webSearch
            ? WebSearchSection(services: s, query: query)
            : q.isEmpty
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

  Widget library() {
    const labels = ['Все', 'Любимые', 'Альбомы', 'Исполнители', 'Плейлисты', 'Скачано'];
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
          5 => downloads(),
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
        onPressed: () {
          HapticFeedback.lightImpact();
          services.library.toggleLike(track.id);
        },
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

  @override
  Widget build(BuildContext context) {
    final c = cover ?? (tracks.isEmpty ? null : tracks.first);
    final width = MediaQuery.sizeOf(context).width;
    final top = MediaQuery.paddingOf(context).top;
    // Обложка на всю ширину, нижняя часть растворяется; название лежит на переходе
    final coverH = width;
    final heroH = coverH - 40 + 78;
    // Фон под цвет обложки альбома, а не играющего трека
    return Backdrop(
      services: services,
      track: c,
      child: Scaffold(
      backgroundColor: Colors.transparent,
      body: AnimatedBuilder(
        animation: Listenable.merge([services.cache, services.library, services.player]),
        builder: (context, _) => CustomScrollView(slivers: [
          SliverToBoxAdapter(
            child: SizedBox(
              height: heroH,
              child: Stack(children: [
                if (c != null) Positioned(top: 0, left: 0, right: 0, height: coverH, child: FadeCover(services: services, track: c, width: width, height: coverH)),
                Positioned(
                  left: 16,
                  top: top + 8,
                  child: Glass(
                    radius: 23,
                    color: C.glassLight,
                    child: InkWell(
                      onTap: () => Navigator.of(context).maybePop(),
                      child: const SizedBox(width: 46, height: 46, child: Icon(Icons.chevron_left_rounded, size: 30, color: C.text)),
                    ),
                  ),
                ),
                Positioned(
                  left: 20,
                  right: 20,
                  top: coverH - 40,
                  child: Column(children: [
                    Text(title, textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis, style: display(26)),
                    const SizedBox(height: 6),
                    Text('${tracks.length} треков', style: const TextStyle(color: C.muted, fontSize: 14)),
                  ]),
                ),
              ]),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Column(children: [
                Row(children: [
                  Material(
                    color: C.raised,
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: tracks.isEmpty ? null : () => play(context, shuffle: true),
                      child: const SizedBox(width: 50, height: 50, child: Icon(Icons.shuffle_rounded, size: 23, color: C.text)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: SizedBox(
                      height: 50,
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(shape: const StadiumBorder(), textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                        onPressed: tracks.isEmpty ? null : () => play(context),
                        icon: const Icon(Icons.play_arrow_rounded, size: 26),
                        label: const Text('Воспроизвести'),
                      ),
                    ),
                  ),
                ]),
                const SizedBox(height: 10),
                DownloadButton(services: services, tracks: tracks),
              ]),
            ),
          ),
          SliverList.builder(
            itemCount: tracks.length,
            itemBuilder: (_, i) => TrackTile(
              services: services,
              track: tracks[i],
              index: i + 1,
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
            : SafeArea(top: false, child: MiniPlayer(services: services, onOpen: () => showPlayer(context, services))),
      ),
    ));
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
    final coverW = compact ? 84.0 : 104.0;
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
              SizedBox(width: coverW - 24),
              Expanded(
                child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15.5)),
                  const SizedBox(height: 1),
                  Text(t.displayArtist, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5, color: C.muted)),
                ]),
              ),
              IconButton(onPressed: p.toggle, icon: Icon(p.playing ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 30, color: C.text)),
              if (!compact) IconButton(onPressed: p.next, icon: const Icon(Icons.skip_next_rounded, size: 30, color: C.text)),
              SizedBox(width: compact ? 6 : 4),
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
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => FractionallySizedBox(heightFactor: 0.8, child: QueueSheet(services: services)),
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
                        IconButton(
                          onPressed: () => services.library.toggleLike(t.id),
                          icon: Icon(services.library.isLiked(t.id) ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                              color: services.library.isLiked(t.id) ? C.accent : C.text, size: 26),
                        ),
                        IconButton(onPressed: () => queue(context), icon: const Icon(Icons.queue_music_rounded, size: 26, color: C.text)),
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
