import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../config.dart';
import 'auth.dart';
import 'log.dart';
import 'drive.dart';
import 'models.dart';
import 'store.dart';
import 'tags.dart';

/// Внутренний сигнал: библиотеку отключили или сменили, пока шло сохранение
class _Abandoned implements Exception {}

/// Снимок «куда смотрит это приложение»: нужен, чтобы понять, в какой библиотеке и папке данных человек сидит
class LocationReport {
  String? hubId, hubName, libFileId, libModified, dataId, error;
  int libSize = 0, libraryFilesInHub = 0, dataFolderCount = 0, dataFiles = 0;
  bool dataOverride = false;
}

class LibraryException implements Exception {
  final String message;
  LibraryException(this.message);
  @override
  String toString() => message;
}

class Album {
  final String key;
  final String title;
  final String artist;
  final List<Track> tracks;
  Album(this.key, this.title, this.artist, this.tracks);
  Track get coverTrack => tracks.firstWhere((t) => t.hasCover, orElse: () => tracks.first);
  String get year => tracks.map((t) => t.year).firstWhere((y) => y.isNotEmpty, orElse: () => '');
}

class Artist {
  final String key;
  final String name;
  final List<Track> tracks;
  Artist(this.key, this.name, this.tracks);
  int get albums => tracks.map((t) => t.albumKey).toSet().length;
  Track get coverTrack => tracks.firstWhere((t) => t.hasCover, orElse: () => tracks.first);
}

class UploadStatus {
  bool running = false;
  int total = 0;
  int done = 0;
  int failed = 0;
  int skipped = 0; // уже были в библиотеке
  String current = '';
  double fileProgress = 0;
}

class ScanStatus {
  bool running = false;
  String text = '';
  int done = 0;
  int total = 0;
}

class LibraryController extends ChangeNotifier {
  final AppStore store;
  final Settings settings;
  final AccountManager accounts;
  final DriveApi drive;

  LibraryData data = LibraryData();
  final List<Map<String, dynamic>> _pending = [];

  /// Недавно сохранённые правки полей (setMeta). Если другой клиент в то же время переписал library.json
  /// со старой копией, наша правка (например, ник) пропадёт; здесь мы это замечаем и сохраняем её заново
  final List<(Map<String, dynamic>, DateTime)> _recentMeta = [];
  int _flushGen = 0;
  String? _libModified;
  bool _flushing = false;
  Timer? _flushTimer;
  Timer? _pollTimer;
  Timer? _scanTimer;
  String? syncError;
  final ScanStatus scan = ScanStatus();

  /// Короткие сообщения для всплывающих уведомлений
  final StreamController<String> messages = StreamController<String>.broadcast();

  LibraryController(this.store, this.settings, this.accounts, this.drive);

  bool get hasHub => settings.hubId != null && settings.libFileId != null;
  String? get me => accounts.primary?.email;
  bool get hasUnsavedChanges => _pending.isNotEmpty;

  Future<void> saveSettings() => store.writeJson('settings.json', settings.toJson());

  /// Личная настройка вида изменилась: сохраняем и перерисовываем экраны, которые слушают библиотеку
  void viewChanged() {
    unawaited(saveSettings());
    notifyListeners();
  }

  // ---------- запуск ----------

  Future<void> start() async {
    final cached = await store.readJson('library_cache.json');
    if (cached is Map && cached['hub'] == settings.hubId) {
      data = LibraryData.fromJson(cached['data']);
      _libModified = cached['modified'] as String?;
    }
    final pend = await store.readJson('pending_ops.json');
    if (pend is List) {
      for (final op in pend) {
        if (op is Map<String, dynamic>) {
          _pending.add(op);
          data.apply(op);
        }
      }
    }
    _changed();
    if (hasHub) _goOnline();
  }

