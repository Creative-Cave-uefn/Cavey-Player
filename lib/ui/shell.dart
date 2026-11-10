import 'dart:async';

import 'package:flutter/gestures.dart' show kBackMouseButton, kForwardMouseButton, kSecondaryMouseButton, PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/services.dart';

import '../app.dart';
import '../core/library.dart';
import '../core/log.dart';
import '../core/media_keys.dart';
import '../core/share_link.dart';
import '../core/models.dart';
import '../core/pin_order.dart';
import '../core/player.dart' show PlayerController;
import '../core/updater.dart';
import 'accounts_view.dart';
import 'albums_view.dart';
import 'cinema_view.dart';
import 'company_view.dart';
import 'download_view.dart';
import 'foreign_deletions.dart';
import 'library_views.dart';
import 'lyrics_panel.dart';
import 'mouse_gesture.dart';
import 'notice_tower.dart';
import 'player_bar.dart';
import 'playlists_view.dart';
import 'profile_view.dart';
import 'theme.dart';
import 'tracks_view.dart';
import 'web_pages.dart';
import 'web_views.dart';
import 'wave_view.dart';
import 'widgets.dart';
import 'glass_popup.dart';
import 'library_home.dart';
import 'library_tabs.dart';
import 'collection_menu.dart';
import 'collection_page.dart';
import 'device_export_ui.dart';
import 'migration_ui.dart';
import 'pin_drag.dart';
import 'album_edit.dart';
import 'queue_panel.dart';

class Nav {
  final String kind; // all, albums, album, liked, playlist, sources, accounts
  final String? id;
  const Nav(this.kind, [this.id]);
  bool same(Nav o) => o.kind == kind && o.id == id;
}

