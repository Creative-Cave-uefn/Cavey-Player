// Поиск лучшей версии трека на YouTube, скачивание через yt-dlp и запись тегов
// через ffmpeg. Перенесено из music_downloaderV2.py.

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'text.dart';
import 'tools.dart';

const searchResults = 8; // сколько вариантов с YouTube сравнивать
const maxDownloadTries = 3; // сколько лучших вариантов пробовать
const fragments = 4; // потоков на скачивание одного файла

class Candidate {
  final String id;
  final String title;
  final String channel;
  final double? duration;
  Candidate(this.id, this.title, this.channel, this.duration);
}

/// Скачанный файл: путь, исполнитель, название, номер в плейлисте
class Entry {
  final String path;
  final String artist;
  final String title;
  final String index;
  Entry(this.path, this.artist, this.title, this.index);
}

const _badWords = [
  'live', 'remix', 'cover', 'slowed', 'reverb', 'sped up', 'speed up', 'speedup',
  'nightcore', 'lyrics', 'lyric', 'karaoke', 'instrumental', '8d', '16d',
  'official video', 'music video', 'clip', 'клип', 'кавер', 'ремикс', 'концерт',
  'acoustic', 'mashup', 'bass boosted', 'bassboosted', 'tiktok', 'pitched',
];

final _progressRe = RegExp(r'^\[download\]\s+\d+(?:\.\d+)?%');

class YouTube {
  final Tools tools;
  final Directory temp;
  final void Function(String) log;
  YouTube(this.tools, this.temp, this.log);

  /// Строки yt-dlp в журнал, кроме промежуточных процентов
  void _stream(String line) {
    if (_progressRe.hasMatch(line) && !line.contains('100%')) return;
    log(line);
  }

  Future<List<Candidate>> search(String query, [int n = searchResults]) async {
    try {
      final out = await Tools.run(tools.ytdlp.path, [...tools.jsArgs, '-J', '--flat-playlist', '--no-warnings', 'ytsearch$n:$query']);
      final json = out.firstWhere((l) => l.startsWith('{'), orElse: () => '');
      if (json.isEmpty) return [];
      final data = jsonDecode(json) as Map;
      return [
        for (final e in (data['entries'] as List? ?? const []))
          if (e is Map && e['id'] != null)
            Candidate('${e['id']}', '${e['title'] ?? ''}', '${e['channel'] ?? e['uploader'] ?? ''}', (e['duration'] as num?)?.toDouble())
      ];
    } catch (e) {
      log('Поиск на YouTube не удался: $e');
      return [];
    }
  }

  static double score(Candidate c, TrackMeta meta) {
    var s = 0.0;
    final want = meta.duration, got = c.duration;
    if (want != null && got != null) {
      final diff = (got - want).abs();
      final limit = want * 0.06 > 10 ? want * 0.06 : 10;
      if (diff <= 2) {
        s += 50;
      } else if (diff <= 5) {
        s += 35;
      } else if (diff <= limit) {
        s += 15;
      } else {
        s -= 100; // другая длина — почти наверняка не оригинал
      }
    }
    final channel = c.channel.toLowerCase();
    if (channel.endsWith('- topic')) {
      s += 60;
    } else if (meta.artist.isNotEmpty && channel.contains(meta.artist.toLowerCase())) {
      s += 10;
    }
    final title = c.title.toLowerCase();
    final query = '${meta.title} ${meta.artist}'.toLowerCase();
    for (final w in _badWords.toSet()) {
      if (hasWord(title, w) && !hasWord(query, w)) s -= 25;
    }
    if (title.contains('official audio')) s += 5;
    final wantTitle = normTitle(meta.title);
    if (wantTitle.isNotEmpty && !normTitle(c.title).contains(wantTitle)) s -= 40;
    return s;
  }

  Future<List<Candidate>> ranked(TrackMeta meta) async {
    final query = '${meta.artist} ${meta.title}'.trim();
    var cands = await search(query);
    if (cands.isEmpty) cands = await search('$query audio');
    int byScore(Candidate a, Candidate b) => score(b, meta).compareTo(score(a, meta));
    cands.sort(byScore);
    // Нет уверенного варианта — добавляем поиск по официальным «Topic»-каналам
    if (cands.isEmpty || score(cands.first, meta) < 40) {
      final seen = {for (final c in cands) c.id};
      for (final c in await search('$query topic')) {
        if (seen.add(c.id)) cands.add(c);
      }
      cands.sort(byScore);
    }
    return cands;
  }

