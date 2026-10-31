// Точное караоке: время каждого слова вычисляется по звуку программой whisper.cpp
// (распознавание речи OpenAI Whisper, работает на процессоре). Текст песни уже известен,
// поэтому распознанные слова только сопоставляются с ним — внутри строк, время которых тоже известно.
// Результат хранится на компьютере и в общей папке на Диске: каждый трек считается один раз на всю компанию.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'audio_cache.dart';
import 'dl/tools.dart';
import 'drive.dart';
import 'library.dart';
import 'log.dart';
import 'lyrics.dart';
import 'models.dart';

/// Слово, которое распознал Whisper
class HeardWord {
  final String text;
  final Duration start, end;
  final double conf; // уверенность Whisper 0..1 (1 — неизвестна, как у старых результатов)
  const HeardWord(this.text, this.start, this.end, [this.conf = 1]);
}

/// Сопоставление распознанных слов с текстом песни.
/// Для каждой строки — время её слов или null, если строку распознать не удалось (там останется разбивка по слогам)
class KaraokeAligner {
  /// Когда строки начинаются на самом деле. Отметки LRCLIB часто сдвинуты на полсекунды-секунду:
  /// где время первого слова известно (Whisper или расширенный LRC), строка начинается с него —
  /// позже отметки до 3 с, раньше до 1,2 с. Остальные строки сдвигаются на типичный сдвиг песни
  /// (медиана по узнанным строкам) — тогда и они не опаздывают и не спешат.
  static List<Duration> lineStarts(List<Duration> marks, List<Duration?> firstWords) {
    final diffs = <int>[];
    for (var i = 0; i < marks.length; i++) {
      final f = i < firstWords.length ? firstWords[i] : null;
      if (f == null) continue;
      diffs.add((f - marks[i]).inMilliseconds); // Ж2: без ограничения сдвига — большой тоже находим
    }
    var shift = 0;
    if (diffs.length >= 3) {
      diffs.sort();
      final median = diffs[diffs.length ~/ 2];
      // Сдвиг устойчивый — большинство строк сдвинуты примерно одинаково
      final close = diffs.where((d) => (d - median).abs() < 450).length;
      if (median.abs() >= 120 && close >= diffs.length * 0.6) shift = median;
    }
    final out = <Duration>[];
    for (var i = 0; i < marks.length; i++) {
      final f = i < firstWords.length ? firstWords[i] : null;
      final d = f == null ? null : (f - marks[i]).inMilliseconds;
      var at = d != null && d - shift > -1200 && d - shift < 3000 ? f! : marks[i] + Duration(milliseconds: shift);
      // Порядок строк не меняется, и каждая видна хотя бы долю секунды
      if (out.isNotEmpty && at < out.last + const Duration(milliseconds: 150)) at = out.last + const Duration(milliseconds: 150);
      out.add(at);
    }
    return out;
  }

  static final _cjk = RegExp(r'[぀-ヿ㐀-䶿一-鿿가-힯]');
  static final _letters = RegExp(r'[\p{L}\p{N}]+', unicode: true);

  static String norm(String s) => s.toLowerCase().replaceAll('ё', 'е').replaceAll(RegExp(r'[^\p{L}\p{N}]', unicode: true), '');

  /// Слова строки с их местом в тексте. Японский, китайский, корейский — по знаку: пробелов там нет
  static List<(int, int, String)> tokens(String text) {
    final out = <(int, int, String)>[];
    for (final m in _letters.allMatches(text)) {
      final w = m.group(0)!;
      if (_cjk.hasMatch(w)) {
        for (var i = 0; i < w.length; i++) {
          out.add((m.start + i, m.start + i + 1, norm(w[i])));
        }
      } else {
        out.add((m.start, m.end, norm(w)));
      }
    }
    return [for (final t in out) if (t.$3.isNotEmpty) t];
  }

  /// Распознанные слова тоже делим на знаки, если это японский и т. п.
  static List<HeardWord> splitHeard(List<HeardWord> heard) {
    final out = <HeardWord>[];
    for (final h in heard) {
      final t = norm(h.text);
      if (t.isEmpty) continue;
      if (_cjk.hasMatch(t) && t.length > 1) {
        final step = (h.end - h.start).inMilliseconds / t.length;
        for (var i = 0; i < t.length; i++) {
          out.add(HeardWord(t[i], h.start + Duration(milliseconds: (step * i).round()), h.start + Duration(milliseconds: (step * (i + 1)).round()), h.conf));
        }
      } else {
        out.add(HeardWord(t, h.start, h.end, h.conf));
      }
    }
    return out;
  }