/// Навигация открытого Shell: ею пользуется шапка окна (шестерёнка, «Назад» и «Вперёд»), которая
/// живёт выше Shell. null — Shell ещё не открыт (первый запуск, вход)
final ValueNotifier<NavController?> shellNav = ValueNotifier(null);

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
  final _gesture = MouseGesture();
  StreamSubscription<String>? _msgs;
  bool _dragging = false;
  String? _toast;
  String? _toastActionLabel;
  VoidCallback? _toastAction;
  ValueNotifier<String?>? _linkSource;
  Timer? _toastTimer;

  // ---------- кинотеатр и волна: панели прячутся ----------

  bool _peekSide = false, _peekBar = false;
  bool _inSide = false, _inBar = false;
  Timer? _hideSide, _hideBar;

  /// Где панели уезжают: кинотеатр всегда, волна — пока играет
  bool _immersive(Nav nav) {
    if (nav.kind == 'cinema') return Services.of(context).player.current != null;
    return nav.kind == 'wave' && Services.of(context).wave.active;
  }

  /// Мышь у края: показываем панель; если в неё так и не зашли — прячем через пару секунд
  void _reveal({required bool side}) {
    setState(() => side ? _peekSide = true : _peekBar = true);
    _scheduleHide(side: side, after: const Duration(milliseconds: 1800));
  }

  void _hover({required bool side, required bool inside}) {
    if (side) {
      _inSide = inside;
    } else {
      _inBar = inside;
    }
    if (inside) {
      (side ? _hideSide : _hideBar)?.cancel();
    } else {
      _scheduleHide(side: side, after: const Duration(milliseconds: 600));
    }
  }

  void _scheduleHide({required bool side, required Duration after}) {
    final t = Timer(after, () {
      if (!mounted || (side ? _inSide : _inBar)) return;
      setState(() => side ? _peekSide = false : _peekBar = false);
    });
    if (side) {
      _hideSide?.cancel();
      _hideSide = t;
    } else {
      _hideBar?.cancel();
      _hideBar = t;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _nav.removeListener(_onNavForScroll);
    _nav.addListener(_onNavForScroll);
    if (shellNav.value != _nav) {
      // Нельзя менять во время сборки: шапка окна сама перестроится после кадра
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) shellNav.value = _nav;
      });
    }
    _msgs ??= Services.of(context).lib.messages.stream.listen((m) {
      if (!mounted) return;
      // Своя плашка вместо SnackBar: маленькая, по центру и над плеером, ничего не перекрывает
      _showToast(m);
    });
    if (!_migrationOffered) {
      _migrationOffered = true;
      // Через несколько секунд после запуска, когда библиотека уже загрузилась
      Timer(const Duration(seconds: 12), () {
        if (mounted) offerMigrationAtStart(context);
      });
    }
    if (_askLib == null) {
      _askLib = Services.of(context).lib..addListener(_checkForeignDeletions);
      WidgetsBinding.instance.addPostFrameCallback((_) => _checkForeignDeletions());
    }
    if (_linkSource == null) {
      _linkSource = Services.of(context).incomingLink..addListener(_onLink);
      WidgetsBinding.instance.addPostFrameCallback((_) => _onLink()); // ссылка, с которой запустили программу
    }
  }

  bool _migrationOffered = false;
  LibraryController? _askLib;

  void _checkForeignDeletions() {
    final lib = _askLib;
    if (!mounted || lib == null || lib.foreignDeletions.isEmpty) return;
    askForeignDeletions(context, lib);
  }

  void _showToast(String text, {String? actionLabel, VoidCallback? action, Duration time = const Duration(seconds: 4)}) {
    setState(() {
      _toast = text;
      _toastActionLabel = actionLabel;
      _toastAction = action;
    });
    _toastTimer?.cancel();
    _toastTimer = Timer(time, () {
      if (mounted) {
        setState(() {
          _toast = null;
          _toastAction = null;
        });
      }
    });
  }

  /// Открыли ссылку caveplayer://track/…: переходим к альбому трека и включаем его
  void _onLink() {
    if (!mounted) return;
    final app = Services.of(context);
    final link = app.incomingLink.value;
    if (link == null) return;
    app.incomingLink.value = null;
    final id = trackIdFromLink(link);
    final track = id == null ? null : app.lib.data.tracks[app.lib.data.resolve(id)];
    if (track == null) {
      _showToast('Этого трека нет в вашей библиотеке');
      return;
    }
    _nav.go(Nav('album', track.albumKey));
    unawaited(app.player.playTracks([track], 0));
  }

  /// Зажатая правая кнопка + движение: ← предыдущий, → следующий, ↑ ↓ громкость
  void _onGesture(GestureDir dir) {
    final app = Services.of(context);
    final p = app.player;
    switch (dir) {
      case GestureDir.left:
        _gesture.end(); // трек меняем один раз за нажатие, а не по треку на каждые 60 пикселей
        p.previous();
      case GestureDir.right:
        _gesture.end();
        p.next();
      case GestureDir.up:
      case GestureDir.down:
        final v = (p.volume + (dir == GestureDir.up ? 5 : -5)).clamp(0, 100).toDouble();
        p.setVolume(v, save: true);
        app.lib.messages.add('Громкость: ${v.round()}%');
    }
  }

  // ---------- стрелка «наверх» ----------

  final _scrollTopVisible = ValueNotifier(false);
  ScrollPosition? _pagePos;
  Nav? _scrollNav;

  bool _onPageScroll(ScrollNotification n) {
    // Только главная вертикальная прокрутка страницы, не ряды плиток внутри неё
    if (n.depth != 0 || n.metrics.axis != Axis.vertical) return false;
    final ctx = n.context;
    if (ctx != null) _pagePos = Scrollable.maybeOf(ctx)?.position;
    _scrollNav = _nav.value;
    _scrollTopVisible.value = n.metrics.pixels > n.metrics.viewportDimension;
    return false;
  }

  void _scrollToTop() {
    final pos = _pagePos;
    if (pos == null || !pos.hasPixels) return;
    final far = pos.pixels > pos.viewportDimension * 6;
    // Издалека — сначала прыжок поближе, иначе плавная прокрутка тянется секунды
    if (far) pos.jumpTo(pos.viewportDimension * 2);
    pos.animateTo(0, duration: const Duration(milliseconds: 420), curve: Curves.easeOutCubic);
  }

  void _onNavForScroll() {
    if (_scrollNav != null && !_nav.value.same(_scrollNav!)) {
      _scrollTopVisible.value = false;
      _pagePos = null;
    }
  }

  @override
  void dispose() {
    if (shellNav.value == _nav) shellNav.value = null;
    _nav.removeListener(_onNavForScroll);
    _scrollTopVisible.dispose();
    _toastTimer?.cancel();
    _hideSide?.cancel();
    _hideBar?.cancel();
    _msgs?.cancel();
    _linkSource?.removeListener(_onLink);
    _askLib?.removeListener(_checkForeignDeletions);
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
          if (e.kind == PointerDeviceKind.mouse && e.buttons == kSecondaryMouseButton) _gesture.start(e.position);
        },
        onPointerMove: (e) {
          if (!_gesture.active) return;
          final dir = _gesture.move(e.position);
          if (dir != null) _onGesture(dir);
        },
        onPointerUp: (_) => _gesture.end(),
        onPointerCancel: (_) => _gesture.end(),
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
            backgroundColor: Colors.transparent,
            body: LayoutBuilder(builder: (context, box) {
              final compact = box.maxWidth < 860;
              const barH = 88.0;
              const dur = Duration(milliseconds: 320);
              const curve = Curves.easeOutCubic;
              // Стекло: боковая панель плавает слева, капсула плеера внизу. В кинотеатре и в играющей волне
              // обе уезжают за край и возвращаются, когда к краю подводишь мышь
              return AnimatedBuilder(
                animation: Listenable.merge([_nav, app.wave, app.lib]),
                builder: (context, _) {
                  // Узкая панель: в узком окне всегда, в широком — если её сузили за ручку на правом краю
                  final narrowSide = compact || app.settings.viewOf('sidebar.mini', '0') == '1';
                  final sideW = (narrowSide ? 72.0 : 240.0) + 12;
                  final nav = _nav.value;
                  final immersive = _immersive(nav);
                  if (!immersive && (_peekSide || _peekBar)) {
                    _peekSide = false;
                    _peekBar = false;
                  }
                  // В кинотеатре панели не выезжают совсем: всё управление на самой странице
                  final cinema = nav.kind == 'cinema';
                  // З1: на странице играющей волны капсулы нет совсем, а боковая панель по-прежнему выезжает
                  final waveLive = nav.kind == 'wave' && immersive;
                  final showSide = !immersive || (_peekSide && !cinema);
                  final showBar = !immersive || (_peekBar && !cinema && !waveLive);
                  return Stack(children: [
                    AnimatedPositioned(
                      duration: dur,
                      curve: curve,
                      left: immersive ? 0 : sideW,
                      top: 0,
                      right: 0,
                      bottom: immersive ? 0 : barH,
                      child: Row(children: [
                        Expanded(
                          child: Stack(children: [
                            // Свой слой для подсветки строк с обрезкой по краю: иначе подсветка рисуется
                            // на общем слое окна и вылезает поверх плеера у нижних строк
                            Positioned.fill(
                              child: ClipRect(
                                child: Material(
                                  type: MaterialType.transparency,
                                  child: NotificationListener<ScrollNotification>(
                                    onNotification: _onPageScroll,
                                    child: _content(nav, compact),
                                  ),
                                ),
                              ),
                            ),
                            // Прокрутили дальше одного экрана — справа снизу стрелка к началу страницы
                            Positioned(
                              right: 18,
                              bottom: 12,
                              child: ValueListenableBuilder<bool>(
                                valueListenable: _scrollTopVisible,
                                builder: (context, on, _) => _ScrollTopButton(visible: on && !immersive, onTap: _scrollToTop),
                              ),
                            ),
                          ]),
                        ),
                        // В кинотеатре текст и так на половине экрана. Справа одна панель: текст песни или очередь
                        if (nav.kind != 'cinema') const SidePanelSlot(),
                      ]),
                    ),
                    if (immersive && !cinema) ...[
                      // Узкие полосы у края: навёл — панель выезжает
                      Positioned(left: 0, top: 0, bottom: 0, width: 12, child: MouseRegion(onEnter: (_) => _reveal(side: true))),
                      if (!waveLive) Positioned(left: 0, right: 0, bottom: 0, height: 14, child: MouseRegion(onEnter: (_) => _reveal(side: false))),
                    ],
                    AnimatedPositioned(
                      duration: dur,
                      curve: curve,
                      left: showSide ? 0 : -sideW - 24,
                      top: 0,
                      bottom: 0,
                      width: sideW,
                      child: MouseRegion(
                        onEnter: (_) => _hover(side: true, inside: true),
                        onExit: (_) => _hover(side: true, inside: false),
                        child: Padding(padding: const EdgeInsets.fromLTRB(12, 0, 0, 12), child: _SidebarHost(compact: compact)),
                      ),
                    ),
                    AnimatedPositioned(
                      duration: dur,
                      curve: curve,
                      left: immersive ? 0 : sideW,
                      right: 0,
                      bottom: showBar ? 0 : -barH - 12,
                      height: barH,
                      child: MouseRegion(
                        onEnter: (_) => _hover(side: false, inside: true),
                        onExit: (_) => _hover(side: false, inside: false),
                        child: PlayerBar(compact: compact),
                      ),
                    ),
                  ]);
                },
              );
            }),
          ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: ValueListenableBuilder<bool>(
                  valueListenable: selectionBarOpen,
                  // Над плеером, а если открыта панель выбора треков — выше неё
                  builder: (context, bar, child) => Padding(padding: EdgeInsets.only(bottom: bar ? 92 + 84 : 92 + 14), child: child),
                  child: IgnorePointer(
                    ignoring: _toastAction == null,
                    child: Center(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 160),
                        child: _toast == null
                            ? const SizedBox.shrink(key: ValueKey('none'))
                            : _ToastCard(_toast!, key: ValueKey(_toast), actionLabel: _toastActionLabel, onAction: _toastAction),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                right: 16,
                bottom: 92 + 10,
                child: ValueListenableBuilder<bool>(
                  valueListenable: selectionBarOpen,
                  builder: (context, bar, child) => ValueListenableBuilder<bool>(
                    valueListenable: _scrollTopVisible,
                    // Башня уведомлений встаёт над стрелкой «наверх»
                    builder: (context, up, _) => AnimatedPadding(
                      duration: const Duration(milliseconds: 180),
                      padding: EdgeInsets.only(bottom: (bar ? 76 : 0) + (up ? 54 : 0)),
                      child: child,
                    ),
                  ),
                  child: const NoticeTower(),
                ),
              ),
              Positioned(
                left: ((MediaQuery.sizeOf(context).width < 860 || app.settings.viewOf('sidebar.mini', '0') == '1') ? 72.0 : 240.0) + 12 + 16,
                bottom: 92 + 10,
                child: const ExportCard(),
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
    if (k == LogicalKeyboardKey.escape && !repeat && (_nav.value.kind == 'cinema' || _immersive(_nav.value))) {
      action = _nav.canBack ? _nav.back : () => _nav.go(const Nav('all')); // З5: из волны по Esc, музыка играет дальше
    }
    // Медиаклавиши и сочетания с Ctrl работают всегда
    // (если включён перехват по всей системе, медиаклавиши ловит он, иначе они сработали бы дважды)
    if (!MediaKeys.running) {
      if (k == LogicalKeyboardKey.mediaPlayPause && !repeat) action = p.toggle;
      if (k == LogicalKeyboardKey.mediaTrackNext && !repeat) action = p.next;
      if (k == LogicalKeyboardKey.mediaTrackPrevious && !repeat) action = p.previous;
    }
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
    final page = _page(nav, compact);
    if (isLibraryTab(nav)) {
      // Вкладки «Медиатеки»: заголовок и ряд вкладок сверху общие и не перестраиваются при переключении
      return LibraryTabsPage(key: const ValueKey('library-tabs'), current: nav, compact: compact, child: page);
    }
    return page;
  }

  Widget _page(Nav nav, bool compact) {
    switch (nav.kind) {
      case 'collection':
        return CollectionPage(key: const ValueKey('collection'), compact: compact);
      case 'playlists':
        return PlaylistsPage(key: const ValueKey('playlists'), compact: compact);
      case 'albums':
        return AlbumsPage(key: ValueKey('albums:${nav.id}'), kind: nav.id);
      case 'songs':
        return AllTracksPage(key: const ValueKey('songs'), compact: compact);
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
      case 'cinema':
        return CinemaPage(key: const ValueKey('cinema'), compact: compact);
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
      case 'sources': // старая вкладка «Папки с музыкой» теперь в настройках, на вкладке «Библиотека»
        return const AccountsPage(key: ValueKey('accounts:library'), tab: 'library');
      case 'accounts':
        return AccountsPage(key: ValueKey('accounts:${nav.id}'), tab: nav.id);
      default:
        return LibraryHomePage(key: const ValueKey('all'), compact: compact);
    }
  }
}

