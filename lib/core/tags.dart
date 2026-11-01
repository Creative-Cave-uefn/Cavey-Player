// Чтение тегов из начала аудиофайла: ID3v2 (MP3), FLAC, Ogg Vorbis/Opus, MP4/M4A.
// На вход — первые ~128 КБ файла. Обложку не копируем: запоминаем, где она
// лежит внутри файла (offset/length), и потом догружаем ровно этот кусок.

import 'dart:convert';
import 'dart:typed_data';

class PicRef {
  final int offset;
  final int length;
  final String mime;
  const PicRef(this.offset, this.length, this.mime);
}

class TrackTags {
  String title;
  String artist;
  String album;
  String albumArtist;
  int? track;
  int? disc;
  String year;
  PicRef? pic;

  TrackTags({
    this.title = '',
    this.artist = '',
    this.album = '',
    this.albumArtist = '',
    this.track,
    this.disc,
    this.year = '',
    this.pic,
  });
}

final RegExp audioExt = RegExp(r'\.(mp3|flac|ogg|oga|opus|m4a|mp4|aac|wav|webm|weba|mka|wma|aiff?|ape|wv)$', caseSensitive: false);
final RegExp coverName = RegExp(r'^(cover|folder|front|album|обложка)\.(jpe?g|png|webp)$', caseSensitive: false);

// ---------- декодирование строк ----------

String _latin1(List<int> b) => latin1.decode(b, allowInvalid: true);

// cp1251: 0x80–0xBF — разное, 0xC0–0xFF — А..я
const List<int> _cp1251High = [
  0x0402, 0x0403, 0x201A, 0x0453, 0x201E, 0x2026, 0x2020, 0x2021, 0x20AC, 0x2030, 0x0409, 0x2039, 0x040A, 0x040C, 0x040B, 0x040F,
  0x0452, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x0020, 0x2122, 0x0459, 0x203A, 0x045A, 0x045C, 0x045B, 0x045F,
  0x00A0, 0x040E, 0x045E, 0x0408, 0x00A4, 0x0490, 0x00A6, 0x00A7, 0x0401, 0x00A9, 0x0404, 0x00AB, 0x00AC, 0x00AD, 0x00AE, 0x0407,
  0x00B0, 0x00B1, 0x0406, 0x0456, 0x0491, 0x00B5, 0x00B6, 0x00B7, 0x0451, 0x2116, 0x0454, 0x00BB, 0x0458, 0x0405, 0x0455, 0x0457,
];

String _cp1251(List<int> b) {
  final sb = StringBuffer();
  for (final c in b) {
    if (c < 0x80) {
      sb.writeCharCode(c);
    } else if (c < 0xC0) {
      sb.writeCharCode(_cp1251High[c - 0x80]);
    } else {
      sb.writeCharCode(0x0410 + (c - 0xC0));
    }
  }
  return sb.toString();
}

// Старые русские MP3 часто записаны в cp1251 под видом latin1 — распознаём это.
String _latinOr1251(List<int> b) {
  var high = 0;
  for (final c in b) {
    if (c >= 0xC0) high++;
  }
  return (high > 0 && high >= b.length * 0.3) ? _cp1251(b) : _latin1(b);
}

String _utf16(List<int> b, {required bool bigEndian}) {
  final codes = <int>[];
  for (var i = 0; i + 1 < b.length; i += 2) {
    codes.add(bigEndian ? (b[i] << 8) | b[i + 1] : b[i] | (b[i + 1] << 8));
  }
  return String.fromCharCodes(codes);
}

String _clean(String s) {
  final z = s.indexOf('\u0000');
  return (z >= 0 ? s.substring(0, z) : s).trim();
}