  static double similarity(String a, String b) {
    if (a == b) return 1;
    if (a.isEmpty || b.isEmpty) return 0;
    // Расстояние Левенштейна, переведённое в похожесть 0..1
    var prev = List<int>.generate(b.length + 1, (i) => i);
    for (var i = 1; i <= a.length; i++) {
      final cur = List<int>.filled(b.length + 1, 0);
      cur[0] = i;
      for (var j = 1; j <= b.length; j++) {
        cur[j] = math.min(math.min(cur[j - 1] + 1, prev[j] + 1), prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1));
      }
      prev = cur;
    }
    return 1 - prev[b.length] / math.max(a.length, b.length);
  }

  /// Грубое число слогов в слове: группы гласных (для русского, английского и похожих)
  static int syllables(String word) {
    final n = RegExp(r'[aeiouyаеёиоуыэюяіїє]+', caseSensitive: false).allMatches(word).length;
    return n < 1 ? 1 : n;
  }

  /// Ж2: общий сдвиг песни. Первые слова строк сопоставляем со всем распознанным без ограничения по времени
  /// и берём медиану расхождений. Положительный сдвиг — песня в этой записи звучит позже, чем в тексте.
  static Duration globalShift(List<LyricLine> lines, List<HeardWord> heard) {
    final firsts = <(int, String)>[]; // строка, первое слово
    final all = <String>[];
    final owner = <int>[]; // для каждого слова текста — номер строки или -1, если слово не первое в строке
    for (var li = 0; li < lines.length; li++) {
      final t = tokens(lines[li].text);
      for (var k = 0; k < t.length; k++) {
        all.add(t[k].$3);
        owner.add(k == 0 ? li : -1);
      }
      if (t.isNotEmpty) firsts.add((li, t.first.$3));
    }
    final n = all.length, m = heard.length;
    if (n < 6 || m < 6) return Duration.zero;
    final score = List.generate(n + 1, (_) => List<double>.filled(m + 1, 0));
    bool good(int i, int j) => all[i].length >= 3 && similarity(all[i], heard[j].text) >= 0.85;
    for (var i = 1; i <= n; i++) {
      for (var j = 1; j <= m; j++) {
        var best = math.max(score[i - 1][j], score[i][j - 1]);
        if (heard[j - 1].conf >= 0.3 && good(i - 1, j - 1)) best = math.max(best, score[i - 1][j - 1] + 1);
        score[i][j] = best;
      }
    }
    final diffs = <int>[];
    var i = n, j = m;
    while (i > 0 && j > 0) {
      if (score[i][j] == score[i - 1][j]) {
        i--;
      } else if (score[i][j] == score[i][j - 1]) {
        j--;
      } else {
        if (owner[i - 1] >= 0) diffs.add((heard[j - 1].start - lines[owner[i - 1]].at!).inMilliseconds);
        i--;
        j--;
      }
    }
    if (diffs.length < 3) return Duration.zero;
    diffs.sort();
    final median = diffs[diffs.length ~/ 2];
    final close = diffs.where((d) => (d - median).abs() < 1500).length;
    return close >= diffs.length * 0.5 ? Duration(milliseconds: median) : Duration.zero;
  }

  /// [lines] — строки текста (время начала), [ends] — когда каждая кончается.
  /// [exactOut] (если дан) получает для каждой строки: найдена по словам (true) или достроена по соседям (false)
  static List<List<KWord>?> align(List<LyricLine> lines, List<Duration> ends, List<HeardWord> heardRaw,
      {List<bool>? exactOut}) {
    // Слова с низкой уверенностью не берём в опору
    final heard = splitHeard([for (final h in heardRaw) if (h.conf >= 0.25) h]);
    final shift = globalShift(lines, heard);
    Duration lineAt(int li) => lines[li].at! + shift;
    Duration lineEnd(int li) => ends[li] + shift;
    // Все слова текста подряд, с номером строки
    final lw = <(int line, int from, int to, String text)>[];
    for (var li = 0; li < lines.length; li++) {
      for (final t in tokens(lines[li].text)) {
        lw.add((li, t.$1, t.$2, t.$3));
      }
    }
    final n = lw.length, m = heard.length;
    final result = List<List<KWord>?>.filled(lines.length, null);
    final exact = List<bool>.filled(lines.length, false);
    if (n == 0 || m == 0) {
      exactOut?.clear();
      exactOut?.addAll(exact);
      return result;
    }

    // Выравнивание как в сравнении текстов: совпадение даёт очки, только если слово похоже
    // и прозвучало около своей строки (±1,5 с от её границ)
    const slack = Duration(milliseconds: 1500);
    bool near(int i, int j) {
      final li = lw[i].$1;
      final a = lineAt(li), b = lineEnd(li);
      return heard[j].start >= a - slack && heard[j].start <= b + slack;
    }

    final score = List.generate(n + 1, (_) => List<double>.filled(m + 1, 0));
    for (var i = 1; i <= n; i++) {
      for (var j = 1; j <= m; j++) {
        var best = math.max(score[i - 1][j], score[i][j - 1]);
        if (near(i - 1, j - 1)) {
          final sim = similarity(lw[i - 1].$4, heard[j - 1].text);
          if (sim >= 0.6) best = math.max(best, score[i - 1][j - 1] + sim);
        }
        score[i][j] = best;
      }
    }
    final match = List<int?>.filled(n, null);
    var i = n, j = m;
    while (i > 0 && j > 0) {
      if (score[i][j] == score[i - 1][j]) {
        i--;
      } else if (score[i][j] == score[i][j - 1]) {
        j--;
      } else {
        match[i - 1] = j - 1;
        i--;
        j--;
      }
    }

    // По строкам: найденные слова получают своё время, ненайденные — между соседями
    var k = 0;
    for (var li = 0; li < lines.length; li++) {
      final idx = <int>[];
      while (k < n && lw[k].$1 == li) {
        idx.add(k++);
      }
      if (idx.isEmpty) continue;
      final found = idx.where((x) => match[x] != null).length;
      if (found < math.max(1, (idx.length * 0.4).ceil())) continue; // слишком мало узнали — оставим слоги
      final start = lineAt(li), end = lineEnd(li);
      final starts = <Duration?>[for (final x in idx) match[x] == null ? null : heard[match[x]!].start];
      // Заполняем пропуски равномерно между известными соседями
      for (var a = 0; a < starts.length; a++) {
        if (starts[a] != null) continue;
        var b = a;
        while (b < starts.length && starts[b] == null) {
          b++;
        }
        final left = a == 0 ? start : starts[a - 1]!;
        final right = b < starts.length ? starts[b]! : end - const Duration(milliseconds: 300);
        final span = (right - left).inMilliseconds;
        // Ж4: пропущенные слова делят промежуток по числу слогов, а не поровну
        final wl = a == 0 ? 0 : syllables(lw[idx[a - 1]].$4);
        final wr = b < starts.length ? syllables(lw[idx[b]].$4) : 0;
        var total = wl + wr;
        for (var c = a; c < b; c++) {
          total += syllables(lw[idx[c]].$4);
        }
        var before = wl;
        for (var c = a; c < b; c++) {
          starts[c] = left + Duration(milliseconds: (span * before / total).round());
          before += syllables(lw[idx[c]].$4);
        }
        a = b;
      }
      final words = <KWord>[];
      for (var a = 0; a < idx.length; a++) {
        var s = starts[a]!;
        if (s < start) s = start;
        if (a > 0 && s < words.last.start) s = words.last.start; // время не идёт назад
        final heardEnd = match[idx[a]] != null ? heard[match[idx[a]]!].end : null;
        var e = a + 1 < idx.length ? starts[a + 1]! : (heardEnd ?? end);
        if (heardEnd != null && heardEnd < e) e = heardEnd;
        if (e < s) e = s;
        if (e > end + slack) e = end;
        words.add(KWord(lw[idx[a]].$2, lw[idx[a]].$3, s, e));
      }
      result[li] = words;
      exact[li] = true;
    }

    // Ж4: строки, где узнали слишком мало, не делим «по линейке» между отметками LRCLIB, а прижимаем
    // к найденным словам соседних строк: не раньше конца предыдущей и не позже начала следующей
    for (var li = 0; li < lines.length; li++) {
      if (result[li] != null) continue;
      final t = tokens(lines[li].text);
      if (t.isEmpty) continue;
      Duration? prevEnd, nextStart;
      for (var p = li - 1; p >= 0; p--) {
        if (result[p] != null && result[p]!.isNotEmpty) {
          prevEnd = result[p]!.last.end;
          break;
        }
      }
      for (var q = li + 1; q < lines.length; q++) {
        if (result[q] != null && result[q]!.isNotEmpty) {
          nextStart = result[q]!.first.start;
          break;
        }
      }
      if (prevEnd == null && nextStart == null) continue; // не к чему прижимать — оставляем слоги
      var s0 = lineAt(li), e0 = lineEnd(li) - const Duration(milliseconds: 250);
      if (prevEnd != null && s0 < prevEnd) s0 = prevEnd;
      if (nextStart != null && e0 > nextStart - const Duration(milliseconds: 100)) e0 = nextStart - const Duration(milliseconds: 100);
      if (e0 <= s0 + const Duration(milliseconds: 200)) continue;
      var total = 0;
      for (final x in t) {
        total += syllables(x.$3);
      }
      var acc = 0;
      final words = <KWord>[];
      for (final x in t) {
        final w = syllables(x.$3);
        final ws = s0 + Duration(milliseconds: ((e0 - s0).inMilliseconds * acc / total).round());
        final we = s0 + Duration(milliseconds: ((e0 - s0).inMilliseconds * (acc + w) / total).round());
        words.add(KWord(x.$1, x.$2, ws, we));
        acc += w;
      }
      result[li] = words;
    }
    if (exactOut != null) {
      exactOut
        ..clear()
        ..addAll(exact);
    }
    return result;
  }
}