/// Небольшое уведомление по центру над плеером
class _ToastCard extends StatelessWidget {
  final String text;
  final String? actionLabel;
  final VoidCallback? onAction;
  const _ToastCard(this.text, {super.key, this.actionLabel, this.onAction});

  @override
  Widget build(BuildContext context) {
    // Material нужен, чтобы у текста вне Scaffold не было жёлтого подчёркивания
    return Material(
      type: MaterialType.transparency,
      child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 620),
      child: GlassPanel(
        radius: 16,
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 13),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Flexible(
            child: Text(text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(color: C.text, fontSize: 16, fontWeight: FontWeight.w500, decoration: TextDecoration.none)),
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(width: 14),
            FilledButton(onPressed: onAction, child: Text(actionLabel!)),
          ],
        ]),
      ),
      ),
    );
  }
}

/// Левая панель с ручкой на правом краю: тянем влево — остаются значки и обложки, вправо — полная панель.
/// Сворачивается плавно: надписи и крупные обложки укатываются вправо, мелкие обложки выезжают слева.
/// Разворачивается зеркально
class _SidebarHost extends StatefulWidget {
  final bool compact;
  const _SidebarHost({required this.compact});

  @override
  State<_SidebarHost> createState() => _SidebarHostState();
}

class _SidebarHostState extends State<_SidebarHost> with SingleTickerProviderStateMixin {
  double _startW = 248;
  double _dx = 0;

