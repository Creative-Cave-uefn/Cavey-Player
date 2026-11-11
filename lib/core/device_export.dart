// «Скачать на устройство»: сохраняет треки, альбомы и плейлисты обычными файлами в выбранную папку компьютера.
// Файл берётся из кэша (офлайн-копии), если он там есть, иначе скачивается с Диска в исходном виде, без перекодирования.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'audio_cache.dart';
import 'drive.dart';
import 'library.dart';
import 'log.dart';
import 'models.dart';


/// Открывает папку в Проводнике
Future<void> openFolder(String dir) async {
  try {
    await Process.start('explorer.exe', [dir], mode: ProcessStartMode.detached);
  } catch (e) {
    AppLog.warn('Открыть папку', e);
  }
}

/// Расширение по началу файла: у копий в кэше своего расширения нет
String sniffAudioExt(List<int> head) {
  bool starts(List<int> p, [int at = 0]) {
    if (head.length < at + p.length) return false;
    for (var i = 0; i < p.length; i++) {
      if (head[at + i] != p[i]) return false;
    }
    return true;
  }

  if (starts([0x49, 0x44, 0x33])) return 'mp3'; // ID3
  if (starts([0x66, 0x4C, 0x61, 0x43])) return 'flac'; // fLaC
  if (starts([0x4F, 0x67, 0x67, 0x53])) return 'ogg'; // OggS
  if (starts([0x52, 0x49, 0x46, 0x46])) return 'wav'; // RIFF
  if (starts([0x66, 0x74, 0x79, 0x70], 4)) return 'm4a'; // ftyp
  if (starts([0x30, 0x26, 0xB2, 0x75])) return 'wma';
  if (head.length > 1 && head[0] == 0xFF && (head[1] & 0xE0) == 0xE0) return 'mp3'; // кадр MPEG без ID3
  return 'mp3';
}

String extFromName(String name, [String mime = '']) {
  final dot = name.lastIndexOf('.');
  if (dot > 0 && dot >= name.length - 6) {
    final e = name.substring(dot + 1).toLowerCase();
    if (RegExp(r'^[a-z0-9]{2,5}$').hasMatch(e)) return e;
  }
  return switch (mime) {
    'audio/mpeg' => 'mp3',
    'audio/flac' || 'audio/x-flac' => 'flac',
    'audio/mp4' || 'audio/x-m4a' || 'audio/aac' => 'm4a',
    'audio/ogg' => 'ogg',
    'audio/wav' || 'audio/x-wav' => 'wav',
    _ => '',
  };
}

const _reserved = {
  'con', 'prn', 'aux', 'nul', 'com1', 'com2', 'com3', 'com4', 'com5', 'com6', 'com7', 'com8', 'com9', //
  'lpt1', 'lpt2', 'lpt3', 'lpt4', 'lpt5', 'lpt6', 'lpt7', 'lpt8', 'lpt9',
};

/// Имя файла или папки, допустимое в Windows: без запрещённых знаков, точек и пробелов на конце, не длиннее [max]
String safeFileName(String raw, {int max = 140}) {
  var s = raw.replaceAll(RegExp(r'[<>:"/\\|?*\u0000-\u001F]'), '_').replaceAll(RegExp(r'\s+'), ' ').trim();
  s = s.replaceAll(RegExp(r'[. ]+$'), '');
  if (s.length > max) s = s.substring(0, max).trimRight();
  if (s.isEmpty) s = '_';
  if (_reserved.contains(s.split('.').first.toLowerCase())) s = '_$s';
  return s;
}

/// Имена файлов для набора треков. Без нумерации: «Исполнитель - Название.ext»; с нумерацией (альбом, плейлист):
/// «01. Название.ext» для альбома и «01. Исполнитель - Название.ext» для плейлиста ([withArtist]).
/// Совпавшие имена получают « (2)», « (3)»
List<String> exportFileNames(List<Track> tracks, List<String> exts, {bool numbered = false, bool withArtist = true}) {
  final width = tracks.length >= 100 ? 3 : 2;
  final used = <String>{};
  final out = <String>[];
  for (var i = 0; i < tracks.length; i++) {
    final t = tracks[i];
    final base = withArtist && t.artist.isNotEmpty ? '${t.displayArtist} - ${t.title}' : t.title;
    String prefix = '';
    if (numbered) {
      // Номер — место в списке, как в плеере и в самом альбоме, а не тег файла: в тегах у докачанных альбомов бывают пропуски (1, 3, 4 … 63, 72)
      prefix = '${(i + 1).toString().padLeft(width, '0')}. ';
    }
    final ext = exts[i];
    final stem = safeFileName('$prefix$base', max: 150);
    var name = ext.isEmpty ? stem : '$stem.$ext';
    var n = 2;
    while (!used.add(name.toLowerCase())) {
      name = ext.isEmpty ? '$stem ($n)' : '$stem ($n).$ext';
      n++;
    }
    out.add(name);
  }
  return out;
}

class ExportJob extends ChangeNotifier {
  final String title;
  final String dir;
  final int total;
  int done = 0, failed = 0;
  String current = '';
  bool finished = false, cancelled = false;
  final List<String> files = [];

