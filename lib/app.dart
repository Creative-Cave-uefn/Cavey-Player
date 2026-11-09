import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'config.dart';
import 'core/preview.dart';
import 'core/web_info.dart';
import 'core/karaoke.dart';
import 'core/wave.dart';
import 'core/app_icon.dart';
import 'core/audio_cache.dart';
import 'core/automix.dart';
import 'core/auth.dart';
import 'core/covers.dart';
import 'core/discord.dart';
import 'core/dl/service.dart';
import 'core/dl/tools.dart';
import 'core/drive.dart';
import 'core/jam.dart';
import 'core/library.dart';
import 'core/lyric_sources.dart';
import 'core/perf.dart';
import 'core/log.dart';
import 'core/lyrics.dart';
import 'core/player.dart';
import 'core/social.dart';
import 'core/store.dart';
import 'core/single_instance.dart';
import 'core/taskbar.dart';
import 'core/tray.dart';
import 'core/tray_cleanup.dart';
import 'core/media_keys.dart';
import 'core/share_link.dart';
import 'core/updater.dart';
import 'ui/ambient.dart';
import 'ui/onboarding.dart';
import 'ui/window_bar.dart';
import 'ui/shell.dart';
import 'ui/theme.dart';
import 'ui/tray_dialog.dart';

/// Нужен, чтобы показать окно вопроса, когда окна самого приложения в дереве ещё нет под рукой
final navigatorKey = GlobalKey<NavigatorState>();

class AppServices {
  final AppStore store;
  final Settings settings;
  final AccountManager accounts;
  final DriveApi drive;
  final LibraryController lib;
  final PlayerController player;
  final CoverService covers;
  final Updater updater;
  final AudioCache cache;
  final LyricsService lyrics;
  final SocialController social;
  final JamController jam;
  final DiscordPresence discord;
  final DownloadService downloads;
  final TrayController tray;

  /// Фото, описания и новинки исполнителей из интернета, отрывки треков
  late final WebInfoService web;
  late final PreviewPlayer preview;
  late final WaveService wave;
  late final KaraokeService karaoke;
  late final MediaKeys mediaKeys;

  /// Ссылка caveplayer://track/…, пришедшая при запуске или от второй копии; окно её обрабатывает и очищает
  final ValueNotifier<String?> incomingLink = ValueNotifier(null);

  /// Ключи Google вшиты при сборке — тогда друзьям не нужно ничего вводить
  final bool keysBuiltIn;

  AppServices._(this.store, this.settings, this.accounts, this.drive, this.lib, this.player, this.covers, this.updater, this.cache, this.lyrics, this.social, this.jam, this.discord, this.downloads, this.tray, this.keysBuiltIn);

