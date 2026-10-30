import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../config.dart';
import 'auth.dart';
import 'log.dart';
import 'drive.dart';
import 'models.dart';
import 'store.dart';
import 'tags.dart';

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
    _scanTimer = Timer.periodic(const Duration(minutes: 10), (_) => scanAll(quiet: true));
    () async {
      try {
        await reload();
        await _ensureHubSource();
        if (_pending.isNotEmpty) _scheduleFlush();
        await scanAll(quiet: true);
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
      ..libFileId = f['id'] as String;
    _libModified = f['modifiedTime'] as String?;
    data = fresh;
    _pending.clear();
    await saveSettings();
    await _saveLocal();
    _changed();
    _goOnline();
  }

  Future<void> joinHub(String input) async {
    final id = parseDriveId(input);
    if (id == null) throw LibraryException('Это не похоже на ссылку на папку Google Диска');
    for (final a in accounts.accounts) {
      Map<String, dynamic> meta;
      try {
        meta = await drive.getFile(a.email, id, fields: 'id,name,mimeType');
      } on DriveException catch (e) {
        if (e.notFound || e.forbidden) continue;
        rethrow;
      }
      if (meta['mimeType'] != 'application/vnd.google-apps.folder') {
        throw LibraryException('По ссылке файл, а нужна папка «Cave Player»');
      }
      final found = await drive.listChildren(a.email, id, nameEquals: 'library.json');
      String libId;
      if (found.isNotEmpty) {
        libId = found.first.id;
      } else {
        final f = await drive.createFile(a.email, id, 'library.json', jsonEncode(LibraryData().toJson()));
        libId = f['id'] as String;
      }
      settings
        ..hubId = id
        ..hubEmail = a.email
        ..libFileId = libId;
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

  /// Ищет общую библиотеку сам: сначала папку из настроек сборки, потом любую
  /// library.json на Дисках подключённых аккаунтов. Так друзьям не нужна ссылка.
  Future<bool> autoJoin() async {
    if (hasHub || accounts.accounts.isEmpty) return hasHub;
    if (kDefaultLibraryId.isNotEmpty) {
      try {
        await joinHub(kDefaultLibraryId);
        return true;
      } catch (_) {
        // к папке по умолчанию нет доступа — поищем другие
      }
    }
    final folders = <String>[];
    for (final a in accounts.accounts) {
      try {
        for (final f in await drive.findLibraries(a.email)) {
          final parents = f['parents'];
          if (parents is List && parents.isNotEmpty && !folders.contains('${parents.first}')) {
            folders.add('${parents.first}');
          }
        }
      } catch (_) {
        // этот аккаунт не смог поискать — пробуем остальные
      }
    }
    for (final id in folders) {
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

  Future<void> leaveHub() async {
    _pollTimer?.cancel();
    _scanTimer?.cancel();
    settings
      ..hubId = null
      ..hubEmail = null
      ..libFileId = null
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
    await _withHub((email) async {
      final meta = await drive.getFile(email, settings.libFileId!, fields: 'id,modifiedTime');
      final latest = await _downloadLatest(email);
      for (final op in _pending) {
        latest.apply(op);
      }
      data = latest;
      _libModified = meta['modifiedTime'] as String?;
    });
    syncError = null;
    await _saveLocal();
    _changed();
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
    data.apply(op);
    _pending.add(op);
    _changed();
    unawaited(store.writeJson('pending_ops.json', _pending));
    _scheduleFlush();
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
    try {
      await _withHub((email) async {
        final latest = await _downloadLatest(email);
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
      });
      syncError = null;
      await store.writeJson('pending_ops.json', _pending);
      await _saveLocal();
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

  Future<void> _runScan(List<Source> sources, {bool quiet = false}) async {
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
          added += await _scanSource(s);
        } catch (e) {
          AppLog.warn('Сканирование «${s.name}»', e);
          messages.add('Не получилось обновить «${s.name}»: $e');
        }
      }
      settings.lastScan = DateTime.now().toIso8601String();
      await saveSettings();
      if (!quiet || added > 0) {
        messages.add(added > 0 ? 'Новых треков: $added' : 'Новых треков нет');
      }
    } finally {
      scan
        ..running = false
        ..text = '';
      notifyListeners();
    }
  }

  Future<int> _scanSource(Source s) async {
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
    if (removed.isNotEmpty) commit({'op': 'removeTracks', 'ids': removed});
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
          if (c.name == dataFolderName && folder == settings.hubId) continue; // служебная папка
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
  void addToPlaylist(String id, List<String> items) => commit({'op': 'addToPlaylist', 'id': id, 'items': items});
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
    final byArtist = <String, List<Track>>{};
    for (final t in all) {
      byArtist.putIfAbsent(t.displayArtist.toLowerCase(), () => []).add(t);
    }
    _artists = [for (final e in byArtist.entries) Artist(e.key, e.value.first.displayArtist, e.value)]
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
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

  Artist? artist(String key) {
    for (final a in artists) {
      if (a.key == key) return a;
    }
    return null;
  }

  /// Последние добавленные на Диск треки, новые сверху
  List<Track> get recent {
    final list = List.of(allTracks);
    String when(Track t) => t.added.isNotEmpty ? t.added : t.modified;
    list.sort((a, b) => when(b).compareTo(when(a)));
    return list.length > 300 ? list.sublist(0, 300) : list;
  }

  /// Группы похожих треков: одинаковые исполнитель и название без мусора вроде «(Official Video)»
  List<List<Track>> get duplicates {
    final groups = <String, List<Track>>{};
    for (final t in allTracks) {
      final k = '${_norm(t.artist)}|${_norm(t.title)}';
      if (k == '|') continue;
      groups.putIfAbsent(k, () => []).add(t);
    }
    return groups.values.where((g) => g.length > 1).toList()
      ..sort((a, b) => a.first.title.toLowerCase().compareTo(b.first.title.toLowerCase()));
  }

  static String _norm(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[\(\[][^\)\]]*(official|video|audio|lyrics|клип|remaster|hq|hd)[^\)\]]*[\)\]]'), '')
      .replaceAll('ё', 'е')
      .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
      .trim();

  // ---------- правка, скрытие, удаление ----------

  void editTrack(String id, {required String title, required String artist, required String album}) =>
      commit({'op': 'editTrack', 'id': id, 'fields': {'t': title, 'a': artist, 'al': album}});

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
      ..failed = 0;
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
      messages.add(upload.failed == 0
          ? 'Загружено: ${ok} ${ok == 1 ? 'трек' : 'треков'}'
          : 'Загружено ${upload.done}, не получилось ${upload.failed}. Подробности в журнале ошибок.');
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
    final n = data.members[email] ?? accounts.byEmail(email)?.name;
    if (n != null && n.isNotEmpty) return n;
    return email.split('@').first;
  }

  String firstNameOf(String email) => nameOf(email).split(' ').first;

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
