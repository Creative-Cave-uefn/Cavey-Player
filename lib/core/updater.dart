// Автообновление: раз в несколько часов смотрим последний релиз в публичном
// репозитории, в фоне скачиваем установщик и ставим его тихо — по кнопке
// или сами при следующем запуске.
//
// Бета-версии: ветка beta публикует пререлизы «beta-v<версия>». Кто включил
// «Получать бета-версии», получает самую свежую из обычной и бета-версии.
// Выключил — вернётся на обычную со следующим обычным релизом (или сразу кнопкой).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config.dart';
import 'log.dart';
import 'store.dart';

enum UpdateState { idle, checking, downloading, ready, upToDate, error }

class Updater extends ChangeNotifier {
  final AppStore store;
  UpdateState state = UpdateState.idle;
  String? latest;
  double progress = 0;
  String? error;
  DateTime? lastCheck;
  Timer? _timer;

  Updater(this.store);

  static const _assetName = 'CavePlayer-Setup.exe';
  static final _betaTag = RegExp(r'^beta-v(\d+(?:\.\d+)*)$');

  /// Получать бета-версии (настройка «Получать бета-версии»)
  bool beta = false;

  /// Последняя бета-версия, если проверяли
  String? latestBeta;

  /// Сейчас стоит бета-сборка
  bool get isBeta => kBuildBeta;

  Future<void> setBeta(bool on) async {
    beta = on;
    notifyListeners();
    if (on) await check();
  }

