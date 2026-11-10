// Очередь «Ожидают загрузки»: файлы, которые скачались или выбраны, но не ушли на Диск
// (брокер недоступен, у владельца нет места и т. п.). Копии лежат в папке приложения и переживают перезапуск.

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'store.dart';

class PendingUpload {
  final String id;
  final String path; // копия файла в папке приложения
  final String name; // исходное имя файла
  final String sourceId, folderId, relPath;
  final String uploadSource; // deezer, soulseek, youtube, bandcamp, manual
  final String added;
  int attempts;
  String lastError;

  /// Невозобновляемая причина (например, файл слишком большой): автоматически не повторяем
  bool stuck;

  /// Метаданные, которые загрузчик передал до окончания загрузки; применятся к треку после неё
  Map<String, String> edit;

  PendingUpload({
    required this.id,
    required this.path,
    required this.name,
    required this.sourceId,
    required this.folderId,
    this.relPath = '',
    this.uploadSource = 'manual',
    String? added,
    this.attempts = 0,
    this.lastError = '',
    this.stuck = false,
    Map<String, String>? edit,
  })  : added = added ?? DateTime.now().toIso8601String(),
        edit = edit ?? {};

  Map<String, dynamic> toJson() => {
        'id': id,
        'path': path,
        'name': name,
        'src': sourceId,
        'folder': folderId,
        'rel': relPath,
        'from': uploadSource,
        'added': added,
        'n': attempts,
        'err': lastError,
        'stuck': stuck,
        'edit': edit,
      };

  static PendingUpload? fromJson(Object? j) {
    if (j is! Map || j['id'] is! String || j['path'] is! String) return null;
    return PendingUpload(
      id: j['id'] as String,
      path: j['path'] as String,
      name: '${j['name'] ?? ''}',
      sourceId: '${j['src'] ?? ''}',
      folderId: '${j['folder'] ?? ''}',
      relPath: '${j['rel'] ?? ''}',
      uploadSource: '${j['from'] ?? 'manual'}',
      added: j['added'] as String?,
      attempts: (j['n'] as num?)?.toInt() ?? 0,
      lastError: '${j['err'] ?? ''}',
      stuck: j['stuck'] == true,
      edit: {
        if (j['edit'] is Map) for (final e in (j['edit'] as Map).entries) '${e.key}': '${e.value}',
      },
    );
  }
}

/// Файл не загрузился сейчас, но сохранён в очереди и уйдёт на Диск позже. Это не ошибка загрузчика.
class UploadDeferred implements Exception {
  final String pendingId;
  final String reason;
  const UploadDeferred(this.pendingId, this.reason);
  @override
  String toString() => 'Ожидает загрузки: $reason';
}

class UploadQueue extends ChangeNotifier {
  static const idPrefix = 'pending:';

  final AppStore store;
  final List<PendingUpload> items = [];
  bool retrying = false;

  UploadQueue(this.store);

  Directory get _dir => store.sub('pending-uploads');

  int get count => items.length;

  PendingUpload? byId(String id) {
    final key = id.startsWith(idPrefix) ? id.substring(idPrefix.length) : id;
    for (final p in items) {
      if (p.id == key) return p;
    }
    return null;
  }

  Future<void> load() async {
    final j = await store.readJson('pending_uploads.json');
    items.clear();
    if (j is List) {
      for (final x in j) {
        final p = PendingUpload.fromJson(x);
        if (p != null) items.add(p);
      }
    }
    notifyListeners();
  }

  Future<void> _save() => store.writeJson('pending_uploads.json', [for (final p in items) p.toJson()]);

  /// Копирует файл в папку очереди (исходный может лежать во временной папке загрузчика и скоро исчезнет)
  Future<PendingUpload> add(File file,
      {required String sourceId, required String folderId, String relPath = '', String uploadSource = 'manual', required String reason}) async {
    final id = '${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(1 << 32).toRadixString(36)}';
    final name = file.uri.pathSegments.where((s) => s.isNotEmpty).last;
    final copy = File('${_dir.path}${Platform.pathSeparator}$id-$name');
    await file.copy(copy.path);
    final p = PendingUpload(
      id: id,
      path: copy.path,
      name: name,
      sourceId: sourceId,
      folderId: folderId,
      relPath: relPath,
      uploadSource: uploadSource,
      lastError: reason,
    );
    items.add(p);
    await _save();
    notifyListeners();
    return p;
  }

  /// Перерисовать экраны, которые показывают очередь (notifyListeners снаружи вызывать нельзя)
  void refresh() => notifyListeners();

  Future<void> update() async {
    await _save();
    notifyListeners();
  }

  Future<void> remove(PendingUpload p, {bool deleteFile = true}) async {
    items.remove(p);
    if (deleteFile) {
      try {
        await File(p.path).delete();
      } catch (_) {}
    }
    await _save();
    notifyListeners();
  }
}
