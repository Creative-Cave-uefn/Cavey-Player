import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:cave_mix/cave_mix.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'log.dart';

// Анализ треков для DJ-режима (ТЗ, раздел 3): доли и даунбиты нейросетью Beat This!, сетка темпа,
// тональность, громкость, энергия по тактам, фразы и точки микса. Считает нативный движок Cavey Mix
// в отдельном изоляте; профиль v2 кладётся рядом с профилями умного перехода: beat_<id>.json.
//
// Что нужно на диске (скачивается один раз в папку инструментов, с проверкой SHA-256):
// • ONNX Runtime 1.20.1 — onnxruntime.dll из официального пакета на PyPI;
// • mel_spectrogram.onnx и beat_this_small.onnx — из репозитория beat-this-rs (MIT) на закреплённом коммите.
// Малая модель Beat This! сверена с эталонной Python-реализацией JKU (F-мера 0,996 по долям и даунбитам).

class _Asset {
  const _Asset(this.name, this.url, this.sha256);
  final String name;
  final String url;
  final String sha256;
}

const _beatThisCommit = '1ae768e78f1ad83b0ed3886241dc29ffde853c40';
const _melAsset = _Asset(
  'mel_spectrogram.onnx',
  'https://raw.githubusercontent.com/danigb/beat-this-rs/$_beatThisCommit/models/mel_spectrogram.onnx',
  'fdd59e65c515331308e4c8841edf99972deca646bdf6197744c2a5b7755e3de9',
);
const _smallAsset = _Asset(
  'beat_this_small.onnx',
  'https://raw.githubusercontent.com/danigb/beat-this-rs/$_beatThisCommit/models/beat_this_small.onnx',
  'a5f8d39d989f31859454ba27afe61c5317ca95e4d9373e6853e5361b8937172f',
);
// Колесо onnxruntime 1.20.1 для Windows x64 (внутри onnxruntime/capi/onnxruntime.dll)
const _ortWheel = _Asset(
  'onnxruntime-1.20.1-win_amd64.whl',
  'https://files.pythonhosted.org/packages/dd/80/76979e0b744307d488c79e41051117634b956612cc731f1028eb17ee7294/onnxruntime-1.20.1-cp312-cp312-win_amd64.whl',
  '19c2d843eb074f385e8bbb753a40df780511061a63f9def1b216bf53860223fb',
);

// Разметка вокала: Spleeter 2stems (Deezer, MIT) в выгрузке sherpa-onnx (Apache-2.0), fp16. В архиве две модели,
// берём только vocals.fp16.onnx (19,7 МБ). Без неё анализ работает, только "vocals" в профиле — null
const _vocalAsset = _Asset(
  'sherpa-onnx-spleeter-2stems-fp16.tar.bz2',
  'https://github.com/k2-fsa/sherpa-onnx/releases/download/source-separation-models/sherpa-onnx-spleeter-2stems-fp16.tar.bz2',
  'd54561979bd2e08a51e7dbd99ac36bb47564e089eefd403636dbca93e811bba2',
);

/// Файлы анализатора в папке инструментов
class BeatAssets {
  BeatAssets(this.dir);
  final Directory dir;

  String _p(String name) => '${dir.path}${Platform.pathSeparator}$name';
  File get ortLib => File(_p(Platform.isWindows ? 'onnxruntime.dll' : 'libonnxruntime.so'));
  File get melModel => File(_p(_melAsset.name));
  File get beatModel => File(_p(_smallAsset.name));
  File get vocalModel => File(_p('spleeter_vocals.fp16.onnx'));

  /// Модель вокала: скачать архив, достать из него vocals.fp16.onnx (распаковка — в отдельном изоляте,
  /// bzip2 на 35 МБ занимает секунды). Не вышло — анализ идёт без вокала
  Future<bool> ensureVocals(void Function(String) log) async {
    if (vocalModel.existsSync()) return true;
    try {
      await dir.create(recursive: true);
      log('Скачиваю модель вокала (Spleeter)…');
      final tarball = File(_p(_vocalAsset.name));
      await _download(_vocalAsset, tarball);
      final src = tarball.path, dest = vocalModel.path;
      try {
        await Isolate.run(() {
          final bytes = BZip2Decoder().decodeBytes(File(src).readAsBytesSync());
          final tar = TarDecoder().decodeBytes(bytes);
          for (final f in tar.files) {
            if (f.isFile && f.name.endsWith('/vocals.fp16.onnx')) {
              File('$dest.part').writeAsBytesSync(f.content as List<int>);
              File('$dest.part').renameSync(dest);
              return;
            }
          }
          throw StateError('в архиве нет vocals.fp16.onnx');
        });
      } finally {
        if (tarball.existsSync()) await tarball.delete();
      }
      return vocalModel.existsSync();
    } catch (e) {
      AppLog.warn('Модель вокала не скачалась, анализ будет без вокала', e);
      return false;
    }
  }

