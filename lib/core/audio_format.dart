// Форматы звука: определение по содержимому, выбор формата для «Скачать на устройство» и перекодирование через ffmpeg.

import 'dart:io';

import 'dl/tools.dart';
import 'log.dart';
import 'store.dart' show Settings;

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


/// Форматы, в которые можно скачать трек на устройство. 'original' — как лежит в библиотеке, без перекодирования
const exportFormats = ['original', 'mp3', 'flac', 'wav'];

String exportFormatLabel(String f) => switch (f) {
      'mp3' => 'MP3',
      'flac' => 'FLAC',
      'wav' => 'WAV',
      _ => 'Как есть (без перекодирования)',
    };

/// Формат по умолчанию для локальной загрузки
String exportFormatOf(Settings s) {
  final f = s.viewOf('export.format', 'original');
  return exportFormats.contains(f) ? f : 'original';
}

/// Спрашивать ли формат при каждой локальной загрузке (по умолчанию — да)
bool exportAskOf(Settings s) => s.viewOf('export.ask', '1') != '0';

/// Аргументы ffmpeg: звук, обложка (если контейнер её держит) и теги переносятся в новый файл
List<String> convertArgs(String src, String dst, String fmt, {bool cover = true}) => [
      '-y',
      '-v',
      'error',
      '-i',
      src,
      '-map',
      '0:a:0',
      if (cover && fmt != 'wav') ...['-map', '0:v:0?', '-c:v', 'copy', '-disposition:v', 'attached_pic'] else '-vn',
      '-map_metadata',
      '0',
      ...switch (fmt) {
        'mp3' => ['-c:a', 'libmp3lame', '-b:a', '320k', '-id3v2_version', '3'],
        'flac' => ['-c:a', 'flac'],
        _ => ['-c:a', 'pcm_s16le'],
      },
      dst,
    ];

/// Перекодирует [src] в [dst] (расширение [dst] должно совпадать с [fmt]). Если с обложкой не вышло — пробует без неё
Future<void> convertAudio(Tools tools, File src, File dst, String fmt) async {
  if (!await tools.ffmpeg.exists()) await tools.ensure((l) => AppLog.info(l));
  for (final cover in [true, false]) {
    try {
      if (await dst.exists()) await dst.delete();
    } catch (_) {}
    final out = await Tools.run(tools.ffmpeg.path, convertArgs(src.path, dst.path, fmt, cover: cover));
    if (await dst.exists() && await dst.length() > 0) return;
    if (!cover) throw StateError('ffmpeg не смог перекодировать файл${out.isEmpty ? '' : ': ${out.last}'}');
  }
}