  /// 0 — полная панель, 1 — узкая. Время и кривая те же, что у ширины панели в окне, поэтому всё едет вместе
  late final AnimationController _ctl = AnimationController(vsync: this, duration: const Duration(milliseconds: 320));
  // Разворачивание — зеркало сворачивания по положению, но с тем же разгоном и торможением: у обратного хода кривая перевёрнута,
  // иначе контроллер проигрывал бы easeOutCubic задом наперёд (медленный старт, резкий конец)
  late final Animation<double> _t = CurvedAnimation(parent: _ctl, curve: Curves.easeOutCubic, reverseCurve: Curves.easeOutCubic.flipped);
  bool _started = false;

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _follow(bool narrow) {
    if (!_started) {
      _started = true;
      _ctl.value = narrow ? 1 : 0;
      return;
    }
    if (narrow && _ctl.value < 1 && _ctl.status != AnimationStatus.forward) {
      _ctl.forward();
    } else if (!narrow && _ctl.value > 0 && _ctl.status != AnimationStatus.reverse) {
      _ctl.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    return ListenableBuilder(
      listenable: app.lib,
      builder: (context, _) {
        final mini = app.settings.viewOf('sidebar.mini', '0') == '1';
        // Узкое окно всегда держит узкую панель; ручка нужна только на широком
        final narrow = widget.compact || mini;
        _follow(narrow);
        void setMini(bool v) {
          if (v == mini) return;
          app.settings.view['sidebar.mini'] = v ? '1' : '0';
          app.lib.viewChanged();
        }

        return Stack(children: [
          // Ширину плавно меняет сама панель (её место в окне анимируется), содержимое имеет постоянную ширину
          // и обрезается краем
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(24), border: Border.all(color: C.line)),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: OverflowBox(
                  alignment: Alignment.topLeft,
                  minWidth: 240,
                  maxWidth: 240,
                  child: _Sidebar(t: _t),
                ),
              ),
            ),
          ),
          if (!widget.compact)
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              width: 8,
              child: MouseRegion(
                cursor: SystemMouseCursors.resizeColumn,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onHorizontalDragStart: (_) {
                    _startW = mini ? 72 : 248;
                    _dx = 0;
                  },
                  onHorizontalDragUpdate: (d) {
                    _dx += d.delta.dx;
                    // Две позиции: ближе к узкой — значки, ближе к широкой — полная панель
                    setMini(_startW + _dx < 160);
                  },
                  onDoubleTap: () => setMini(!mini),
                ),
              ),
            ),
        ]);
      },
    );
  }
}

/// Два вида одного блока панели и переход между ними: полный уезжает вправо и гаснет,
/// узкий выезжает слева. [t] — 0 полный вид, 1 узкий
class _SlideSwap extends StatelessWidget {
  final double t;
  final Widget full;
  final Widget mini;

  /// Высоты видов, если они известны: тогда блок плавно растёт или сжимается вместе с переходом,
  /// а то, что ниже, едет следом, а не прыгает в конце
  final double? fullH;
  final double? miniH;
  const _SlideSwap({required this.t, required this.full, required this.mini, this.fullH, this.miniH});

  static const fullW = 240.0;
  static const miniW = 72.0;

  @override
  Widget build(BuildContext context) {
    // Align снимает жёсткую ширину родителя (панель растягивает детей на 240), иначе узкий вид растягивался бы до полной ширины
    if (t <= 0) return Align(alignment: Alignment.topLeft, child: SizedBox(width: fullW, child: full));
    if (t >= 1) return Align(alignment: Alignment.topLeft, child: SizedBox(width: miniW, child: mini));
    final stack = Stack(clipBehavior: Clip.none, children: [
      Opacity(
        opacity: (1 - t * 1.25).clamp(0.0, 1.0),
        child: Transform.translate(offset: Offset(t * 90, 0), child: SizedBox(width: fullW, child: full)),
      ),
      Positioned(
        left: 0,
        top: 0,
        width: miniW,
        child: Opacity(
          opacity: ((t - 0.15) / 0.85).clamp(0.0, 1.0),
          child: Transform.translate(offset: Offset(-(1 - t) * 60, 0), child: mini),
        ),
      ),
    ]);
    final a = fullH, b = miniH;
    if (a == null || b == null) return stack;
    return SizedBox(height: a + (b - a) * t, child: stack);
  }
}