  /// Скачивает аудио в mp3. Возвращает скачанные файлы.
  Future<List<Entry>> download(String template, String target, {bool playlist = false, bool embedThumb = true}) async {
    final info = File('${temp.path}${Platform.pathSeparator}info-${DateTime.now().microsecondsSinceEpoch}.txt');
    await info.writeAsString('');
    final args = [
      ...tools.jsArgs,
      '--ffmpeg-location', tools.dir.path,
      playlist ? '--yes-playlist' : '--no-playlist',
      '--concurrent-fragments', '$fragments',
      '--newline',
      '-x', '--audio-format', 'mp3', '--audio-quality', '0',
      '--embed-metadata',
      '--replace-in-metadata', 'uploader', r' - Topic$', '',
      '--windows-filenames',
      '--print-to-file', 'after_move:%(filepath)s\t%(artists.0,uploader)s\t%(track,title)s\t%(playlist_index|)s', info.path,
      if (embedThumb) ...['--embed-thumbnail', '--convert-thumbnails', 'jpg'],
      if (playlist) '--ignore-errors',
      '-o', template,
      target,
    ];
    await Tools.run(tools.ytdlp.path, args, onLine: _stream);
    final entries = <Entry>[];
    for (final line in await info.readAsLines()) {
      final p = line.split('\t');
      if (p.length >= 3 && p[0].isNotEmpty && File(p[0]).existsSync()) {
        entries.add(Entry(p[0], p[1], p[2], p.length > 3 ? p[3] : ''));
      }
    }
    try {
      await info.delete();
    } catch (_) {}
    return entries;
  }

  /// Скачивает обложку во временную папку
  Future<File?> cover(String? url) async {
    if (url == null || url.isEmpty) return null;
    try {
      final res = await http.get(Uri.parse(url), headers: {'User-Agent': 'Mozilla/5.0'}).timeout(const Duration(seconds: 20));
      if (res.statusCode != 200 || res.bodyBytes.length < 1000) return null;
      final f = File('${temp.path}${Platform.pathSeparator}cover-${url.hashCode.toUnsigned(32)}.img');
      await f.writeAsBytes(res.bodyBytes);
      return f;
    } catch (e) {
      log('Не удалось скачать обложку: $e');
      return null;
    }
  }

  /// Записывает теги (и обложку) в mp3 через ffmpeg
  Future<bool> tag(String path, TrackMeta meta, {File? coverFile}) async {
    final tmp = '$path.tagged.mp3';
    final args = ['-y', '-loglevel', 'error', '-i', path];
    if (coverFile != null) {
      final head = await coverFile.openRead(0, 2).first;
      final jpeg = head.length >= 2 && head[0] == 0xFF && head[1] == 0xD8;
      args.addAll(['-i', coverFile.path, '-map', '0:a', '-map', '1:v', '-c:a', 'copy']);
      args.addAll(jpeg ? ['-c:v', 'copy'] : ['-c:v', 'mjpeg', '-q:v', '2', '-vf', 'format=yuvj420p']);
      args.addAll(['-metadata:s:v', 'title=Album cover', '-metadata:s:v', 'comment=Cover (front)']);
    } else {
      args.addAll(['-map', '0', '-c', 'copy']); // сохраняем обложку, если она уже есть
    }
    args.addAll(['-id3v2_version', '3', '-write_id3v1', '1']);
    for (final kv in [
      ('title', meta.title),
      ('artist', meta.artistTag.isNotEmpty ? meta.artistTag : meta.artist),
      ('album_artist', meta.albumArtist),
      ('album', meta.album),
      ('date', meta.year),
      ('track', meta.track),
    ]) {
      if (kv.$2.isNotEmpty) args.addAll(['-metadata', '${kv.$1}=${kv.$2}']);
    }
    args.add(tmp);
    final out = await Tools.run(tools.ffmpeg.path, args);
    final f = File(tmp);
    if (f.existsSync() && f.lengthSync() > 0) {
      await File(path).delete();
      await f.rename(path);
      return true;
    }
    if (f.existsSync()) await f.delete();
    log('Не удалось записать теги: ${out.take(3).join(' ')}');
    return false;
  }

  /// Переименовывает файл в «Исполнитель - Название.mp3»
  static String moveTo(String path, String folder, String base, [String prefix = '']) {
    final ext = path.contains('.') ? path.substring(path.lastIndexOf('.')) : '';
    final target = '$folder${Platform.pathSeparator}$prefix$base$ext';
    if (target.toLowerCase() == path.toLowerCase()) return path;
    try {
      final t = File(target);
      if (t.existsSync()) t.deleteSync();
      File(path).renameSync(target);
      return target;
    } catch (_) {
      return path;
    }
  }
}