/// Точные тайминги слов для треков: читает готовые, считает недостающие в фоне
class KaraokeService extends ChangeNotifier {
  final Directory dir;
  final LibraryController lib;
  final DriveApi drive;
  final AudioCache cache;
  final Tools tools;
  KaraokeService(this.dir, this.lib, this.drive, this.cache, this.tools);

  /// Новые версии whisper.cpp выходят «предварительными», а ссылка latest/download ведёт только на стабильные —
  /// там нужного архива может не быть (так и было: 404). Поэтому берём список выпусков и ищем архив сами
  static const _releasesApi = 'https://api.github.com/repos/ggml-org/whisper.cpp/releases?per_page=15';
  static const _assetNames = ['whisper-bin-x64.zip', 'whisper-blas-bin-x64.zip'];

  Future<String> _whisperUrl() async {
    final res = await http.get(Uri.parse(_releasesApi), headers: {'Accept': 'application/vnd.github+json', 'User-Agent': 'CavePlayer'});
    if (res.statusCode != 200) throw Exception('GitHub не отдал список версий whisper.cpp (${res.statusCode})');
    final list = jsonDecode(utf8.decode(res.bodyBytes));
    if (list is! List) throw Exception('GitHub прислал непонятный ответ');
    for (final name in _assetNames) {
      for (final r in list) {
        if (r is! Map || r['draft'] == true) continue;
        for (final a in (r['assets'] as List? ?? const [])) {
          if (a is Map && a['name'] == name) {
            AppLog.info('Караоке: whisper.cpp ${r['tag_name']} — $name');
            return '${a['browser_download_url']}';
          }
        }
      }
    }
    throw Exception('в последних версиях whisper.cpp нет сборки для Windows');
  }
  static String modelUrl(String m) => 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-$m.bin';