  static Future<AppServices> create() async {
    final store = await AppStore.open();
    final updater = Updater(store);
    // Скачанное в прошлый раз обновление ставим до запуска интерфейса
    if (await updater.installPendingOnStart()) exit(0);
    final settings = Settings.fromJson(await store.readJson('settings.json'));
    final savedAccent = C.parseAccent(settings.view['accent']);
    if (savedAccent != null) C.setAccent(savedAccent);
    final builtIn = kGoogleClientId.isNotEmpty && kGoogleClientSecret.isNotEmpty;
    if (builtIn) {
      settings
        ..clientId = kGoogleClientId
        ..clientSecret = kGoogleClientSecret;
    }
    final accounts = AccountManager(store, settings);
    await accounts.load();
    final drive = DriveApi(accounts);
    final lib = LibraryController(store, settings, accounts, drive);
    final covers = CoverService(drive, lib, store.sub('covers'));
    final cache = AudioCache(store.sub('audio'), drive, lib, settings);
    final player = PlayerController(lib, accounts, settings, cache);
    final lyrics = LyricsService(store.sub('lyrics'));
    // Текст ищем сразу, как трек открылся: панель потом покажет его без ожидания
    // Л1, Л6: сначала смотрим, нет ли текста рядом с треком на Диске или внутри самого файла
    lyrics.ownSource = (t) async {
      final email = await lib.accessFor(t.source);
      final meta = await drive.getFile(email, t.id, fields: 'id,name,parents');
      final name = '${meta['name'] ?? ''}';
      final dot = name.lastIndexOf('.');
      final base = dot > 0 ? name.substring(0, dot) : name;
      final parents = (meta['parents'] as List?)?.cast<String>() ?? const <String>[];
      if (parents.isNotEmpty && base.isNotEmpty) {
        for (final ext in const ['txt', 'ass', 'lrc']) {
          final found = await drive.listChildren(email, parents.first, nameEquals: '$base.$ext');
          if (found.isEmpty) continue;
          final text = utf8.decode(await drive.download(email, found.first.id), allowMalformed: true);
          if (ext == 'txt' && text.contains('#BPM')) return SourceText(LyricKind.ultrastar, text);
          if (ext == 'ass') return SourceText(LyricKind.ass, text);
          final c = LyricFiles.classify(text);
          if (c != null) return c;
        }
      }
      final head = await drive.readRange(email, t.id, 0, 262143);
      return LyricFiles.embedded(head);
    };
    player.onTrackReady = (t, d) {
      lyrics.forTrack(t, d).then<void>((_) {}, onError: (Object _) {});
      lib.noteDuration(t, d);
      // Л5: текст следующего трека ищем заранее, вместе с предзагрузкой звука
      final next = player.upcoming.firstOrNull;
      if (next != null && (next.durationMs ?? 0) > 0 && !lyrics.known(next)) {
        lyrics.forTrack(next, Duration(milliseconds: next.durationMs!)).then<void>((_) {}, onError: (Object _) {});
      }
    };
    PerfLog.start(); // И1: раз в минуту в журнал — кадры и время отрисовки
    accounts.addListener(lib.saveSettings);
    await lib.start();
    // Картинки первых треков читаем с диска заранее, чтобы список открылся уже с обложками
    unawaited(covers.warm(lib.allTracks));
    updater.start();
    await cache.init();
    player.restoreSession();
    final social = SocialController(lib, drive, player)..start();
    final discord = DiscordPresence();
    void showInDiscord() => discord.update(
          player.current,
          playing: player.playing,
          position: player.position.value,
          duration: player.duration,
          enabled: settings.discord,
        );
    player.addListener(showInDiscord);
    // Слушаем вместе с другом: переходы идут по его трекам, плавный переход мешал бы синхронизации
    final jam = JamController(lib, drive, player, social,
        serverUrl: () => settings.viewOf('ntfy', '1') == '0' ? '' : settings.viewOf('ntfy.server', 'https://ntfy.sh'));
    player.crossfadeBlocked = () => jam.active;
    social.jamInfo = () => jam.active ? {'id': jam.jamId, 'm': jam.participants} : null;
    social.onFreshNotice = jam.onFreshNotice;
    jam.start();
    player.onUserAction = () {
      social.onUserAction();
      showInDiscord();
    };
    final downloads = DownloadService(lib, store.sub('downloads'), cache: cache, covers: covers,
        onAudioReplaced: player.invalidateStream);
    late final AppServices app;
    final tray = TrayController(
      player: player,
      settings: settings,
      save: lib.saveSettings,
      onQuit: () => app.shutdown(),
      askFirstTime: () async {
        final context = navigatorKey.currentContext;
        if (context == null) return true;
        return askTrayOnClose(context);
      },
    );
    app = AppServices._(
        store, settings, accounts, drive, lib, player, covers, updater, cache, lyrics, social, jam, discord, downloads, tray, builtIn);
    app.web = WebInfoService(store.sub('web'), lib);
    app.preview = PreviewPlayer(player);
    app.karaoke = KaraokeService(store.sub('karaoke'), lib, drive, cache, Tools(store.sub('tools')));
    // Умный переход: профили звука треков и темп из Deezer (если уже узнали)
    player.mixer = MixAnalyzer(store.sub('mix'), cache, Tools(store.sub('tools')))..onProfile = (id) {
        if (id == player.current?.id) player.refreshNormalize();
      };
    final tempo = <String, double?>{};
    player.tempoOf = (t) {
      if (tempo.containsKey(t.id)) return tempo[t.id];
      tempo[t.id] = null;
      if (t.artists.isNotEmpty) app.web.bpm(t.artists.first, t.title).then((b) => tempo[t.id] = b).catchError((Object _) => null);
      return null;
    };
    app.wave = await WaveService.open(store, lib, player, social, app.web, downloads);
    Updater.beforeExit = tray.dispose;
    app.mediaKeys = MediaKeys(player, settings)..start();
    unawaited(tray.start());
    // Значок в цвете акцента: в трее и у окна — сразу при запуске
    unawaited(app.collectIconResult().then((_) => app.refreshAppIcon()));
    // Значки, оставшиеся от закрытых принудительно прошлых версий, Проводник выбрасывает, когда над ними «проведут курсор»
    Timer(const Duration(seconds: 2), sweepGhostTrayIcons);
    Timer(const Duration(seconds: 12), sweepGhostTrayIcons);
    // Ярлык на панели задач запускает вторую копию; она просит первую показать окно
    listenForSecondLaunch(() {
      unawaited(tray.showWindow());
      final link = takePendingLink();
      if (link != null) app.incomingLink.value = link;
    });
    // Кнопки «Назад / Пауза / Дальше» в превью на панели задач живут до выхода из приложения
    unawaited(TaskbarController(player).start());
    return app;
  }

