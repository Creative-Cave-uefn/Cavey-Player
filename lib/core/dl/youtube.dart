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

  /// Найден в YouTube Music среди «Песен»: это студийная запись с официального канала, а не клип и не концерт
  final bool song;

  Candidate(this.id, this.title, this.channel, this.duration, {this.song = false});

  /// Кандидаты всегда ведут на YouTube.
  String get url => 'https://www.youtube.com/watch?v=$id';
  String get site => song ? 'YouTube Music' : 'YouTube';
}

/// Скачанный файл: путь, исполнитель, название, номер в плейлисте
class Entry {
  final String path;
  final String artist;
  final String title;
  final String index;
  final String album;
  final int? trackNumber;
  Entry(this.path, this.artist, this.title, this.index, {this.album = '', this.trackNumber});
}

/// Не та версия: концерт, ремикс, кавер, замедленная и т. п. Штраф, если этого слова нет в самом запросе
const _badWords = [
  'live', 'remix', 'cover', 'slowed', 'reverb', 'sped up', 'speed up', 'speedup',
  'nightcore', 'karaoke', 'instrumental', '8d', '16d',
  'кавер', 'ремикс', 'концерт', 'живьём', 'вживую', 'live at', 'live from', 'live in', 'unplugged', 'session', 'sessions',
  'performance', 'concert', 'tour', 'festival', 'acoustic', 'mashup', 'bass boosted', 'bassboosted', 'tiktok', 'pitched',
  'reaction', 'tutorial', 'lesson', 'drum cover', 'guitar cover', 'piano', 'full album', 'extended', '1 hour', 'loop',
  'teaser', 'trailer', 'snippet', 'demo',
];

/// Клип, а не трек: часто с вступлением, сценками и другой длиной. Штраф меньше — у клипа бывает чистый звук
const _videoWords = ['official video', 'music video', 'official music video', 'video', 'mv', 'clip', 'клип', 'lyric video', 'lyrics', 'lyric', 'visualizer', 'visualiser'];

final _progressRe = RegExp(r'^\[download\]\s+\d+(?:\.\d+)?%');

class YouTube {
  final Tools tools;
  final Directory temp;
  final void Function(String) log;
  YouTube(this.tools, this.temp, this.log);

  /// Уникальная часть имени временного файла. Одних микросекунд мало: часы Windows
  /// тикают грубо, и параллельные загрузки альбома получали одно и то же имя —
  /// одна удаляла файл со списком скачанного, пока другая его ждала
  static int _seq = 0;
  static String unique() => '${DateTime.now().microsecondsSinceEpoch}-${_seq++}';

  /// Строки yt-dlp в журнал, кроме промежуточных процентов
  void _stream(String line) {
    if (_progressRe.hasMatch(line) && !line.contains('100%')) return;
    log(line);
  }

  Future<List<Candidate>> search(String query, [int n = searchResults]) => _list('ytsearch$n:$query', n);

  /// Поиск в YouTube Music только среди песен: там студийные записи с официальных каналов, без клипов и концертов
  Future<List<Candidate>> searchSongs(String query, [int n = searchResults]) =>
      _list('https://music.youtube.com/search?q=${Uri.encodeQueryComponent(query)}#songs', n, song: true);

  Future<List<Candidate>> _list(String target, int n, {bool song = false}) async {
    try {
      final out = await Tools.run(
          tools.ytdlp.path, [...tools.jsArgs, '-J', '--flat-playlist', '--no-warnings', '--playlist-end', '$n', target]);
      final json = out.firstWhere((l) => l.startsWith('{'), orElse: () => '');
      if (json.isEmpty) return [];
      final data = jsonDecode(json) as Map;
      return [
        for (final e in (data['entries'] as List? ?? const []))
          if (e is Map && e['id'] != null && '${e['id']}'.length == 11)
            Candidate('${e['id']}', '${e['title'] ?? ''}', '${e['channel'] ?? e['uploader'] ?? e['artist'] ?? ''}',
                (e['duration'] as num?)?.toDouble(),
                song: song),
      ];
    } catch (e) {
      log(song ? 'Поиск в YouTube Music не удался: $e' : 'Поиск на YouTube не удался: $e');
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
    } else if (c.song) {
      s += 55; // песня из YouTube Music — та же студийная запись, что и на «Topic»-канале
    } else if (meta.artist.isNotEmpty && channel.contains(meta.artist.toLowerCase())) {
      s += 10;
    }
    // Каналы VEVO выкладывают клипы
    if (channel.endsWith('vevo') && !c.song) s -= 20;
    final title = c.title.toLowerCase();
    final query = '${meta.title} ${meta.artist}'.toLowerCase();
    for (final w in _badWords.toSet()) {
      if (hasWord(title, w) && !hasWord(query, w)) s -= 45;
    }
    if (!_videoWords.any((w) => hasWord(query, w)) && _videoWords.any((w) => hasWord(title, w))) s -= 20;
    if (title.contains('official audio') || hasWord(title, 'audio')) s += 8;
    final wantTitle = normTitle(meta.title);
    if (wantTitle.isNotEmpty && !normTitle(c.title).contains(wantTitle)) s -= 40;
    return s;
  }

  Future<List<Candidate>> ranked(TrackMeta meta) async {
    final query = '${meta.artist} ${meta.title}'.trim();
    // Сначала песни из YouTube Music, потом обычный поиск — в нём бывают клипы и концерты
    final both = await Future.wait([searchSongs(query), search(query)]);
    final seen0 = <String>{};
    var cands = [for (final c in [...both[0], ...both[1]]) if (seen0.add(c.id)) c];
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
    final info = File('${temp.path}${Platform.pathSeparator}info-${unique()}.txt');
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
      '--print-to-file', 'after_move:%(filepath)s\t%(artists.0,uploader)s\t%(track,title)s\t%(playlist_index|)s\t%(album|)s\t%(track_number|)s', info.path,
      if (embedThumb) ...['--embed-thumbnail', '--convert-thumbnails', 'jpg'],
      if (playlist) '--ignore-errors',
      '-o', template,
      target,
    ];
    await Tools.run(tools.ytdlp.path, args, onLine: _stream);
    final entries = <Entry>[];
    final lines = await info.exists() ? await info.readAsLines() : const <String>[];
    for (final line in lines) {
      final p = line.split('\t');
      if (p.length >= 3 && p[0].isNotEmpty && File(p[0]).existsSync()) {
        entries.add(Entry(p[0], p[1], p[2], p.length > 3 ? p[3] : '',
            album: p.length > 4 ? p[4] : '',
            trackNumber: p.length > 5 ? int.tryParse(p[5]) : null));
      }
    }
    // Список не записался — берём mp3, которые появились в папке загрузки
    if (entries.isEmpty && !playlist) {
      final dir = File(template).parent;
      if (dir.path != temp.path && await dir.exists()) {
        await for (final f in dir.list()) {
          if (f is File && f.path.toLowerCase().endsWith('.mp3')) entries.add(Entry(f.path, '', '', ''));
        }
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
      // Обложка лежит в самом начале файла, и плеер скачивает её целиком до первого звука.
      // Поэтому встраиваем её не больше 600 пикселей (десятки килобайт вместо мегабайт)
      args.addAll(['-i', coverFile.path, '-map', '0:a', '-map', '1:v', '-c:a', 'copy']);
      args.addAll(['-c:v', 'mjpeg', '-q:v', '3', '-vf', "scale=w='min(600,iw)':h=-2,format=yuvj420p"]);
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
      ('disc', meta.disc),
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
