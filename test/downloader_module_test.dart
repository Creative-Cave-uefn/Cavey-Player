// Модуль скачки снаружи плеера: выбор сборки из релизов и протокол обмена.
// Вместо настоящего cave-downloader.exe к сокету плеера подключается подставной модуль.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cave_player/config.dart';
import 'package:cave_player/core/downloader/module.dart';
import 'package:cave_player/core/downloader/session.dart';
import 'package:flutter_test/flutter_test.dart';

Map release(String tag, {bool pre = false, bool draft = false, String? digest, bool shaFile = false, bool exe = true}) => {
      'tag_name': tag,
      'prerelease': pre,
      'draft': draft,
      'assets': [
        if (exe)
          {
            'name': DownloaderModule.assetName,
            'url': 'https://api.github.com/repos/o/r/releases/assets/$tag-exe',
            if (digest != null) 'digest': 'sha256:$digest',
          },
        if (shaFile) {'name': '${DownloaderModule.assetName}.sha256', 'url': 'https://api.github.com/repos/o/r/releases/assets/$tag-sha'},
      ],
    };

/// Подставной модуль: подключается к плееру по аргументам serve и делает [script]
Launcher fakeModule(Future<void> Function(Socket s, StreamIterator<String> lines, Map job) script,
    {int protocol = kDownloaderProtocol, String? token, int exitCode = 0}) {
  return (exe, args, onLine) async {
    expect(args.first, 'serve');
    final address = args[args.indexOf('--connect') + 1];
    final s = await Socket.connect('127.0.0.1', int.parse(address.split(':').last));
    final lines = StreamIterator(s.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter()));
    s.write('${jsonEncode({'t': 'hello', 'token': token ?? args[args.indexOf('--token') + 1], 'version': '1.0.7', 'protocol': protocol})}\n');
    try {
      // Плеер мог отказать и закрыть соединение — это не ошибка подставного модуля
      if (await lines.moveNext()) {
        final first = jsonDecode(lines.current) as Map;
        if (first['t'] == 'job') await script(s, lines, first);
      }
    } catch (e) {
      stderr.writeln('подставной модуль: $e');
    } finally {
      try {
        await s.close();
      } catch (_) {}
    }
    return exitCode;
  };
}

void send(Socket s, Map m) => s.write('${jsonEncode(m)}\n');

Future<Map> next(StreamIterator<String> lines) async {
  expect(await lines.moveNext(), isTrue);
  return jsonDecode(lines.current) as Map;
}