  // ---------- значок в цвете акцента ----------

  String _accentHex() => C.accentHex(C.accent);

  /// Какой значок должен быть в файле программы: цвет и версия (после обновления файл новый, со стандартным значком)
  String _wantedExeIcon() => '${_accentHex()}@$kAppVersion';

  /// Значок файла программы ещё не в цвете акцента (сменили цвет или обновились)
  bool get exeIconPending {
    final applied = settings.viewOf('exeIcon', '');
    final isDefault = C.accent.value == C.defaultAccent.value;
    // Стандартный цвет и значок ни разу не меняли — менять нечего
    if (applied.isEmpty && isDefault) return false;
    return applied != _wantedExeIcon();
  }

  /// Сколько раз подряд замена значка в файле программы не удалась (после двух неудач сама на выходе не запускается)
  int get exeIconFails => int.tryParse(settings.viewOf('exeIconFails', '0')) ?? 0;

  String get _iconResultPath => '${store.dir.path}${Platform.pathSeparator}icon-result.txt';

  /// Итог прошлой замены значка файла: скрипт кладёт его, когда приложение уже закрыто.
  /// Значок считаем сменённым только если замена действительно прошла
  Future<void> collectIconResult() async {
    final r = await AppIcon.takeResult(_iconResultPath);
    if (r == null) return;
    if (r.$1) {
      settings.view['exeIcon'] = r.$2;
      settings.view.remove('exeIconFails');
      AppLog.info('Значок файла программы заменён (${r.$2})');
    } else {
      settings.view['exeIconFails'] = '${exeIconFails + 1}';
      AppLog.warn('Значок файла программы не заменился', r.$2);
    }
    await lib.saveSettings();
  }