  // ---------- настройки ----------

  bool get enabled => lib.settings.view['karaoke.on'] == '1';
  String get model => lib.settings.view['karaoke.model'] ?? 'small';

  Future<void> setEnabled(bool on) async {
    lib.settings.view['karaoke.on'] = on ? '1' : '0';
    await lib.saveSettings();
    notifyListeners();
  }

  Future<void> setModel(String m) async {
    lib.settings.view['karaoke.model'] = m;
    await lib.saveSettings();
    notifyListeners();
  }

  // ---------- программы ----------

  Directory get _bin => Directory('${dir.path}${Platform.pathSeparator}whisper');
  File get _cli => File('${_bin.path}${Platform.pathSeparator}whisper-cli.exe');
  File _modelFile(String m) => File('${dir.path}${Platform.pathSeparator}ggml-$m.bin');
  bool get installed => _cli.existsSync() && _modelFile(model).existsSync();

  String status = '';
  double? progress;

  void _status(String s, [double? p]) {
    status = s;
    progress = p;
    notifyListeners();
  }

  Future<void> _install() async {
    await dir.create(recursive: true);
    if (!_cli.existsSync()) {
      final zip = File('${dir.path}${Platform.pathSeparator}whisper.zip');
      await _download(await _whisperUrl(), zip, 'whisper.cpp');
      _status('Распаковываю whisper.cpp…');
      await _bin.create(recursive: true);
      final input = InputFileStream(zip.path);
      try {
        final archive = ZipDecoder().decodeBuffer(input);
        for (final f in archive.files) {
          if (!f.isFile) continue;
          final base = f.name.split('/').last;
          final low = base.toLowerCase();
          if (!low.endsWith('.exe') && !low.endsWith('.dll')) continue;
          final out = OutputFileStream('${_bin.path}${Platform.pathSeparator}$base');
          f.writeContent(out);
          await out.close();
        }
      } finally {
        await input.close();
      }
      await zip.delete();
      if (!_cli.existsSync()) throw Exception('в архиве whisper.cpp не нашлась whisper-cli.exe');
    }
    final mf = _modelFile(model);
    if (!mf.existsSync()) await _download(modelUrl(model), mf, 'модель Whisper «$model» (только один раз)');
  }