  void _goOnline() {
    _pollTimer?.cancel();
    _scanTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 30), (_) => _poll());
    _scanTimer = Timer.periodic(const Duration(minutes: 10), (_) => scanAll(quiet: true).then((_) => fillDurations()));
    () async {
      try {
        await reload();
        await _ensureHubSource();
        if (_pending.isNotEmpty) _scheduleFlush();
        await scanAll(quiet: true);
        unawaited(fillDurations());
      } catch (e) {
        _report(e);
      }
    }();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _scanTimer?.cancel();
    _flushTimer?.cancel();
    super.dispose();
  }

  // ---------- общая папка «Cave Player» ----------

  /// Музыку естественно класть прямо в общую папку, поэтому она тоже сканируется.
  /// Добавляем её в источники один раз на этом компьютере: если её потом
  /// уберут из списка, сами не возвращаем.
  Future<void> _ensureHubSource() async {
    final hub = settings.hubId;
    if (hub == null || settings.hubSourceChecked == hub) return;
    if (!data.sources.any((s) => s.id == hub)) {
      commit({
        'op': 'addSource',
        'source': Source(
          id: hub,
          name: 'Cave Player',
          addedBy: me ?? settings.hubEmail ?? '',
          addedAt: DateTime.now().millisecondsSinceEpoch,
        ).toJson(),
      });
    }
    settings.hubSourceChecked = hub;
    await saveSettings();
  }

  /// Выполняет действие от имени аккаунта, у которого есть доступ к общей папке.
  Future<T> _withHub<T>(Future<T> Function(String email) fn) async {
    final cached = settings.hubEmail;
    if (cached != null && accounts.byEmail(cached) != null) {
      try {
        return await fn(cached);
      } on DriveException catch (e) {
        if (!e.notFound && !e.forbidden) rethrow;
      }
    }
    for (final a in accounts.accounts) {
      if (a.email == cached) continue;
      try {
        await drive.getFile(a.email, settings.hubId!, fields: 'id');
      } on DriveException catch (e) {
        if (e.notFound || e.forbidden) continue;
        rethrow;
      }
      settings.hubEmail = a.email;
      await saveSettings();
      return fn(a.email);
    }
    throw LibraryException('Ни у одного подключённого аккаунта нет доступа к папке «Cave Player». '
        'Попросите друга поделиться ею с вами.');
  }

  Future<void> createHub(String email) async {
    final folder = await drive.createFolder(email, 'Cave Player');
    final fresh = LibraryData();
    final acc = accounts.byEmail(email);
    if (acc != null) fresh.members[email] = acc.name;
    final f = await drive.createFile(email, folder, 'library.json', jsonEncode(fresh.toJson()));
    settings
      ..hubId = folder
      ..hubEmail = email
      ..libFileId = f['id'] as String
      ..autoJoinDisabled = false
      ..dataFolderOverride = null;
    _dataFolderId = null;
    dataFolders = const [];
    _libModified = f['modifiedTime'] as String?;
    data = fresh;
    _pending.clear();
    await saveSettings();
    await _saveLocal();
    _changed();
    _goOnline();
  }

  Future<void> joinHub(String input) async {
    var id = parseDriveId(input);
    if (id == null) throw LibraryException('Это не похоже на ссылку на папку Google Диска');
    for (final a in accounts.accounts) {
      Map<String, dynamic> meta;
      try {
        meta = await drive.getFile(a.email, id!, fields: 'id,name,mimeType,parents');
      } on DriveException catch (e) {
        if (e.notFound || e.forbidden) continue;
        rethrow;
      }
      if (meta['mimeType'] != 'application/vnd.google-apps.folder') {
        // Ссылка прямо на library.json: берём папку, в которой он лежит
        final parents = meta['parents'];
        if (meta['name'] == 'library.json' && parents is List && parents.isNotEmpty) {
          id = '${parents.first}';
        } else {
          throw LibraryException('По ссылке файл, а нужна папка «Cave Player» или сам файл library.json');
        }
      }
      final found = await drive.listChildren(a.email, id!, nameEquals: 'library.json');
      if (found.isEmpty) {
        // Раньше здесь создавалась новая пустая библиотека: если вставить ссылку на папку с музыкой,
        // человек оказывался в отдельной пустой библиотеке без плейлистов и друзей
        throw LibraryException('В этой папке нет общей библиотеки Cave Player (файла library.json). '
            'Нужна ссылка на папку «Cave Player», а не на папку с музыкой.');
      }
      // Если в папке несколько library.json, настоящий — самый большой
      found.sort((x, y) => y.size.compareTo(x.size));
      final libId = found.first.id;
      if (hasHub) await flushNow();
      settings
        ..hubId = id
        ..hubEmail = a.email
        ..libFileId = libId
        ..autoJoinDisabled = false
        ..dataFolderOverride = null;
      _dataFolderId = null;
      dataFolders = const [];
      data = LibraryData();
      _pending.clear();
      _libModified = null;
      await saveSettings();
      await reload();
      final p = accounts.primary;
      if (p != null) commit({'op': 'members', 'm': {p.email: p.name}});
      _goOnline();
      return;
    }
    throw LibraryException('Ни у одного подключённого аккаунта нет доступа к этой папке. '
        'Проверьте, что друг поделился ею с вашей почтой.');
  }

  // ---------- где лежат данные ----------

  /// Переносит библиотеку в другую папку Диска: создаёт там library.json с текущим содержимым
  /// и дальше работает с ним. Старый файл не трогаем — друзья, которые на него смотрят, ничего не потеряют.
  Future<void> moveLibraryTo(String input) async {
    final id = parseDriveId(input);
    if (id == null) throw LibraryException('Это не похоже на ссылку на папку Google Диска');
    if (!hasHub) throw LibraryException('Сначала подключитесь к библиотеке');
    if (id == settings.hubId) throw LibraryException('Библиотека уже лежит в этой папке');
    await flushNow();
    final email = await accessFor(id, recheck: true);
    final meta = await drive.getFile(email, id, fields: 'id,name,mimeType');
    if (meta['mimeType'] != 'application/vnd.google-apps.folder') {
      throw LibraryException('По ссылке файл, а нужна папка');
    }
    final existing = await drive.listChildren(email, id, nameEquals: 'library.json');
    if (existing.isNotEmpty) {
      throw LibraryException('В этой папке уже есть library.json. Чтобы работать с ним, используйте «Подключить другую папку».');
    }
    final f = await drive.createFile(email, id, 'library.json', jsonEncode(data.toJson()));
    settings
      ..hubId = id
      ..hubEmail = email
      ..libFileId = f['id'] as String
      ..autoJoinDisabled = false;
    _libModified = f['modifiedTime'] as String?;
    _dataFolderId = null;
    dataFolders = const [];
    await saveSettings();
    await _saveLocal();
    _changed();
    _goOnline();
  }

  /// Своя папка для статусов, ленты и чартов (cave-data). Можно дать ссылку на саму cave-data
  /// или на любую папку: тогда cave-data найдётся внутри неё или будет создана.
  Future<void> setDataFolder(String input) async {
    final id = parseDriveId(input);
    if (id == null) throw LibraryException('Это не похоже на ссылку на папку Google Диска');
    final email = await accessFor(id, recheck: true);
    final meta = await drive.getFile(email, id, fields: 'id,name,mimeType');
    if (meta['mimeType'] != 'application/vnd.google-apps.folder') {
      throw LibraryException('По ссылке файл, а нужна папка');
    }
    var target = id;
    if (meta['name'] != dataFolderName) {
      final inside = (await drive.listChildren(email, id, nameEquals: dataFolderName)).where((f) => f.isFolder).toList()
        ..sort((a, b) => a.createdTime.compareTo(b.createdTime));
      target = inside.isNotEmpty ? inside.first.id : await drive.createFolder(email, dataFolderName, parent: id);
    }
    settings.dataFolderOverride = target;
    _dataFolderId = null;
    dataFolders = const [];
    await saveSettings();
    _changed();
  }

  /// Вернуть cave-data на обычное место: внутри общей папки
  Future<void> resetDataFolder() async {
    settings.dataFolderOverride = null;
    _dataFolderId = null;
    dataFolders = const [];
    await saveSettings();
    _changed();
  }

  /// Что реально используется сейчас: для диагностики на странице «Папки с музыкой»
  Future<LocationReport> locationReport() async {
    final r = LocationReport();
    final hub = settings.hubId, lib = settings.libFileId;
    r.hubId = hub;
    r.libFileId = lib;
    r.dataOverride = settings.dataFolderOverride != null;
    if (hub == null || lib == null) return r;
    try {
      await _withHub((email) async {
        try {
          r.hubName = (await drive.getFile(email, hub, fields: 'id,name'))['name'] as String?;
        } catch (_) {}
        try {
          final m = await drive.getFile(email, lib, fields: 'id,name,size,modifiedTime');
          r.libSize = int.tryParse('${m['size'] ?? 0}') ?? 0;
          r.libModified = m['modifiedTime'] as String?;
        } catch (_) {}
        final strays = await drive.listChildren(email, hub, nameEquals: 'library.json');
        r.libraryFilesInHub = strays.length;
        final dataId = await dataFolder();
        r.dataId = dataId;
        r.dataFolderCount = dataFolders.length;
        final files = await drive.listChildren(email, dataId);
        r.dataFiles = files.where((f) => f.name.startsWith('user-')).length;
      });
    } catch (e) {
      r.error = '$e';
    }
    return r;
  }

  /// Ищет общую библиотеку сам: сначала папку из настроек сборки, потом любую
  /// library.json на Дисках подключённых аккаунтов. Так друзьям не нужна ссылка.
  Future<bool> autoJoin({bool manual = false}) async {
    if (hasHub || accounts.accounts.isEmpty) return hasHub;
    // После «Отключиться от библиотеки» ищем только по явной просьбе человека
    if (settings.autoJoinDisabled && !manual) return false;
    if (kDefaultLibraryId.isNotEmpty) {
      try {
        await joinHub(kDefaultLibraryId);
        return true;
      } catch (_) {
        // к папке по умолчанию нет доступа — поищем другие
      }
    }
    // Настоящая библиотека — самый большой library.json: случайный пустой файл, даже свежий, её не перебьёт
    final found = <(String, int)>[];
    for (final a in accounts.accounts) {
      try {
        for (final f in await drive.findLibraries(a.email)) {
          final parents = f['parents'];
          if (parents is List && parents.isNotEmpty && !found.any((x) => x.$1 == '${parents.first}')) {
            found.add(('${parents.first}', int.tryParse('${f['size'] ?? 0}') ?? 0));
          }
        }
      } catch (_) {
        // этот аккаунт не смог поискать — пробуем остальные
      }
    }
    found.sort((a, b) => b.$2.compareTo(a.$2));
    for (final id in [for (final x in found) x.$1]) {
      try {
        await joinHub(id);
        return true;
      } catch (_) {
        continue;
      }
    }
    return false;
  }

  /// Приглашает друга: доступ редактора к общей папке и ко всем папкам с музыкой,
  /// которыми этот аккаунт может делиться. Возвращает папки, которые не удалось расшарить.
  Future<List<String>> invite(String friendEmail) async {
    final email = friendEmail.trim().toLowerCase();
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
      throw LibraryException('Это не похоже на адрес почты');
    }
    const note = 'Приглашаю в нашу общую музыкальную библиотеку Cave Player. '
        'Установи Cave Player и войди через Google с этой почтой — библиотека подключится сама.';
    await _withHub((me) => drive.share(me, settings.hubId!, email, message: note));
    final failed = <String>[];
    for (final s in data.sources) {
      if (s.id == settings.hubId) continue;
      try {
        final who = await accessFor(s.id);
        await drive.share(who, s.id, email, role: 'reader');
      } catch (_) {
        failed.add(s.name);
      }
    }
    return failed;
  }

  /// Для соседних модулей: выполнить запрос от аккаунта с доступом к общей папке
  Future<T> withHub<T>(Future<T> Function(String email) fn) => _withHub(fn);

  /// События для ленты: загрузки, новые плейлисты, лайки
  void Function(Map<String, dynamic> event)? onEvent;

  // ---------- служебная папка cave-data внутри общей папки ----------

  String? _dataFolderId;
  Future<String>? _dataFolderFuture;

  /// Все папки cave-data: из-за одновременного создания в старых версиях их могло стать несколько
  List<String> dataFolders = const [];

  /// Папка для журналов, статусов «сейчас слушаю» и ленты событий.
  /// Ищется и создаётся один раз; если папок несколько, всегда берём самую старую,
  /// чтобы все компьютеры писали в одну и ту же.
  Future<String> dataFolder() {
    final cached = _dataFolderId;
    if (cached != null) return Future.value(cached);
    final own = settings.dataFolderOverride;
    if (own != null) {
      dataFolders = [own];
      return Future.value(_dataFolderId = own);
    }
    return _dataFolderFuture ??= _withHub((email) async {
      final found = (await drive.listChildren(email, settings.hubId!, nameEquals: dataFolderName))
          .where((f) => f.isFolder)
          .toList()
        ..sort((a, b) => a.createdTime.compareTo(b.createdTime));
      final id = found.isNotEmpty ? found.first.id : await drive.createFolder(email, dataFolderName, parent: settings.hubId);
      dataFolders = found.isNotEmpty ? [for (final f in found) f.id] : [id];
      if (found.length > 1) AppLog.warn('Найдено несколько папок cave-data: ${found.length}, используем самую старую');
      _dataFolderId = id;
      return id;
    }).whenComplete(() => _dataFolderFuture = null);
  }

  static const dataFolderName = 'cave-data';

  /// Кладёт журнал в общую папку, чтобы его мог посмотреть тот, кто чинит приложение
  Future<void> uploadLog(String text) async {
    final folder = await dataFolder();
    final who = (me ?? 'unknown').split('@').first;
    final ts = DateTime.now().toIso8601String().split('.').first.replaceAll(':', '-');
    await _withHub((e) => drive.createFile(e, folder, 'log-$who-$ts.txt', text, mime: 'text/plain'));
  }

  /// Отключает этот компьютер от библиотеки. Только локально: ни одной общей операции
  /// (удаление треков или папок) в library.json не пишется, у друзей всё остаётся как было.
  /// После этого библиотеку сами больше не ищем: подключиться можно только вручную.
  Future<void> leaveHub() async {
    _pollTimer?.cancel();
    _scanTimer?.cancel();
    _flushTimer?.cancel();
    settings
      ..hubId = null
      ..hubEmail = null
      ..libFileId = null
      ..dataFolderOverride = null
      ..autoJoinDisabled = true
      ..sourceAccess.clear();
    data = LibraryData();
    _pending.clear();
    _libModified = null;
    _dataFolderId = null;
    dataFolders = const [];
    await saveSettings();
    await _saveLocal();
    _changed();
  }

  // ---------- синхронизация ----------

  Future<LibraryData> _downloadLatest(String email) async {
    final bytes = await drive.download(email, settings.libFileId!);
    if (bytes.isEmpty) return LibraryData();
    return LibraryData.fromJson(jsonDecode(utf8.decode(bytes)));
  }

  Future<void> reload() async {
    if (!hasHub) return;
    final gen = _flushGen;
    await _withHub((email) async {
      final meta = await drive.getFile(email, settings.libFileId!, fields: 'id,modifiedTime');
      final latest = await _downloadLatest(email);
      // Пока скачивали, мы сами сохранили правки: скачанная копия уже старая, её не берём
      if (_flushing || gen != _flushGen) return;
      for (final op in _pending) {
        latest.apply(op);
      }
      data = latest;
      _libModified = meta['modifiedTime'] as String?;
    });
    syncError = null;
    _reassertRecentMeta();
    await _saveLocal();
    _changed();
    // Кто-то из друзей удалил мои файлы — удаляем их с Диска
    unawaited(processDeletions());
  }

  /// Правки полей за последние минуты, которых нет в скачанной копии, сохраняем ещё раз
  void _reassertRecentMeta() {
    final cutoff = DateTime.now().subtract(const Duration(minutes: 3));
    _recentMeta.removeWhere((r) => r.$2.isBefore(cutoff));
    if (_recentMeta.isEmpty) return;
    final want = <String, Map<String, String>>{};
    for (final r in _recentMeta) {
      (r.$1['meta'] as Map).forEach((id, fields) {
        want['$id'] = {...?want['$id'], ...(fields as Map).map((a, b) => MapEntry('$a', '$b'))};
      });
    }
    final lost = <String, Map<String, String>>{};
    want.forEach((id, fields) {
      fields.forEach((k, v) {
        if ((data.edits[id]?[k] ?? '') != v) lost.putIfAbsent(id, () => {})[k] = v;
      });
    });
    if (lost.isNotEmpty) {
      AppLog.info('Правки пропали из скачанной копии, сохраняю заново: ${lost.length}');
      // Повторное сохранение само в «недавние» не попадает, иначе при спорной правке двух людей мы бы бесконечно переписывали друг друга
      commit({'op': 'setMeta', 'meta': lost, 're': true});
    }
  }

  Future<void> _poll() async {
    if (!hasHub || _flushing || _pending.isNotEmpty) return;
    try {
      final meta = await _withHub((e) => drive.getFile(e, settings.libFileId!, fields: 'id,modifiedTime'));
      if (meta['modifiedTime'] != _libModified) await reload();
    } catch (_) {
      // нет сети — попробуем в следующий раз
    }
  }

  void commit(Map<String, dynamic> op) {
    // Отключились от библиотеки, а сканирование ещё дописывает: эти правки уже ничьи
    if (!hasHub) return;
    data.apply(op);
    _pending.add(op);
    _changed();
    unawaited(store.writeJson('pending_ops.json', _pending));
    _scheduleFlush();
  }

  /// Сохраняет накопленные правки на Диск сразу — перед выходом из приложения
  Future<void> flushNow() async {
    _flushTimer?.cancel();
    if (_pending.isEmpty || !hasHub) return;
    await _flush().timeout(const Duration(seconds: 6), onTimeout: () {});
  }

  void _scheduleFlush([Duration? delay]) {
    _flushTimer?.cancel();
    // Во время сканирования правок много — копим их и сохраняем реже
    _flushTimer = Timer(delay ?? Duration(milliseconds: scan.running ? 6000 : 800), _flush);
  }

  Future<void> _flush() async {
    if (_flushing || _pending.isEmpty || !hasHub) return;
    _flushing = true;
    final batch = List<Map<String, dynamic>>.of(_pending);
    final libAtStart = settings.libFileId;
    try {
      await _withHub((email) async {
        final latest = await _downloadLatest(email);
        // Пока качали, человек отключился или сменил библиотеку: в чужой файл ничего не пишем
        if (settings.libFileId != libAtStart) throw _Abandoned();
        for (final op in batch) {
          latest.apply(op);
        }
        final modified = await drive.updateFile(email, settings.libFileId!, jsonEncode(latest.toJson()));
        _pending.removeRange(0, batch.length);
        for (final op in _pending) {
          latest.apply(op);
        }
        data = latest;
        _libModified = modified;
        _flushGen++;
        final now = DateTime.now();
        for (final op in batch) {
          if (op['op'] == 'setMeta' && op['re'] != true) _recentMeta.add((op, now));
        }
      });
      syncError = null;
      await store.writeJson('pending_ops.json', _pending);
      await _saveLocal();
    } on _Abandoned {
      // библиотеку сменили: письмо в старый файл не нужно
    } catch (e) {
      syncError = 'Изменения пока не сохранены на Диске: $e';
      _scheduleFlush(const Duration(seconds: 15));
    } finally {
      _flushing = false;
      _changed();
      if (_pending.isNotEmpty && syncError == null) _scheduleFlush();
    }
  }

  Future<void> _saveLocal() => store.writeJson('library_cache.json', {
        'hub': settings.hubId,
        'modified': _libModified,
        'data': data.toJson(),
      });

  // ---------- источники ----------

  /// Какой из подключённых аккаунтов видит эту папку.
  Future<String> accessFor(String folderId, {bool recheck = false}) async {
    final cached = settings.sourceAccess[folderId];
    if (!recheck && cached != null && accounts.byEmail(cached) != null) return cached;
    for (final a in accounts.accounts) {
      try {
        await drive.getFile(a.email, folderId, fields: 'id');
        settings.sourceAccess[folderId] = a.email;
        await saveSettings();
        return a.email;
      } on DriveException catch (e) {
        if (e.notFound || e.forbidden) continue;
        rethrow;
      }
    }
    settings.sourceAccess.remove(folderId);
    throw LibraryException('Нет доступа к папке. Подключите аккаунт, с которым ею поделились.');
  }

  Future<void> addSource(String input) async {
    final id = parseDriveId(input);
    if (id == null) throw LibraryException('Это не похоже на ссылку на папку Google Диска');
    if (data.sources.any((s) => s.id == id)) throw LibraryException('Эта папка уже в библиотеке');
    final email = await accessFor(id, recheck: true);
    final meta = await drive.getFile(email, id, fields: 'id,name,mimeType');
    if (meta['mimeType'] != 'application/vnd.google-apps.folder') {
      throw LibraryException('По ссылке файл, а нужна папка с музыкой');
    }
    commit({
      'op': 'addSource',
      'source': Source(
        id: id,
        name: (meta['name'] as String?) ?? 'Папка',
        addedBy: me ?? email,
        addedAt: DateTime.now().millisecondsSinceEpoch,
      ).toJson(),
    });
    final src = data.sources.firstWhere((s) => s.id == id);
    unawaited(_runScan([src]));
  }

  void removeSource(String id) => commit({'op': 'removeSource', 'id': id});

  Future<void> scanAll({bool quiet = false}) => _runScan(List.of(data.sources), quiet: quiet);

  /// Сколько треков можно убрать за одну проверку без вопросов: если папка вдруг «опустела»,
  /// это почти всегда потеря доступа, а не то, что все файлы удалили.
  static const _bulkRemoveLimit = 10;

  /// Источники, где проверка нашла подозрительно мало файлов: [id] → сколько треков не тронуто
  final Map<String, int> suspiciousSources = {};

  /// Подтверждённая очистка: убрать из библиотеки треки, которых больше нет в папке
  Future<void> rescanAndPrune(String id) async {
    final src = data.sources.firstWhere((s) => s.id == id);
    await _runScan([src], forcePrune: true);
  }

  Future<void> _runScan(List<Source> sources, {bool quiet = false, bool forcePrune = false}) async {
    if (scan.running || accounts.accounts.isEmpty) return;
    scan
      ..running = true
      ..done = 0
      ..total = 0
      ..text = 'Проверяю папки…';
    notifyListeners();
    var added = 0;
    try {
      for (final s in sources) {
        try {
          added += await _scanSource(s, forcePrune: forcePrune);
        } catch (e) {
          AppLog.warn('Сканирование «${s.name}»', e);
          messages.add('Не получилось обновить «${s.name}»: $e');
        }
      }
      settings.lastScan = DateTime.now().toIso8601String();
      await saveSettings();
      // Один и тот же файл в разных папках — объединяем сами, без потерь
      final merged = mergeExactCopies();
      unawaited(processDeletions());
      if (!quiet || added > 0) {
        messages.add(added > 0 ? 'Новых треков: $added' : 'Новых треков нет');
      }
      if (merged > 0) messages.add('Одинаковые файлы объединены, лишние копии удалены: $merged');
    } finally {
      scan
        ..running = false
        ..text = '';
      notifyListeners();
    }
  }

  Future<int> _scanSource(Source s, {bool forcePrune = false}) async {
    var email = await accessFor(s.id);
    List<_Found> found;
    Map<String, String> covers;
    try {
      (found, covers) = await _walk(email, s);
    } on DriveException catch (e) {
      if (!e.notFound && !e.forbidden) rethrow;
      email = await accessFor(s.id, recheck: true);
      (found, covers) = await _walk(email, s);
    }

    final existing = {for (final t in data.tracks.values) if (t.source == s.id) t.id: t};
    final seen = <String>{};
    final toParse = <_Found>[];
    final upserts = <String, dynamic>{};
    final members = <String, String>{};
    for (final f in found) {
      if (data.deleted.containsKey(f.file.id)) continue; // удалён, файл ещё ждёт владельца
      seen.add(f.file.id);
      if (f.file.ownerEmail.isNotEmpty && f.file.ownerName.isNotEmpty && data.members[f.file.ownerEmail] == null) {
        members[f.file.ownerEmail] = f.file.ownerName;
      }
      final old = existing[f.file.id];
      final cover = covers[f.folder];
      if (old == null || old.modified != f.file.modifiedTime) {
        toParse.add(f);
      } else if (old.cover != cover) {
        final j = old.toJson();
        if (cover != null) {
          j['c'] = cover;
        } else {
          j.remove('c');
        }
        upserts[old.id] = j;
      }
    }
    if (members.isNotEmpty) commit({'op': 'members', 'm': members});
    if (upserts.isNotEmpty) commit({'op': 'upsertTracks', 'tracks': upserts});

    scan
      ..total = toParse.length
      ..done = 0
      ..text = toParse.isEmpty ? 'Проверяю «${s.name}»' : 'Читаю теги в «${s.name}»';
    notifyListeners();

    var batch = <String, dynamic>{};
    await _pool<_Found>(toParse, 4, (f) async {
      TrackTags tags;
      try {
        final len = f.file.size > 0 ? min(f.file.size, 131072) : 131072;
        final head = await drive.readRange(email, f.file.id, 0, len - 1);
        tags = parseTags(head, f.file.name);
      } catch (_) {
        tags = parseTags(Uint8List(0), f.file.name);
      }
      batch[f.file.id] = Track(
        id: f.file.id,
        source: s.id,
        title: tags.title,
        artist: tags.artist,
        album: tags.album,
        albumArtist: tags.albumArtist,
        no: tags.track,
        year: tags.year,
        pic: tags.pic,
        cover: covers[f.folder],
        modified: f.file.modifiedTime,
        size: f.file.size,
        by: f.file.ownerEmail,
        path: f.path,
        added: f.file.createdTime,
      ).toJson();
      scan.done++;
      if (batch.length >= 100) {
        commit({'op': 'upsertTracks', 'tracks': batch});
        batch = <String, dynamic>{};
      } else if (scan.done % 10 == 0) {
        notifyListeners();
      }
    });
    if (batch.isNotEmpty) commit({'op': 'upsertTracks', 'tracks': batch});

    // Свои новые файлы, загруженные мимо приложения, тоже попадают в ленту
    final mine = toParse.where((f) => existing[f.file.id] == null && f.file.ownerEmail == me).length;
    if (mine > 0) onEvent?.call({'k': 'upload', 'n': mine, 'folder': s.name});

    final removed = existing.keys.where((id) => !seen.contains(id)).toList();
    if (removed.isNotEmpty) {
      // Пустой ответ или «исчезла» большая часть папки — скорее всего пропал доступ, а не файлы:
      // у друзей треки не трогаем, пока человек сам не подтвердит очистку
      final looksLost = removed.length >= _bulkRemoveLimit && (seen.isEmpty || removed.length * 2 > existing.length);
      if (looksLost && !forcePrune) {
        suspiciousSources[s.id] = removed.length;
        AppLog.warn('«${s.name}»: не найдено ${removed.length} из ${existing.length} треков, из библиотеки не убираю');
        messages.add('«${s.name}»: не нашёл ${removed.length} треков. Из общей библиотеки они не убраны — '
            'проверьте доступ к папке или подтвердите очистку на странице «Папки с музыкой».');
      } else {
        suspiciousSources.remove(s.id);
        commit({'op': 'removeTracks', 'ids': removed});
      }
    } else {
      suspiciousSources.remove(s.id);
    }
    return toParse.where((f) => existing[f.file.id] == null).length;
  }

  Future<(List<_Found>, Map<String, String>)> _walk(String email, Source s) async {
    final found = <_Found>[];
    final covers = <String, String>{};
    final queue = <(String, String, int)>[(s.id, '', 0)];
    while (queue.isNotEmpty) {
      final (folder, path, depth) = queue.removeAt(0);
      scan.text = 'Смотрю «${path.isEmpty ? s.name : path}»';
      notifyListeners();
      final children = await drive.listChildren(email, folder);
      for (final c in children) {
        if (c.isFolder) {
          if ((c.name == dataFolderName || c.name == coversFolderName) && folder == settings.hubId) continue; // служебные папки
          if (depth < 10) queue.add((c.id, path.isEmpty ? c.name : '$path/${c.name}', depth + 1));
        } else if (audioExt.hasMatch(c.name) || c.mimeType.startsWith('audio/')) {
          found.add(_Found(c, folder, path));
        } else if (coverName.hasMatch(c.name)) {
          covers[folder] ??= c.id;
        }
      }
    }
    return (found, covers);
  }

  static Future<void> _pool<T>(List<T> items, int n, Future<void> Function(T) fn) async {
    var i = 0;
    Future<void> worker() async {
      while (i < items.length) {
        final item = items[i++];
        await fn(item);
      }
    }

    await Future.wait(List.generate(n, (_) => worker()));
  }

  // ---------- лайки и плейлисты ----------

  bool isLiked(String trackId) => me != null && (data.likes[trackId]?.contains(me) ?? false);

  void toggleLike(String trackId) {
    final m = me;
    if (m == null) return;
    final on = !isLiked(trackId);
    commit({'op': 'like', 'id': trackId, 'email': m, 'on': on});
    if (on) onEvent?.call({'k': 'like', 'track': trackId});
  }

  String createPlaylist(String name, [List<String> items = const []]) {
    final id = 'pl${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}${Random().nextInt(1 << 20).toRadixString(36)}';
    commit({
      'op': 'createPlaylist',
      'playlist': Playlist(
        id: id,
        name: name,
        by: me ?? '',
        createdAt: DateTime.now().millisecondsSinceEpoch,
        items: List.of(items),
      ).toJson(),
    });
    onEvent?.call({'k': 'playlist', 'id': id, 'name': name});
    return id;
  }

  void renamePlaylist(String id, String name) => commit({'op': 'renamePlaylist', 'id': id, 'name': name});
  void deletePlaylist(String id) => commit({'op': 'deletePlaylist', 'id': id});
  void addToPlaylist(String id, List<String> items) =>
      commit({'op': 'addToPlaylist', 'id': id, 'items': items, 'at': DateTime.now().millisecondsSinceEpoch});

  /// Когда трек добавлен в плейлист (мс). У старых записей даты нет, берём дату создания плейлиста
  int playlistAddedAt(Playlist p, String trackId) => int.tryParse(data.edits['pl:${p.id}']?['t:$trackId'] ?? '') ?? p.createdAt;
  /// Переставляет трек в плейлисте: [after] — трек, за которым он должен стоять (null — в начало)
  void movePlaylistItem(String id, String trackId, String? after) =>
      commit({'op': 'movePlaylistItem', 'id': id, 'track': trackId, 'after': after});

  void removeFromPlaylist(String id, String trackId) =>
      commit({'op': 'removeFromPlaylist', 'id': id, 'track': trackId});

  Playlist? playlist(String id) {
    for (final p in data.playlists) {
      if (p.id == id) return p;
    }
    return null;
  }

  // ---------- представления ----------

  int _version = 0;
  int _cachedVersion = -1;
  List<Track> _all = const [];
  List<Album> _albums = const [];
  List<Artist> _artists = const [];

  void _changed() {
    _version++;
    notifyListeners();
  }

  void _rebuild() {
    if (_cachedVersion == _version) return;
    _cachedVersion = _version;
    final all = data.tracks.values.where((t) => !data.hidden.contains(t.id)).toList()..sort(_compare);
    _all = all;
    final byAlbum = <String, List<Track>>{};
    for (final t in all) {
      byAlbum.putIfAbsent(t.albumKey, () => []).add(t);
    }
    // Трек с соавторами («A, B», «A feat. B») попадает к каждому из них
    final byArtist = <String, List<Track>>{};
    final names = <String, String>{};
    for (final t in all) {
      for (final name in t.artists) {
        final key = name.toLowerCase();
        names.putIfAbsent(key, () => name);
        byArtist.putIfAbsent(key, () => []).add(t);
      }
    }
    _artists = [for (final e in byArtist.entries) Artist(e.key, names[e.key]!, e.value)]
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    _artistByKey = {for (final a in _artists) a.key: a};
    _albums = byAlbum.entries.map((e) {
      final t = e.value.first;
      final artists = e.value.map((x) => x.albumArtist.isNotEmpty ? x.albumArtist : x.artist).toSet();
      return Album(e.key, t.displayAlbum, artists.length == 1 ? t.displayArtist : 'Разные исполнители', e.value);
    }).toList()
      ..sort((a, b) => a.artist.toLowerCase().compareTo(b.artist.toLowerCase()) != 0
          ? a.artist.toLowerCase().compareTo(b.artist.toLowerCase())
          : a.title.toLowerCase().compareTo(b.title.toLowerCase()));
  }

  static int _compare(Track a, Track b) {
    int c(String x, String y) => x.toLowerCase().compareTo(y.toLowerCase());
    final aa = a.albumArtist.isNotEmpty ? a.albumArtist : a.artist;
    final ba = b.albumArtist.isNotEmpty ? b.albumArtist : b.artist;
    var r = c(aa, ba);
    if (r != 0) return r;
    r = c(a.displayAlbum, b.displayAlbum);
    if (r != 0) return r;
    r = (a.no ?? 9999).compareTo(b.no ?? 9999);
    if (r != 0) return r;
    return c(a.title, b.title);
  }

  List<Track> get allTracks {
    _rebuild();
    return _all;
  }

  List<Album> get albums {
    _rebuild();
    return _albums;
  }

  Album? album(String key) {
    for (final a in albums) {
      if (a.key == key) return a;
    }
    return null;
  }

  Album? albumOf(Track t) => album(t.albumKey);

  List<Track> get liked => allTracks.where((t) => isLiked(t.id)).toList();

  /// Исполнители по алфавиту
  List<Artist> get artists {
    _rebuild();
    return _artists;
  }

  Map<String, Artist> _artistByKey = const {};

  Artist? artist(String key) {
    _rebuild();
    return _artistByKey[key.toLowerCase()];
  }

  /// Последние добавленные на Диск треки, новые сверху
  List<Track> get recent {
    final list = List.of(allTracks);
    String when(Track t) => t.added.isNotEmpty ? t.added : t.modified;
    list.sort((a, b) => when(b).compareTo(when(a)));
    return list.length > 300 ? list.sublist(0, 300) : list;
  }

  /// Ключ «одна и та же песня»: первый исполнитель и название без мусора вроде
  /// «(Official Video)», «(feat. …)», «Remastered». Ремиксы и live остаются разными
  static String dupKey(String artist, String title) {
    final first = splitArtists(artist).firstOrNull ?? '';
    final k = '${_norm(first)}|${_norm(title)}';
    return k == '|' ? '' : k;
  }

  /// Группы похожих треков (одна и та же песня в нескольких копиях)
  List<List<Track>> get duplicates {
    final groups = <String, List<Track>>{};
    for (final t in allTracks) {
      final k = dupKey(t.artist, t.title);
      if (k.isEmpty) continue;
      groups.putIfAbsent(k, () => []).add(t);
    }
    return groups.values.where((g) => g.length > 1).toList()
      ..sort((a, b) => a.first.title.toLowerCase().compareTo(b.first.title.toLowerCase()));
  }

  /// Такая песня уже есть в библиотеке (видимая копия) — чтобы не качать и не загружать её снова
  Track? existing(String artist, String title) {
    final k = dupKey(artist, title);
    if (k.isEmpty) return null;
    if (_dupVersion != _version) {
      _dupVersion = _version;
      _dupIndex = {};
      for (final t in allTracks) {
        final tk = dupKey(t.artist, t.title);
        if (tk.isNotEmpty) _dupIndex.putIfAbsent(tk, () => t);
      }
    }
    return _dupIndex[k];
  }

  Map<String, Track> _dupIndex = {};
  int _dupVersion = -1;

  /// Какую копию оставить: самый большой файл (обычно лучшее качество), при равенстве — более раннюю
  static Track bestOf(List<Track> copies) {
    final list = List.of(copies)
      ..sort((a, b) {
        final r = b.size.compareTo(a.size);
        if (r != 0) return r;
        final ra = a.added.isNotEmpty ? a.added : a.modified;
        final rb = b.added.isNotEmpty ? b.added : b.modified;
        final r2 = ra.compareTo(rb);
        return r2 != 0 ? r2 : a.id.compareTo(b.id);
      });
    return list.first;
  }

  /// Объединяет копии в [keep]: лайки и места в плейлистах переходят на неё, остальные скрываются
  void mergeTracks(String keep, Iterable<String> drop) {
    final ids = [for (final d in drop) if (d != keep) d];
    if (ids.isEmpty) return;
    commit({'op': 'mergeTracks', 'keep': keep, 'drop': ids});
  }

  /// Вернуть объединённую копию отдельным треком
  void unmergeTrack(String id) => commit({'op': 'unmergeTrack', 'id': id});

  // ---------- удаление с Диска ----------

  /// Удаляет треки полностью: из библиотеки у всех сразу, а файлы — с Диска их владельцев.
  /// Свои файлы удаляются сразу, чужие — когда владелец откроет Cave Player
  /// (удалить чужой файл Google Диск не даёт никому, кроме владельца)
  void deleteTracks(Iterable<Track> list) {
    final ids = {for (final t in list) t.id: t.by};
    if (ids.isEmpty) return;
    commit({'op': 'deleteTracks', 'ids': ids});
    AppLog.info('Удаление с Диска: ${ids.length}');
    unawaited(processDeletions());
  }

  /// Объединить копии в [keep] (лайки, плейлисты, прослушивания переходят на неё) и удалить остальные
  void mergeAndDelete(Track keep, Iterable<Track> copies) {
    final drop = [for (final t in copies) if (t.id != keep.id) t];
    if (drop.isEmpty) return;
    mergeTracks(keep.id, drop.map((t) => t.id));
    deleteTracks(drop);
  }

  /// Копии, объединённые раньше и только скрытые, — удалить с Диска
  int deleteMergedCopies() {
    final list = [
      for (final id in data.merged.keys)
        if (data.hidden.contains(id) && data.tracks[id] != null) data.tracks[id]!
    ];
    deleteTracks(list);
    return list.length;
  }

  /// Чьи файлы удалены, но ещё лежат на Диске и я их владелец — удаляем
  bool _purging = false;

  Future<int> processDeletions() async {
    if (_purging || data.deleted.isEmpty) return 0;
    _purging = true;
    final done = <String>[];
    try {
      for (final e in Map.of(data.deleted).entries) {
        final owner = e.value.toLowerCase();
        final acc = accounts.accounts.where((a) => a.email.toLowerCase() == owner).firstOrNull;
        if (acc == null) continue; // не мой файл — удалит владелец
        try {
          await drive.deleteFile(acc.email, e.key);
          done.add(e.key);
        } on DriveException catch (err) {
          if (err.notFound) {
            done.add(e.key); // уже удалён
          } else {
            AppLog.warn('Не получилось удалить файл ${e.key} с Диска', err);
          }
        } catch (err) {
          AppLog.warn('Не получилось удалить файл ${e.key} с Диска', err);
        }
      }
    } finally {
      _purging = false;
    }
    if (done.isNotEmpty) {
      commit({'op': 'purged', 'ids': done});
      AppLog.info('Удалено с Диска файлов: ${done.length}');
    }
    return done.length;
  }

  /// Точные копии (та же песня и тот же размер файла — один и тот же файл в разных папках)
  /// объединяем сами. Выбор однозначный, поэтому у всех друзей остаётся одна и та же копия.
  int mergeExactCopies() {
    var n = 0;
    for (final g in duplicates) {
      final bySize = <int, List<Track>>{};
      for (final t in g) {
        if (t.size > 0) bySize.putIfAbsent(t.size, () => []).add(t);
      }
      for (final same in bySize.values.where((l) => l.length > 1)) {
        final keep = bestOf(same);
        mergeAndDelete(keep, same);
        n += same.length - 1;
      }
    }
    if (n > 0) AppLog.info('Дубликаты: объединено точных копий $n');
    return n;
  }

  static String _norm(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[\(\[][^\)\]]*(official|video|audio|lyrics|клип|remaster|hq|hd|feat|ft\.|prod\.|при уч)[^\)\]]*[\)\]]'), '')
      .replaceAll('ё', 'е')
      .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
      .trim();

  // ---------- правка, скрытие, удаление ----------

  /// [cover]: id картинки в папке covers, пустая строка — убрать свою обложку, null — не трогать
  void editTrack(String id, {required String title, required String artist, required String album, String? cover}) =>
      editTracks([id], {'t': title, 'a': artist, 'al': album, if (cover != null) 'cv': cover});

  /// Массовая правка: только переданные поля — название 't', исполнитель 'a', альбом 'al', обложка 'cv'.
  /// Если альбом со своей обложкой переезжает целиком, обложка переезжает вместе с ним.
  void editTracks(Iterable<String> ids, Map<String, String> fields) {
    if (fields.isEmpty) return;
    final list = ids.toList();
    final meta = <String, Map<String, String>>{for (final id in list) id: fields};
    if (fields.containsKey('a') || fields.containsKey('al')) {
      final picked = list.toSet();
      final byAlbum = <String, List<Track>>{};
      for (final id in list) {
        final t = data.tracks[id];
        if (t != null) byAlbum.putIfAbsent(t.albumKey, () => []).add(t);
      }
      byAlbum.forEach((oldKey, tracks) {
        final cover = albumCover(oldKey);
        if (cover == null) return;
        if (!data.tracks.values.where((t) => t.albumKey == oldKey).every((t) => picked.contains(t.id))) return;
        final newKeys = {for (final t in tracks) t.albumKeyWith(newArtist: fields['a'], newAlbum: fields['al'])};
        if (newKeys.length != 1 || newKeys.first == oldKey || albumCover(newKeys.first) != null) return;
        meta['album:${newKeys.first}'] = {'cv': cover};
      });
    }
    setMeta(meta);
  }

  // ---------- данные, которые хранятся в общих правках (edits) ----------
  // Старые версии приложения про них не знают, но сохраняют: в edits при записи файла ничего не теряется.
  // Ключи: id трека, 'album:<ключ альбома>', 'pl:<id плейлиста>', 'u:<почта>' (личные настройки).

  void setMeta(Map<String, Map<String, String>> meta) {
    if (meta.isEmpty) return;
    commit({'op': 'setMeta', 'meta': meta});
  }

  String? _metaValue(String id, String key) {
    final v = data.edits[id]?[key];
    return (v == null || v.isEmpty) ? null : v;
  }

  /// Своя обложка: у альбома она важнее, чем у его треков, а у трека — важнее обложки из файла
  String? customCoverOf(Track t) => _metaValue('album:${t.albumKey}', 'cv') ?? t.customCover;
  // ---------- профиль: ник, аватарка, баннер (хранятся в edits['u:<почта>']) ----------

  String? profileNick(String email) => _metaValue('u:$email', 'nick');
  String? profileAvatar(String email) => _metaValue('u:$email', 'av');
  String? profileBanner(String email) => _metaValue('u:$email', 'bn');

  /// Меняет только свой профиль. Значение '' возвращает прежнее (имя из Google, цветной кружок, обычную шапку)
  void setProfile({String? nick, String? avatar, String? banner}) {
    final m = me;
    if (m == null) return;
    final f = <String, String>{
      if (nick != null) 'nick': nick,
      if (avatar != null) 'av': avatar,
      if (banner != null) 'bn': banner,
    };
    setMeta({'u:$m': f});
  }

  /// Все, кого мы знаем в компании: участники библиотеки, те, кто грузил треки, собирал плейлисты или лайкал
  Set<String> get people => {
        ...data.members.keys,
        for (final t in data.tracks.values) t.by,
        for (final p in data.playlists) p.by,
        for (final who in data.likes.values) ...who,
        if (me != null) me!,
      }..removeWhere((e) => e.isEmpty);

  String? albumCover(String albumKey) => _metaValue('album:$albumKey', 'cv');
  String? playlistCover(String id) => _metaValue('pl:$id', 'cv');

  /// [cover]: id картинки, пустая строка — вернуть обложку из файлов
  void setAlbumCover(String albumKey, String cover) => setMeta({'album:$albumKey': {'cv': cover}});
  void setPlaylistCover(String id, String cover) => setMeta({'pl:$id': {'cv': cover}});

  /// Любимые исполнители: у каждого свой список
  bool isFavArtist(String artistKey) => me != null && _metaValue('u:$me', 'fa:${artistKey.toLowerCase()}') != null;

  void toggleFavArtist(String artistKey) {
    final m = me;
    if (m == null) return;
    setMeta({'u:$m': {'fa:${artistKey.toLowerCase()}': isFavArtist(artistKey) ? '' : '1'}});
  }

  // ---------- папка с загруженными обложками ----------

  static const coversFolderName = 'cave-covers';
  String? _coversFolderId;

  Future<String> coversFolder() async {
    final cached = _coversFolderId;
    if (cached != null) return cached;
    final id = await _withHub((email) async {
      final found = (await drive.listChildren(email, settings.hubId!, nameEquals: coversFolderName))
          .where((f) => f.isFolder)
          .toList()
        ..sort((a, b) => a.createdTime.compareTo(b.createdTime));
      return found.isNotEmpty ? found.first.id : await drive.createFolder(email, coversFolderName, parent: settings.hubId);
    });
    return _coversFolderId = id;
  }

  /// Кладёт картинку в общую папку обложек и возвращает её id. Одинаковые картинки не дублируются
  Future<String> uploadCover(Uint8List bytes, String ext) async {
    final name = '${sha1.convert(bytes)}.$ext';
    final folder = await coversFolder();
    final tmp = File('${Directory.systemTemp.path}${Platform.pathSeparator}cave-$name');
    await tmp.writeAsBytes(bytes, flush: true);
    try {
      return await _withHub((email) async {
        final same = await drive.listChildren(email, folder, nameEquals: name);
        if (same.isNotEmpty) return same.first.id;
        return (await drive.uploadFile(email, folder, tmp)).id;
      });
    } finally {
      try {
        await tmp.delete();
      } catch (_) {}
    }
  }

  Future<Uint8List> downloadCover(String fileId) => _withHub((email) => drive.download(email, fileId));

  // ---------- длительность треков ----------

  bool _durationsRunning = false;
  final Set<String> _durationFailed = {};

  /// Узнаёт длительность у треков, у которых её ещё нет, и записывает в общие правки:
  /// следующим друзьям считать уже не придётся. Читает по паре небольших кусков файла.
  Future<void> fillDurations() async {
    if (_durationsRunning || !hasHub) return;
    _durationsRunning = true;
    try {
      final todo = [
        for (final t in allTracks)
          if (data.edits[t.id]?['d'] == null && !_durationFailed.contains(t.id)) t,
      ];
      if (todo.isEmpty) return;
      var batch = <String, Map<String, String>>{};
      void save() {
        if (batch.isEmpty) return;
        setMeta(batch);
        batch = {};
      }

      await _pool<Track>(todo, 2, (t) async {
        try {
          final email = await accessFor(t.source);
          final ms = await probeDurationMs((s, e) => drive.readRange(email, t.id, s, e), t.size);
          // 0 — «определить не вышло», чтобы не пробовать снова; настоящую длительность запишет плеер
          batch[t.id] = {'d': '${ms ?? 0}'};
        } catch (_) {
          _durationFailed.add(t.id); // сеть или доступ — попробуем при следующем запуске
          return;
        }
        if (batch.length >= 100) save();
      });
      save();
    } finally {
      _durationsRunning = false;
    }
  }

  /// Плеер знает точную длительность: запоминаем её, если для трека ещё ничего нет
  void noteDuration(Track t, Duration d) {
    if (d <= Duration.zero || (t.durationMs ?? 0) > 0) return;
    setMeta({t.id: {'d': '${d.inMilliseconds}'}});
  }

  void hideTrack(String id, bool hide) => commit({'op': 'hideTrack', 'id': id, 'on': hide});

  /// Отправляет файл в корзину Диска (можно восстановить оттуда 30 дней) и убирает из библиотеки
  Future<void> trashTrack(Track t) async {
    final email = await accessFor(t.source);
    await drive.trash(email, t.id);
    commit({'op': 'removeTracks', 'ids': [t.id]});
  }

  // ---------- загрузка файлов на Диск ----------

  final UploadStatus upload = UploadStatus();

  /// Загружает аудиофайлы с компьютера в папку библиотеки и сразу добавляет их в список
  Future<void> uploadFiles(List<String> paths, String folderId) async {
    final files = paths.where((p) => audioExt.hasMatch(p)).toList();
    if (files.isEmpty) {
      messages.add('Среди выбранных файлов нет музыки');
      return;
    }
    if (upload.running) {
      messages.add('Дождитесь окончания текущей загрузки');
      return;
    }
    upload
      ..running = true
      ..total = files.length
      ..done = 0
      ..failed = 0
      ..skipped = 0;
    notifyListeners();
    final source = data.sources.where((s) => s.id == folderId).firstOrNull;
    try {
      final email = await accessFor(folderId);
      for (final path in files) {
        final file = File(path);
        final name = file.uri.pathSegments.last;
        upload
          ..current = name
          ..fileProgress = 0;
        notifyListeners();
        try {
          // Такая песня уже есть — не загружаем вторую копию
          final tags = parseTags(await _readHead(file), name);
          final same = existing(tags.artist, tags.title);
          if (same != null) {
            upload.skipped++;
            AppLog.info('Уже есть в библиотеке, не загружаю: $name');
            continue;
          }
          await uploadOne(file, sourceId: folderId, folderId: folderId, email: email, onProgress: (p) {
            upload.fileProgress = p;
            notifyListeners();
          });
          upload.done++;
        } catch (e) {
          upload.failed++;
          AppLog.warn('Не удалось загрузить $name', e);
        }
      }
      final ok = upload.done;
      if (ok > 0) {
        onUploaded?.call(ok, source?.name ?? 'Cave Player');
        onEvent?.call({'k': 'upload', 'n': ok, 'folder': source?.name ?? 'Cave Player'});
      }
      final skipped = upload.skipped == 0 ? '' : ', уже были в библиотеке: ${upload.skipped}';
      messages.add(upload.failed == 0
          ? 'Загружено: $ok ${ok == 1 ? 'трек' : 'треков'}$skipped'
          : 'Загружено ${upload.done}, не получилось ${upload.failed}$skipped. Подробности в журнале ошибок.');
    } catch (e) {
      messages.add('Не получилось загрузить: $e');
    } finally {
      upload
        ..running = false
        ..current = '';
      notifyListeners();
    }
  }

  /// Загружает один файл в папку на Диске и сразу добавляет его в библиотеку.
  /// [sourceId] — папка библиотеки, [folderId] — она же или подпапка внутри неё.
  Future<Track> uploadOne(File file,
      {required String sourceId, required String folderId, String path = '', String? email, void Function(double)? onProgress}) async {
    final who = email ?? await accessFor(sourceId);
    final name = file.uri.pathSegments.where((s) => s.isNotEmpty).last;
    final tags = parseTags(await _readHead(file), name);
    final f = await drive.uploadFile(who, folderId, file, onProgress: onProgress);
    final t = Track(
      id: f.id,
      source: sourceId,
      title: tags.title,
      artist: tags.artist,
      album: tags.album,
      albumArtist: tags.albumArtist,
      no: tags.track,
      year: tags.year,
      pic: tags.pic,
      cover: null,
      modified: f.modifiedTime,
      size: f.size,
      by: me ?? who,
      path: path,
      added: f.createdTime,
    );
    commit({'op': 'upsertTracks', 'tracks': {f.id: t.toJson()}});
    return t;
  }

  /// Подпапка с таким именем внутри [parentId]; создаётся, если её нет
  Future<String> ensureSubfolder(String sourceId, String parentId, String name) async {
    final email = await accessFor(sourceId);
    final found = (await drive.listChildren(email, parentId, nameEquals: name)).where((f) => f.isFolder).toList();
    if (found.isNotEmpty) return found.first.id;
    return drive.createFolder(email, name, parent: parentId);
  }

  /// Вызывается после удачной загрузки — для ленты событий
  void Function(int count, String folderName)? onUploaded;

  static Future<Uint8List> _readHead(File f) async {
    final raf = await f.open();
    try {
      final len = await raf.length();
      return await raf.read(len < 131072 ? len : 131072);
    } finally {
      await raf.close();
    }
  }

  List<Track> playlistTracks(String id) {
    final p = playlist(id);
    if (p == null) return const [];
    return [for (final x in p.items) if (data.tracks[x] != null) data.tracks[x]!];
  }

  int tracksIn(String sourceId) => data.tracks.values.where((t) => t.source == sourceId).length;

  String nameOf(String email) {
    if (email.isEmpty) return 'кто-то';
    final nick = profileNick(email);
    if (nick != null) return nick;
    final n = data.members[email] ?? accounts.byEmail(email)?.name;
    if (n != null && n.isNotEmpty) return n;
    return email.split('@').first;
  }

  /// Ник показываем целиком, а имя из Google — только первое слово
  String firstNameOf(String email) => profileNick(email) ?? nameOf(email).split(' ').first;

  void _report(Object e) {
    AppLog.warn('Синхронизация', e);
    syncError = '$e';
    messages.add('$e');
    notifyListeners();
  }
}

class _Found {
  final DriveFile file;
  final String folder;
  final String path;
  _Found(this.file, this.folder, this.path);
}