class _Sidebar extends StatelessWidget {
  final Animation<double> t;
  const _Sidebar({required this.t});

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final nav = NavScope.of(context);
    return SizedBox(
      width: 240,
      child: ListenableBuilder(
        listenable: Listenable.merge([app.lib, nav, app.downloads, app.social, t]),
        builder: (context, _) {
          final lib = app.lib;
          final cur = nav.value;
          final v = t.value;
          Widget item(IconData icon, String label, Nav target, {Widget? trailing, List<String> also = const []}) => _NavItem(
                icon: icon,
                label: label,
                t: v,
                selected: cur.same(target) || also.contains(cur.kind),
                trailing: trailing,
                onTap: () => nav.go(target),
              );

          // Вид раздела: «Список с обложкой» или «Обложки» (старый вид «Списком» показывается как список с обложкой)
          final mode = app.settings.viewOf('sidebar.playlists', 'both') == 'covers' ? 'covers' : 'both';
          bool on(String k) => app.settings.viewOf(k, '1') == '1';
          final favs = lib.me == null ? null : lib.favoritesOf(lib.me!);
          // Раздел «Коллекция»: свои плейлисты и всё, что отмечено сердечком
          final entries = <_SideEntry>[
            if (on('sidebar.showPl'))
              for (final p in lib.visiblePlaylists)
                if (p.by.isEmpty || p.by == lib.me || lib.isFavPlaylist(p.id)) _SideEntry.playlist(p),
            if (on('sidebar.showAl') && favs != null)
              for (final a in favs.albums) _SideEntry.album(a),
            if (on('sidebar.showAr') && favs != null)
              for (final a in favs.artists) _SideEntry.artist(a),
          ];
          // Закреплённые — наверху, в порядке закрепа
          final pins = lib.pinned;
          final pinSet = pins.toSet();
          final split = splitPinned(entries, (e) => e.tokens, pins);
          final shownEntries = [...split.pinned, ...split.rest];
          final shownTokens = [for (final e in shownEntries) e.tokenIn(pinSet)];
          void drop(String dragged, String target) => applyPinDrop(app, shownTokens, split.pinned.length, dragged, target);
          final unread = unreadNotices(app);
          final head = <Widget>[
            // Значок остаётся на месте (сдвигается на пару пикселей), название укатывается вправо
            Padding(
              padding: const EdgeInsets.fromLTRB(0, 26, 0, 22),
              child: SizedBox(
                height: 34,
                child: Stack(clipBehavior: Clip.none, children: [
                  Positioned(left: 22 - 2.5 * v, top: 0, child: const BrandMark(size: 33)),
                  Positioned(
                    left: 22 + 33 + 10,
                    top: 0,
                    bottom: 0,
                    child: Opacity(
                      opacity: (1 - v * 1.5).clamp(0.0, 1.0),
                      child: Transform.translate(
                        offset: Offset(v * 80, 0),
                        child: Center(child: Text('Cavey', maxLines: 1, softWrap: false, style: brand(22))),
                      ),
                    ),
                  ),
                ]),
              ),
            ),
            item(Icons.library_music_outlined, 'Медиатека', const Nav('all'),
                also: const ['albums', 'artists', 'recent', 'songs', 'playlists', 'collection']),
            item(Icons.waves_rounded, 'Моя волна', const Nav('wave'), trailing: waveSidebarMark(context)),
            const SizedBox(height: 14),
            item(Icons.travel_explore_rounded, 'Поиск в интернете', const Nav('websearch')),
            item(Icons.new_releases_outlined, 'Новинки', const Nav('new')),
            item(Icons.cloud_download_outlined, 'Скачать', const Nav('download'),
                trailing: app.downloads.busy
                    ? const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2))
                    : null),
            const SizedBox(height: 14),
            item(Icons.favorite_border_rounded, 'Любимое', const Nav('liked')),
            if (lib.me != null) item(Icons.person_outline_rounded, 'Моя страница', Nav('user', lib.me)),
            item(Icons.groups_outlined, 'Компания', const Nav('company'),
                trailing: unread > 0
                    ? Tooltip(
                        message: 'Новых уведомлений: $unread',
                        child: Container(width: 8, height: 8, decoration: const BoxDecoration(color: Color(0xFFFF4D4F), shape: BoxShape.circle)),
                      )
                    : null),
            const SizedBox(height: 18),
            _SlideSwap(
              t: v,
              fullH: _PlaylistsHeader.fullH,
              miniH: _PlaylistsHeader.miniH,
              full: _PlaylistsHeader(compact: false, selected: cur.same(const Nav('collection')), mode: mode),
              mini: _PlaylistsHeader(compact: true, selected: cur.same(const Nav('collection')), mode: mode),
            ),
          ];

          // Коллекция в двух видах: крупном и узком (мелкие обложки в один столбец)
          Widget collection(bool compact) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (mode == 'covers')
                  _SideTiles(
                    entries: shownEntries,
                    pins: pinSet,
                    onDrop: drop,
                    compact: compact,
                    current: cur,
                    cols: compact ? 1 : int.tryParse(app.settings.viewOf('sidebar.cols', '2'))?.clamp(2, 4) ?? 2,
                    names: !compact && on('sidebar.names'),
                  )
                else
                  for (final e in shownEntries)
                    PinDrag(
                      token: e.tokenIn(pinSet),
                      vertical: true,
                      onDrop: drop,
                      child: _SideRow(entry: e, compact: compact, selected: cur.same(e.target), pinned: pinSet.contains(e.tokenIn(pinSet)), onTap: () => nav.go(e.target)),
                    ),
                if (entries.isEmpty && !compact)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(22, 4, 16, 0),
                    child: Text('Пока пусто. Здесь ваши плейлисты и то, что вы отметили сердечком: плейлисты друзей, альбомы и исполнители.',
                        style: TextStyle(color: C.faint, fontSize: 13, height: 1.4)),
                  ),
              ]);
          final playlists = <Widget>[_SlideSwap(t: v, full: collection(false), mini: collection(true))];

          Widget footPart(bool compact) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                UploadLine(compact: compact),
                _UpdateLine(compact: compact),
              ]);
          final foot = <Widget>[
            _SlideSwap(t: v, full: const NowListeningSidebar(compact: false), mini: const NowListeningSidebar(compact: true)),
            const Divider(height: 1),
            const SizedBox(height: 8),
            _SlideSwap(t: v, full: footPart(false), mini: footPart(true)),
            const SizedBox(height: 10),
          ];

          return LayoutBuilder(builder: (context, box) {
            // Сколько места нужно, чтобы верх и низ панели стояли на месте, а прокручивались только плейлисты.
            // Оценка с запасом; если места меньше, прокручивается вся панель целиком
            final live = app.social.friends.where((m) => m.live).length;
            final need = 864 + (live > 0 ? 44 : 0) + (app.jam.active ? 36 : 0);
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

/// «Коллекция»: заголовок — ссылка на вкладку «Коллекция» в медиатеке; рядом настройки вида и «+»
class _PlaylistsHeader extends StatelessWidget {
  final bool compact;
  final bool selected;
  final String mode;
  const _PlaylistsHeader({required this.compact, required this.selected, required this.mode});

  /// Высоты обоих видов заданы жёстко: переход между ними растёт плавно, и «+» в узком виде выезжает вместе с обложками
  static const fullH = 52.0;
  static const miniH = 96.0;

  @override
  Widget build(BuildContext context) {
    final nav = NavScope.of(context);
    if (compact) {
      return SizedBox(height: miniH, child: Column(children: [
        IconButton(
          tooltip: 'Коллекция',
          icon: Icon(Icons.queue_music_rounded, color: selected ? C.accent : C.muted),
          onPressed: () => nav.go(const Nav('collection')),
        ),
        IconButton(
          tooltip: 'Новый плейлист',
          icon: const Icon(Icons.playlist_add_rounded),
          onPressed: () => newPlaylistFlow(context),
        ),
      ]));
    }
    return SizedBox(height: fullH, child: Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 4, 4),
      child: Row(children: [
        Expanded(
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => nav.go(const Nav('collection')),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
              child: Row(children: [
                Text('Коллекция',
                    style: TextStyle(color: selected ? C.text : C.muted, fontSize: 13, fontWeight: selected ? FontWeight.w600 : FontWeight.w400)),
                const SizedBox(width: 2),
                Icon(Icons.chevron_right_rounded, size: 18, color: selected ? C.accent : C.faint),
              ]),
            ),
          ),
        ),
        Builder(
          builder: (btn) => IconButton(
            tooltip: 'Что и как показывать',
            icon: Icon(mode == 'covers' ? Icons.grid_view_rounded : Icons.view_agenda_outlined, size: 18),
            onPressed: () => showGlassPopover(context: btn, width: 250, builder: (_) => const _CollectionViewPanel()),
          ),
        ),
        IconButton(
          tooltip: 'Новый плейлист',
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.add_rounded, size: 20),
          onPressed: () => newPlaylistFlow(context),
        ),
      ]),
    ));
  }
}

