// Модуль скачки cave-downloader живёт в отдельном репозитории (kDownloaderRepo).
// Здесь его установка: при первом скачивании берём из релизов последнюю сборку
// с нашей версией протокола, сверяем SHA-256 и кладём в папку приложения.
// Раз в сутки проверяем, не вышла ли новая.
//
// Для разработки: переменная окружения CAVE_DOWNLOADER_EXE=<путь к exe> —
// тогда используется этот файл, без скачивания и обновлений.

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../config.dart';
import '../tools.dart';

/// Сборка модуля из релизов GitHub
class ModuleRelease {
  final String version;
  final String url;

  /// SHA-256 из данных релиза (поле digest); null — искать в файле [shaUrl]
  final String? sha256;
  final String? shaUrl;
  const ModuleRelease(this.version, this.url, {this.sha256, this.shaUrl});
}

class DownloaderModule {
  final Directory dir;
  final String repo;
  final int protocol;

  /// Путь к своей сборке модуля вместо скачанной (для разработки)
  final String? override;

  DownloaderModule(this.dir, {this.repo = kDownloaderRepo, this.protocol = kDownloaderProtocol, String? override})
      : override = override ?? _envOverride();

  static String? _envOverride() {
    final v = Platform.environment['CAVE_DOWNLOADER_EXE']?.trim() ?? '';
    return v.isEmpty ? null : v;
  }

  static const assetName = 'cave-downloader-windows-x64.exe';
  static const checkEvery = Duration(hours: 24);

  File get exe => override != null ? File(override!) : File('${dir.path}${Platform.pathSeparator}cave-downloader.exe');
  File get _stateFile => File('${dir.path}${Platform.pathSeparator}module.json');

  bool get installed => exe.existsSync();

  /// Версия установленного модуля ('' — не установлен или своя сборка)
  String get version => override != null ? 'своя сборка' : (installed ? '${_state()['version'] ?? ''}' : '');

  // Интерфейс спрашивает версию при каждой перерисовке — файл читаем один раз
  Map? _stateCache;
  Map _state() => _stateCache ??= _readState();

  Map _readState() {
    try {
      final j = jsonDecode(_stateFile.readAsStringSync());
      if (j is Map) return j;
    } catch (_) {}
    return const {};
  }

  void _save(String version) {
    final state = {'version': version, 'checked': DateTime.now().toIso8601String()};
    _stateCache = state;
    try {
      _stateFile.writeAsStringSync(jsonEncode(state));
    } catch (_) {}
  }

  /// Модуль на месте; раз в сутки (или при [check]) — обновлён до свежей версии.
  /// Ошибка только если модуля нет совсем: без связи с GitHub работает прежняя версия
  Future<void> ensure(void Function(String) log, {bool check = false}) async {
    if (override != null) {
      if (!installed) throw Exception('Нет файла модуля скачки из CAVE_DOWNLOADER_EXE: $override');
      return;
    }
    if (!Platform.isWindows) {
      throw Exception('Модуль скачки собирается только для Windows. Для разработки укажите путь к своей сборке в CAVE_DOWNLOADER_EXE.');
    }
    if (installed && !check) {
      final checked = DateTime.tryParse('${_state()['checked'] ?? ''}');
      if (checked != null && DateTime.now().difference(checked).abs() < checkEvery) return;
    }
    ModuleRelease? rel;
    String? sha;
    try {
      rel = await latest();
      if (rel != null) sha = rel.sha256 ?? await _shaFromFile(rel.shaUrl);
    } catch (e) {
      if (!installed) throw Exception('Не удалось скачать модуль скачки из $repo: $e');
      log('Не удалось проверить обновления модуля скачки: $e');
      return;
    }
    if (rel == null) {
      if (!installed) throw Exception('В $repo нет сборки модуля скачки для этой версии Cavey (протокол $protocol). Обновите Cavey.');
      _save(version);
      return;
    }
    if (installed && rel.version == version) {
      _save(version);
      return;
    }
    if (sha == null) {
      // Исполняемый файл без контрольной суммы не запускаем
      final why = 'у сборки ${rel.version} нет контрольной суммы SHA-256';
      if (!installed) throw Exception('Модуль скачки не установлен: $why');
      log('Обновление модуля скачки пропущено: $why');
      _save(version);
      return;
    }
    log(installed ? 'Обновляю модуль скачки до ${rel.version}…' : 'Первый запуск: скачиваю модуль скачки ${rel.version}…');
    try {
      await dir.create(recursive: true);
      await Tools.download(rel.url, exe, 'модуль скачки ${rel.version}', log, sha256: sha);
      _save(rel.version);
    } catch (e) {
      if (!installed) rethrow;
      log('Обновить модуль скачки не удалось, работаю на прежней версии: $e');
    }
  }

  static Map<String, String> get _headers =>
      {'Accept': 'application/vnd.github+json', 'User-Agent': 'CavePlayer/${kAppVersion.isEmpty ? 'dev' : kAppVersion}'};

  /// Свежая сборка модуля с нашей версией протокола или null, если такой нет
  Future<ModuleRelease?> latest() async {
    final res = await http
        .get(Uri.parse('https://api.github.com/repos/$repo/releases?per_page=30'), headers: _headers)
        .timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) throw Exception('GitHub ответил ${res.statusCode}');
    final list = jsonDecode(res.body);
    return pick(list is List ? list : const [], protocol);
  }

  /// Из списка релизов GitHub — самая новая обычная сборка v<protocol>.x.y с exe для Windows
  static ModuleRelease? pick(List releases, int protocol) {
    ModuleRelease? best;
    List<int>? bestParts;
    for (final r in releases) {
      if (r is! Map || r['draft'] == true || r['prerelease'] == true) continue;
      final m = RegExp(r'^v(\d+)\.(\d+)\.(\d+)$').firstMatch('${r['tag_name'] ?? ''}');
      if (m == null || int.parse(m[1]!) != protocol) continue;
      final parts = [int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!)];
      if (bestParts != null && _compare(parts, bestParts) <= 0) continue;
      String? url, sha, shaUrl;
      for (final a in (r['assets'] as List? ?? const [])) {
        if (a is! Map) continue;
        if (a['name'] == assetName) {
          url = '${a['browser_download_url'] ?? ''}';
          final d = '${a['digest'] ?? ''}';
          if (d.startsWith('sha256:')) sha = d.substring(7).toLowerCase();
        } else if (a['name'] == '$assetName.sha256') {
          shaUrl = '${a['browser_download_url'] ?? ''}';
        }
      }
      if (url == null || url.isEmpty) continue;
      best = ModuleRelease('${parts[0]}.${parts[1]}.${parts[2]}', url, sha256: sha, shaUrl: shaUrl);
      bestParts = parts;
    }
    return best;
  }

  static int _compare(List<int> a, List<int> b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return a[i].compareTo(b[i]);
    }
    return 0;
  }

  /// Файл вида «<sha256>  <имя>» рядом со сборкой
  static Future<String?> _shaFromFile(String? url) async {
    if (url == null || url.isEmpty) return null;
    final res = await http.get(Uri.parse(url), headers: {'User-Agent': 'CavePlayer'}).timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) return null;
    return parseSha(res.body);
  }

  static String? parseSha(String text) {
    final first = text.trim().split(RegExp(r'\s+')).first.toLowerCase();
    return RegExp(r'^[0-9a-f]{64}$').hasMatch(first) ? first : null;
  }
}
