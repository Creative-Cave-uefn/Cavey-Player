import 'dart:io';

// Ссылки на треки, альбомы, исполнителей и плейлисты: caveplayer://track/<id>, …/album/<ключ>, …/artist/<ключ>, …/playlist/<id>
// открывают приложение на нужной странице.
// В мессенджерах такие ссылки не кликабельны, поэтому есть и обычная https-ссылка на страницу-переадресацию
// (docs/open/index.html), которая сама открывает caveplayer://.

/// Адрес страницы-переадресации по умолчанию: GitHub Pages публичного репозитория релизов
const kDefaultShareUrl = 'https://creative-cave-uefn.github.io/cave-player-releases/open/';

const _shareFromBuild = String.fromEnvironment('SHARE_URL');

/// Адрес страницы-переадресации (с косой чертой на конце). Можно заменить при сборке:
/// --dart-define=SHARE_URL=https://…/open/ (переменная SHARE_URL в настройках репозитория)
const kShareRedirectUrl = _shareFromBuild == '' ? kDefaultShareUrl : _shareFromBuild;

const _scheme = 'caveplayer';

/// Ссылка для открытия в приложении
String appLinkFor(String trackId) => '$_scheme://track/$trackId';

/// Ссылка для мессенджеров; null, если страница-переадресация не настроена
String? webLinkFor(String trackId, {String base = kShareRedirectUrl}) =>
    base.isEmpty ? null : '${base.endsWith('/') ? base : '$base/'}?t=${Uri.encodeQueryComponent(trackId)}';

/// Что можно отправить ссылкой
/// tag: ключ — «почта владельца|id тега» (чужой тег виден по ссылке, как открытый плейлист)
enum ShareKind { track, album, artist, playlist, tag }

/// Ссылка на что-то в Cavey: [key] — id трека, ключ альбома, ключ исполнителя или id плейлиста
class ShareTarget {
  final ShareKind kind;
  final String key;
  const ShareTarget(this.kind, this.key);

  @override
  bool operator ==(Object other) => other is ShareTarget && other.kind == kind && other.key == key;

  @override
  int get hashCode => Object.hash(kind, key);
}

const _webParam = {ShareKind.track: 't', ShareKind.album: 'al', ShareKind.artist: 'ar', ShareKind.playlist: 'pl', ShareKind.tag: 'tg'};

/// Ссылка для открытия в приложении
String appShareLink(ShareKind kind, String key) =>
    kind == ShareKind.track ? appLinkFor(key) : '$_scheme://${kind.name}/${Uri.encodeComponent(key)}';

/// Ссылка для мессенджеров; null, если страница-переадресация не настроена
String? webShareLink(ShareKind kind, String key, {String base = kShareRedirectUrl}) => base.isEmpty
    ? null
    : '${base.endsWith('/') ? base : '$base/'}?${_webParam[kind]}=${Uri.encodeQueryComponent(key)}';

/// То, что кладётся в буфер по «Скопировать ссылку»: ссылка для мессенджеров, а если её нет — ссылка приложения
String shareLinkText(ShareKind kind, String key) => webShareLink(kind, key) ?? appShareLink(kind, key);

final _trackIdPattern = RegExp(r'^[A-Za-z0-9_\-]+$');
final _tagKeyPattern = RegExp(r'^[^\s|]+\|[A-Za-z0-9_\-]+$');

bool _keyOk(ShareKind kind, String key) => switch (kind) {
      ShareKind.track || ShareKind.playlist => _trackIdPattern.hasMatch(key),
      ShareKind.tag => _tagKeyPattern.hasMatch(key),
      _ => true,
    };

/// Разбирает ссылку любого вида (caveplayer:// или страница-переадресация); null, если это не ссылка Cavey
ShareTarget? shareTargetFromLink(String link) {
  final text = link.trim();
  final app = RegExp('^$_scheme:(?://)?(track|album|artist|playlist|tag)/(.+?)/?\$', caseSensitive: false).firstMatch(text);
  if (app != null) {
    final kind = ShareKind.values.byName(app.group(1)!.toLowerCase());
    String key;
    try {
      key = Uri.decodeComponent(app.group(2)!);
    } catch (_) {
      return null;
    }
    if (key.isEmpty) return null;
    if (!_keyOk(kind, key)) return null;
    return ShareTarget(kind, key);
  }
  final uri = Uri.tryParse(text);
  if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) return null;
  for (final e in _webParam.entries) {
    final v = uri.queryParameters[e.value];
    if (v == null || v.isEmpty) continue;
    if (!_keyOk(e.key, v)) return null;
    return ShareTarget(e.key, v);
  }
  return null;
}

/// Достаёт id трека из ссылки обоих видов; null, если это не ссылка на трек
String? trackIdFromLink(String link) {
  final t = shareTargetFromLink(link);
  return t != null && t.kind == ShareKind.track ? t.key : null;
}

/// Файл, через который вторая копия передаёт ссылку первой (обычный сигнал «покажись» ссылку не несёт)
File pendingLinkFile() => File('${Directory.systemTemp.path}${Platform.pathSeparator}cave-player-link.txt');

/// Вторая копия: оставляет ссылку для первой
void leavePendingLink(String link) {
  try {
    pendingLinkFile().writeAsStringSync(link, flush: true);
  } catch (_) {}
}

/// Первая копия: забирает оставленную ссылку (и удаляет файл)
String? takePendingLink() {
  try {
    final f = pendingLinkFile();
    if (!f.existsSync()) return null;
    final text = f.readAsStringSync().trim();
    f.deleteSync();
    return text.isEmpty ? null : text;
  } catch (_) {
    return null;
  }
}

/// Ссылка среди аргументов запуска
String? linkFromArgs(List<String> args) {
  for (final a in args) {
    if (a.toLowerCase().startsWith('$_scheme:')) return a;
  }
  return null;
}