/// Окошко «Что и как показывать»: не закрывается от нажатий, при смене вида плавно растёт или сжимается,
/// а пункты сдвигаются на новые места
class _CollectionViewPanel extends StatelessWidget {
  const _CollectionViewPanel();

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    return ListenableBuilder(
      listenable: app.lib,
      builder: (context, _) {
        final mode = app.settings.viewOf('sidebar.playlists', 'both') == 'covers' ? 'covers' : 'both';
        bool on(String k) => app.settings.viewOf(k, '1') == '1';
        void set(String k, String v) {
          app.settings.view[k] = v;
          app.lib.viewChanged();
        }

        void flip(String k) => set(k, on(k) ? '0' : '1');
        final covers = mode == 'covers';
        return AnimatedSize(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _PopCheck('Список с обложкой', !covers, () => set('sidebar.playlists', 'both')),
            _PopCheck('Обложки', covers, () => set('sidebar.playlists', 'covers')),
            // Подписи и размер есть только у плиток: появляются и пропадают плавно
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeIn,
              transitionBuilder: (child, anim) => FadeTransition(opacity: anim, child: SizeTransition(sizeFactor: anim, axisAlignment: -1, child: child)),
              child: covers
                  ? Column(key: const ValueKey('cv'), mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      _PopCheck('Подписи', on('sidebar.names'), () => flip('sidebar.names')),
                      Padding(padding: const EdgeInsets.symmetric(horizontal: 18), child: _CoverSizeSlider(app: app)),
                    ])
                  : const SizedBox(key: ValueKey('nocv'), width: double.infinity),
            ),
            const Padding(padding: EdgeInsets.symmetric(vertical: 5), child: Divider(height: 1, color: C.divider)),
            _PopCheck('Плейлисты', on('sidebar.showPl'), () => flip('sidebar.showPl')),
            _PopCheck('Альбомы', on('sidebar.showAl'), () => flip('sidebar.showAl')),
            _PopCheck('Исполнители', on('sidebar.showAr'), () => flip('sidebar.showAr')),
          ]),
        );
      },
    );
  }
}

/// Строка окошка с галочкой
class _PopCheck extends StatelessWidget {
  final String label;
  final bool checked;
  final VoidCallback onTap;
  const _PopCheck(this.label, this.checked, this.onTap);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        hoverColor: C.hoverOverlay,
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 38),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.centerLeft,
          child: Row(children: [
            SizedBox(
              width: 20,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 140),
                opacity: checked ? 1 : 0,
                child: Icon(Icons.check_rounded, size: 18, color: C.accent),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(label, style: const TextStyle(color: C.text, fontSize: 14))),
          ]),
        ),
      ),
    );
  }
}

/// Размер обложек в боковой панели: 4, 3 или 2 в ряд
class _CoverSizeSlider extends StatelessWidget {
  final AppServices app;
  const _CoverSizeSlider({required this.app});

  @override
  Widget build(BuildContext context) {
    final cols = int.tryParse(app.settings.viewOf('sidebar.cols', '2'))?.clamp(2, 4) ?? 2;
    return SizedBox(
      height: 38,
      child: Row(children: [
        const Text('Размер', style: TextStyle(color: C.text, fontSize: 14)),
        Expanded(
          child: Slider(
            min: 2,
            max: 4,
            divisions: 2,
            // Вправо — крупнее, то есть меньше обложек в ряд
            value: (6 - cols).toDouble(),
            onChanged: (v) {
              app.settings.view['sidebar.cols'] = '${6 - v.round()}';
              app.lib.viewChanged();
            },
          ),
        ),
      ]),
    );
  }
}

/// Пункт раздела «Коллекция»: плейлист, альбом или исполнитель
class _SideEntry {
  final String label;
  final Nav target;
  final Widget Function(double size) cover;
  final bool round;
  final String? owner; // для цветной точки автора плейлиста

  /// Что за пункт: для меню по правому клику
  final Playlist? playlist;
  final Album? album;
  final Artist? artist;
  const _SideEntry(this.label, this.target, this.cover, {this.round = false, this.owner, this.playlist, this.album, this.artist});

  /// Жетоны закрепа: у склеенного альбома их несколько
  List<String> get tokens => playlist != null
      ? [LibraryController.playlistPin(playlist!.id)]
      : album != null
          ? LibraryController.albumPins(album!).toList()
          : [LibraryController.artistPin(artist!)];

  /// Тот жетон, под которым пункт уже закреплён, иначе основной
  String tokenIn(Set<String> pins) => tokens.firstWhere(pins.contains, orElse: () => tokens.first);

  factory _SideEntry.playlist(Playlist p) => _SideEntry(p.name, Nav('playlist', p.id),
      (size) => PlaylistCover(playlist: p, size: size, radius: 5), owner: p.by, playlist: p);

  factory _SideEntry.album(Album a) =>
      _SideEntry(a.title, Nav('album', a.key), (size) => CoverImage(track: a.coverTrack, size: size, radius: 5), album: a);

  factory _SideEntry.artist(Artist a) => _SideEntry(
        a.name,
        Nav('artist', a.key),
        (size) => ClipOval(
          child: ArtistPhoto(name: a.name, size: size, fallback: CoverImage(track: a.coverTrack, size: size, radius: 0)),
        ),
        round: true,
        artist: a,
      );
}

/// Правый клик по плейлисту, альбому или исполнителю в боковой панели
Future<void> _showSideMenu(BuildContext context, _SideEntry e, Offset at) =>
    showCollectionMenu(context, at, playlist: e.playlist, album: e.album, artist: e.artist);