  Future<void> _download(String url, File dest, String label) async {
    final client = http.Client();
    try {
      final res = await client.send(http.Request('GET', Uri.parse(url))..headers['User-Agent'] = 'Mozilla/5.0');
      if (res.statusCode != 200) throw Exception('$label: сервер ответил ${res.statusCode}');
      final part = File('${dest.path}.part');
      final sink = part.openWrite();
      final total = res.contentLength ?? 0;
      var got = 0, shown = -1;
      await for (final chunk in res.stream) {
        sink.add(chunk);
        got += chunk.length;
        final pc = total > 0 ? got * 100 ~/ total : -1;
        if (pc != shown) {
          shown = pc;
          _status('Скачиваю $label${pc >= 0 ? ': $pc%' : '…'}', pc >= 0 ? pc / 100 : null);
        }
      }
      await sink.close();
      if (dest.existsSync()) await dest.delete();
      await part.rename(dest.path);
    } finally {
      client.close();
    }
  }

  // ---------- готовые тайминги ----------

  final Map<String, List<List<KWord>?>?> _mem = {};
  final Set<String> _loading = {};

  /// Ключ: файл трека и сам текст — если текст поменяли, тайминги считаются заново
  static String keyFor(Track t, Lyrics ly) {
    var h = 0;
    for (final l in ly.lines) {
      for (final c in '${l.at?.inMilliseconds}|${l.text}\n'.codeUnits) {
        h = (h * 31 + c) & 0x7fffffff;
      }
    }
    return '${t.id}_${h.toRadixString(36)}_a$algVersion'; // Ж6: новая версия алгоритма — результат считается заново
  }

  /// Версия алгоритма сопоставления: при изменении старые результаты (у всех друзей) не используются
  static const algVersion = 2;

  /// Ж6: в общую папку выкладываем, только если найдено по словам не меньше такой доли строк
  static const shareQuality = 0.7;

  File _local(String key) => File('${dir.path}${Platform.pathSeparator}kw_$key.json');

  /// Время слов по строкам, если уже посчитано. Иначе null — и в фоне ищем или считаем
  List<List<KWord>?>? wordsFor(Track t, Lyrics ly) {
    if (!ly.synced) return null;
    final key = keyFor(t, ly);
    if (_mem.containsKey(key)) return _mem[key];
    if (_loading.add(key)) unawaited(_fetch(t, ly, key));
    return null;
  }

  static List<List<KWord>?>? decode(dynamic j) {
    if (j is! Map || j['v'] != 1) return null;
    final lines = j['lines'];
    if (lines is! List) return null;
    return [
      for (final l in lines)
        l is List ? [for (final w in l) if (KWord.fromJson(w) case final k?) k] : null,
    ];
  }

