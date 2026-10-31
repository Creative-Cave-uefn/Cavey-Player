// Тексты песен из файлов, а не из интернета (Л1, Л6):
// - встроенный текст: ID3 USLT (обычный) и SYLT (синхронный), Vorbis LYRICS в FLAC;
// - файлы рядом с треком на Диске: .lrc, UltraStar .txt (слоги с нотами), .ass с тегами \k.
// Готовая разметка по слогам точнее любого расчёта, поэтому она в приоритете над LRCLIB.

import 'dart:convert';
import 'dart:typed_data';

import 'lyrics.dart';

/// Откуда взят текст — нужно, чтобы разобрать сохранённый в кэше сырой текст так же
enum LyricKind { lrc, plain, ultrastar, ass }

class SourceText {
  final LyricKind kind;
  final String text;
  const SourceText(this.kind, this.text);

  Map<String, dynamic> toJson() => {'side': kind.name, 'text': text};
  static SourceText? fromJson(Map j) {
    final k = LyricKind.values.where((e) => e.name == j['side']).firstOrNull;
    final t = j['text'];
    return k == null || t is! String ? null : SourceText(k, t);
  }

  Lyrics? parse() => switch (kind) {
        LyricKind.lrc => LyricFiles.fromLrc(text),
        LyricKind.plain => LyricFiles.fromPlain(text),
        LyricKind.ultrastar => LyricFiles.fromUltraStar(text),
        LyricKind.ass => LyricFiles.fromAss(text),
      };
}

class LyricFiles {
  static final _lrcTag = RegExp(r'\[\d+:\d+(?:[.:]\d+)?\]');

  /// Текст с отметками [мм:сс.xx] — синхронный, без них — обычный
  static Lyrics? fromLrc(String text) {
    if (!_lrcTag.hasMatch(text)) return fromPlain(text);
    return Lyrics.fromLrclib({'syncedLyrics': text});
  }

  static Lyrics? fromPlain(String text) {
    final lines = [for (final l in const LineSplitter().convert(text)) l.trim()];
    if (lines.every((l) => l.isEmpty)) return null;
    return Lyrics([for (final l in lines) LyricLine(null, l)], synced: false);
  }

  /// Определяет вид текста, прочитанного из файла
  static SourceText? classify(String text) {
    final t = text.trim();
    if (t.isEmpty) return null;
    return SourceText(_lrcTag.hasMatch(t) ? LyricKind.lrc : LyricKind.plain, t);
  }

  // ---------- UltraStar ----------

  /// Файл UltraStar: заголовок #BPM, #GAP, затем строки «: начало длина нота слог».
  /// Время слога = GAP + доля такта × 60 / (BPM × 4). Режим #RELATIVE не поддерживается.
  static Lyrics? fromUltraStar(String text) {
    double? bpm;
    var gap = 0.0;
    final body = <String>[];
    for (final raw in const LineSplitter().convert(text)) {
      final line = raw.trimRight();
      if (line.startsWith('#')) {
        final c = line.indexOf(':');
        if (c < 0) continue;
        final key = line.substring(1, c).toUpperCase();
        final val = line.substring(c + 1).trim().replaceAll(',', '.');
        if (key == 'BPM') bpm = double.tryParse(val);
        if (key == 'GAP') gap = double.tryParse(val) ?? 0;
        if (key == 'RELATIVE' && val.toUpperCase() == 'YES') return null;
      } else if (line.isNotEmpty) {
        body.add(line);
      }
    }
    if (bpm == null || bpm <= 0) return null;
    final beatMs = 60000 / (bpm * 4);
    Duration at(num beat) => Duration(milliseconds: (gap + beat * beatMs).round());

    final lines = <LyricLine>[];
    final buf = StringBuffer();
    final syl = <(int, int, Duration, Duration)>[];
    void flush() {
      final raw = buf.toString();
      final lead = raw.length - raw.trimLeft().length;
      final textLine = raw.trim();
      if (textLine.isNotEmpty && syl.isNotEmpty) {
        final words = [
          for (final s in syl)
            KWord((s.$1 - lead).clamp(0, textLine.length), (s.$2 - lead).clamp(0, textLine.length), s.$3, s.$4),
        ];
        lines.add(LyricLine(syl.first.$3, textLine, words));
      }
      buf.clear();
      syl.clear();
    }

    for (final l in body) {
      if (l == 'E') break;
      final kind = l[0];
      if (kind == '-') {
        flush();
        continue;
      }
      if (kind != ':' && kind != '*' && kind != 'F' && kind != 'R' && kind != 'G') continue;
      // «: 12 4 7 слог» — слог может содержать пробелы в начале (признак нового слова)
      final m = RegExp(r'^[:*FRG]\s(-?\d+)\s(\d+)\s(-?\d+)\s?(.*)$').firstMatch(l);
      if (m == null) continue;
      final start = int.parse(m.group(1)!);
      final len = int.parse(m.group(2)!);
      final s = m.group(4) ?? '';
      if (s.isEmpty) continue;
      final from = buf.length;
      buf.write(s);
      syl.add((from, buf.length, at(start), at(start + (len < 1 ? 1 : len))));
    }
    flush();
    return lines.isEmpty ? null : Lyrics(lines, synced: true);
  }