  ExportJob(this.title, this.dir, this.total);

  void changed() => notifyListeners();
}

class DeviceExport extends ChangeNotifier {
  final LibraryController lib;
  final DriveApi drive;
  final AudioCache cache;
  DeviceExport(this.lib, this.drive, this.cache);

  final List<ExportJob> jobs = [];

  ExportJob? get active => jobs.where((j) => !j.finished).firstOrNull;

  void dismiss(ExportJob j) {
    if (!j.finished) j.cancelled = true;
    jobs.remove(j);
    notifyListeners();
  }

  /// Запускает выгрузку. [folderName] — подпапка (альбом, плейлист); без неё файлы кладутся прямо в [baseDir]
  ExportJob start(List<Track> tracks, String baseDir, {String? folderName, bool numbered = false, bool withArtist = true, String? title}) {
    final dir = folderName == null ? baseDir : '$baseDir${Platform.pathSeparator}${safeFileName(folderName)}';
    final job = ExportJob(title ?? folderName ?? (tracks.length == 1 ? tracks.first.title : '${tracks.length} треков'), dir, tracks.length);
    jobs.add(job);
    notifyListeners();
    unawaited(_run(job, tracks, numbered, withArtist));
    return job;
  }

  Future<String> _extFor(Track t) async {
    if (cache.has(t.id)) {
      try {
        final raf = await cache.fileFor(t.id).open();
        try {
          return sniffAudioExt(await raf.read(12));
        } finally {
          await raf.close();
        }
      } catch (_) {}
    }
    try {
      final email = await lib.accessFor(t.source);
      final meta = await drive.getFile(email, t.id, fields: 'name,mimeType').timeout(const Duration(seconds: 20));
      final e = extFromName('${meta['name'] ?? ''}', '${meta['mimeType'] ?? ''}');
      if (e.isNotEmpty) return e;
    } catch (e) {
      AppLog.warn('Скачать на устройство: не узнал расширение «${t.title}»', e);
    }
    return 'mp3';
  }

  Future<void> _run(ExportJob job, List<Track> tracks, bool numbered, bool withArtist) async {
    try {
      await Directory(job.dir).create(recursive: true);
      final exts = await Future.wait([for (final t in tracks) _extFor(t)]);
      final names = exportFileNames(tracks, exts, numbered: numbered, withArtist: withArtist);
      // Не затираем то, что уже лежит в папке
      for (var i = 0; i < names.length; i++) {
        var name = names[i];
        var n = 2;
        while (await File('${job.dir}${Platform.pathSeparator}$name').exists()) {
          final dot = name.lastIndexOf('.');
          final stem = dot > 0 ? names[i].substring(0, names[i].lastIndexOf('.')) : names[i];
          final ext = dot > 0 ? names[i].substring(names[i].lastIndexOf('.')) : '';
          name = '$stem ($n)$ext';
          n++;
        }
        names[i] = name;
      }
      var cursor = 0;
      Future<void> worker() async {
        while (!job.cancelled) {
          final i = cursor++;
          if (i >= tracks.length) return;
          final t = tracks[i];
          final target = File('${job.dir}${Platform.pathSeparator}${names[i]}');
          job.current = t.title;
          job.changed();
          try {
            await _copyOne(t, target);
            job.files.add(target.path);
            job.done++;
          } catch (e, st) {
            AppLog.error('Скачать на устройство: «${t.title}»', e, st);
            job.failed++;
            try {
              if (await target.exists()) await target.delete();
            } catch (_) {}
          }
          job.changed();
        }
      }

      await Future.wait([for (var k = 0; k < 3 && k < tracks.length; k++) worker()]);
    } catch (e, st) {
      AppLog.error('Скачать на устройство', e, st);
      job.failed = job.total - job.done;
    } finally {
      job.finished = true;
      job.current = '';
      job.changed();
      notifyListeners();
      if (job.failed > 0) {
        lib.messages.add(job.done == 0 ? 'Не удалось сохранить файлы на устройство' : 'Сохранено ${job.done} из ${job.total}, не удалось: ${job.failed}');
      } else if (!job.cancelled) {
        lib.messages.add('Сохранено на устройство: ${job.title}');
      }
    }
  }

  Future<void> _copyOne(Track t, File target) async {
    if (cache.has(t.id)) {
      final src = cache.fileFor(t.id);
      if (await src.exists() && await src.length() > 0) {
        await src.copy(target.path);
        return;
      }
    }
    final email = await lib.accessFor(t.source);
    await drive.downloadToFile(email, t.id, target, expectedModified: t.modified);
    if (!await target.exists() || await target.length() == 0) throw StateError('Пустой файл');
  }

  /// Проводник с выделенным файлом сохранённого офлайн трека
  Future<bool> reveal(Track t) async {
    if (!cache.has(t.id)) return false;
    final f = cache.fileFor(t.id);
    if (!await f.exists()) return false;
    try {
      await Process.start('explorer.exe', ['/select,${f.path}'], mode: ProcessStartMode.detached);
      return true;
    } catch (e) {
      AppLog.warn('Показать на устройстве', e);
      return false;
    }
  }
}
