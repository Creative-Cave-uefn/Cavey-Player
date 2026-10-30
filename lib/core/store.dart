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
      return null;
    }
  }

  /// Записи одного файла по очереди: раньше одновременные сохранения (например,
  /// pending_ops.json при быстрых правках) мешали друг другу через общий .tmp
  final Map<String, Future<void>> _writes = {};

  Future<void> writeJson(String name, Object value) {
    final text = jsonEncode(value); // снимок данных на момент вызова
    final prev = _writes[name] ?? Future<void>.value();
    late final Future<void> next;
    next = prev.catchError((Object _) {}).then((_) => _write(name, text)).whenComplete(() {
      if (identical(_writes[name], next)) _writes.remove(name);
    });
    _writes[name] = next;
    return next;
  }

  Future<void> _write(String name, String text) async {
    final f = file(name);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(text, flush: true);
    try {
      // rename поверх существующего файла на Windows работает, а удаление заранее
      // оставляло окно, когда файла нет совсем
      await tmp.rename(f.path);
    } on FileSystemException {
      // Файл держит антивирус или индексатор — пробуем ещё раз чуть позже
      await Future<void>.delayed(const Duration(milliseconds: 200));
      if (await f.exists()) await f.delete();
      await tmp.rename(f.path);
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
  String? primaryEmail;
  Map<String, String> sourceAccess = {};
  double volume = 80;
  String? lastScan;
  String? hubSourceChecked;
  int cacheLimitMb = 2048;
  bool offlineLiked = false;
  Set<String> offlinePlaylists = {};
  bool discord = true;
  bool normalize = false; // выравнивать громкость треков
  bool betaUpdates = false; // получать бета-версии
  bool trayOnClose = true; // крестик прячет окно в трей, музыка играет дальше
  bool trayAsked = false; // уже спрашивали, что делать по крестику
  bool artistsDesc = false; // «Исполнители» сортируются Я–А
  bool albumsDesc = false; // «Альбомы» сортируются Я–А

  /// Что играло при закрытии: очередь, место в ней и позиция
  Map<String, dynamic>? session;

  Map<String, dynamic> toJson() => {
        'clientId': clientId,
        'clientSecret': clientSecret,
        'hubId': hubId,
        'hubEmail': hubEmail,
        'libFileId': libFileId,
        'primaryEmail': primaryEmail,
        'sourceAccess': sourceAccess,
        'volume': volume,
        'lastScan': lastScan,
        'hubSourceChecked': hubSourceChecked,
        'cacheLimitMb': cacheLimitMb,
        'offlineLiked': offlineLiked,
        'offlinePlaylists': offlinePlaylists.toList(),
        'discord': discord,
        'normalize': normalize,
        'betaUpdates': betaUpdates,
        'trayOnClose': trayOnClose,
        'trayAsked': trayAsked,
        'artistsDesc': artistsDesc,
        'albumsDesc': albumsDesc,
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
    s.primaryEmail = j['primaryEmail'] as String?;
    final sa = j['sourceAccess'];
    if (sa is Map) s.sourceAccess = sa.map((k, v) => MapEntry('$k', '$v'));
    s.volume = ((j['volume'] as num?) ?? 80).toDouble();
    s.lastScan = j['lastScan'] as String?;
    s.hubSourceChecked = j['hubSourceChecked'] as String?;
    s.cacheLimitMb = (j['cacheLimitMb'] as num?)?.toInt() ?? 2048;
    s.offlineLiked = j['offlineLiked'] == true;
    s.offlinePlaylists = {for (final x in (j['offlinePlaylists'] as List? ?? const [])) '$x'};
    s.discord = j['discord'] != false;
    s.normalize = j['normalize'] == true;
    s.betaUpdates = j['betaUpdates'] == true;
    s.trayOnClose = j['trayOnClose'] != false;
    s.trayAsked = j['trayAsked'] == true;
    s.artistsDesc = j['artistsDesc'] == true;
    s.albumsDesc = j['albumsDesc'] == true;
    final ses = j['session'];
    if (ses is Map) s.session = ses.map((k, v) => MapEntry('$k', v));
    return s;
  }
}