  // ---------- ASS (Karaoke Mugen и др.) ----------

  static final _assTime = RegExp(r'^(\d+):(\d{2}):(\d{2})[.:](\d{2,3})$');

  static Duration? _assAt(String s) {
    final m = _assTime.firstMatch(s.trim());
    if (m == null) return null;
    final frac = m.group(4)!;
    final ms = frac.length == 2 ? int.parse(frac) * 10 : int.parse(frac);
    return Duration(hours: int.parse(m.group(1)!), minutes: int.parse(m.group(2)!), seconds: int.parse(m.group(3)!), milliseconds: ms);
  }

  /// Строки «Dialogue: …,начало,конец,…,{\k50}сло{\k30}г» → слоги по тегам \k, \kf, \ko (сотые доли секунды)
  static Lyrics? fromAss(String text) {
    final lines = <LyricLine>[];
    for (final raw in const LineSplitter().convert(text)) {
      if (!raw.startsWith('Dialogue:')) continue;
      final parts = raw.substring(9).split(',');
      if (parts.length < 10) continue;
      final start = _assAt(parts[1]);
      if (start == null) continue;
      final body = parts.sublist(9).join(',');
      final buf = StringBuffer();
      final syl = <(int, int, Duration, Duration)>[];
      var t = start;
      var pendingCs = 0;
      var hasK = false;
      var cursor = 0;
      final tag = RegExp(r'\{[^}]*\}');
      void addText(String chunk) {
        if (chunk.isEmpty) return;
        final from = buf.length;
        buf.write(chunk);
        final dur = Duration(milliseconds: pendingCs * 10);
        if (hasK) syl.add((from, buf.length, t, t + dur));
        t += dur;
        pendingCs = 0;
      }

      for (final m in tag.allMatches(body)) {
        addText(body.substring(cursor, m.start).replaceAll(r'\N', ' ').replaceAll(r'\n', ' '));
        final k = RegExp(r'\\k[fo]?(\d+)').firstMatch(m.group(0)!);
        if (k != null) {
          pendingCs = int.parse(k.group(1)!);
          hasK = true;
        }
        cursor = m.end;
      }
      addText(body.substring(cursor).replaceAll(r'\N', ' ').replaceAll(r'\n', ' '));
      final rawText = buf.toString();
      final lead = rawText.length - rawText.trimLeft().length;
      final textLine = rawText.trim();
      if (textLine.isEmpty) continue;
      final words = syl.isEmpty
          ? null
          : [
              for (final s in syl)
                if (s.$2 - lead > 0 && s.$1 - lead < textLine.length)
                  KWord((s.$1 - lead).clamp(0, textLine.length), (s.$2 - lead).clamp(0, textLine.length), s.$3, s.$4),
            ];
      lines.add(LyricLine(start, textLine, words == null || words.isEmpty ? null : words));
    }
    lines.sort((a, b) => a.at!.compareTo(b.at!));
    return lines.isEmpty ? null : Lyrics(lines, synced: true);
  }

  // ---------- текст внутри файла трека ----------

  /// ID3v2: USLT (обычный текст) и SYLT (синхронный, время в мс). Ищем в начале файла.
  /// Синхронный текст возвращается как LRC-строка
  static SourceText? fromId3(Uint8List b) {
    if (b.length < 10 || b[0] != 0x49 || b[1] != 0x44 || b[2] != 0x33) return null; // «ID3»
    final ver = b[3];
    if (ver < 2 || ver > 4) return null;
    final flags = b[5];
    int synchsafe(int o) => (b[o] << 21) | (b[o + 1] << 14) | (b[o + 2] << 7) | b[o + 3];
    int be32(int o) => (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];
    final size = synchsafe(6);
    final end = (10 + size) < b.length ? 10 + size : b.length;
    var p = 10;
    if (flags & 0x40 != 0 && p + 4 <= b.length) p += ver == 4 ? synchsafe(10) : be32(10) + 4;
    final idLen = ver == 2 ? 3 : 4;
    final hdrLen = ver == 2 ? 6 : 10;
    SourceText? plain;
    while (p + hdrLen <= end) {
      final id = latin1.decode(b.sublist(p, p + idLen), allowInvalid: true);
      if (!RegExp(r'^[A-Z0-9]+$').hasMatch(id)) break;
      final fsize = ver == 2
          ? (b[p + 3] << 16) | (b[p + 4] << 8) | b[p + 5]
          : ver == 4
              ? synchsafe(p + 4)
              : be32(p + 4);
      final d = p + hdrLen;
      if (fsize <= 0 || d + fsize > b.length) break;
      final frame = b.sublist(d, d + fsize);
      if (id == 'SYLT' || id == 'SLT') {
        final lrc = _sylt(frame);
        if (lrc != null) return SourceText(LyricKind.lrc, lrc);
      } else if (id == 'USLT' || id == 'ULT') {
        final t = _uslt(frame);
        if (t != null && t.trim().isNotEmpty) plain = classify(t);
      }
      p = d + fsize;
    }
    return plain;
  }

