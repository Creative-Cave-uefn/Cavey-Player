// Автообновление: раз в несколько часов смотрим последний релиз в публичном
// репозитории, в фоне скачиваем установщик и ставим его тихо — по кнопке
// или сами при следующем запуске.
//
// Тестовые сборки: каждая ветка, кроме main, собирается в пререлиз
// «test-<ветка>-v<версия>». Обычные версии их не видят; в настройках можно
// поставить любую. Тестовая сборка дальше обновляется сборками своей ветки,
// а когда ветку удалят — возвращается к обычным версиям.
//
// Бета-версии: ветка beta публикует пререлизы «beta-v<версия>». Кто включил
// «Получать бета-версии», получает самую свежую из обычной и бета-версии.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config.dart';
import 'log.dart';
import 'store.dart';

enum UpdateState { idle, checking, downloading, ready, upToDate, error }

/// Одна сборка из релизов: обычная версия или тестовая сборка ветки
class BuildInfo {
  final String version;
  final String branch; // пусто — обычная версия
  final String slug; // имя ветки в теге
  final String notes;
  final DateTime? published;
  final String url;
  final int size;
  final bool beta;

  const BuildInfo({
    required this.version,
    required this.branch,
    required this.slug,
    required this.notes,
    required this.published,
    required this.url,
    required this.size,
    this.beta = false,
  });

  /// Обычная версия для всех (не бета и не тестовая сборка ветки)
  bool get stable => branch.isEmpty && !beta;

  /// Первая строка описания — обычно заголовок коммита
  String get summary => notes.split('\n').firstWhere((l) => l.trim().isNotEmpty, orElse: () => '').trim();
}

class Updater extends ChangeNotifier {
  final AppStore store;
  UpdateState state = UpdateState.idle;
  String? latest;
  double progress = 0;
  String? error;
  DateTime? lastCheck;
  Timer? _timer;

  /// Тестовые сборки для списка в настройках
  List<BuildInfo> testBuilds = const [];
  bool loadingBuilds = false;
  String? buildsError;

  /// Сейчас ставим выбранную вручную сборку
  BuildInfo? installing;

  Updater(this.store);

  static const _assetName = 'CavePlayer-Setup.exe';
  static final _testTag = RegExp(r'^test-(.+)-v(\d+(?:\.\d+)*)$');
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
  static Map<String, String> get _headers =>
      {'Accept': 'application/vnd.github+json', 'User-Agent': 'CavePlayer/${kAppVersion.isEmpty ? 'dev' : kAppVersion}'};

  /// Обновления работают в установленной версии, собранной в GitHub Actions
  bool get enabled => kAppVersion.isNotEmpty && Platform.isWindows;
  String get currentVersion => kAppVersion.isEmpty ? 'сборка для разработки' : kAppVersion;

