import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'config.dart';
import 'core/preview.dart';
import 'core/web_info.dart';
import 'core/audio_cache.dart';
import 'core/auth.dart';
import 'core/covers.dart';
import 'core/discord.dart';
import 'core/dl/service.dart';
import 'core/dl/tools.dart';
import 'core/drive.dart';
import 'core/library.dart';
import 'core/lyrics.dart';
import 'core/player.dart';
import 'core/social.dart';
import 'core/store.dart';
import 'core/taskbar.dart';
import 'core/tray.dart';
import 'core/updater.dart';
import 'ui/onboarding.dart';
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
  final DiscordPresence discord;
  final DownloadService downloads;
  final TrayController tray;

  /// Фото, описания и новинки исполнителей из интернета, отрывки треков
  late final WebInfoService web;
  late final PreviewPlayer preview;

  /// Ключи Google вшиты при сборке — тогда друзьям не нужно ничего вводить
  final bool keysBuiltIn;

  AppServices._(this.store, this.settings, this.accounts, this.drive, this.lib, this.player, this.covers, this.updater, this.cache, this.lyrics, this.social, this.discord, this.downloads, this.tray, this.keysBuiltIn);

  static Future<AppServices> create() async {
    final store = await AppStore.open();
    final updater = Updater(store);
    // Скачанное в прошлый раз обновление ставим до запуска интерфейса
    if (await updater.installPendingOnStart()) exit(0);
    final settings = Settings.fromJson(await store.readJson('settings.json'));
    final builtIn = kGoogleClientId.isNotEmpty && kGoogleClientSecret.isNotEmpty;
    if (builtIn) {
      settings
        ..clientId = kGoogleClientId
        ..clientSecret = kGoogleClientSecret;
    }
    updater.beta = settings.betaUpdates;
    final accounts = AccountManager(store, settings);
    await accounts.load();
    final drive = DriveApi(accounts);
    final lib = LibraryController(store, settings, accounts, drive);
    final covers = CoverService(drive, lib, store.sub('covers'));
    final cache = AudioCache(store.sub('audio'), drive, lib, settings);
    final player = PlayerController(lib, accounts, settings, cache);
    final lyrics = LyricsService(store.sub('lyrics'));
    // Текст ищем сразу, как трек открылся: панель потом покажет его без ожидания
    player.onTrackReady = (t, d) {
      lyrics.forTrack(t, d).then<void>((_) {}, onError: (Object _) {});
      lib.noteDuration(t, d);
    };
    accounts.addListener(lib.saveSettings);
    await lib.start();
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
    player.onUserAction = () {
      social.onUserAction();
      showInDiscord();
    };
    final downloads = DownloadService(lib, Tools(store.sub('tools')), store.sub('downloads'));
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
        store, settings, accounts, drive, lib, player, covers, updater, cache, lyrics, social, discord, downloads, tray, builtIn);
    app.web = WebInfoService(store.sub('web'), lib);
    app.preview = PreviewPlayer(player);
    unawaited(tray.start());
    // Кнопки «Назад / Пауза / Дальше» в превью на панели задач живут до выхода из приложения
    unawaited(TaskbarController(player).start());
    return app;
  }

  /// Полный выход (из меню трея или по крестику, если трей выключен): сохраняем, что не сохранено, и закрываемся
  Future<void> shutdown() async {
    try {
      await player.flushSession();
      await lib.flushNow();
    } catch (_) {}
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
        title: 'Cave Player',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
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