  static String _text(int enc, Uint8List b) {
    switch (enc) {
      case 1:
        if (b.length >= 2 && b[0] == 0xFE && b[1] == 0xFF) return _utf16(b.sublist(2), true);
        if (b.length >= 2 && b[0] == 0xFF && b[1] == 0xFE) return _utf16(b.sublist(2), false);
        return _utf16(b, false);
      case 2:
        return _utf16(b, true);
      case 3:
        return utf8.decode(b, allowMalformed: true);
      default:
        return latin1.decode(b, allowInvalid: true);
    }
  }

  static String _utf16(Uint8List b, bool be) {
    final units = <int>[];
    for (var i = 0; i + 1 < b.length; i += 2) {
      units.add(be ? (b[i] << 8) | b[i + 1] : b[i] | (b[i + 1] << 8));
    }
    return String.fromCharCodes(units);
  }

  static int _term(Uint8List b, int o, int enc) {
    if (enc == 1 || enc == 2) {
      for (var i = o; i + 1 < b.length; i += 2) {
        if (b[i] == 0 && b[i + 1] == 0) return i;
      }
    } else {
      for (var i = o; i < b.length; i++) {
        if (b[i] == 0) return i;
      }
    }
    return -1;
  }

  static String? _uslt(Uint8List f) {
    if (f.length < 5) return null;
    final enc = f[0];
    final t = _term(f, 4, enc); // после кодировки и языка — описание
    if (t < 0) return null;
    final start = t + ((enc == 1 || enc == 2) ? 2 : 1);
    if (start >= f.length) return null;
    return _text(enc, f.sublist(start));
  }

  static String? _sylt(Uint8List f) {
    if (f.length < 8) return null;
    final enc = f[0];
    final format = f[4]; // 2 — миллисекунды
    if (format != 2) return null;
    final t = _term(f, 6, enc);
    if (t < 0) return null;
    var p = t + ((enc == 1 || enc == 2) ? 2 : 1);
    final out = StringBuffer();
    while (p < f.length) {
      final e = _term(f, p, enc);
      if (e < 0 || e + ((enc == 1 || enc == 2) ? 2 : 1) + 4 > f.length) break;
      final chunk = _text(enc, f.sublist(p, e));
      final q = e + ((enc == 1 || enc == 2) ? 2 : 1);
      final ms = (f[q] << 24) | (f[q + 1] << 16) | (f[q + 2] << 8) | f[q + 3];
      p = q + 4;
      final text = chunk.replaceAll('\n', '').trim();
      if (text.isEmpty) continue;
      final m = ms ~/ 60000, s = (ms % 60000) / 1000;
      out.writeln('[${m.toString().padLeft(2, '0')}:${s.toStringAsFixed(2).padLeft(5, '0')}]$text');
    }
    final r = out.toString();
    return r.trim().isEmpty ? null : r;
  }

  /// FLAC: поле Vorbis-комментария LYRICS (или UNSYNCEDLYRICS) в блоке метаданных
  static SourceText? fromFlac(Uint8List b) {
    if (b.length < 8 || b[0] != 0x66 || b[1] != 0x4C || b[2] != 0x61 || b[3] != 0x43) return null; // «fLaC»
    int le32(int o) => b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);
    var p = 4;
    while (p + 4 <= b.length) {
      final last = b[p] & 0x80 != 0;
      final type = b[p] & 0x7F;
      final len = (b[p + 1] << 16) | (b[p + 2] << 8) | b[p + 3];
      final d = p + 4;
      if (type == 4 && d + len <= b.length) {
        var o = d;
        if (o + 4 > b.length) return null;
        o += 4 + le32(o);
        if (o + 4 > b.length) return null;
        final n = le32(o);
        o += 4;
        for (var i = 0; i < n && o + 4 <= b.length; i++) {
          final l = le32(o);
          o += 4;
          if (l < 0 || o + l > b.length) break;
          final s = utf8.decode(b.sublist(o, o + l), allowMalformed: true);
          o += l;
          final eq = s.indexOf('=');
          if (eq <= 0) continue;
          final key = s.substring(0, eq).toUpperCase();
          if (key == 'LYRICS' || key == 'UNSYNCEDLYRICS' || key == 'SYNCEDLYRICS') return classify(s.substring(eq + 1));
        }
      }
      p = d + len;
      if (last) break;
    }
    return null;
  }

  /// Встроенный текст из начала файла (формат определяется по сигнатуре)
  static SourceText? embedded(Uint8List head) => fromId3(head) ?? fromFlac(head);
}