  /// Значок в трее и у окна — в цвет акцента (или стандартный)
  Future<void> refreshAppIcon() async {
    try {
      final isDefault = C.accent.value == C.defaultAccent.value;
      final path = await AppIcon.prepare(store.dir, C.accent.value, isDefault: isDefault) ?? AppIcon.defaultIcon;
      AppLog.info('Значок акцента: $path');
      await tray.setIcon(path);
      final changed = !isDefault || settings.viewOf('exeIcon', '').isNotEmpty;
      if (changed) await AppIcon.applyToWindow(path);
      // Ярлыки (панель задач, «Пуск», рабочий стол) получают значок сразу, без перезапуска
      // (повторно — только после смены цвета или обновления: установщик пересоздаёт ярлыки со стандартным значком)
      final lnkWant = '${isDefault ? '' : path}@$kAppVersion';
      if (changed && settings.viewOf('lnkIcon', '') != lnkWant) {
        settings.view['lnkIcon'] = lnkWant;
        unawaited(AppIcon.refreshShortcuts(isDefault ? null : path).then((_) => lib.saveSettings()));
      }
    } catch (e) {
      AppLog.warn('Значок в цвете акцента не получился', e);
    }
  }

  /// Записать значок в файл программы: Cavey закрывается, значок меняется, проводник перезапускается.
  /// [relaunch] — открыть Cavey снова (кнопка в настройках); при обычном выходе — нет
  Future<void> applyExeIcon({required bool relaunch}) async {
    final isDefault = C.accent.value == C.defaultAccent.value;
    final ico = await AppIcon.prepare(store.dir, C.accent.value, isDefault: isDefault) ?? AppIcon.bundledIco();
    // Метку «значок сменён» ставит collectIconResult после запуска, когда скрипт сообщит, что получилось
    final started = await AppIcon.patchExeAfterExit(ico, relaunch: relaunch, token: _wantedExeIcon(), resultFile: _iconResultPath);
    if (relaunch && started) {
      await shutdown(patchIcon: false);
    } else if (relaunch) {
      AppLog.warn('Значок файла программы: замена не запустилась, перезапуск отменён');
    }
  }

  /// Полный выход (из меню трея или по крестику, если трей выключен): сохраняем, что не сохранено, и закрываемся.
  /// Если значок файла программы ещё не в цвете акцента — он меняется сразу после выхода
  Future<void> shutdown({bool patchIcon = true}) async {
    if (patchIcon && exeIconPending && exeIconFails < 2) {
      try {
        await applyExeIcon(relaunch: false);
      } catch (_) {}
    }
    try {
      await jam.shutdown();
    } catch (_) {}
    try {
      await player.flushSession();
      await wave.flush();
      await lib.flushNow();
    } catch (_) {}
    await AppLog.flush();
    try {
      await tray.dispose();
      await windowManager.destroy();
    } catch (_) {}
    exit(0);
  }
}

class Services extends InheritedWidget {
  final AppServices app;
  const Services({super.key, required this.app, required super.child});

  static AppServices of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<Services>()!.app;

  @override
  bool updateShouldNotify(Services oldWidget) => oldWidget.app != app;
}

class CavePlayerApp extends StatelessWidget {
  final AppServices app;
  const CavePlayerApp({super.key, required this.app});

  @override
  Widget build(BuildContext context) {
    return Services(
      app: app,
      child: MaterialApp(
        navigatorKey: navigatorKey,
        title: 'Cavey',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        // Стеклянный фон под всеми экранами, включая первый запуск и диалоги.
        // Выделяемый текст не должен менять указатель на «текстовый»: над ссылками остаётся рука, над остальным — стрелка
        builder: (context, child) => DefaultSelectionStyle(
          mouseCursor: MouseCursor.defer,
          child: Stack(children: [
            const Positioned.fill(child: AmbientBackground()),
            // Своя шапка окна сверху, всё остальное под ней — шапка сливается со стеклом
            Positioned.fill(
              child: Column(children: [
                if (WindowBar.enabled) const WindowBar(),
                Expanded(child: child ?? const SizedBox.shrink()),
              ]),
            ),
          ]),
        ),
        home: ListenableBuilder(
          listenable: Listenable.merge([app.accounts, app.lib]),
          builder: (context, _) {
            if (!app.accounts.configured) return const SetupScreen();
            if (app.accounts.accounts.isEmpty) return const WelcomeScreen();
            if (!app.lib.hasHub) return const HubScreen();
            return const Shell();
          },
        ),
      ),
    );
  }
}