  static Map<String, dynamic> encode(List<List<KWord>?> words) => {
        'v': 1,
        'lines': [for (final l in words) l == null ? null : [for (final w in l) w.toJson()]],
      };

  Future<void> _fetch(Track t, Lyrics ly, String key) async {
    try {
      // 1. На этом компьютере
      final f = _local(key);
      if (await f.exists()) {
        final w = decode(jsonDecode(await f.readAsString()));
        if (w != null) return _ready(key, w);
      }
      // 2. В общей папке: кто-то из друзей уже посчитал
      if (lib.hasHub) {
        final bytes = await lib.withHub((email) async {
          final folder = await _sharedFolder(email);
          final found = await drive.listChildren(email, folder, nameEquals: 'kw_$key.json');
          return found.isEmpty ? null : drive.download(email, found.first.id);
        });
        if (bytes != null) {
          final text = utf8.decode(bytes);
          final w = decode(jsonDecode(text));
          if (w != null) {
            await f.writeAsString(text);
            return _ready(key, w);
          }
        }
      }
      // 3. Посчитать самим — если включено
      if (enabled) _enqueue(t, ly, key);
    } catch (e) {
      AppLog.warn('Караоке: тайминги для «${t.title}»', e);
    } finally {
      _loading.remove(key);
    }
  }

  void _ready(String key, List<List<KWord>?> w) {
    _mem[key] = w;
    notifyListeners();
  }

  String? _folderId;
  Future<String> _sharedFolder(String email) async {
    final cached = _folderId;
    if (cached != null) return cached;
    final data = await lib.dataFolder();
    final found = (await drive.listChildren(email, data, nameEquals: 'karaoke')).where((f) => f.isFolder).toList();
    return _folderId = found.isNotEmpty ? found.first.id : await drive.createFolder(email, 'karaoke', parent: data);
  }

  // ---------- подсчёт ----------

  final List<(Track, Lyrics, String)> _queue = [];
  bool _busy = false;

  /// В очереди или уже считается — второй раз не ставим (раньше один трек считался дважды)
  final Set<String> _working = {};

  void _enqueue(Track t, Lyrics ly, String key) {
    if (!_working.add(key)) return;
    _queue.insert(0, (t, ly, key)); // свежий запрос — первым: обычно это то, что играет сейчас
    if (_queue.length > 3) _working.remove(_queue.removeLast().$3);
    unawaited(_pump());
  }

  Future<void> _pump() async {
    if (_busy) return;
    _busy = true;
    try {
      while (_queue.isNotEmpty && enabled) {
        final (t, ly, key) = _queue.removeAt(0);
        try {
          await _compute(t, ly, key);
          _working.remove(key);
        } catch (e) {
          // Не вышло — не пробуем снова в этот запуск, чтобы не гонять процессор по кругу
          AppLog.warn('Караоке: не посчиталось «${t.title}»', e);
          _status('Не получилось: ${'$e'.replaceFirst('Exception: ', '')}');
        }
      }
    } finally {
      _busy = false;
      if (status.isNotEmpty && !status.startsWith('Скачиваю') && !status.startsWith('Не получилось')) _status('');
    }
  }

  static String langOf(Lyrics ly) {
    final text = ly.lines.map((l) => l.text).join(' ');
    if (RegExp(r'[぀-ヿ]').hasMatch(text)) return 'ja';
    if (RegExp(r'[가-힯]').hasMatch(text)) return 'ko';
    if (RegExp(r'[一-鿿]').hasMatch(text)) return 'zh';
    final cyr = RegExp(r'[а-яё]', caseSensitive: false).allMatches(text).length;
    final lat = RegExp(r'[a-z]', caseSensitive: false).allMatches(text).length;
    if (cyr > lat) return RegExp(r'[іїєґ]', caseSensitive: false).hasMatch(text) ? 'uk' : 'ru';
    return lat > 0 ? 'en' : 'auto';
  }