void main() {
  group('выбор сборки модуля', () {
    test('самая новая обычная сборка своего протокола', () {
      final r = DownloaderModule.pick([
        release('v1.0.9', digest: 'a' * 64),
        release('v1.0.12', digest: 'b' * 64),
        release('v1.0.20', pre: true),
        release('v1.0.21', draft: true),
        release('v2.0.30'),
        release('v1.0.13', exe: false),
        release('nightly'),
      ], 1);
      expect(r?.version, '1.0.12');
      expect(r?.sha256, 'b' * 64);
      expect(r?.url, 'https://api.github.com/repos/o/r/releases/assets/v1.0.12-exe');
    });

    test('нет сборки для протокола — null', () {
      expect(DownloaderModule.pick([release('v2.0.1')], 1), isNull);
      expect(DownloaderModule.pick(const [], 1), isNull);
    });

    test('контрольная сумма из файла .sha256', () {
      final r = DownloaderModule.pick([release('v1.0.3', shaFile: true)], 1);
      expect(r?.sha256, isNull);
      expect(r?.shaUrl, 'https://api.github.com/repos/o/r/releases/assets/v1.0.3-sha');
      expect(DownloaderModule.parseSha('${'C' * 64}  cave-downloader-windows-x64.exe'), 'c' * 64);
      expect(DownloaderModule.parseSha('not a hash'), isNull);
    });

    test('ключ доступа идёт только в заголовке Authorization и только если он задан', () {
      expect(DownloaderModule.apiHeaders('', file: true).containsKey('Authorization'), isFalse);
      final h = DownloaderModule.apiHeaders('ghp_secret');
      expect(h['Authorization'], 'Bearer ghp_secret');
      expect(h['Accept'], 'application/vnd.github+json');
      expect(DownloaderModule.apiHeaders('ghp_secret', file: true)['Accept'], 'application/octet-stream');
      expect(h.entries.where((e) => e.key != 'Authorization').any((e) => e.value.contains('ghp_secret')), isFalse);
    });

    test('своя сборка из CAVE_DOWNLOADER_EXE не скачивается', () async {
      final dir = await Directory.systemTemp.createTemp('cave-module-');
      addTearDown(() => dir.delete(recursive: true));
      final exe = File('${dir.path}/my.exe')..writeAsStringSync('x');
      final m = DownloaderModule(dir, override: exe.path);
      expect(m.exe.path, exe.path);
      expect(m.installed, isTrue);
      await m.ensure((_) {});
      await expectLater(DownloaderModule(dir, override: '${dir.path}/missing.exe').ensure((_) {}), throwsException);
    });
  });

  group('сессия с модулем', () {
    test('задание, журнал, прогресс, запросы и итог', () async {
      final logs = <String>[];
      final progress = <Map>[];
      final installing = <bool>[];
      final calls = <String>[];
      final res = await DownloaderSession.run(
        exe: 'cave-downloader.exe',
        job: {'kind': 'download', 'input': 'Кино - Группа крови'},
        onLog: logs.add,
        onProgress: progress.add,
        onInstalling: installing.add,
        onCall: (m, a) async {
          calls.add(m);
          if (m == 'existing') return null;
          if (m == 'upload') return 'track-1';
          throw StateError('нельзя');
        },
        launch: fakeModule((s, lines, job) async {
          expect(job['input'], 'Кино - Группа крови');
          send(s, {'t': 'installing', 'on': true});
          send(s, {'t': 'log', 'text': 'Ищу на YouTube…'});
          send(s, {'t': 'installing', 'on': false});
          send(s, {'t': 'call', 'id': 1, 'm': 'existing', 'artist': 'Кино', 'title': 'Группа крови'});
          expect(await next(lines), {'t': 'reply', 'id': 1, 'ok': true, 'value': null});
          send(s, {'t': 'call', 'id': 2, 'm': 'upload', 'file': 'x.mp3'});
          expect((await next(lines))['value'], 'track-1');
          send(s, {'t': 'call', 'id': 3, 'm': 'teleport'});
          final err = await next(lines);
          expect(err['ok'], isFalse);
          expect(err['error'], contains('нельзя'));
          send(s, {'t': 'progress', 'title': 'Кино - Группа крови', 'total': 1, 'done': 1, 'failed': 0, 'skipped': 0});
          send(s, {'t': 'end', 'ok': true});
        }),
      );
      expect(res.ok, isTrue);
      expect(res.error, isNull);
      expect(logs, ['Ищу на YouTube…']);
      expect(installing, [true, false]);
      expect(calls, ['existing', 'upload', 'teleport']);
      expect(progress.single['done'], 1);
    });

    test('ошибка задания доходит до плеера', () async {
      final res = await DownloaderSession.run(
        exe: 'x',
        job: {'kind': 'download'},
        onLog: (_) {},
        launch: fakeModule((s, lines, job) async => send(s, {'t': 'end', 'ok': false, 'error': 'нет сети'})),
      );
      expect(res.ok, isFalse);
      expect(res.error, 'нет сети');
    });

    test('чужой токен игнорируется, модуль без подключения — ошибка с кодом', () async {
      await expectLater(
        DownloaderSession.run(
          exe: 'x',
          job: {'kind': 'tools-version'},
          onLog: (_) {},
          launch: fakeModule((s, lines, job) async => fail('задание не должно уйти чужому'), token: 'чужой', exitCode: 3),
        ),
        throwsA(predicate((e) => '$e'.contains('кодом 3'))),
      );
    });

    test('другая версия протокола', () async {
      await expectLater(
        DownloaderSession.run(
          exe: 'x',
          job: {'kind': 'tools-version'},
          onLog: (_) {},
          launch: fakeModule((s, lines, job) async {}, protocol: kDownloaderProtocol + 1),
        ),
        throwsA(isA<ModuleProtocolMismatch>().having((e) => '$e', 'текст', contains('Обновите Cavey'))),
      );
    });

    test('модуль оборвал связь без итога', () async {
      final res = await DownloaderSession.run(
        exe: 'x',
        job: {'kind': 'download'},
        onLog: (_) {},
        launch: fakeModule((s, lines, job) async => send(s, {'t': 'log', 'text': 'упал'}), exitCode: 255),
      );
      expect(res.ok, isFalse);
      expect(res.error, contains('оборвал связь'));
    });

    test('модуль не запустился', () async {
      await expectLater(
        DownloaderSession.run(exe: 'x', job: const {}, onLog: (_) {}, launch: (e, a, o) async => throw const FileSystemException('нет файла')),
        throwsA(predicate((e) => '$e'.contains('не запустился'))),
      );
    });
  });
}