String _decodeText(int enc, Uint8List b) {
  String s;
  if (enc == 0) {
    s = _latinOr1251(b);
  } else if (enc == 1) {
    if (b.length >= 2 && b[0] == 0xFE && b[1] == 0xFF) {
      s = _utf16(b.sublist(2), bigEndian: true);
    } else if (b.length >= 2 && b[0] == 0xFF && b[1] == 0xFE) {
      s = _utf16(b.sublist(2), bigEndian: false);
    } else {
      s = _utf16(b, bigEndian: false);
    }
  } else if (enc == 2) {
    s = _utf16(b, bigEndian: true);
  } else {
    s = utf8.decode(b, allowMalformed: true);
  }
  return _clean(s);
}

String _ascii(Uint8List b, int o, int n) {
  if (o < 0 || o + n > b.length) return '';
  return _latin1(b.sublist(o, o + n));
}

int _synchsafe(Uint8List b, int o) => (b[o] << 21) | (b[o + 1] << 14) | (b[o + 2] << 7) | b[o + 3];
int _be32(Uint8List b, int o) => (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];
int _le32(Uint8List b, int o) => b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);

int _findTerm(Uint8List b, int o, int enc, int limit) {
  if (enc == 1 || enc == 2) {
    for (var i = o; i + 1 < limit; i += 2) {
      if (b[i] == 0 && b[i + 1] == 0) return i;
    }
  } else {
    for (var i = o; i < limit; i++) {
      if (b[i] == 0) return i;
    }
  }
  return -1;
}

// ---------- форматы ----------

class _Raw {
  final Map<String, String> f = {};
  PicRef? pic;
  void set(String key, String value) {
    if (value.isNotEmpty && !f.containsKey(key)) f[key] = value;
  }
}

const _id3Map = {
  'TIT2': 'title', 'TT2': 'title', 'TPE1': 'artist', 'TP1': 'artist',
  'TALB': 'album', 'TAL': 'album', 'TPE2': 'albumArtist', 'TP2': 'albumArtist',
  'TRCK': 'track', 'TRK': 'track', 'TPOS': 'disc', 'TPA': 'disc', 'TYER': 'year', 'TDRC': 'year', 'TYE': 'year',
};

final _frameId = RegExp(r'^[A-Z0-9]+$');

int _parseId3(Uint8List b, _Raw r) {
  final ver = b[3];
  final flags = b[5];
  final size = _synchsafe(b, 6);
  final end = (10 + size) < b.length ? 10 + size : b.length;
  var p = 10;
  if (flags & 0x40 != 0) p += ver == 4 ? _synchsafe(b, 10) : _be32(b, 10) + 4;
  final idLen = ver == 2 ? 3 : 4;
  final hdrLen = ver == 2 ? 6 : 10;
  while (p + hdrLen <= end) {
    final id = _ascii(b, p, idLen);
    if (!_frameId.hasMatch(id)) break;
    final fsize = ver == 2
        ? (b[p + 3] << 16) | (b[p + 4] << 8) | b[p + 5]
        : ver == 4
            ? _synchsafe(b, p + 4)
            : _be32(b, p + 4);
    final d = p + hdrLen;
    if (fsize <= 0) break;
    final key = _id3Map[id];
    if (key != null && d + fsize <= b.length) {
      r.set(key, _decodeText(b[d], b.sublist(d + 1, d + fsize)));
    } else if ((id == 'APIC' || id == 'PIC') && r.pic == null && d + 4 < b.length) {
      final enc = b[d];
      var q = d + 1;
      String mime;
      if (id == 'PIC') {
        mime = _ascii(b, q, 3).toLowerCase() == 'png' ? 'image/png' : 'image/jpeg';
        q += 3;
      } else {
        final t = _findTerm(b, q, 0, b.length);
        if (t < 0) break;
        mime = _ascii(b, q, t - q);
        if (mime.isEmpty) mime = 'image/jpeg';
        if (!mime.contains('/')) mime = 'image/$mime';
        q = t + 1;
      }
      q += 1; // тип картинки
      final t = _findTerm(b, q, enc, b.length);
      if (t >= 0) {
        q = t + ((enc == 1 || enc == 2) ? 2 : 1);
        final len = d + fsize - q;
        if (len > 0) r.pic = PicRef(q, len, mime);
      }
    }
    p = d + fsize;
  }
  return 10 + size;
}