  Future<void> _compute(Track t, Lyrics ly, String key) async {
    await _install();
    _status('Точное караоке: готовлю звук «${t.title}»…');
    final work = Directory('${dir.path}${Platform.pathSeparator}work');
    await work.create(recursive: true);
    final src = File('${work.path}${Platform.pathSeparator}src.audio');
    final wav = File('${work.path}${Platform.pathSeparator}in.wav');
    final out = '${work.path}${Platform.pathSeparator}out';
    try {
      // Звук трека: из кэша плеера, иначе скачиваем с Диска
      final cached = cache.fileFor(t.id);
      if (cache.has(t.id) && cached.existsSync()) {
        await cached.copy(src.path);
      } else {
        final email = await lib.accessFor(t.source);
        await src.writeAsBytes(await drive.download(email, t.id));
      }
      if (!tools.ffmpeg.existsSync()) await tools.ensure((l) => _status(l));
      await Tools.run(tools.ffmpeg.path, ['-y', '-i', src.path, '-ar', '16000', '-ac', '1', '-c:a', 'pcm_s16le', wav.path]);
      if (!wav.existsSync()) throw Exception('ffmpeg не подготовил звук');

      _status('Точное караоке: слушаю «${t.title}»…');
      final threads = math.max(1, Platform.numberOfProcessors ~/ 2); // половина ядер: музыка не должна заикаться
      final lang = langOf(ly);
      // Ж5: подсказка — короткий список редких слов песни, а не начало текста: так Whisper
      // не «дописывает» слова, которых в этот момент не пели
      final prompt = promptWords(ly);
      final started = DateTime.now();
      final json = File('$out.json');
      List<String> args({required bool dtw}) => [
            '-m', _modelFile(model).path,
            '-f', wav.path,
            '-l', lang,
            '-t', '$threads',
            '-ml', '1', '-sow', // каждое слово — отдельным кусочком со своим временем
            if (dtw && _dtwPreset(model) != null) ...['--dtw', _dtwPreset(model)!], // Ж1: DTW-отметки времени
            '-ojf', '-of', out, // полный JSON с вероятностью каждого слова
            '-np',
            if (prompt.isNotEmpty) ...['--prompt', prompt],
          ];
      await Tools.run(_cli.path, args(dtw: true));
      if (!json.existsSync()) await Tools.run(_cli.path, args(dtw: false)); // версия whisper.cpp без --dtw
      if (!json.existsSync()) throw Exception('whisper.cpp не выдал результат');
      final heard = parseWhisper(jsonDecode(utf8.decode(await json.readAsBytes(), allowMalformed: true)));
      final ends = [
        for (var i = 0; i < ly.lines.length; i++)
          i + 1 < ly.lines.length ? ly.lines[i + 1].at! : ly.lines[i].at! + const Duration(seconds: 6),
      ];
      final exact = <bool>[];
      final words = KaraokeAligner.align(ly.lines, ends, heard, exactOut: exact);
      final withText = [for (var i = 0; i < ly.lines.length; i++) if (KaraokeAligner.tokens(ly.lines[i].text).isNotEmpty) i];
      final ok = withText.where((i) => exact[i]).length;
      final quality = withText.isEmpty ? 0.0 : ok / withText.length;
      AppLog.info('Караоке: «${t.title}» — распознано ${heard.length} слов, строк по словам $ok из ${withText.length} '
          '(${(quality * 100).round()}%), ${DateTime.now().difference(started).inSeconds} с');
      final body = jsonEncode({...encode(words), 'alg': algVersion, 'q': double.parse(quality.toStringAsFixed(2))});
      await _local(key).writeAsString(body);
      _ready(key, words);
      // Ж6: друзьям выкладываем только хороший результат (≥ 70% строк по словам)
      if (lib.hasHub && quality >= shareQuality) {
        try {
          await lib.withHub((email) async {
            final folder = await _sharedFolder(email);
            final found = await drive.listChildren(email, folder, nameEquals: 'kw_$key.json');
            if (found.isEmpty) {
              await drive.createFile(email, folder, 'kw_$key.json', body);
            } else if (_forced.remove(key)) {
              await drive.updateFile(email, found.first.id, body); // ручной пересчёт заменяет прежний
            }
          });
        } catch (e) {
          AppLog.warn('Караоке: не выложилось в общую папку', e);
        }
      } else if (lib.hasHub) {
        AppLog.info('Караоке: «${t.title}» не выложено в общую папку — точных строк меньше ${(shareQuality * 100).round()}%');
      }
    } finally {
      for (final f in [src, wav, File('$out.json')]) {
        try {
          if (f.existsSync()) await f.delete();
        } catch (_) {}
      }
    }
  }

