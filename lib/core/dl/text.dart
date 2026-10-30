// Работа с названиями: чистка, разбор «Исполнитель - Название», имена файлов.
// Перенесено из music_downloaderV2.py.

class TrackMeta {
  String artist;
  String artistTag; // все исполнители через запятую
  String albumArtist;
  String title;
  String album;
  String year;
  String track; // «3/12» или «3»
  double? duration; // секунды
  String? coverUrl;

  TrackMeta({
    this.artist = '',
    this.artistTag = '',
    this.albumArtist = '',
    this.title = '',
    this.album = '',
    this.year = '',
    this.track = '',
    this.duration,
    this.coverUrl,
  });

  String get label => artist.isEmpty ? title : '$artist - $title';
}

const maxNameLen = 120;

final _forbidden = RegExp(r'[<>:"/\\|?*\x00-\x1f]');

/// Имя папки, допустимое в Windows
String safeName(String name, [int limit = 100]) {
  var s = name.replaceAll(_forbidden, '').trim();
  s = s.replaceAll(RegExp(r'^[ .]+|[ .]+$'), '');
  if (s.length > limit) s = s.substring(0, limit).replaceAll(RegExp(r'[ .]+$'), '');
  return s.isEmpty ? 'Album' : s;
}

/// Имя файла: тире, запрещённые символы, длина
String clampName(String name) {
  var s = name.replaceAll(RegExp(r'\s+[–—]\s+'), ' - ');
  s = s.replaceAll(_forbidden, '');
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim().replaceAll(RegExp(r'^[ .]+|[ .]+$'), '');
  if (s.length > maxNameLen) s = s.substring(0, maxNameLen).replaceAll(RegExp(r'[ .]+$'), '');
  return s.isEmpty ? 'track' : s;
}

const _noise = r'official\s*(?:music\s*)?(?:audio|video|lyric\s*video|visuali[sz]er)'
    r'|lyric\s*video|lyrics?|audio|video|clip|hd|hq|4k|visuali[sz]er'
    r'|full\s*version|клип|аудио|текст|официальный\s*(?:клип|аудио|трек)';
final _noiseRe = RegExp(r'\s*[\(\[]\s*(?:' + _noise + r')\s*[\)\]]', caseSensitive: false);

/// Ведущий номер трека в названии: «01. », «01) », «01: », «01 - »
final leadNumRe = RegExp(r'^\s*(\d{1,3})\s*(?:[.)\]:]\s+|[-–—]\s+)');

String stripLeadNum(String text) => text.replaceFirst(leadNumRe, '').trim();

/// Убирает хвосты вроде (Official audio), [Lyrics], (Клип)
String cleanTitle(String title) {
  String? prev;
  var t = title;
  while (prev != t) {
    prev = t;
    t = t.replaceAll(_noiseRe, '');
  }
  return t.trim();
}

/// Из названия ролика получает (исполнитель, трек) без дублирования
(String, String) splitArtistTitle(String artist, String title) {
  final t = title.trim();
  var a = artist.trim();
  if (a == 'NA') a = '';
  final m = RegExp(r'^(.+?)\s+[-–—]\s+(.+)$').firstMatch(t);
  if (m != null) return (m.group(1)!.trim(), m.group(2)!.trim());
  if (a.isNotEmpty && t.toLowerCase().startsWith(a.toLowerCase())) {
    final rest = t.substring(a.length).replaceFirst(RegExp(r'^[ \-–—:|]+'), '').trim();
    if (rest.isNotEmpty) return (a, rest);
  }
  return (a, t);
}

/// Для сравнения названий: без скобок, знаков препинания и регистра
String normTitle(String s) {
  var x = s.toLowerCase().replaceAll(RegExp(r'[\(\[].*?[\)\]]'), ' ');
  x = x.replaceAll(RegExp(r'[^\p{L}\p{N}\s]', unicode: true), ' ');
  return x.replaceAll(RegExp(r'\s+'), ' ').trim();
}

bool hasWord(String text, String word) =>
    RegExp(r'(?<![\p{L}\p{N}_])' + RegExp.escape(word) + r'(?![\p{L}\p{N}_])', unicode: true).hasMatch(text);
