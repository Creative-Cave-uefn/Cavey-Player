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
import 'notices.dart' show maxAddedTracksInEvent;
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

  /// Все причастные исполнители: самые частые первыми
  final List<String> artists;

  /// Ключи «исполнитель + название», из которых склеен альбом (старые ссылки и обложки ведут сюда)
  final Set<String> keys;
  Album(this.key, this.title, this.artist, this.tracks, {List<String>? artists, Set<String>? keys})
      : artists = artists ?? splitArtists(artist),
        keys = keys ?? {key};
  Track get coverTrack => tracks.firstWhere((t) => t.hasCover, orElse: () => tracks.first);
  String get year => tracks.map((t) => t.year).firstWhere((y) => y.isNotEmpty, orElse: () => '');
}

class Artist {
  final String key;
  final String name;
  final List<Track> tracks;
  final int? _albums;
  Artist(this.key, this.name, this.tracks, {int? albums}) : _albums = albums;
  int get albums => _albums ?? tracks.map((t) => t.albumKey).toSet().length;
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

class FolderMergeStatus {
  bool running = false;
  int done = 0;
  int movedTracks = 0;
  String current = '';
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
  final FolderMergeStatus folderMerge = FolderMergeStatus();

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
        throw LibraryException('В этой папке нет общей библиотеки Cavey (файла library.json). '
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
    const note = 'Приглашаю в нашу общую музыкальную библиотеку Cavey. '
        'Установи Cavey и войди через Google с этой почтой — библиотека подключится сама.';
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
    // И6: разбор большого JSON — в фоновом потоке, чтобы интерфейс не дёргался
    final parsed = bytes.length > 200000 ? await compute(_decodeJson, bytes) : _decodeJson(bytes);
    return LibraryData.fromJson(parsed);
  }

  static dynamic _decodeJson(Uint8List bytes) => jsonDecode(utf8.decode(bytes));

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
    if (!hasHub || _flushing || _pending.isNotEmpty || folderMerge.running) return;
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
    if (_localTimer != null) {
      _localTimer!.cancel();
      _localTimer = null;
      await _saveLocalNow();
    }
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
        // Б1: перед записью проверяем, что файл не менял кто-то другой с момента скачивания.
        // Изменился — качаем заново и применяем свои правки поверх (до 3 попыток)
        late LibraryData latest;
        String? modified;
        for (var attempt = 0;; attempt++) {
          final before = (await drive.getFile(email, settings.libFileId!, fields: 'id,modifiedTime'))['modifiedTime'];
          // Е1: файл не менялся с нашего последнего чтения и новых правок за время сохранения нет —
          // локальная копия уже и есть актуальная, скачивать целиком не нужно
          if (before != null && before == _libModified && _pending.length == batch.length) {
            latest = data;
            modified = await drive.updateFile(email, settings.libFileId!, jsonEncode(latest.toJson()));
            break;
          }
          latest = await _downloadLatest(email);
          // Пока качали, человек отключился или сменил библиотеку: в чужой файл ничего не пишем
          if (settings.libFileId != libAtStart) throw _Abandoned();
          for (final op in batch) {
            latest.apply(op);
          }
          final after = (await drive.getFile(email, settings.libFileId!, fields: 'id,modifiedTime'))['modifiedTime'];
          if (after != before) {
            if (attempt >= 2) throw LibraryException('Библиотеку одновременно правят другие, сохраню чуть позже');
            AppLog.info('Библиотека изменилась во время сохранения, повторяю (${attempt + 1})');
            continue;
          }
          modified = await drive.updateFile(email, settings.libFileId!, jsonEncode(latest.toJson()));
          break;
        }
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

  // И6: локальную копию записываем не чаще раза в 5 секунд: при потоке правок (сканирование) это были лишние рывки
  DateTime _localAt = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _localTimer;

  Future<void> _saveLocal() async {
    final wait = const Duration(seconds: 5) - DateTime.now().difference(_localAt);
    if (wait > Duration.zero) {
      _localTimer ??= Timer(wait, () {
        _localTimer = null;
        unawaited(_saveLocalNow());
      });
      return;
    }
    await _saveLocalNow();
  }

  Future<void> _saveLocalNow() {
    _localAt = DateTime.now();
    return store.writeJson('library_cache.json', {
      'hub': settings.hubId,
      'modified': _libModified,
      'data': data.toJson(),
    });
  }

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