  bool get ready => ortLib.existsSync() && melModel.existsSync() && beatModel.existsSync();

  /// Скачать недостающее. Пока скачиваем ONNX Runtime только для Windows: на других системах
  /// библиотеку можно положить в папку вручную (libonnxruntime.so).
  Future<void> ensure(void Function(String) log) async {
    if (ready) return;
    await dir.create(recursive: true);
    for (final a in [_melAsset, _smallAsset]) {
      if (File(_p(a.name)).existsSync()) continue;
      log('Скачиваю модель анализа ${a.name}…');
      await _download(a, File(_p(a.name)));
    }
    if (!ortLib.existsSync()) {
      if (!Platform.isWindows) throw StateError('нет ${ortLib.path}: положите сюда ONNX Runtime ≥ 1.20');
      log('Скачиваю ONNX Runtime для анализа треков…');
      final wheel = File(_p(_ortWheel.name));
      await _download(_ortWheel, wheel);
      try {
        final input = InputFileStream(wheel.path);
        try {
          final archive = ZipDecoder().decodeBuffer(input);
          for (final item in archive.files) {
            final name = item.name.split('/').last.toLowerCase();
            if (!item.isFile || !item.name.startsWith('onnxruntime/capi/')) continue;
            if (name != 'onnxruntime.dll' && name != 'onnxruntime_providers_shared.dll') continue;
            final out = OutputFileStream(_p(name));
            item.writeContent(out);
            await out.close();
          }
        } finally {
          await input.close();
        }
      } finally {
        if (wheel.existsSync()) await wheel.delete();
      }
      if (!ortLib.existsSync()) throw StateError('в пакете ONNX Runtime нет onnxruntime.dll');
    }
  }

  static Future<void> _download(_Asset a, File dest) async {
    final part = File('${dest.path}.part');
    final client = http.Client();
    try {
      final req = http.Request('GET', Uri.parse(a.url))..headers['User-Agent'] = 'Cavey-Player';
      final resp = await client.send(req).timeout(const Duration(seconds: 40));
      if (resp.statusCode != 200) throw HttpException('${a.name}: HTTP ${resp.statusCode}');
      final sink = part.openWrite();
      try {
        await for (final chunk in resp.stream.timeout(const Duration(seconds: 60))) {
          sink.add(chunk);
        }
      } finally {
        await sink.close();
      }
      final digest = sha256.convert(await part.readAsBytes()).toString();
      if (digest != a.sha256) throw StateError('${a.name}: контрольная сумма не совпала');
      await part.rename(dest.path);
    } finally {
      client.close();
      if (part.existsSync()) await part.delete();
    }
  }
}

/// Нативный анализатор в отдельном изоляте: модели грузятся один раз, треки идут по очереди
class _Worker {
  _Worker._(this._isolate, this._inbox, this.vocals);
  final Isolate _isolate;
  final SendPort _inbox;

  /// Разметка вокала работает
  final bool vocals;

  static Future<_Worker> start(BeatAssets a) async {
    final hello = ReceivePort();
    final iso = await Isolate.spawn(
        _main, [hello.sendPort, a.ortLib.path, a.melModel.path, a.beatModel.path, a.vocalModel.existsSync() ? a.vocalModel.path : null]);
    final first = await hello.first as List<Object?>;
    hello.close();
    final err = first[1] as String?;
    if (err != null) {
      iso.kill(priority: Isolate.immediate);
      throw StateError(err);
    }
    final vErr = first.length > 3 ? first[3] as String? ?? '' : '';
    if (vErr.isNotEmpty) AppLog.warn('Модель вокала не загрузилась, анализ без вокала', vErr);
    return _Worker._(iso, first[0] as SendPort, first.length > 2 && first[2] == true);
  }

  static void _main(List<Object?> args) {
    final reply = args[0] as SendPort;
    final inbox = ReceivePort();
    TrackAnalyzer? an;
    String? err;
    try {
      an = TrackAnalyzer.create(ortLib: args[1] as String, melModel: args[2] as String, beatModel: args[3] as String);
    } catch (e) {
      err = '$e';
    }
    final vocals = args[4] as String?;
    var vocalErr = '';
    if (an != null && vocals != null) {
      try {
        an.setVocalModel(vocals);
      } catch (e) {
        vocalErr = '$e';
      }
    }
    reply.send([inbox.sendPort, err, vocals != null && vocalErr.isEmpty, vocalErr]);
    inbox.listen((msg) {
      final m = msg as List<Object?>;
      final to = m[0] as SendPort?;
      if (to == null) {
        an?.dispose();
        inbox.close();
        return;
      }
      try {
        to.send(['ok', an!.analyzeFile(m[1] as String, ffmpeg: m[2] as String)]);
      } catch (e) {
        to.send(['err', '$e']);
      }
    });
  }

