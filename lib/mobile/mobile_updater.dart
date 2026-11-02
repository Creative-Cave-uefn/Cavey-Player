import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../config.dart';
import '../core/log.dart';
import '../core/updater.dart' show Updater;

/// Свежая сборка для телефона.
class MobileBuild {
  final String version;
  final String notes;
  final String url;
  final int size;
  final String? sha256;
  const MobileBuild({
    required this.version,
    required this.notes,
    required this.url,
    required this.size,
    this.sha256,
  });
}

/// Автообновление Android-версии. Сборки лежат рядом с Windows-версиями, в cave-player-releases,
/// но с тегами `android-v<версия>` и как пререлиз — Windows-плеер их не видит.
/// Ставить обновление поверх можно, пока подпись APK та же (в CI она всегда одна).
class MobileUpdater extends ChangeNotifier {
  static const _channel = MethodChannel('cavey/installer');
  static final _tag = RegExp(r'^android-v(\d+(?:\.\d+)*)$');
  static const _asset = 'CaveyPlayer.apk';

  bool get enabled => kAppVersion.isNotEmpty && Platform.isAndroid;

  MobileBuild? available;
  bool checking = false;
  bool upToDate = false;
  double? progress;
  String? error;
  DateTime? checkedAt;
  Timer? _timer;

  void start() {
    if (!enabled) return;
    unawaited(check());
    _timer = Timer.periodic(const Duration(hours: 4), (_) => check());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> check({bool manual = false}) async {
    if (!enabled || checking || progress != null) return;
    checking = true;
    error = null;
    if (manual) notifyListeners();
    final client = http.Client();
    try {
      final res = await client
          .get(
            Uri.parse('https://api.github.com/repos/$kReleasesRepo/releases?per_page=40'),
            headers: {'Accept': 'application/vnd.github+json', 'User-Agent': 'CaveyAndroid/$kAppVersion'},
          )
          .timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) throw 'GitHub ответил ${res.statusCode}';
      MobileBuild? best;
      for (final r in (jsonDecode(res.body) as List).whereType<Map>()) {
        if (r['draft'] == true) continue;
        final m = _tag.firstMatch('${r['tag_name']}');
        if (m == null) continue;
        final v = m.group(1)!;
        if (best != null && !Updater.isNewer(v, best.version)) continue;
        final asset = (r['assets'] as List? ?? const [])
            .whereType<Map>()
            .where((a) => a['name'] == _asset)
            .firstOrNull;
        if (asset == null) continue;
        final digest = '${asset['digest'] ?? ''}';
        best = MobileBuild(
          version: v,
          notes: _cleanNotes('${r['body'] ?? ''}'),
          url: '${asset['browser_download_url']}',
          size: (asset['size'] as num?)?.toInt() ?? 0,
          sha256: digest.startsWith('sha256:') ? digest.substring(7) : null,
        );
      }
      checkedAt = DateTime.now();
      if (best != null && Updater.isNewer(best.version, kAppVersion)) {
        available = best;
        upToDate = false;
        AppLog.info('Обновления Android: доступна ${best.version}, у меня $kAppVersion');
      } else {
        available = null;
        upToDate = true;
      }
    } catch (e) {
      AppLog.info('Обновления Android: проверка не удалась: $e');
      if (manual) error = 'Не удалось проверить обновления';
    } finally {
      client.close();
      checking = false;
      notifyListeners();
    }
  }

  static String _cleanNotes(String s) {
    final skip = RegExp(r'^\s*(Co-Authored-By:|Claude-Session:|Signed-off-by:)', caseSensitive: false);
    return s.split('\n').where((l) => !skip.hasMatch(l)).join('\n').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  }

  /// Скачивает APK и открывает системный установщик. Возвращает false, если нужно разрешение:
  /// тогда открывается экран настроек «Установка неизвестных приложений».
  Future<bool> install() async {
    final build = available;
    if (build == null || progress != null) return false;
    error = null;
    if (await _channel.invokeMethod<bool>('canInstall') != true) {
      await _channel.invokeMethod<void>('openSettings');
      return false;
    }
    progress = 0;
    notifyListeners();
    final client = http.Client();
    try {
      final dir = Directory('${(await getTemporaryDirectory()).path}/updates');
      if (dir.existsSync()) dir.deleteSync(recursive: true);
      dir.createSync(recursive: true);
      final part = File('${dir.path}/$_asset.part');
      final req = http.Request('GET', Uri.parse(build.url))..headers['User-Agent'] = 'CaveyAndroid/$kAppVersion';
      final res = await client.send(req).timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) throw 'Сервер ответил ${res.statusCode}';
      final total = res.contentLength ?? build.size;
      final sink = part.openWrite();
      var got = 0;
      await for (final chunk in res.stream.timeout(const Duration(seconds: 30))) {
        sink.add(chunk);
        got += chunk.length;
        if (total > 0) {
          final p = got / total;
          if (p - (progress ?? 0) >= 0.01) {
            progress = p.clamp(0.0, 1.0);
            notifyListeners();
          }
        }
      }
      await sink.close();
      if (build.size > 0 && got != build.size) throw 'Файл скачался не полностью';
      if (build.sha256 != null) {
        final sum = (await crypto.sha256.bind(part.openRead()).first).toString();
        if (sum.toLowerCase() != build.sha256!.toLowerCase()) throw 'Контрольная сумма не совпала';
      }
      final apk = await part.rename('${dir.path}/$_asset');
      await _channel.invokeMethod<bool>('install', {'path': apk.path});
      return true;
    } catch (e) {
      AppLog.info('Обновления Android: установка не удалась: $e');
      error = 'Не удалось скачать обновление: $e';
      return false;
    } finally {
      client.close();
      progress = null;
      notifyListeners();
    }
  }
}