  // ---------- merge one music folder into another ----------

  /// Move actual Drive items, preserving their IDs. Merge same-named
  /// subfolders recursively; leave both files when their names collide.
  /// The original folder is trashed only after an empty-folder check and
  /// successful shared-index commit. A failed transfer can be retried.
  Future<void> mergeSourceInto(String sourceId, String targetId) async {
    if (!hasHub) throw LibraryException('Библиотека не подключена');
    if (sourceId == targetId || sourceId == settings.hubId) {
      throw LibraryException('Нельзя сливать папку с собой или убирать основную библиотеку');
    }
    if (!data.sources.any((s) => s.id == sourceId) ||
        !data.sources.any((s) => s.id == targetId)) {
      throw LibraryException('Обе папки должны быть подключены к библиотеке');
    }
    if (folderMerge.running || scan.running) {
      throw LibraryException('Дождитесь окончания сканирования или другого слияния');
    }
    await flushNow();
    if (hasUnsavedChanges) {
      throw LibraryException('Сначала дождитесь сохранения изменений в library.json');
    }
    final email = await accessFor(sourceId, recheck: true);
    final src = await drive.getFile(email, sourceId, fields: 'id,mimeType');
    final dst = await drive.getFile(email, targetId, fields: 'id,mimeType');
    if (src['mimeType'] != 'application/vnd.google-apps.folder' ||
        dst['mimeType'] != 'application/vnd.google-apps.folder') {
      throw LibraryException('Нужно выбрать две папки');
    }
    var ancestor = targetId;
    for (var i = 0; i < 40; i++) {
      if (ancestor == sourceId) {
        throw LibraryException('Папка назначения находится внутри исходной');
      }
      final info = await drive.getFile(email, ancestor, fields: 'id,parents');
      final parents = info['parents'];
      if (parents is! List || parents.isEmpty) break;
      ancestor = '${parents.first}';
    }

    folderMerge
      ..running = true
      ..done = 0
      ..movedTracks = 0
      ..current = 'Начинаю перенос';
    _changed();

    Future<void> relocate(Map<String, String> paths) async {
      if (paths.isEmpty) return;
      commit({
        'op': 'relocateSourceTracks',
        'from': sourceId,
        'to': targetId,
        'paths': paths,
      });
      folderMerge.movedTracks += paths.length;
      await store.writeJson('pending_ops.json', _pending);
    }

    Future<void> mergeDirectory(String from, String to, String path, int depth) async {
      if (depth > 20) throw LibraryException('Вложенность папок слишком глубокая');
      final items = await drive.listChildren(email, from);
      final targets = await drive.listChildren(email, to);
      for (final item in items) {
        folderMerge.current = item.name;
        _changed();
        if (item.isFolder) {
          final childPath = path.isEmpty ? item.name : '$path/${item.name}';
          final match = targets.where((f) => f.isFolder && f.name == item.name).toList();
          if (match.length == 1) {
            await mergeDirectory(item.id, match.single.id, childPath, depth + 1);
            if ((await drive.listChildren(email, item.id)).isEmpty) {
              await drive.trash(email, item.id);
            }
          } else {
            await drive.moveToFolder(email, item.id, fromParent: from, toParent: to);
            final moved = <String, String>{};
            for (final track in data.tracks.values) {
              if (track.source == sourceId &&
                  (track.path == childPath || track.path.startsWith('$childPath/'))) {
                moved[track.id] = track.path;
              }
            }
            await relocate(moved);
            folderMerge.done++;
          }
        } else {
          await drive.moveToFolder(email, item.id, fromParent: from, toParent: to);
          final track = data.tracks[item.id];
          if (track != null && track.source == sourceId) {
            await relocate({item.id: path});
          }
          folderMerge.done++;
        }
        _changed();
      }
    }

    try {
      await mergeDirectory(sourceId, targetId, '', 0);
      if ((await drive.listChildren(email, sourceId)).isNotEmpty) {
        throw LibraryException('В исходной папке остались файлы, повторите слияние');
      }
      if (data.tracks.values.any((t) => t.source == sourceId)) {
        throw LibraryException('Некоторые записи всё ещё относятся к исходной папке. '
            'Чтобы не потерять их, папка оставлена');
      }
      await flushNow();
      if (hasUnsavedChanges) {
        throw LibraryException('Перемещение ещё не сохранено в общей библиотеке');
      }
      commit({'op': 'removeSource', 'id': sourceId});
      await flushNow();
      if (hasUnsavedChanges) {
        throw LibraryException('Не удалось сохранить исключение исходной папки');
      }
      // Trash empty root only; no audio or cover file is deleted.
      await drive.trash(email, sourceId);
      settings.sourceAccess.remove(sourceId);
      await saveSettings();
      messages.add('Слияние выполнено. Треки, лайки и плейлисты сохранены');
    } catch (e) {
      messages.add('Слияние приостановлено: $e. У перенесённых файлов ID не менялись');
      rethrow;
    } finally {
      folderMerge
        ..running = false
        ..current = '';
      _changed();
    }
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
    if (scan.running || folderMerge.running || accounts.accounts.isEmpty) return;
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
      } else if (old.cover != cover || (old.md5.isEmpty && f.file.md5.isNotEmpty)) {
        // обложка поменялась или у старой записи ещё нет md5 — обновляем без чтения тегов
        final j = old.toJson();
        if (cover != null) {
          j['c'] = cover;
        } else {
          j.remove('c');
        }
        if (f.file.md5.isNotEmpty) j['md5'] = f.file.md5;
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
        md5: f.file.md5,
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
            'проверьте доступ к папке или подтвердите очистку в настройках, в разделе «Папки с музыкой».');
      } else {
        suspiciousSources.remove(s.id);
        commit({'op': 'removeTracks', 'ids': removed});
      }
    } else {
      suspiciousSources.remove(s.id);
    }
    // Сообщаем только о своих новых треках: чужие появляются в библиотеке и ленте без уведомления
    return mine;
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

  /// Добавить в любимое сразу несколько треков (или убрать, если [on] false). Лента не засоряется.
  void setLikes(Iterable<String> trackIds, bool on) {
    final m = me;
    if (m == null) return;
    for (final id in trackIds) {
      if (isLiked(id) != on) commit({'op': 'like', 'id': id, 'email': m, 'on': on});
    }
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
    _announceAdded(id, items);
    return id;
  }

  /// Сообщаем друзьям, что в плейлист добавлены их треки (они получат уведомление). Названием плейлиста делимся,
  /// только если он открытый: приватный остаётся приватным.
  void _announceAdded(String playlistId, List<String> items) {
    final m = me;
    final others = [
      for (final x in items)
        if (data.tracks[x] != null && data.tracks[x]!.by.isNotEmpty && data.tracks[x]!.by != m) x
    ];
    if (others.isEmpty) return;
    final p = playlist(playlistId);
    onEvent?.call({
      'k': 'addpl',
      'tracks': others.take(maxAddedTracksInEvent).toList(),
      if (p != null && isPlaylistPublic(playlistId)) 'name': p.name,
    });
  }

  /// Поделиться треком с друзьями внутри приложения
  void shareTrack(String trackId, List<String> to, {String note = ''}) {
    if (to.isEmpty) return;
    onEvent?.call({'k': 'share', 'to': to, 'track': trackId, if (note.trim().isNotEmpty) 'note': note.trim()});
  }

  void renamePlaylist(String id, String name) => commit({'op': 'renamePlaylist', 'id': id, 'name': name});
  void deletePlaylist(String id) => commit({'op': 'deletePlaylist', 'id': id});
  void addToPlaylist(String id, List<String> items) {
    commit({'op': 'addToPlaylist', 'id': id, 'items': items, 'at': DateTime.now().millisecondsSinceEpoch});
    _announceAdded(id, items);
  }

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
    final merged = mergeAlbumGroups(byAlbum);
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
    _albums = [for (final keys in merged) buildAlbum(keys, byAlbum)]
      ..sort((a, b) => a.artist.toLowerCase().compareTo(b.artist.toLowerCase()) != 0
          ? a.artist.toLowerCase().compareTo(b.artist.toLowerCase())
          : a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    _albumByKey = {
      for (final a in _albums)
        for (final k in a.keys) k: a,
    };
    for (final a in _albums) {
      _albumByKey[a.key] = a;
    }
    _artists = [
      for (final e in byArtist.entries)
        Artist(e.key, names[e.key]!, e.value, albums: {for (final t in e.value) _albumByKey[t.albumKey]?.key ?? t.albumKey}.length)
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    _artistByKey = {for (final a in _artists) a.key: a};
  }

  Map<String, Album> _albumByKey = const {};

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

  /// Альбом по ключу: и по новому (склеенному), и по старому «исполнитель + название»
  Album? album(String key) {
    _rebuild();
    return _albumByKey[key];
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

  /// Отличаем одинаковые названия на разных альбомах: это могут быть разные записи.
  static String recordingKey(Track track) {
    final name = dupKey(track.artist, track.title);
    return name.isEmpty ? '' : '$name|${_albumName(track.album)}';
  }

  static String _albumName(String album) =>
      album.toLowerCase().trim().replaceAll(RegExp(r'\s+'), ' ');

  /// Совпадения по названию недостаточно: альбом должен совпасть, если указан.
  /// Длительность дополнительно защищает от разных аранжировок одного альбома.
  static bool matchesRecording(Track candidate, {String album = '', double? duration}) {
    final requestedAlbum = _albumName(album);
    if (requestedAlbum.isNotEmpty && _albumName(candidate.album) != requestedAlbum) return false;
    if (duration != null && duration > 0) {
      final existingMs = candidate.durationMs;
      if (existingMs == null || existingMs <= 0) {
        // Без альбома и без длительности нельзя уверенно считать записи одинаковыми.
        if (requestedAlbum.isEmpty) return false;
      } else if ((existingMs - duration * 1000).abs() > 2500) {
        return false;
      }
    }
    return true;
  }

  /// Группы копий в пределах одного альбома, не объединяя разные саундтреки.
  List<List<Track>> get duplicates {
    final groups = <String, List<Track>>{};
    for (final t in allTracks) {
      final k = recordingKey(t);
      if (k.isEmpty) continue;
      groups.putIfAbsent(k, () => []).add(t);
    }
    return groups.values.where((g) => g.length > 1).toList()
      ..sort((a, b) => a.first.title.toLowerCase().compareTo(b.first.title.toLowerCase()));
  }

  /// Такая песня уже есть в библиотеке (видимая копия) — чтобы не качать и не загружать её снова
  /// Ищет не только точное совпадение: в названии может стоять исполнитель («Korn - Freak On a Leash»),
  /// исполнитель может быть записан иначе («KoЯn», «The Weeknd» и «Weeknd», «A feat. B»)
  Track? existing(String artist, String title, {String album = '', double? duration}) {
    final k = dupKey(artist, title);
    if (k.isEmpty) return null;
    if (_dupVersion != _version) {
      _dupVersion = _version;
      _dupIndex = {};
      _titleIndex = {};
      for (final t in allTracks) {
        final tk = dupKey(t.artist, t.title);
        if (tk.isNotEmpty) _dupIndex.putIfAbsent(tk, () => []).add(t);
        final tt = titleKey(t.artist, t.title);
        if (tt.isNotEmpty) _titleIndex.putIfAbsent(tt, () => []).add(t);
      }
    }
    // Не останавливаемся на первом совпавшем названии: оно может быть из другого альбома.
    for (final candidate in _dupIndex[k] ?? const <Track>[]) {
      if (matchesRecording(candidate, album: album, duration: duration)) return candidate;
    }
    for (final candidate in _titleIndex[titleKey(artist, title)] ?? const <Track>[]) {
      if (artistsMatch(artist, candidate.artist) &&
          matchesRecording(candidate, album: album, duration: duration)) return candidate;
    }
    return null;
  }

  /// Название без мусора и без исполнителя в начале («Korn - Blind» → «blind»)
  static String titleKey(String artist, String title) {
    var t = _norm(title);
    for (final a in [...splitArtists(artist), artist]) {
      final n = _norm(a);
      if (n.isNotEmpty && t.startsWith('$n ') && t.length > n.length + 1) {
        t = t.substring(n.length + 1).trim();
        break;
      }
    }
    // «… - Remastered 2011», «… 2011 Remaster» без скобок
    t = t.replaceAll(RegExp(r'\s+(\d{4}\s+)?remaster(ed)?(\s+\d{4})?(\s+version)?$'), '').trim();
    return t;
  }

  /// Один и тот же исполнитель, записанный по-разному: совпадает хоть один из соавторов,
  /// без «the», пробелов и знаков; короткие имена — только точно
  static bool artistsMatch(String a, String b) {
    Set<String> keys(String s) => {
          for (final x in [...splitArtists(s), s])
            if (_norm(x).replaceAll(RegExp(r'^the '), '').replaceAll(' ', '') case final k when k.isNotEmpty) k,
        };
    final ka = keys(a), kb = keys(b);
    for (final x in ka) {
      for (final y in kb) {
        if (x == y) return true;
        if (x.length >= 4 && y.length >= 4 && (x.startsWith(y) || y.startsWith(x))) return true;
      }
    }
    return false;
  }

  Map<String, List<Track>> _titleIndex = {};
  Map<String, List<Track>> _dupIndex = {};
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

  /// Удаляет треки: из библиотеки у всех сразу, а файлы — в корзину Диска их владельцев (30 дней можно вернуть).
  /// Свои файлы удаляются сразу, чужие — когда владелец откроет Cave Player
  /// (удалить чужой файл Google Диск не даёт никому, кроме владельца)
  void deleteTracks(Iterable<Track> list) {
    final ids = {for (final t in list) t.id: t.by};
    if (ids.isEmpty) return;
    final names = {for (final t in list) t.id: '${t.displayArtist} — ${t.title}'};
    commit({'op': 'deleteTracks', 'ids': ids, 'names': names, if (me != null) 'by': me});
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

  /// Мои файлы, которые удалил друг: сами не удаляем, спрашиваем (А3). id → кто предложил
  Map<String, String> get foreignDeletions {
    final mine = {for (final a in accounts.accounts) a.email.toLowerCase()};
    return {
      for (final e in data.deleted.entries)
        if (mine.contains(e.value.toLowerCase()) &&
            (data.deletedBy[e.key] ?? '').isNotEmpty &&
            !mine.contains(data.deletedBy[e.key]!.toLowerCase()))
          e.key: data.deletedBy[e.key]!
    };
  }

  /// «Удалить» — файл уходит в корзину Диска
  Future<void> approveForeignDeletions(Iterable<String> ids) async {
    for (final id in ids) {
    }
    commit({'op': 'approveDeletion', 'ids': ids.toList()});
    await processDeletions();
  }

  /// «Оставить» — снимаем отметку, ближайший скан вернёт трек в библиотеку
  Future<void> keepForeignDeletions(Iterable<String> ids) async {
    commit({'op': 'purged', 'ids': ids.toList()});
    AppLog.info('Оставлены файлы, которые предлагали удалить: ${ids.length}');
    unawaited(scanAll(quiet: true));
  }

  Future<int> processDeletions() async {
    if (_purging || data.deleted.isEmpty) return 0;
    _purging = true;
    final done = <String>[];
    try {
      for (final e in Map.of(data.deleted).entries) {
        final owner = e.value.toLowerCase();
        final acc = accounts.accounts.where((a) => a.email.toLowerCase() == owner).firstOrNull;
        if (acc == null) continue; // не мой файл — удалит владелец
        // Удаление записал не я и не владелец (я им стал) — ждёт моего подтверждения
        final by = (data.deletedBy[e.key] ?? '').toLowerCase();
        if (by != owner && !accounts.accounts.any((a) => a.email.toLowerCase() == by)) continue;
        try {
          await drive.trash(acc.email, e.key); // в корзину Диска, не навсегда
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

  /// Точные копии (та же песня и одинаковая md5-сумма файла) объединяем сами.
  /// Выбор однозначный, поэтому у всех друзей остаётся одна и та же копия.
  /// Записи без md5 (старые, ещё не пересканированные) не трогаем.
  int mergeExactCopies() {
    var n = 0;
    for (final g in duplicates) {
      final byHash = <String, List<Track>>{};
      for (final t in g) {
        if (t.md5.isNotEmpty) byHash.putIfAbsent(t.md5, () => []).add(t);
      }
      for (final same in byHash.values.where((l) => l.length > 1)) {
        final keep = bestOf(same);
        mergeAndDelete(keep, same);
        n += same.length - 1;
      }
    }
    if (n > 0) AppLog.info('Дубликаты: объединено точных копий $n');
    return n;
  }

  static String _norm(String s) => _latinize(s
      .toLowerCase())
      .replaceAll(RegExp(r'[\(\[][^\)\]]*(official|video|audio|lyrics|клип|remaster|hq|hd|feat|ft\.|prod\.|при уч)[^\)\]]*[\)\]]'), '')
      .replaceAll('ё', 'е')
      .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
      .trim();

  static const _lookalike = {
    'а': 'a', 'в': 'b', 'е': 'e', 'к': 'k', 'м': 'm', 'н': 'h', 'о': 'o', 'р': 'p', 'с': 'c', 'т': 't', 'у': 'y', 'х': 'x', 'я': 'r', 'и': 'n',
  };

  /// Латинское слово с кириллической буквой-двойником («koяn») → латиница («korn»)
  static String _latinize(String s) => s.replaceAllMapped(RegExp(r'[\p{L}]+', unicode: true), (m) {
        final w = m[0]!;
        if (!w.contains(RegExp(r'[a-z]')) || !w.contains(RegExp(r'[а-яё]'))) return w;
        return w.split('').map((c) => _lookalike[c] ?? c).join();
      });

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
    if (fields.containsKey('a') || fields.containsKey('al') || fields.containsKey('aa')) {
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
        final newKeys = {
          for (final t in tracks) t.albumKeyWith(newArtist: fields['a'], newAlbum: fields['al'], newAlbumArtist: fields['aa'])
        };
        if (newKeys.length != 1 || newKeys.first == oldKey || albumCover(newKeys.first) != null) return;
        meta['album:${newKeys.first}'] = {'cv': cover};
      });
    }
    setMeta(meta);
  }

  /// Правка альбома целиком (окно «Альбом»): название, год и исполнитель альбома — у всех его треков,
  /// обложка — альбому. null — поле не меняется; cover == '' — вернуть обложку из файлов.
  /// Исполнители отдельных треков не трогаются, иначе пропадут соавторы.
  void editAlbum(Album a, {String? title, String? year, String? albumArtist, String? cover}) {
    final ids = [for (final t in a.tracks) t.id];
    if (ids.isEmpty) return;
    final keep = albumCover(a.key);
    final fields = <String, String>{
      if (title != null) 'al': title,
      if (year != null) 'y': year,
      if (albumArtist != null) 'aa': albumArtist,
    };
    if (fields.isNotEmpty) editTracks(ids, fields);
    final now = data.tracks[ids.first];
    if (now == null) return;
    final target = cover ?? keep;
    if (target != null && (cover != null || fields.isNotEmpty)) setAlbumCover(now.albumKey, target);
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
  String? customCoverOf(Track t) => albumCover(t.albumKey) ?? t.customCover;
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

  // ---------- открытые и приватные плейлисты (edits['pl:<id>']['pub']) ----------
  // Новый плейлист приватный: его видит только автор. Старые версии приложения флаг не знают и показывают всё.

  bool isPlaylistPublic(String id) => _metaValue('pl:$id', 'pub') == '1';

  bool canSeePlaylist(Playlist p) => p.by.isEmpty || p.by == me || isPlaylistPublic(p.id);

  /// Плейлисты, которые видит этот человек: свои и открытые
  List<Playlist> get visiblePlaylists => [for (final p in data.playlists) if (canSeePlaylist(p)) p];

  void setPlaylistPublic(String id, bool on) => setMeta({'pl:$id': {'pub': on ? '1' : ''}});

  /// Своя обложка альбома. У склеенного альбома — первая найденная среди его частей, главная часть важнее
  String? albumCover(String albumKey) {
    final a = album(albumKey);
    if (a == null) return _metaValue('album:$albumKey', 'cv');
    for (final k in [a.key, ...a.keys]) {
      final v = _metaValue('album:$k', 'cv');
      if (v != null) return v;
    }
    return null;
  }
  String? playlistCover(String id) => _metaValue('pl:$id', 'cv');

  /// [cover]: id картинки, пустая строка — вернуть обложку из файлов
  void setAlbumCover(String albumKey, String cover) {
    final a = album(albumKey);
    if (a == null) {
      setMeta({'album:$albumKey': {'cv': cover}});
      return;
    }
    // Своя обложка ставится главной части, а со всех остальных снимается: иначе у склеенного альбома их две
    setMeta({
      for (final k in a.keys) 'album:$k': {'cv': ''},
      'album:${a.key}': {'cv': cover},
    });
  }
  void setPlaylistCover(String id, String cover) => setMeta({'pl:$id': {'cv': cover}});

  /// Любимые исполнители: у каждого свой список
  bool isFavArtist(String artistKey) => me != null && _metaValue('u:$me', 'fa:${artistKey.toLowerCase()}') != null;

  void toggleFavArtist(String artistKey) {
    final m = me;
    if (m == null) return;
    setMeta({'u:$m': {'fa:${artistKey.toLowerCase()}': isFavArtist(artistKey) ? '' : '1'}});
  }

  /// Любимые плейлисты (чужие — свои и так всегда в боковой панели) и альбомы. Хранятся, как и исполнители,
  /// в общей записи человека: одинаковы на всех его компьютерах и видны друзьям в профиле
  bool isFavPlaylist(String id) => me != null && _metaValue('u:$me', 'fp:$id') != null;

  void toggleFavPlaylist(String id) {
    final m = me;
    if (m == null) return;
    setMeta({'u:$m': {'fp:$id': isFavPlaylist(id) ? '' : '1'}});
  }

  /// У склеенного альбома отметка могла стоять на любой его части
  bool isFavAlbum(Album a) => me != null && [a.key, ...a.keys].any((k) => _metaValue('u:$me', 'fl:${k.toLowerCase()}') != null);

  void toggleFavAlbum(Album a) {
    final m = me;
    if (m == null) return;
    if (isFavAlbum(a)) {
      setMeta({'u:$m': {for (final k in {a.key, ...a.keys}) 'fl:${k.toLowerCase()}': ''}});
    } else {
      setMeta({'u:$m': {'fl:${a.key.toLowerCase()}': '1'}});
    }
  }

  /// Что человек отметил сердечком: плейлисты, альбомы и исполнители (для боковой панели и профиля)
  ({List<Playlist> playlists, List<Album> albums, List<Artist> artists}) favoritesOf(String email) {
    final e = data.edits['u:$email'] ?? const <String, String>{};
    final pl = <Playlist>[];
    final al = <Album>[];
    final ar = <Artist>[];
    final seenAlbums = <String>{};
    for (final entry in e.entries) {
      if (entry.value.isEmpty) continue;
      final k = entry.key;
      if (k.startsWith('fp:')) {
        final p = playlist(k.substring(3));
        if (p != null && (p.by == email || isPlaylistPublic(p.id) || email == me)) pl.add(p);
      } else if (k.startsWith('fl:')) {
        final a = album(k.substring(3));
        if (a != null && seenAlbums.add(a.key)) al.add(a);
      } else if (k.startsWith('fa:')) {
        final a = artist(k.substring(3));
        if (a != null) ar.add(a);
      }
    }
    pl.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    al.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    ar.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return (playlists: pl, albums: al, artists: ar);
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
          final same = existing(tags.artist, tags.title, album: tags.album);
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
      md5: f.md5,
      by: me ?? who,
      path: path,
      added: f.createdTime,
    );
    commit({'op': 'upsertTracks', 'tracks': {f.id: t.toJson()}});
    return t;
  }

  /// Replaces audio in place. The Drive file ID is stable so playlist entries,
  /// likes, shared links and user metadata edits continue to refer to this track.
  Future<void> replaceTrackAudio(Track original, File audio,
      {required String mime, void Function(double)? onProgress,
       void Function(String)? onStatus}) async {
    if (data.tracks[original.id] == null) {
      throw LibraryException('Трек исчез из библиотеки.');
    }
    final email = await accessFor(original.source);
    final result = await drive.replaceFileMedia(email, original.id, audio,
        mime: mime, onProgress: onProgress, onStatus: onStatus);
    final tags = parseTags(await _readHead(audio), audio.uri.pathSegments.last);
    final json = original.toJson();
    json['m'] = result.modifiedTime;
    json['sz'] = result.size;
    if (result.md5.isNotEmpty) json['md5'] = result.md5;
    if (tags.pic != null) {
      json['p'] = [tags.pic!.offset, tags.pic!.length, tags.pic!.mime];
    } else {
      json.remove('p'); // old embedded image offset would refer to wrong bytes
    }
    commit({'op': 'upsertTracks', 'tracks': {original.id: json}});
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

// ---------- склейка альбомов ----------

String _normAlbumTitle(String s) => s.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();

Set<String> _albumNames(Track t) => {
      for (final n in t.artists) n.toLowerCase(),
      if (t.albumArtist.isNotEmpty) ...splitArtists(t.albumArtist).map((n) => n.toLowerCase()),
    };

/// Какие группы «исполнитель + название» — один альбом. Склеиваются группы с одним названием,
/// если они лежат в одной папке на Диске или у них есть общий исполнитель.
/// Треки без названия альбома в тегах (альбом — имя папки или «Без альбома») не склеиваются.
List<List<String>> mergeAlbumGroups(Map<String, List<Track>> groups) {
  final byTitle = <String, List<String>>{};
  final out = <List<String>>[];
  for (final e in groups.entries) {
    final first = e.value.first;
    if (e.value.every((t) => t.album.isEmpty)) {
      out.add([e.key]);
      continue;
    }
    byTitle.putIfAbsent(_normAlbumTitle(first.displayAlbum), () => []).add(e.key);
  }
  for (final keys in byTitle.values) {
    if (keys.length == 1) {
      out.add(keys);
      continue;
    }
    final parent = {for (final k in keys) k: k};
    String find(String k) {
      while (parent[k] != k) {
        k = parent[k] = parent[parent[k]!]!;
      }
      return k;
    }

    final folders = {for (final k in keys) k: {for (final t in groups[k]!) '${t.source}/${t.path}'}};
    final names = {for (final k in keys) k: {for (final t in groups[k]!) ..._albumNames(t)}};
    for (var i = 0; i < keys.length; i++) {
      for (var j = i + 1; j < keys.length; j++) {
        final a = keys[i], b = keys[j];
        if (folders[a]!.any(folders[b]!.contains) || names[a]!.any(names[b]!.contains)) {
          parent[find(a)] = find(b);
        }
      }
    }
    final sets = <String, List<String>>{};
    for (final k in keys) {
      sets.putIfAbsent(find(k), () => []).add(k);
    }
    out.addAll(sets.values);
  }
  return out;
}

/// Собирает альбом из склеенных групп: ключ — у самой большой части, исполнитель — самый частый
Album buildAlbum(List<String> keys, Map<String, List<Track>> groups) {
  final sorted = List.of(keys)..sort((a, b) => groups[b]!.length.compareTo(groups[a]!.length));
  final tracks = [for (final k in sorted) ...groups[k]!];
  if (sorted.length > 1) {
    tracks.sort((a, b) {
      final r = (a.no ?? 9999).compareTo(b.no ?? 9999);
      return r != 0 ? r : a.title.toLowerCase().compareTo(b.title.toLowerCase());
    });
  }
  String most(Map<String, int> m) => (m.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).first.key;

  final titles = <String, int>{};
  final whole = <String, int>{}; // исполнитель альбома целиком, как в тегах
  final single = <String, int>{}; // каждый исполнитель отдельно
  final shown = <String, String>{};
  for (final t in tracks) {
    titles[t.displayAlbum] = (titles[t.displayAlbum] ?? 0) + 1;
    final w = t.albumArtist.isNotEmpty ? t.albumArtist : t.displayArtist;
    whole[w] = (whole[w] ?? 0) + 1;
    for (final n in {...t.artists, if (t.albumArtist.isNotEmpty) ...splitArtists(t.albumArtist)}) {
      final k = n.toLowerCase();
      shown.putIfAbsent(k, () => n);
      single[k] = (single[k] ?? 0) + 1;
    }
  }
  final half = (tracks.length + 1) ~/ 2;
  String artist;
  final topWhole = most(whole);
  if (whole[topWhole]! >= half) {
    artist = topWhole;
  } else if (single.isNotEmpty && single[most(single)]! >= half) {
    artist = shown[most(single)]!;
  } else {
    artist = 'Разные исполнители';
  }
  final order = single.keys.toList()..sort((a, b) => single[b]!.compareTo(single[a]!));
  return Album(sorted.first, most(titles), artist, tracks, artists: [for (final k in order) shown[k]!], keys: keys.toSet());
}