  Future<String> analyze(String path, String ffmpeg) async {
    final rp = ReceivePort();
    _inbox.send([rp.sendPort, path, ffmpeg]);
    final r = await rp.first as List<Object?>;
    rp.close();
    if (r[0] != 'ok') throw StateError(r[1] as String);
    return r[1] as String;
  }

  void stop() {
    _inbox.send([null]);
    Timer(const Duration(seconds: 5), () => _isolate.kill());
  }
}

/// Профили v2: анализ, хранение, чтение
class BeatAnalysis {
  // версия разбора, которой помечается сохранённый профиль (своя, не из движка): 3 — разметка вокала,
  // 4 — ровные участки в начале и конце у треков с плавающим темпом, 5 — период по атакам, сильная доля по
  // вероятности даунбита, 6 — уверенность в тональности без оглядки на совместимые тональности
  static const _algo = 6;

  BeatAnalysis(this.mixDir, Directory toolsDir) : assets = BeatAssets(Directory('${toolsDir.path}${Platform.pathSeparator}beat'));

  final Directory mixDir;
  final BeatAssets assets;
  final Map<String, Map<String, dynamic>> _mem = {};
  _Worker? _worker;
  Future<_Worker>? _starting;

  /// Анализ не запустился (нет сети, не загрузилась библиотека) — до перезапуска программы не пытаемся
  bool failed = false;

  File _file(String id) => File('${mixDir.path}${Platform.pathSeparator}beat_$id.json');

  /// Профиль v2, если уже посчитан
  Map<String, dynamic>? profile(String id) => _load(id, keep: true);

  /// Посчитан ли свежий профиль (не держит его в памяти — для проверки многих треков разом)
  bool isFresh(String id) => _load(id, keep: false) != null;

  Map<String, dynamic>? _load(String id, {required bool keep}) {
    final m = _mem[id];
    if (m != null) return m;
    final f = _file(id);
    if (!f.existsSync()) return null;
    try {
      final p = jsonDecode(f.readAsStringSync());
      // algo — версия алгоритма сетки долей; профили старее пересчитываются (в них могла быть сетка на слабых долях)
      // профиль без вокала, хотя модель вокала уже работает, — тоже пересчитать
      final noVocals = p is Map<String, dynamic> && p['vocals'] == null && (_worker?.vocals ?? false);
      if (p is Map<String, dynamic> && p['v'] == 2 && (p['algo'] is int ? p['algo'] as int : 1) >= _algo && !noVocals) {
        if (keep) _mem[id] = p;
        return p;
      }
    } catch (_) {}
    return null;
  }

  bool has(String id) => profile(id) != null;

  /// Темп трека по анализу; null — не посчитан или плавающий
  double? bpm(String id) {
    final p = profile(id);
    if (p == null || p['variableTempo'] == true) return null;
    final b = p['bpm'];
    return b is num && b > 0 ? b.toDouble() : null;
  }

  Future<_Worker> _ensureWorker() {
    final w = _worker;
    if (w != null) return Future.value(w);
    return _starting ??= () async {
      try {
        await assets.ensure((l) => AppLog.info(l));
        await assets.ensureVocals((l) => AppLog.info(l));
        final w = await _Worker.start(assets);
        _worker = w;
        AppLog.info('Анализ треков (Beat This!) готов${w.vocals ? ', с разметкой вокала' : ', без разметки вокала'}');
        return w;
      } finally {
        _starting = null;
      }
    }();
  }

  /// Посчитать профиль трека; false — не получилось (причина в журнале)
  Future<bool> analyze(String id, File src, String ffmpeg) async {
    if (failed) return false;
    _Worker w;
    try {
      w = await _ensureWorker();
    } catch (e) {
      failed = true;
      AppLog.warn('Анализ треков недоступен', e);
      return false;
    }
    try {
      final sw = Stopwatch()..start();
      final json = await w.analyze(src.path, ffmpeg);
      final p = jsonDecode(json) as Map<String, dynamic>;
      p['analyzedAt'] = DateTime.now().toUtc().toIso8601String();
      p['algo'] = _algo;
      await mixDir.create(recursive: true);
      await _file(id).writeAsString(jsonEncode(p));
      _mem[id] = p;
      final v = p['vocals'];
      final vocalBars = v is List ? v.where((x) => x is num && x > 0.15).length : -1;
      AppLog.info('Анализ трека $id: ${p['bpm']} BPM, ${p['beatsPerBar']}/4, тональность ${p['key']}, '
          '${p['lufs']} LUFS, ${vocalBars < 0 ? 'вокал не размечен' : 'голос в $vocalBars тактах из ${(v as List).length}'}, '
          '${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)} с');
      return true;
    } catch (e) {
      AppLog.warn('Анализ трека $id не удался', e);
      return false;
    }
  }

  void dispose() {
    _worker?.stop();
    _worker = null;
  }
}