const _vorbisMap = {
  'TITLE': 'title', 'ARTIST': 'artist', 'ALBUM': 'album', 'ALBUMARTIST': 'albumArtist',
  'TRACKNUMBER': 'track', 'DISCNUMBER': 'disc', 'DATE': 'year',
};

void _parseVorbisComments(Uint8List b, int o, _Raw r) {
  if (o + 8 > b.length) return;
  final vlen = _le32(b, o);
  o += 4 + vlen;
  if (o + 4 > b.length) return;
  final n = _le32(b, o);
  o += 4;
  for (var i = 0; i < n && o + 4 <= b.length; i++) {
    final len = _le32(b, o);
    o += 4;
    if (len < 0 || o + len > b.length) break;
    final s = utf8.decode(b.sublist(o, o + len), allowMalformed: true);
    o += len;
    final eq = s.indexOf('=');
    if (eq <= 0) continue;
    final key = _vorbisMap[s.substring(0, eq).toUpperCase()];
    if (key != null) r.set(key, s.substring(eq + 1).trim());
  }
}

void _parseFlac(Uint8List b, int start, _Raw r) {
  var p = start + 4;
  while (p + 4 <= b.length) {
    final last = b[p] & 0x80 != 0;
    final type = b[p] & 0x7F;
    final len = (b[p + 1] << 16) | (b[p + 2] << 8) | b[p + 3];
    final d = p + 4;
    if (type == 4 && d + len <= b.length) _parseVorbisComments(b, d, r);
    if (type == 6 && r.pic == null && d + 40 < b.length) {
      var o = d + 4;
      final ml = _be32(b, o);
      o += 4;
      final mime = _ascii(b, o, ml);
      o += ml;
      if (o + 4 <= b.length) {
        final dl = _be32(b, o);
        o += 4 + dl + 16;
        if (o + 4 <= b.length) {
          final plen = _be32(b, o);
          o += 4;
          r.pic = PicRef(o, plen, mime.isEmpty ? 'image/jpeg' : mime);
        }
      }
    }
    p = d + len;
    if (last) break;
  }
}