  /// Самая свежая бета: пререлиз beta-v… с установщиком
  Future<Map<String, dynamic>?> _latestBetaRelease() async {
    final res = await http
        .get(
          Uri.parse('https://api.github.com/repos/$kReleasesRepo/releases?per_page=40'),
          headers: {'Accept': 'application/vnd.github+json', 'User-Agent': 'CavePlayer/$kAppVersion'},
        )
        .timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) {
      AppLog.warn('Бета-версии: $kReleasesRepo ответил ${res.statusCode}');
      return null;
    }
    Map<String, dynamic>? best;
    var bestV = '';
    for (final r in (jsonDecode(res.body) as List).whereType<Map<String, dynamic>>()) {
      if (r['prerelease'] != true) continue;
      final m = _betaTag.firstMatch('${r['tag_name']}');
      if (m == null) continue;
      final hasAsset = (r['assets'] as List? ?? const []).any((a) => a is Map && a['name'] == _assetName);
      if (hasAsset && (bestV.isEmpty || isNewer(m.group(1)!, bestV))) {
        best = r;
        bestV = m.group(1)!;
      }
    }
    latestBeta = best == null ? null : bestV;
    return best;
  }

  /// Обновления работают в установленной версии, собранной в GitHub Actions
  bool get enabled => kAppVersion.isNotEmpty && Platform.isWindows;
  String get currentVersion => kAppVersion.isEmpty ? 'сборка для разработки' : kAppVersion;

  /// Сравнение версий вида 0.2.15
  static bool isNewer(String a, String b) {
    List<int> parts(String v) => v.split('.').map((x) => int.tryParse(x) ?? 0).toList();
    final pa = parts(a), pb = parts(b);
    for (var i = 0; i < 4; i++) {
      final x = i < pa.length ? pa[i] : 0, y = i < pb.length ? pb[i] : 0;
      if (x != y) return x > y;
    }
    return false;
  }

  /// Вызывается до запуска интерфейса. Если обновление уже скачано —
  /// запускает его установку и возвращает true (приложение закроется,
  /// установщик откроет новую версию сам).
  Future<bool> installPendingOnStart() async {
    if (!enabled) return false;
    final meta = await store.readJson('update.json');
    if (meta is! Map) return false;
    final version = meta['version'] as String?;
    final path = meta['path'] as String?;
    if (version == null || path == null || !isNewer(version, kAppVersion)) {
      await _forget(path);
      return false;
    }
    // Одна попытка: если установщик не справился, не зацикливаемся на перезапусках
    if (meta['attempted'] == true || !File(path).existsSync()) return false;
    await store.writeJson('update.json', {...meta, 'attempted': true});
    await _launch(path);
    return true;
  }

  void start() {
    if (!enabled) return;
    unawaited(check());
    _timer = Timer.periodic(const Duration(hours: 4), (_) => check());
  }

  Future<void> check() async {
    if (!enabled) {
      state = UpdateState.error;
      error = 'Обновления работают только в версии, установленной через CavePlayer-Setup.exe';
      notifyListeners();
      return;
    }
    if (state == UpdateState.checking || state == UpdateState.downloading) return;
    state = UpdateState.checking;
    error = null;
    notifyListeners();
    try {
      // Смотрим все места, где могут лежать релизы, и берём самую свежую версию с установщиком
      Map<String, dynamic>? j;
      var tag = '';
      var reachable = 0;
      for (final repo in kReleasesRepos) {
        final res = await http.get(
          Uri.parse('https://api.github.com/repos/$repo/releases/latest'),
          headers: {'Accept': 'application/vnd.github+json', 'User-Agent': 'CavePlayer/$kAppVersion'},
        );
        // 404 — репозитория нет, он приватный или релизов ещё нет
        if (res.statusCode == 404) continue;
        if (res.statusCode != 200) {
          AppLog.warn('Обновления: $repo ответил ${res.statusCode}');
          continue;
        }
        reachable++;
        final r = jsonDecode(res.body) as Map<String, dynamic>;
        final t = ((r['tag_name'] as String?) ?? '').replaceFirst(RegExp(r'^v'), '');
        final hasAsset = (r['assets'] as List? ?? const []).any((a) => a is Map && a['name'] == _assetName);
        if (hasAsset && (tag.isEmpty || isNewer(t, tag))) {
          tag = t;
          j = r;
        }
      }
      if (beta) {
        try {
          final b = await _latestBetaRelease();
          if (b != null && (tag.isEmpty || isNewer(latestBeta!, tag))) {
            tag = latestBeta!;
            j = b;
          }
        } catch (e) {
          AppLog.warn('Не получилось проверить бета-версии', e);
        }
      }
      lastCheck = DateTime.now();
      if (j == null) {
        state = UpdateState.upToDate; // опубликованных обновлений пока нет
        AppLog.info('Обновления: доступных релизов нет (проверено мест: $reachable из ${kReleasesRepos.length})');
        notifyListeners();
        return;
      }
      latest = tag;
      AppLog.info('Обновления: последняя версия $tag, у меня $kAppVersion');
      if (tag.isEmpty || !isNewer(tag, kAppVersion)) {
        state = UpdateState.upToDate;
        notifyListeners();
        return;
      }
      final meta = await store.readJson('update.json');
      if (meta is Map && meta['version'] == tag && File('${meta['path']}').existsSync()) {
        state = UpdateState.ready;
        notifyListeners();
        return;
      }
      Map? asset;
      for (final a in (j['assets'] as List? ?? const [])) {
        if (a is Map && a['name'] == _assetName) asset = a;
      }
      if (asset == null) throw Exception('в релизе $tag нет $_assetName');
      final path = await _download('${asset['browser_download_url']}', tag, (asset['size'] as num?)?.toInt() ?? 0);
      await store.writeJson('update.json', {'version': tag, 'path': path});
      state = UpdateState.ready;
    } catch (e) {
      state = UpdateState.error;
      error = 'Не получилось проверить обновления: $e';
    }
    notifyListeners();
  }

  /// Ставит последнюю обычную версию, даже если она старее установленной беты.
  /// Приложение закроется, установщик откроет обычную версию сам.
  Future<void> installStable() async {
    if (!enabled || state == UpdateState.downloading) return;
    error = null;
    try {
      Map? release;
      var tag = '';
      for (final repo in kReleasesRepos) {
        final res = await http.get(
          Uri.parse('https://api.github.com/repos/$repo/releases/latest'),
          headers: {'Accept': 'application/vnd.github+json', 'User-Agent': 'CavePlayer/$kAppVersion'},
        );
        if (res.statusCode != 200) continue;
        final r = jsonDecode(res.body) as Map<String, dynamic>;
        final t = ((r['tag_name'] as String?) ?? '').replaceFirst(RegExp(r'^v'), '');
        final hasAsset = (r['assets'] as List? ?? const []).any((a) => a is Map && a['name'] == _assetName);
        if (hasAsset && (tag.isEmpty || isNewer(t, tag))) {
          tag = t;
          release = r;
        }
      }
      if (release == null) throw Exception('обычных версий пока нет');
      Map? asset;
      for (final a in (release['assets'] as List? ?? const [])) {
        if (a is Map && a['name'] == _assetName) asset = a;
      }
      latest = tag;
      final path = await _download('${asset!['browser_download_url']}', tag, (asset['size'] as num?)?.toInt() ?? 0);
      await _forget(null);
      AppLog.info('Возвращаюсь на обычную версию $tag');
      await _launch(path);
      exit(0);
    } catch (e) {
      state = UpdateState.error;
      error = 'Не получилось вернуться на обычную версию: $e';
      notifyListeners();
    }
  }

  Future<String> _download(String url, String version, int size) async {
    state = UpdateState.downloading;
    progress = 0;
    notifyListeners();
    final file = File('${Directory.systemTemp.path}${Platform.pathSeparator}CavePlayer-Setup-$version.exe');
    final part = File('${file.path}.part');
    final client = http.Client();
    try {
      final res = await client.send(http.Request('GET', Uri.parse(url))..headers['User-Agent'] = 'CavePlayer/$kAppVersion');
      if (res.statusCode != 200) throw Exception('загрузка ответила ${res.statusCode}');
      final total = res.contentLength ?? size;
      final sink = part.openWrite();
      var got = 0;
      await for (final chunk in res.stream) {
        sink.add(chunk);
        got += chunk.length;
        if (total > 0) {
          final p = got / total;
          if (p - progress >= 0.02 || p >= 1) {
            progress = p;
            notifyListeners();
          }
        }
      }
      await sink.close();
      if (await file.exists()) await file.delete();
      await part.rename(file.path);
      return file.path;
    } finally {
      client.close();
    }
  }

  /// Ставит скачанное обновление: закрывает приложение, установщик откроет его снова
  Future<void> installNow() async {
    final meta = await store.readJson('update.json');
    if (meta is! Map || meta['path'] == null) return;
    await store.writeJson('update.json', {...meta, 'attempted': true});
    await _launch('${meta['path']}');
    exit(0);
  }

  Future<void> _launch(String path) async {
    await Process.start(
      path,
      ['/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CLOSEAPPLICATIONS'],
      mode: ProcessStartMode.detached,
    );
  }

  Future<void> _forget(String? path) async {
    try {
      if (path != null && File(path).existsSync()) await File(path).delete();
      final f = store.file('update.json');
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}