  /// Ж5: до 25 самых редких длинных слов песни, не больше 220 знаков
  static String promptWords(Lyrics ly) {
    final count = <String, int>{};
    for (final l in ly.lines) {
      for (final t in KaraokeAligner.tokens(l.text)) {
        count[t.$3] = (count[t.$3] ?? 0) + 1;
      }
    }
    final rare = [for (final e in count.entries) if (e.value == 1 && e.key.length >= 6) e.key]..sort((a, b) => b.length.compareTo(a.length));
    final out = StringBuffer();
    var n = 0;
    for (final w in rare) {
      if (n >= 25 || out.length + w.length + 2 > 220) break;
      if (out.isNotEmpty) out.write(', ');
      out.write(w);
      n++;
    }
    return out.toString();
  }

  /// Название модели для --dtw (только те, что знает whisper.cpp)
  static String? _dtwPreset(String model) {
    const known = {
      'tiny': 'tiny', 'tiny.en': 'tiny.en', 'base': 'base', 'base.en': 'base.en', 'small': 'small', 'small.en': 'small.en',
      'medium': 'medium', 'medium.en': 'medium.en', 'large-v1': 'large.v1', 'large-v2': 'large.v2', 'large-v3': 'large.v3',
      'large-v3-turbo': 'large.v3.turbo',
    };
    return known[model];
  }

  /// Ж6: пересчитать караоке для трека: старый результат стирается, считается заново, хороший заменяет общий
  Future<void> recompute(Track t, Lyrics ly) async {
    final key = keyFor(t, ly);
    try {
      final f = _local(key);
      if (await f.exists()) await f.delete();
    } catch (_) {}
    _mem.remove(key);
    _forced.add(key);
    notifyListeners();
    if (!enabled) {
      lib.messages.add('Включите точное караоке в настройках, чтобы пересчитать');
      return;
    }
    _enqueue(t, ly, key);
  }

  final Set<String> _forced = {};

  // ---------- Ж7: ручная поправка времени ----------

  /// Общая задержка звука устройства (Bluetooth-наушники), мс; плюс поправка этого трека
  int get globalDelayMs => int.tryParse(lib.settings.view['karaoke.delay'] ?? '') ?? 0;
  int trackOffsetMs(Track t) => int.tryParse(lib.settings.view['karaoke.off.${t.id}'] ?? '') ?? 0;

  /// Сколько прибавить к позиции плеера: положительное — текст идёт раньше
  int offsetMs(Track t) => globalDelayMs + trackOffsetMs(t);

  void nudge(Track t, int ms) {
    final v = (trackOffsetMs(t) + ms).clamp(-3000, 3000);
    if (v == 0) {
      lib.settings.view.remove('karaoke.off.${t.id}');
    } else {
      lib.settings.view['karaoke.off.${t.id}'] = '$v';
    }
    unawaited(lib.saveSettings());
    notifyListeners();
  }

  void setGlobalDelay(int ms) {
    lib.settings.view['karaoke.delay'] = '${ms.clamp(-1000, 1000)}';
    unawaited(lib.saveSettings());
    notifyListeners();
  }

  /// Слова из JSON whisper.cpp: transcription[].offsets.from/to в миллисекундах
  static List<HeardWord> parseWhisper(dynamic j) {
    final out = <HeardWord>[];
    final list = j is Map ? j['transcription'] : null;
    if (list is! List) return out;
    for (final s in list) {
      if (s is! Map) continue;
      final text = '${s['text'] ?? ''}'.trim();
      final o = s['offsets'];
      if (text.isEmpty || o is! Map) continue;
      final a = (o['from'] as num?)?.toInt(), b = (o['to'] as num?)?.toInt();
      if (a == null || b == null) continue;
      // Ж1: средняя вероятность настоящих токенов слова (служебные вида [_TT_…] не считаем)
      var sum = 0.0, cnt = 0;
      final toks = s['tokens'];
      if (toks is List) {
        for (final tk in toks) {
          if (tk is! Map) continue;
          final tt = '${tk['text'] ?? ''}';
          final p = (tk['p'] as num?)?.toDouble();
          if (p == null || tt.startsWith('[_')) continue;
          sum += p;
          cnt++;
        }
      }
      out.add(HeardWord(text, Duration(milliseconds: a), Duration(milliseconds: b), cnt == 0 ? 1 : sum / cnt));
    }
    return out;
  }
}