int _indexOf(Uint8List b, List<int> needle, [int from = 0]) {
  outer:
  for (var i = from; i + needle.length <= b.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (b[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}

void _parseOgg(Uint8List b, _Raw r) {
  // Склеиваем полезную нагрузку первых страниц и ищем пакет с комментариями
  final all = BytesBuilder(copy: false);
  var p = 0;
  var pages = 0;
  while (p + 27 <= b.length && _ascii(b, p, 4) == 'OggS' && pages < 30) {
    final nseg = b[p + 26];
    if (p + 27 + nseg > b.length) break;
    var len = 0;
    for (var i = 0; i < nseg; i++) {
      len += b[p + 27 + i];
    }
    final d = p + 27 + nseg;
    final e = (d + len) < b.length ? d + len : b.length;
    all.add(b.sublist(d, e));
    p = d + len;
    pages++;
  }
  final data = all.toBytes();
  var i = _indexOf(data, 'OpusTags'.codeUnits);
  if (i >= 0) {
    _parseVorbisComments(data, i + 8, r);
    return;
  }
  i = _indexOf(data, [3, ...'vorbis'.codeUnits]);
  if (i >= 0) _parseVorbisComments(data, i + 7, r);
}

const _mp4Map = {
  '©nam': 'title', '©ART': 'artist', '©alb': 'album',
  'aART': 'albumArtist', '©day': 'year',
};

void _parseMp4(Uint8List b, _Raw r) {
  final i = _indexOf(b, 'ilst'.codeUnits);
  if (i < 4) return;
  final total = _be32(b, i - 4);
  final end = (i - 4 + total) < b.length ? i - 4 + total : b.length;
  var p = i + 4;
  while (p + 8 <= end) {
    final size = _be32(b, p);
    final type = _ascii(b, p + 4, 4);
    if (size < 8) break;
    if (_ascii(b, p + 12, 4) == 'data') {
      final ds = _be32(b, p + 8);
      final vo = p + 24;
      final vl = ds - 16;
      final key = _mp4Map[type];
      if (key != null && vl > 0 && vo + vl <= b.length) {
        r.set(key, utf8.decode(b.sublist(vo, vo + vl), allowMalformed: true).trim());
      }
      if (type == 'trkn' && vo + 4 <= b.length) r.set('track', '${(b[vo + 2] << 8) | b[vo + 3]}');
      if (type == 'disk' && vo + 4 <= b.length) r.set('disc', '${(b[vo + 2] << 8) | b[vo + 3]}');
      if (type == 'covr' && vl > 0 && vo < b.length) {
        r.pic = PicRef(vo, vl, b[vo] == 0x89 ? 'image/png' : 'image/jpeg');
      }
    }
    p += size;
  }
}

// «01 - Исполнитель - Название.mp3» → разбор по имени файла
TrackTags fromFileName(String name) {
  var base = name.replaceAll(RegExp(r'\.[^.]+$'), '').replaceAll('_', ' ').trim();
  int? track;
  final num = RegExp(r'^(\d{1,3})[\s.\-)]+').firstMatch(base);
  if (num != null) {
    track = int.tryParse(num.group(1)!);
    base = base.substring(num.end);
  }
  final parts = base.split(RegExp(r'\s+[-–—]\s+'));
  if (parts.length >= 2) {
    return TrackTags(artist: parts.first.trim(), title: parts.sublist(1).join(' - ').trim(), track: track);
  }
  return TrackTags(title: base, track: track);
}

TrackTags parseTags(Uint8List b, String fileName) {
  final r = _Raw();
  try {
    var p = 0;
    if (b.length >= 10 && _ascii(b, 0, 3) == 'ID3') p = _parseId3(b, r);
    if (_ascii(b, p, 4) == 'fLaC') {
      _parseFlac(b, p, r);
    } else if (_ascii(b, 0, 4) == 'OggS') {
      _parseOgg(b, r);
    } else if (_ascii(b, 4, 4) == 'ftyp') {
      _parseMp4(b, r);
    }
  } catch (_) {
    // Битые теги — не повод ронять сканирование: ниже есть разбор по имени файла
  }
  final fb = fromFileName(fileName);
  final f = r.f;
  final trackStr = f['track'] ?? '';
  final trackNum = int.tryParse(RegExp(r'^\d+').stringMatch(trackStr) ?? '');
  final year = f['year'] ?? '';
  return TrackTags(
    title: f['title'] ?? (fb.title.isNotEmpty ? fb.title : fileName),
    artist: f['artist'] ?? f['albumArtist'] ?? fb.artist,
    album: f['album'] ?? '',
    albumArtist: f['albumArtist'] ?? '',
    track: trackNum ?? fb.track,
    disc: int.tryParse(RegExp(r'^\d+').stringMatch(f['disc'] ?? '') ?? ''),
    year: year.length > 4 ? year.substring(0, 4) : year,
    pic: (r.pic != null && r.pic!.length > 0) ? r.pic : null,
  );
}

// ---------- длительность ----------
// Определяем по нескольким небольшим кускам файла, целиком его не скачиваем:
// FLAC — из заголовка, MP3 — из кадра Xing/VBRI (или по битрейту), M4A — из mvhd,
// Ogg/Opus — по последней странице в конце файла.

/// Читает кусок файла [start, endInclusive]
typedef RangeReader = Future<Uint8List> Function(int start, int endInclusive);

int? _flacDurationMs(Uint8List b, int s) {
  final d = s + 8;
  if (b.length < d + 18 || _ascii(b, s, 4) != 'fLaC' || (b[s + 4] & 0x7F) != 0) return null;
  final rate = (b[d + 10] << 12) | (b[d + 11] << 4) | (b[d + 12] >> 4);
  final total = ((b[d + 13] & 0x0F) << 32) | (b[d + 14] << 24) | (b[d + 15] << 16) | (b[d + 16] << 8) | b[d + 17];
  return (rate > 0 && total > 0) ? total * 1000 ~/ rate : null;
}

// Битрейты MPEG по номеру в заголовке кадра: ключ — версия (1 или 2, куда входит и 2.5) * 10 + слой
const _mp3Bitrates = <int, List<int>>{
  13: [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320],
  12: [0, 32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384],
  11: [0, 32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448],
  21: [0, 32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256],
  22: [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160],
  23: [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160],
};
const _mp3Rates = <int, List<int>>{
  1: [44100, 48000, 32000],
  2: [22050, 24000, 16000],
  3: [11025, 12000, 8000],
};

/// [b] — начало звука после тега ID3, [bytesAfterTags] — сколько байт звука в файле (для оценки по битрейту)
int? _mp3DurationMs(Uint8List b, int bytesAfterTags) {
  final limit = b.length < 8192 ? b.length : 8192;
  for (var i = 0; i + 4 <= limit; i++) {
    if (b[i] != 0xFF || (b[i + 1] & 0xE0) != 0xE0) continue;
    final vb = (b[i + 1] >> 3) & 3;
    final lb = (b[i + 1] >> 1) & 3;
    final bi = b[i + 2] >> 4;
    final si = (b[i + 2] >> 2) & 3;
    if (vb == 1 || lb == 0 || bi == 0 || bi == 15 || si == 3) continue;
    final ver = vb == 3 ? 1 : (vb == 2 ? 2 : 3); // MPEG 1, 2, 2.5
    final layer = lb == 3 ? 1 : (lb == 2 ? 2 : 3);
    final kbps = _mp3Bitrates[(ver == 1 ? 1 : 2) * 10 + layer]![bi];
    final rate = _mp3Rates[ver]![si];
    final pad = (b[i + 2] >> 1) & 1;
    final spf = layer == 1 ? 384 : ((layer == 2 || ver == 1) ? 1152 : 576);
    // Настоящий кадр: следом за ним должен начаться ещё один, иначе это случайные байты
    final frameLen = layer == 1 ? (12000 * kbps ~/ rate + pad) * 4 : (spf == 1152 ? 144000 : 72000) * kbps ~/ rate + pad;
    final next = i + frameLen;
    if (next + 2 <= b.length && (b[next] != 0xFF || (b[next + 1] & 0xE0) != 0xE0)) continue;
    final mono = (b[i + 3] >> 6) == 3;
    final crc = (b[i + 1] & 1) == 0;
    final side = ver == 1 ? (mono ? 17 : 32) : (mono ? 9 : 17);
    final x = i + 4 + side + (crc ? 2 : 0);
    if (layer == 3 && x + 12 <= b.length) {
      final tag = _ascii(b, x, 4);
      if ((tag == 'Xing' || tag == 'Info') && (_be32(b, x + 4) & 1) != 0) {
        final frames = _be32(b, x + 8);
        if (frames > 0) return frames * spf * 1000 ~/ rate;
      }
    }
    final v = i + 36;
    if (v + 18 <= b.length && _ascii(b, v, 4) == 'VBRI') {
      final frames = _be32(b, v + 14);
      if (frames > 0) return frames * spf * 1000 ~/ rate;
    }
    return bytesAfterTags > 0 ? bytesAfterTags * 8 ~/ kbps : null;
  }
  return null;
}

/// [o] — начало коробки mvhd (размер, имя, содержимое)
int? _mvhdDurationMs(Uint8List b, int o) {
  if (o + 8 > b.length || _ascii(b, o + 4, 4) != 'mvhd') return null;
  final d = o + 8;
  if (d + 20 > b.length) return null;
  final int timescale;
  final int duration;
  if (b[d] == 0) {
    timescale = _be32(b, d + 12);
    duration = _be32(b, d + 16);
  } else {
    if (d + 32 > b.length) return null;
    timescale = _be32(b, d + 20);
    duration = (_be32(b, d + 24) << 32) | _be32(b, d + 28);
  }
  return (timescale > 0 && duration > 0) ? duration * 1000 ~/ timescale : null;
}

Future<int?> _mp4DurationMs(Future<Uint8List> Function(int start, int len) rd, int size) async {
  var pos = 0;
  for (var n = 0; n < 8 && pos < size; n++) {
    final h = await rd(pos, 16);
    if (h.length < 8) return null;
    var total = _be32(h, 0);
    var hdr = 8;
    if (total == 1 && h.length >= 16) {
      total = (_be32(h, 8) << 32) | _be32(h, 12);
      hdr = 16;
    } else if (total == 0) {
      total = size - pos;
    }
    if (_ascii(h, 4, 4) == 'moov') return _mvhdDurationMs(await rd(pos + hdr, 64), 0);
    if (total < 8) return null;
    pos += total;
  }
  return null;
}

/// [head] — начало файла, [tail] — его последние ~64 КБ
int? _oggDurationMs(Uint8List head, Uint8List tail) {
  var pre = 0;
  int rate;
  var i = _indexOf(head, 'OpusHead'.codeUnits);
  if (i >= 0 && i + 12 <= head.length) {
    pre = head[i + 10] | (head[i + 11] << 8);
    rate = 48000;
  } else {
    i = _indexOf(head, [1, ...'vorbis'.codeUnits]);
    if (i < 0 || i + 16 > head.length) return null;
    rate = _le32(head, i + 12);
  }
  if (rate <= 0) return null;
  var k = -1;
  for (var j = tail.length - 14; j >= 0; j--) {
    if (tail[j] == 0x4F && tail[j + 1] == 0x67 && tail[j + 2] == 0x67 && tail[j + 3] == 0x53) {
      k = j;
      break;
    }
  }
  if (k < 0) return null;
  final granule = _le32(tail, k + 6) | (_le32(tail, k + 10) << 32);
  return granule > pre ? (granule - pre) * 1000 ~/ rate : null;
}

/// Длительность файла в миллисекундах; null — по этому файлу определить не вышло.
/// Сетевые ошибки не глотаются: пусть вызывающий решит, повторять ли позже.
Future<int?> probeDurationMs(RangeReader read, int size) async {
  if (size <= 0) return null;
  Future<Uint8List> rd(int start, int len) {
    if (start >= size) return Future.value(Uint8List(0));
    final end = start + len - 1;
    return read(start, end < size - 1 ? end : size - 1);
  }

  final head = await rd(0, 4096);
  if (head.length < 12) return null;
  if (_ascii(head, 0, 4) == 'fLaC') return _flacDurationMs(head, 0);
  if (_ascii(head, 0, 4) == 'OggS') {
    final tailStart = size > 65536 ? size - 65536 : 0;
    return _oggDurationMs(head, await rd(tailStart, 65536));
  }
  if (_ascii(head, 4, 4) == 'ftyp') return _mp4DurationMs(rd, size);
  var start = 0;
  if (_ascii(head, 0, 3) == 'ID3') start = 10 + _synchsafe(head, 6) + ((head[5] & 0x10) != 0 ? 10 : 0);
  final body = start == 0 ? head : await rd(start, 8192);
  if (_ascii(body, 0, 4) == 'fLaC') return _flacDurationMs(body, 0);
  return _mp3DurationMs(body, size - start);
}
