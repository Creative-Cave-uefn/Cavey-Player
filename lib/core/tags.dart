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
  String year;
  PicRef? pic;

  TrackTags({
    this.title = '',
    this.artist = '',
    this.album = '',
    this.albumArtist = '',
    this.track,
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
  'TRCK': 'track', 'TRK': 'track', 'TYER': 'year', 'TDRC': 'year', 'TYE': 'year',
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
  'TRACKNUMBER': 'track', 'DATE': 'year',
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
    year: year.length > 4 ? year.substring(0, 4) : year,
    pic: (r.pic != null && r.pic!.length > 0) ? r.pic : null,
  );
}
