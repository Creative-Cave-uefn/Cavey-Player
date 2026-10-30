import 'dart:io';

// Ссылки на треки: caveplayer://track/<id> открывает приложение на этом треке.
// В мессенджерах такие ссылки не кликабельны, поэтому есть и обычная https-ссылка на страницу-переадресацию
// (docs/open/index.html), которая сама открывает caveplayer://.

/// Адрес страницы-переадресации (с косой чертой на конце). Пусто — страница ещё не опубликована.
/// Задаётся при сборке: --dart-define=SHARE_URL=https://…/open/
const kShareRedirectUrl = String.fromEnvironment('SHARE_URL');

const _scheme = 'caveplayer';

/// Ссылка для открытия в приложении
String appLinkFor(String trackId) => '$_scheme://track/$trackId';

/// Ссылка для мессенджеров; null, если страница-переадресация не настроена
String? webLinkFor(String trackId, {String base = kShareRedirectUrl}) =>
    base.isEmpty ? null : '${base.endsWith('/') ? base : '$base/'}?t=${Uri.encodeQueryComponent(trackId)}';

/// Достаёт id трека из ссылки обоих видов; null, если это не ссылка на трек
String? trackIdFromLink(String link) {
  final text = link.trim();
  final app = RegExp('^$_scheme:(?://)?track/([A-Za-z0-9_\\-]+)/?\$', caseSensitive: false).firstMatch(text);
  if (app != null) return app.group(1);
  final uri = Uri.tryParse(text);
  final t = uri?.queryParameters['t'];
  if (uri != null && (uri.scheme == 'https' || uri.scheme == 'http') && t != null && RegExp(r'^[A-Za-z0-9_\-]+$').hasMatch(t)) return t;
  return null;
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
