import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'core/audio_cache.dart';
import 'core/drive.dart';
import 'core/library.dart';
import 'core/log.dart';
import 'core/player.dart';
import 'core/store.dart';
import 'core/covers.dart';
import 'core/dl/service.dart';
import 'core/lyric_sources.dart';
import 'core/lyrics.dart';
import 'core/preview.dart';
import 'core/social.dart';
import 'core/wave.dart';
import 'core/web_info.dart';
import 'mobile/mobile_auth.dart';
import 'mobile/mobile_home.dart';
import 'mobile/mobile_updater.dart';

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
  final MobileUpdater updater;
  final LyricsService lyrics;
  final SocialController social;
  final WebInfoService web;
  final PreviewPlayer preview;
  final WaveService wave;

  MobileServices._(this.store, this.settings, this.accounts, this.drive,
      this.library, this.covers, this.cache, this.player, this.updater,
      this.lyrics, this.social, this.web, this.preview, this.wave);

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
    final updater = MobileUpdater()..start();

    // Тексты: сначала ищем рядом с треком на Диске и внутри файла, потом в интернете (как на ПК)
    final lyrics = LyricsService(store.sub('lyrics'));
    lyrics.ownSource = (t) async {
      final email = await library.accessFor(t.source);
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
      library.noteDuration(t, d);
    };

    final social = SocialController(library, drive, player)..start();
    final web = WebInfoService(store.sub('web'), library);
    final preview = PreviewPlayer(player);
    // Скачивание новых треков из интернета делает программа на ПК; на телефоне её нет,
    // поэтому «Моя волна» здесь работает только по готовой библиотеке
    final downloads = DownloadService(library, store.sub('downloads'), cache: cache, covers: covers);
    final wave = await WaveService.open(store, library, player, social, web, downloads);
    wave.discover = false;
    return MobileServices._(
        store, settings, accounts, drive, library, covers, cache, player, updater,
        lyrics, social, web, preview, wave);
  }
}
