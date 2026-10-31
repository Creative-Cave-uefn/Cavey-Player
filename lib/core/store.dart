import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Локальные файлы приложения: аккаунты, настройки, кэш библиотеки и обложек.
class AppStore {
  final Directory dir;
  AppStore._(this.dir);

  static Future<AppStore> open() async {
    final base = await getApplicationSupportDirectory();
    final d = Directory('${base.path}${Platform.pathSeparator}cave_player');
    await d.create(recursive: true);
    return AppStore._(d);
  }

  File file(String name) => File('${dir.path}${Platform.pathSeparator}$name');

  Directory sub(String name) {
    final d = Directory('${dir.path}${Platform.pathSeparator}$name');
    d.createSync(recursive: true);
    return d;
  }

  Future<dynamic> readJson(String name) async {
    final f = file(name);
    try {
      if (!await f.exists()) return null;
      return jsonDecode(await f.readAsString());
    } catch (_) {
      // Г6: файл повреждён — берём прошлую удачную копию вместо тихого сброса всего
      try {
        final bak = File('${f.path}.bak');
        if (await bak.exists()) return jsonDecode(await bak.readAsString());
      } catch (_) {}
      return null;
    }
  }

  /// Записи в один файл идут по очереди: раньше десять правок подряд писали в один .tmp одновременно
  /// и спотыкались друг о друга («файл занят другим процессом»)
  final Map<String, Future<void>> _writes = {};

  Future<void> writeJson(String name, Object value) {
    final text = jsonEncode(value); // снимок на момент вызова, а не на момент записи
    final prev = _writes[name] ?? Future<void>.value();
    final next = prev.catchError((Object _) {}).then((_) => _write(name, text));
    _writes[name] = next;
    return next.whenComplete(() {
      if (identical(_writes[name], next)) _writes.remove(name);
    });
  }

  Future<void> _write(String name, String text) async {
    final f = file(name);
    final tmp = File('${f.path}.tmp');
    for (var attempt = 0;; attempt++) {
      try {
        await tmp.writeAsString(text, flush: true);
        try {
          // Г6: прошлая версия остаётся рядом как .bak (если она читается)
          if (await f.exists()) {
            await f.copy('${f.path}.bak');
          }
        } catch (_) {}
        try {
          await tmp.rename(f.path); // в Windows это заменяет существующий файл
        } on FileSystemException {
          if (await f.exists()) await f.delete();
          await tmp.rename(f.path);
        }
        return;
      } on FileSystemException {
        // Файл на мгновение занят (антивирус, индексация): подождём и повторим
        if (attempt >= 4) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 150 * (attempt + 1)));
      }
    }
  }
}

/// Настройки этого компьютера. Общие данные (плейлисты, лайки) лежат на Диске.
class Settings {
  String clientId = '';
  String clientSecret = '';
  String? hubId;
  String? hubEmail;
  String? libFileId;

  /// Человек сам нажал «Отключиться от библиотеки»: сами её больше не ищем, пока он не подключится вручную
  bool autoJoinDisabled = false;

  /// Своя папка cave-data (если задана вручную). Иначе ищется внутри общей папки
  String? dataFolderOverride;
  String? primaryEmail;
  Map<String, String> sourceAccess = {};
  double volume = 80;
  String? lastScan;
  String? hubSourceChecked;
  int cacheLimitMb = 2048;
  bool offlineLiked = false;
  Set<String> offlinePlaylists = {};
  bool useZotify = false;
  bool useSockseek = false;
  String zotifyExecutable = 'zotify';
  bool discord = true;
  bool betaUpdates = false; // получать бета-версии
  bool trayOnClose = true; // крестик прячет окно в трей, музыка играет дальше
  bool trayAsked = false; // уже спрашивали, что делать по крестику
  bool globalMediaKeys = true; // медиаклавиши работают и когда окно не активно
  String? bellSeen; // когда человек последний раз открывал колокольчик в «Компании» (ISO)
  String? noticeSeen; // время последнего показанного уведомления «Вам» (ISO)
  int crossfadeSec = 3; // плавный переход между треками, секунд (0 — выключен)
  bool artistsDesc = false; // «Исполнители» сортируются Я–А
  bool albumsDesc = false; // «Альбомы» сортируются Я–А

