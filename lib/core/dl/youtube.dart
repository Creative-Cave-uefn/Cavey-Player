// Поиск лучшей версии трека на YouTube, скачивание через yt-dlp и запись тегов
// через ffmpeg. Перенесено из music_downloaderV2.py.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'text.dart';
import 'tools.dart';

const searchResults = 8; // сколько вариантов с YouTube сравнивать
const maxDownloadTries = 3; // сколько лучших вариантов пробовать
const fragments = 3; // не перегружаем YouTube одновременными фрагментами

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

  // Shared by concurrent album workers: avoid request bursts and HTTP 429.
  static const maxConcurrentSearches = 2;
  static int _activeSearches = 0;
  static final Queue<Completer<void>> _searchWaiters = Queue<Completer<void>>();

  static Future<T> _limitSearch<T>(Future<T> Function() action) async {
    if (_activeSearches >= maxConcurrentSearches) {
      final waiter = Completer<void>();
      _searchWaiters.add(waiter);
      await waiter.future;
    } else {
      _activeSearches++;
    }
    try {
      return await action();
    } finally {
      if (_searchWaiters.isNotEmpty) {
        _searchWaiters.removeFirst().complete();
      } else {
        _activeSearches--;
      }
    }
  }

  static bool retryable(String message) => RegExp(
      r'(?:\b(?:429|500|502|503|504)\b|too many requests|rate limit|timed? out|'
      r'connection (?:reset|refused|aborted)|temporar(?:ily|y)|network (?:error|unreachable))',
      caseSensitive: false).hasMatch(message);

  static List<String> searchQueries(TrackMeta meta) {
    final base = '${meta.artist} ${meta.title}'.trim();
    return ['$base official audio', base, '$base audio', '$base topic', '$base lyrics'];
  }

  Future<List<Candidate>> search(String query, [int n = searchResults]) =>
      _list('ytsearch$n:$query', n);

  /// The #songs URL fragment isn't transmitted to the server; don't rely on it.
  Future<List<Candidate>> searchSongs(String query, [int n = searchResults]) =>
      _list('https://music.youtube.com/search?q=${Uri.encodeQueryComponent(query)}', n, song: true);

  Future<List<Candidate>> _list(String target, int n, {bool song = false}) =>
      _limitSearch(() => _searchWithRetries(target, n, song: song));

  Future<List<Candidate>> _searchWithRetries(String target, int n, {required bool song}) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final out = await Tools.run(tools.ytdlp.path, [
          ...tools.jsArgs,
          '--socket-timeout', '20',
          '--extractor-retries', '3',
          '--retry-sleep', 'extractor:exp=1:6',
          '--sleep-requests', '0.35',
          '-J', '--flat-playlist', '--no-warnings',
          '--playlist-end', '$n', target,
        ]);
        final payload = out.firstWhere((line) => line.startsWith('{'), orElse: () => '');
        if (payload.isNotEmpty) {
          final data = jsonDecode(payload);
          if (data is! Map) return [];
          return [
            for (final e in (data['entries'] as List? ?? const []))
              if (e is Map && e['id'] != null && '${e['id']}'.length == 11)
                Candidate(
                  '${e['id']}',
                  '${e['title'] ?? ''}',
                  '${e['channel'] ?? e['uploader'] ?? e['artist'] ?? ''}',
                  (e['duration'] as num?)?.toDouble(),
                  song: song && (e['track'] != null || e['album'] != null ||
                      e['artist'] != null ||
                      '${e['channel'] ?? ''}'.toLowerCase().endsWith(' - topic')),
                ),
          ];
        }
        final detail = out.where((line) =>
            line.contains('ERROR') || line.contains('WARNING')).take(3).join(' ');
        if (attempt < 2 && retryable(detail)) {
          log('YouTube: временная ошибка поиска, попытка ${attempt + 2}/3.');
          await Future<void>.delayed(Duration(seconds: 2 << attempt));
          continue;
        }
        if (detail.isNotEmpty) log('YouTube: ${detail.length > 280 ? detail.substring(0, 280) : detail}');
        return [];
      } catch (e) {
        if (attempt < 2 && retryable('$e')) {
          await Future<void>.delayed(Duration(seconds: 2 << attempt));
          continue;
        }
        log(song ? 'YouTube Music: поиск недоступен ($e).' : 'YouTube: поиск недоступен ($e).');
        return [];
      }
    }
    return [];
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
    final queries = searchQueries(meta);
    final first = await Future.wait([
      searchSongs(queries[1]),
      search(queries[0]),
      search(queries[1]),
    ]);
    final seen = <String>{};
    final candidates = <Candidate>[
      for (final group in first)
        for (final c in group)
          if (seen.add(c.id)) c,
    ];
    void sort() => candidates.sort((a, b) => score(b, meta).compareTo(score(a, meta)));
    sort();
    if (candidates.isEmpty || score(candidates.first, meta) < 65) {
      final extra = await Future.wait([
        search(queries[2]),
        search(queries[3]),
        search(queries[4]),
      ]);
      for (final group in extra) {
        for (final c in group) {
          if (seen.add(c.id)) candidates.add(c);
        }
      }
      sort();
    }
    return candidates;
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
      '--socket-timeout', '20',
      '--retries', '5',
      '--fragment-retries', '5',
      '--extractor-retries', '3',
      '--retry-sleep', 'http:exp=1:8',
      '--retry-sleep', 'fragment:exp=1:8',
      '--retry-sleep', 'extractor:exp=1:8',
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