/// Строка «Коллекции»: миниатюра и название
class _SideRow extends StatelessWidget {
  final _SideEntry entry;
  final bool compact;
  final bool selected;
  final bool pinned;
  final VoidCallback onTap;
  const _SideRow({required this.entry, required this.compact, required this.selected, required this.onTap, this.pinned = false});

  @override
  Widget build(BuildContext context) {
    final color = selected ? C.text : C.muted;
    final body = InkWell(
      onTap: onTap,
      onSecondaryTapUp: (d) => _showSideMenu(context, entry, d.globalPosition),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        height: 46,
        padding: EdgeInsets.symmetric(horizontal: compact ? 0 : 9),
        decoration: BoxDecoration(color: selected ? C.raised : null, borderRadius: BorderRadius.circular(8)),
        child: Row(
          mainAxisAlignment: compact ? MainAxisAlignment.center : MainAxisAlignment.start,
          children: [
            SizedBox.square(dimension: 34, child: entry.cover(34)),
            if (!compact) ...[
              const SizedBox(width: 12),
              Expanded(
                child: Text(entry.label,
                    overflow: TextOverflow.ellipsis, style: TextStyle(color: color, fontWeight: selected ? FontWeight.w600 : FontWeight.w400)),
              ),
              // Точка присутствия — только у чужих плейлистов: у собственных она ничего не говорит
              if (entry.owner != null && entry.owner!.isNotEmpty && entry.owner != Services.of(context).lib.me) FriendDot(entry.owner!, size: 7),
              if (pinned) const Padding(padding: EdgeInsets.only(left: 6), child: PinMark(size: 13)),
              const SizedBox(width: 4),
            ],
          ],
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
      child: compact ? Tooltip(message: entry.label, child: body) : body,
    );
  }
}

/// «Коллекция» плитками из обложек: от 2 до 4 в ряд, в узкой панели по одной
class _SideTiles extends StatelessWidget {
  final List<_SideEntry> entries;
  final bool compact;
  final Nav current;
  final int cols;
  final bool names;
  final Set<String> pins;
  final void Function(String dragged, String target) onDrop;
  const _SideTiles(
      {required this.entries, required this.compact, required this.current, required this.cols, required this.names, required this.pins, required this.onDrop});

  @override
  Widget build(BuildContext context) {
    final nav = NavScope.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
      child: LayoutBuilder(builder: (context, box) {
        final gap = cols >= 4 ? 6.0 : 10.0;
        final w = (box.maxWidth - gap * (cols - 1)) / cols;
        return Wrap(spacing: gap, runSpacing: names ? 10 : gap, children: [
          for (final e in entries)
            SizedBox(
              width: w,
              child: PinDrag(
                token: e.tokenIn(pins),
                onDrop: onDrop,
                child: Tooltip(
                message: e.label,
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => nav.go(e.target),
                  onSecondaryTapUp: (d) => _showSideMenu(context, e, d.globalPosition),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    DecoratedBox(
                      position: DecorationPosition.foreground,
                      decoration: BoxDecoration(
                        shape: e.round ? BoxShape.circle : BoxShape.rectangle,
                        borderRadius: e.round ? null : BorderRadius.circular(8),
                        border: current.same(e.target) ? Border.all(color: C.accent, width: 2) : null,
                      ),
                      child: SizedBox.square(
                        dimension: w,
                        child: Stack(children: [
                          Positioned.fill(child: e.cover(w)),
                          if (pins.contains(e.tokenIn(pins)))
                            const Positioned(right: 4, top: 4, child: DecoratedBox(
                                decoration: BoxDecoration(color: Color(0x99000000), shape: BoxShape.circle),
                                child: Padding(padding: EdgeInsets.all(3), child: PinMark(size: 12)))),
                        ]),
                      ),
                    ),
                    if (names) ...[
                      const SizedBox(height: 4),
                      Text(e.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: e.round ? TextAlign.center : TextAlign.start,
                          style: const TextStyle(color: C.muted, fontSize: 12)),
                    ],
                  ]),
                ),
              ),
              ),
            ),
        ]);
      }),
    );
  }
}

/// Вышла новая версия: маленькая плашка внизу боковой панели, по нажатию открывает настройки с кнопками «Скачать» и «Установить».
/// Сама ничего не скачивает и не перезапускает
class _UpdateLine extends StatelessWidget {
  final bool compact;
  const _UpdateLine({required this.compact});

