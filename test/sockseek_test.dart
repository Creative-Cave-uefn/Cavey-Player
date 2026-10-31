import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:cave_player/core/dl/sockseek.dart';
import 'package:cave_player/core/dl/text.dart';
import 'package:cave_player/core/dl/tools.dart';
import 'package:cave_player/core/dl/winproc.dart';
import 'package:cave_player/core/store.dart';

void main() {
  test('Sockseek is opt-in and persists independently of Zotify', () {
    final old = Settings.fromJson({'useZotify': true});
    expect(old.useZotify, true);
    expect(old.useSockseek, false);
    old.useSockseek = true;
    old.useZotify = false;
    final restored = Settings.fromJson(old.toJson());
    expect(restored.useSockseek, true);
    expect(restored.useZotify, false);
  });
  test('CSV preserves Unicode, quotes, commas, recording version and length', () {
    final value = Sockseek.csv([TrackMeta(artist: 'bôa, Guest', title: 'Elephant "Live"', album: 'A, B', duration: 234.264)]);
    expect(value, 'artist,title,album,length\r\n"bôa, Guest","Elephant ""Live""","A, B","234"\r\n');
    expect(Sockseek.csv([TrackMeta(artist: 'a', title: 't')]), contains('"a","t","",""'));
  });
  test('CLI forces CSV and strict conditions without credentials in argv', () {
    final args = Sockseek.arguments('C:/input with spaces.csv', 'C:/output', 'C:/private.conf');
    expect(args.first, 'C:/input with spaces.csv');
    expect(args, containsAll(['--input-type', 'csv', '--strict-title', '--strict-artist', '--strict-conditions', '--length-tol', '3']));
    expect(args, isNot(contains('--pass')));
    expect(args, isNot(contains('--user')));
    expect(args, isNot(contains('--relax')));
  });
  test('only completed audio can be imported', () {
    for (final path in ['a.FLAC', 'folder/song.mp3', 'a.opus']) {
      expect(Sockseek.completedAudio(path), true);
    }
    for (final path in ['a.mp3.incomplete', 'a.incomplete.mp3', 'a.csv', 'a.exe', 'a.mp3.part']) {
      expect(Sockseek.completedAudio(path), false);
    }
  });
  test('config creation never overwrites an existing account', () async {
    final dir = await Directory.systemTemp.createTemp('sockseek-config-');
    addTearDown(() => dir.delete(recursive: true));
    final tools = Tools(dir);
    await Sockseek.prepareConfig(tools);
    expect(await Sockseek.config(tools).readAsString(), contains('YOUR_SOULSEEK_USERNAME'));
    await Sockseek.config(tools).writeAsString('existing settings');
    await Sockseek.prepareConfig(tools);
    expect(await Sockseek.config(tools).readAsString(), 'existing settings');
  });
  test('Windows installer and real CLI parse generated CSV without login', () async {
    final dir = await Directory.systemTemp.createTemp('sockseek-install-');
    addTearDown(() => dir.delete(recursive: true));
    final tools = Tools(dir);
    await Sockseek.install(tools, print);
    expect(await Sockseek.executable(tools).exists(), true);
    final csv = File('${dir.path}/input.csv');
    await csv.writeAsString(Sockseek.csv([TrackMeta(artist: 'bôa', title: 'Elephant', duration: 234)]));
    final lines = <String>[];
    final code = await WinProc.run(Sockseek.executable(tools).absolute.path,
        [csv.absolute.path, '--input-type', 'csv', '--no-config', '--print', 'jobs-full'], lines.add);
    expect(code, 0, reason: lines.join('\n'));
    expect(lines.join('\n'), contains('Elephant'));
  }, skip: !Platform.isWindows || Platform.environment['CAVE_SOCKSEEK_SMOKE'] != '1',
      timeout: const Timeout(Duration(minutes: 4)));
}
