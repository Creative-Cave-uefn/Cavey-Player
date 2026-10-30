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

  Future<void> writeJson(String name, Object value) async {
    final f = file(name);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(value), flush: true);
    if (await f.exists()) await f.delete();
    await tmp.rename(f.path);
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
  bool betaUpdates = false; // получать бета-версии

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
        'betaUpdates': betaUpdates,
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
    s.betaUpdates = j['betaUpdates'] == true;
    return s;
  }
}