  /// Эта программа — тестовая сборка ветки
  bool get isTestBuild => kBuildChannel.isNotEmpty;
  String get channel => kBuildChannel;
  static String slugOf(String branch) {
    final s = branch.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '');
    return s.isEmpty ? 'branch' : s;
  }

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

  // ---------- где лежат сборки ----------

  static Map? _asset(Map release) {
    for (final a in (release['assets'] as List? ?? const [])) {
      if (a is Map && a['name'] == _assetName) return a;
    }
    return null;
  }

  /// Самая свежая обычная версия во всех местах, где лежат релизы
  Future<BuildInfo?> _latestStable() async {
    BuildInfo? best;
    var reachable = 0;
    for (final repo in kReleasesRepos) {
      final res = await http
          .get(Uri.parse('https://api.github.com/repos/$repo/releases/latest'), headers: _headers)
          .timeout(const Duration(seconds: 20));
      // 404 — репозитория нет, он приватный или релизов ещё нет
      if (res.statusCode == 404) continue;
      if (res.statusCode != 200) {
        AppLog.warn('Обновления: $repo ответил ${res.statusCode}');
        continue;
      }
      reachable++;
      final r = jsonDecode(res.body) as Map<String, dynamic>;
      final v = ((r['tag_name'] as String?) ?? '').replaceFirst(RegExp(r'^v'), '');
      final a = _asset(r);
      if (a == null || v.isEmpty) continue;
      if (best == null || isNewer(v, best.version)) {
        best = BuildInfo(
          version: v,
          branch: '',
          slug: '',
          notes: (r['body'] as String?) ?? '',
          published: DateTime.tryParse('${r['published_at']}'),
          url: '${a['browser_download_url']}',
          size: (a['size'] as num?)?.toInt() ?? 0,
        );
      }
    }
    if (best == null) AppLog.info('Обновления: обычных релизов нет (проверено мест: $reachable из ${kReleasesRepos.length})');
    return best;
  }

  /// Пререлизы публичного репозитория: тестовые сборки веток и бета-версии
  Future<List<Map>> _fetchPrereleases() async {
    final res = await http
        .get(Uri.parse('https://api.github.com/repos/$kReleasesRepo/releases?per_page=60'), headers: _headers)
        .timeout(const Duration(seconds: 20));
    if (res.statusCode == 404) return const [];
    if (res.statusCode != 200) throw HttpException('GitHub ответил ${res.statusCode}');
    return [for (final r in (jsonDecode(res.body) as List).whereType<Map>()) if (r['prerelease'] == true) r];
  }

  /// Тестовые сборки (test-*), новые сверху
  static List<BuildInfo> _testBuildsFrom(List<Map> releases) {
    final list = <BuildInfo>[];
    for (final r in releases) {
      final m = _testTag.firstMatch('${r['tag_name']}');
      final a = _asset(r);
      if (m == null || a == null) continue;
      // Название вида «Тест: feature/x · 0.2.40» — в нём настоящее имя ветки
      final title = '${r['name'] ?? ''}';
      final named = RegExp(r'^Тест:\s*(.+?)\s*·').firstMatch(title)?.group(1);
      list.add(BuildInfo(
        version: m.group(2)!,
        branch: (named == null || named.isEmpty) ? m.group(1)! : named,
        slug: m.group(1)!,
        notes: (r['body'] as String?) ?? '',
        published: DateTime.tryParse('${r['published_at']}'),
        url: '${a['browser_download_url']}',
        size: (a['size'] as num?)?.toInt() ?? 0,
      ));
    }
    list.sort((a, b) => isNewer(a.version, b.version) ? -1 : (isNewer(b.version, a.version) ? 1 : 0));
    return list;
  }

  /// Самая свежая бета (beta-v*)
  static BuildInfo? _latestBetaFrom(List<Map> releases) {
    BuildInfo? best;
    for (final r in releases) {
      final m = _betaTag.firstMatch('${r['tag_name']}');
      final a = _asset(r);
      if (m == null || a == null) continue;
      final v = m.group(1)!;
      if (best != null && !isNewer(v, best.version)) continue;
      best = BuildInfo(
        version: v,
        branch: '',
        slug: 'beta',
        beta: true,
        notes: (r['body'] as String?) ?? '',
        published: DateTime.tryParse('${r['published_at']}'),
        url: '${a['browser_download_url']}',
        size: (a['size'] as num?)?.toInt() ?? 0,
      );
    }
    return best;
  }

  /// Обновляет список тестовых сборок для настроек
  Future<void> loadTestBuilds() async {
    if (loadingBuilds) return;
    loadingBuilds = true;
    buildsError = null;
    notifyListeners();
    try {
      final pre = await _fetchPrereleases();
      testBuilds = _testBuildsFrom(pre);
      latestBeta = _latestBetaFrom(pre)?.version;
    } catch (e) {
      buildsError = 'Не получилось загрузить список: $e';
    }
    loadingBuilds = false;
    notifyListeners();
  }

  // ---------- автообновление ----------

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
      BuildInfo? target;
      List<Map>? pre;
      if (isTestBuild || beta) {
        pre = await _fetchPrereleases();
        testBuilds = _testBuildsFrom(pre);
        latestBeta = _latestBetaFrom(pre)?.version;
      }
      if (isTestBuild) {
        // Тестовая сборка следит за своей веткой
        final mine = slugOf(channel);
        target = testBuilds.where((b) => b.slug == mine).firstOrNull;
        if (target == null) AppLog.info('Обновления: тестовых сборок ветки $channel больше нет, слежу за обычными версиями');
      }
      if (target == null) {
        // Обычная версия, а с галочкой «бета» — самая свежая из обычной и беты
        target = await _latestStable();
        final b = pre == null || !beta ? null : _latestBetaFrom(pre);
        if (b != null && (target == null || isNewer(b.version, target.version))) target = b;
      }
      lastCheck = DateTime.now();
      if (target == null) {
        state = UpdateState.upToDate; // опубликованных обновлений пока нет
        notifyListeners();
        return;
      }
      latest = target.version;
      AppLog.info('Обновления: последняя версия ${target.version}'
          '${target.beta ? ' (бета)' : target.stable ? '' : ' (${target.branch})'}, у меня $kAppVersion');
      if (!isNewer(target.version, kAppVersion)) {
        state = UpdateState.upToDate;
        notifyListeners();
        return;
      }
      final meta = await store.readJson('update.json');
      if (meta is Map && meta['version'] == target.version && File('${meta['path']}').existsSync()) {
        state = UpdateState.ready;
        notifyListeners();
        return;
      }
      final path = await _download(target.url, target.version, target.size);
      await store.writeJson('update.json', {'version': target.version, 'path': path});
      state = UpdateState.ready;
    } catch (e) {
      state = UpdateState.error;
      error = 'Не получилось проверить обновления: $e';
    }
    notifyListeners();
  }

  // ---------- установка выбранной сборки ----------

  /// Ставит выбранную тестовую сборку (или обычную версию — [b] без ветки), даже если она старее текущей.
  /// Приложение закроется, установщик откроет новую версию сам.
  Future<void> install(BuildInfo b) async {
    if (!enabled || state == UpdateState.downloading) return;
    installing = b;
    latest = b.version;
    error = null;
    try {
      final path = await _download(b.url, b.branch.isEmpty ? b.version : '${b.version}-${b.slug}', b.size);
      // Скачанное раньше автообновление больше не нужно
      await _forget(null);
      AppLog.info('Ставлю ${b.beta ? 'бета-версию' : b.stable ? 'версию' : 'тестовую сборку ${b.branch}'} ${b.version}');
      await _removeTrayIcon();
      await _launch(path);
      exit(0);
    } catch (e) {
      state = UpdateState.error;
      error = 'Не получилось скачать сборку ${b.version}: $e';
      installing = null;
      notifyListeners();
    }
  }

  /// Вернуться с тестовой сборки на последнюю обычную версию
  Future<void> installStable() async {
    if (!enabled) return;
    try {
      final b = await _latestStable();
      if (b == null) throw Exception('обычных версий пока нет');
      await install(b);
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
    // Значок из трея убираем сами и ДО запуска установщика: после exit(0) или принудительного закрытия
    // Windows оставляет «призрак» значка, пока не наведёшь на него курсор, и после обновлений в трее копятся старые иконки
    await _removeTrayIcon();
    await _launch('${meta['path']}');
    exit(0);
  }

  Future<void> _removeTrayIcon() async {
    try {
      await beforeExit?.call().timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  /// Что сделать перед выходом ради установки обновления (убрать значок из трея)
  static Future<void> Function()? beforeExit;

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
