import 'package:flutter/material.dart';

import 'config.dart';
import 'core/auth.dart';
import 'core/covers.dart';
import 'core/drive.dart';
import 'core/library.dart';
import 'core/player.dart';
import 'core/store.dart';
import 'ui/onboarding.dart';
import 'ui/shell.dart';
import 'ui/theme.dart';

class AppServices {
  final AppStore store;
  final Settings settings;
  final AccountManager accounts;
  final DriveApi drive;
  final LibraryController lib;
  final PlayerController player;
  final CoverService covers;

  /// Ключи Google вшиты при сборке — тогда друзьям не нужно ничего вводить
  final bool keysBuiltIn;

  AppServices._(this.store, this.settings, this.accounts, this.drive, this.lib, this.player, this.covers, this.keysBuiltIn);

  static Future<AppServices> create() async {
    final store = await AppStore.open();
    final settings = Settings.fromJson(await store.readJson('settings.json'));
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
    final player = PlayerController(lib, accounts, settings);
    accounts.addListener(lib.saveSettings);
    await lib.start();
    return AppServices._(store, settings, accounts, drive, lib, player, covers, builtIn);
  }
}

class Services extends InheritedWidget {
  final AppServices app;
  const Services({super.key, required this.app, required super.child});

  static AppServices of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<Services>()!.app;

  @override
  bool updateShouldNotify(Services oldWidget) => oldWidget.app != app;
}

class PolkaApp extends StatelessWidget {
  final AppServices app;
  const PolkaApp({super.key, required this.app});

  @override
  Widget build(BuildContext context) {
    return Services(
      app: app,
      child: MaterialApp(
        title: 'Полка',
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