  @override
  Widget build(BuildContext context) {
    final up = Services.of(context).updater;
    final nav = NavScope.of(context);
    return ListenableBuilder(
      listenable: up,
      builder: (context, _) {
        final has = up.state == UpdateState.available || up.state == UpdateState.downloading || up.state == UpdateState.ready;
        if (!has) return const SizedBox.shrink();
        final label = up.state == UpdateState.ready ? 'Готово к установке: ${up.latest}' : 'Доступна версия ${up.latest}';
        final chip = InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () => nav.go(const Nav('accounts', 'main')),
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 12, vertical: 7),
            decoration: BoxDecoration(
              color: C.accent.withValues(alpha: 0.16),
              border: Border.all(color: C.accent.withValues(alpha: 0.5)),
              borderRadius: BorderRadius.circular(20),
            ),
            child: compact
                ? Icon(Icons.system_update_alt_rounded, size: 18, color: C.accent)
                : Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.system_update_alt_rounded, size: 15, color: C.accent),
                    const SizedBox(width: 8),
                    Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: C.accent, fontSize: 12.5, fontWeight: FontWeight.w600))),
                  ]),
          ),
        );
        return Padding(
          padding: EdgeInsets.fromLTRB(compact ? 10 : 16, 12, compact ? 10 : 16, 0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Tooltip(message: label, child: Align(alignment: compact ? Alignment.center : Alignment.centerLeft, child: chip)),
            if (up.state == UpdateState.downloading && !compact) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: up.progress),
            ],
          ]),
        );
      },
    );
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;

  /// 0 — полная панель, 1 — узкая. Значок стоит на месте, подпись укатывается вправо и гаснет
  final double t;
  final VoidCallback onTap;
  final Widget? trailing;
  final Widget? leading;

  const _NavItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.t,
    required this.onTap,
    this.trailing,
    this.leading,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected ? C.text : C.muted;
    final fade = (1 - t * 1.5).clamp(0.0, 1.0);
    // Подсветка выбранного пункта сужается вместе с панелью: 220 → 52
    final width = 220 - (220 - 52) * t;
    Widget body = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        height: 40,
        decoration: BoxDecoration(
          color: selected ? C.hover : null,
          borderRadius: BorderRadius.circular(12),
        ),
        // Содержимое всегда выложено на полную ширину, лишнее обрезает край подсветки
        child: ClipRect(
          child: OverflowBox(
            alignment: Alignment.centerLeft,
            minWidth: 0,
            maxWidth: 220,
            child: SizedBox(
              width: 220,
              child: Row(
                children: [
                  // 16: центр значка совпадает с узкой панелью, и при её сворачивании значки не прыгают
                  const SizedBox(width: 16),
                  Stack(clipBehavior: Clip.none, children: [
                    Icon(icon, size: 20, color: selected ? C.accent : color),
                    if (trailing != null && t > 0)
                      Positioned(right: -8, top: -6, child: Opacity(opacity: t.clamp(0.0, 1.0), child: trailing!)),
                  ]),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Opacity(
                      opacity: fade,
                      child: Transform.translate(
                        offset: Offset(t * 70, 0),
                        child: Row(children: [
                          Expanded(
                            child: Text(label,
                                maxLines: 1,
                                softWrap: false,
                                overflow: TextOverflow.clip,
                                style: TextStyle(color: color, fontWeight: selected ? FontWeight.w600 : FontWeight.w400)),
                          ),
                          if (leading != null) ...[leading!, const SizedBox(width: 4)],
                          if (trailing != null) trailing!,
                          const SizedBox(width: 16),
                        ]),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (t >= 1) body = Tooltip(message: label, child: body);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 1),
      child: Align(alignment: Alignment.centerLeft, child: SizedBox(width: width, child: body)),
    );
  }
}

/// Подсказка, когда над окном тащат файлы: стеклянная карточка по центру на затемнённом фоне
class _DropOverlay extends StatelessWidget {
  const _DropOverlay();

  @override
  Widget build(BuildContext context) {
    // Material нужен тексту: без него на нём рисовалось жёлтое подчёркивание и стиль по умолчанию
    return Material(
      type: MaterialType.transparency,
      child: Container(
        color: Colors.black.withValues(alpha: 0.5),
        alignment: Alignment.center,
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: GlassPanel(
            radius: 24,
            blur: 32,
            border: C.accent.withValues(alpha: 0.55),
            padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 34),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: C.accent.withValues(alpha: 0.16),
                  border: Border.all(color: C.accent.withValues(alpha: 0.5)),
                ),
                child: Icon(Icons.upload_rounded, size: 30, color: C.accent),
              ),
              const SizedBox(height: 18),
              Text('Отпустите, чтобы загрузить', textAlign: TextAlign.center, style: display(20)),
              const SizedBox(height: 8),
              const Text('Музыка уйдёт на Google Диск и появится в библиотеке у всех',
                  textAlign: TextAlign.center, style: TextStyle(color: C.muted, fontSize: 14, height: 1.4, decoration: TextDecoration.none)),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Круглая стрелка «наверх» справа снизу над плеером
class _ScrollTopButton extends StatelessWidget {
  final bool visible;
  final VoidCallback onTap;
  const _ScrollTopButton({required this.visible, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !visible,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: const Duration(milliseconds: 180),
        child: AnimatedScale(
          scale: visible ? 1 : 0.8,
          duration: const Duration(milliseconds: 180),
          child: Tooltip(
            message: 'Наверх',
            child: Material(
              color: C.glass,
              shape: const CircleBorder(side: BorderSide(color: C.line)),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: onTap,
                child: const SizedBox.square(dimension: 44, child: Icon(Icons.arrow_upward_rounded, color: C.text)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}


/// Правая панель: текст песни или очередь. Обе одной ширины; появляются и исчезают плавно, раскрываясь от правого края
class SidePanelSlot extends StatefulWidget {
  const SidePanelSlot({super.key});

  /// Ширина самой панели; с отступом справа слот занимает на 12 больше
  static const panelWidth = 360.0;

  @override
  State<SidePanelSlot> createState() => _SidePanelSlotState();
}

class _SidePanelSlotState extends State<SidePanelSlot> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 300));
  late final Animation<double> _t = CurvedAnimation(parent: _c, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
  String? _shown; // что рисуем сейчас; пока панель закрывается, остаётся прежним
  PlayerController? _p;

  String? _want(PlayerController p) => p.lyricsOpen.value ? 'lyrics' : (p.queueOpen.value ? 'queue' : null);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final p = Services.of(context).player;
    if (!identical(p, _p)) {
      _p?.lyricsOpen.removeListener(_sync);
      _p?.queueOpen.removeListener(_sync);
      _p = p;
      p.lyricsOpen.addListener(_sync);
      p.queueOpen.addListener(_sync);
      _shown = _want(p);
      _c.value = _shown == null ? 0 : 1;
    }
  }

  @override
  void dispose() {
    _p?.lyricsOpen.removeListener(_sync);
    _p?.queueOpen.removeListener(_sync);
    _c.dispose();
    super.dispose();
  }

  void _sync() {
    final want = _want(_p!);
    if (want != null) {
      // Открыли другую панель вместо прежней — меняем содержимое без скачка ширины
      setState(() => _shown = want);
      _c.forward();
    } else {
      _c.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_shown == null) return const SizedBox.shrink();
    const full = SidePanelSlot.panelWidth + 12;
    return AnimatedBuilder(
      animation: _t,
      builder: (context, _) {
        final t = _t.value;
        if (t <= 0 && !_c.isAnimating) return const SizedBox.shrink();
        return ClipRect(
          child: SizedBox(
            width: full * t,
            child: OverflowBox(
              alignment: Alignment.centerRight,
              minWidth: full,
              maxWidth: full,
              child: Opacity(
                opacity: t.clamp(0.0, 1.0),
                child: Transform.scale(
                  alignment: Alignment.topRight,
                  scale: 0.94 + 0.06 * t,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child: KeyedSubtree(
                      key: ValueKey(_shown),
                      child: _shown == 'lyrics' ? const LyricsPanel() : const QueuePanel(),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
