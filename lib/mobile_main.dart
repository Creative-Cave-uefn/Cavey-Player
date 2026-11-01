import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'core/audio_cache.dart';
import 'core/drive.dart';
import 'core/library.dart';
import 'core/log.dart';
import 'core/player.dart';
import 'core/store.dart';
import 'core/covers.dart';
import 'mobile/mobile_auth.dart';
import 'mobile/mobile_home.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await AppLog.init();

  try {
    final services = await MobileServices.open();
    runApp(CaveyAndroid(services: services));
  } catch (e, stack) {
    AppLog.error('Android startup', e, stack);
    runApp(MaterialApp(
      home: Scaffold(
        body: Center(child: Padding(
          padding: const EdgeInsets.all(24),
          child: SelectableText('Не удалось запустить Cavey Player:\n$e'),
        )),
      ),
    ));
  }
}

class MobileServices {
  final AppStore store;
  final Settings settings;
  final MobileAccountManager accounts;
  final DriveApi drive;
  final LibraryController library;
  final CoverService covers;
  final AudioCache cache;
  final PlayerController player;

  MobileServices._(this.store, this.settings, this.accounts, this.drive,
      this.library, this.covers, this.cache, this.player);

  static Future<MobileServices> open() async {
    final store = await AppStore.open();
    final settings = Settings.fromJson(await store.readJson('settings.json'));
    // Mobile avoids two simultaneous decoders while the UI is in the foreground.
    settings.crossfadeSec = 0;
    final accounts = MobileAccountManager(store, settings);
    await accounts.load();
    final drive = DriveApi(accounts);
    final library = LibraryController(store, settings, accounts, drive,
        mobileReadOnlyIndex: true);
    await library.start();
    final covers = CoverService(drive, library, store.sub('covers'));
    final cache = AudioCache(store.sub('audio'), drive, library, settings);
    await cache.init();
    final player = PlayerController(library, accounts, settings, cache);
    player.restoreSession();
    return MobileServices._(
        store, settings, accounts, drive, library, covers, cache, player);
  }
}