  /// Личные настройки вида (сетка или список, размеры, вид плейлистов в боковой панели): ключ → значение
  Map<String, String> view = {};
  String viewOf(String key, String def) => view[key] ?? def;
  double viewNum(String key, double def) => double.tryParse(view[key] ?? '') ?? def;

  /// Что играло при закрытии: очередь, место в ней и позиция
  Map<String, dynamic>? session;

  Map<String, dynamic> toJson() => {
        'clientId': clientId,
        'clientSecret': clientSecret,
        'hubId': hubId,
        'hubEmail': hubEmail,
        'libFileId': libFileId,
        'autoJoinDisabled': autoJoinDisabled,
        'dataFolderOverride': dataFolderOverride,
        'primaryEmail': primaryEmail,
        'sourceAccess': sourceAccess,
        'volume': volume,
        'lastScan': lastScan,
        'hubSourceChecked': hubSourceChecked,
        'cacheLimitMb': cacheLimitMb,
        'offlineLiked': offlineLiked,
        'offlinePlaylists': offlinePlaylists.toList(),
        'useZotify': useZotify,
        'useSockseek': useSockseek,
        'zotifyExecutable': zotifyExecutable,
        'discord': discord,
        'betaUpdates': betaUpdates,
        'trayOnClose': trayOnClose,
        'trayAsked': trayAsked,
        'globalMediaKeys': globalMediaKeys,
        'crossfadeSec': crossfadeSec,
        'noticeSeen': noticeSeen,
        'bellSeen': bellSeen,
        'artistsDesc': artistsDesc,
        'albumsDesc': albumsDesc,
        'view': view,
        if (session != null) 'session': session,
      };

  static Settings fromJson(dynamic j) {
    final s = Settings();
    if (j is! Map) return s;
    s.clientId = (j['clientId'] as String?) ?? '';
    s.clientSecret = (j['clientSecret'] as String?) ?? '';
    s.hubId = j['hubId'] as String?;
    s.hubEmail = j['hubEmail'] as String?;
    s.libFileId = j['libFileId'] as String?;
    s.autoJoinDisabled = j['autoJoinDisabled'] == true;
    s.dataFolderOverride = j['dataFolderOverride'] as String?;
    s.primaryEmail = j['primaryEmail'] as String?;
    final sa = j['sourceAccess'];
    if (sa is Map) s.sourceAccess = sa.map((k, v) => MapEntry('$k', '$v'));
    s.volume = ((j['volume'] as num?) ?? 80).toDouble();
    s.lastScan = j['lastScan'] as String?;
    s.hubSourceChecked = j['hubSourceChecked'] as String?;
    s.cacheLimitMb = (j['cacheLimitMb'] as num?)?.toInt() ?? 2048;
    s.offlineLiked = j['offlineLiked'] == true;
    s.offlinePlaylists = {for (final x in (j['offlinePlaylists'] as List? ?? const [])) '$x'};
    s.useZotify = j['useZotify'] == true;
    s.useSockseek = j['useSockseek'] == true;
    s.zotifyExecutable = (j['zotifyExecutable'] as String?) ?? 'zotify';
    s.discord = j['discord'] != false;
    s.betaUpdates = j['betaUpdates'] == true;
    s.trayOnClose = j['trayOnClose'] != false;
    s.trayAsked = j['trayAsked'] == true;
    s.globalMediaKeys = j['globalMediaKeys'] != false;
    s.noticeSeen = j['noticeSeen'] as String?;
    s.bellSeen = j['bellSeen'] as String?;
    s.crossfadeSec = ((j['crossfadeSec'] as num?)?.toInt() ?? 3).clamp(0, 10).toInt();
    s.artistsDesc = j['artistsDesc'] == true;
    s.albumsDesc = j['albumsDesc'] == true;
    final vw = j['view'];
    if (vw is Map) s.view = vw.map((k, v) => MapEntry('$k', '$v'));
    final ses = j['session'];
    if (ses is Map) s.session = ses.map((k, v) => MapEntry('$k', v));
    return s;
  }
}


