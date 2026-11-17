import 'dart:convert';

import '../drive.dart';
import '../library.dart';
import 'intel_store.dart';
import 'record.dart';

// Общий индекс признаков через Google Диск без сервера.
//
// Схема «каждый пишет только своё»: в папке cave-data/audio-intel каждое устройство добавляет собственные файлы
// ai-<устройство>-<время>.json (неизменяемые «шарды» с пачкой записей) и никогда не перезаписывает чужие и свои старые.
// Поэтому одновременная публикация с разных устройств не может затереть чужие результаты: файлы просто лежат рядом.
// Читатель перечисляет папку, скачивает шарды, которых у него ещё нет, и сливает записи по правилу
// TrackFeatures.compare (нужная версия файла → новее схема и анализатор → полный разбор → охват → время).
// Список слитых шардов хранится локально, поэтому уже скачанное повторно не качается.
// Оборванный или повреждённый шард (не разобрался JSON, не сошлось число записей) пропускается и будет прочитан в следующий раз.
// Если Диск недоступен, плеер работает с последним локальным индексом.

const String intelFolderName = 'audio-intel';
const int _shardFormat = 1;

/// Keep richer section records from turning a shard into an unbounded upload.
List<TrackFeatures> boundedIntelBatch(List<TrackFeatures> candidates, {int maxBytes = 1024 * 1024}) {
  final out = <TrackFeatures>[];
  var bytes = 256;
  for (final record in candidates) {
    final size = utf8.encode(jsonEncode(record.toJson())).length + 1;
    if (out.isNotEmpty && bytes + size > maxBytes) break;
    out.add(record); bytes += size;
  }
  return out;
}

/// Что произошло за один обмен с Диском
class IntelSyncReport {
  final int shardsRead;
  final int recordsMerged;
  final int shardsPublished;
  final int recordsPublished;
  final int skipped; // повреждённые шарды
  final String? error;
  const IntelSyncReport({this.shardsRead = 0, this.recordsMerged = 0, this.shardsPublished = 0, this.recordsPublished = 0, this.skipped = 0, this.error});

  bool get ok => error == null;
  bool get changed => recordsMerged > 0 || recordsPublished > 0;
}

/// Содержимое шарда: собирается и разбирается здесь, чтобы формат был в одном месте и проверялся тестами
class IntelShard {
  final String device;
  final List<TrackFeatures> records;
  IntelShard(this.device, this.records);

  String encode() => jsonEncode({
        'v': _shardFormat,
        'sv': TrackFeatures.schemaVersion,
        'dev': device,
        'n': records.length,
        'records': [for (final r in records) r.toJson()],
      });

  /// null — шард повреждён или от более нового формата: его пропускают, не теряя остальное
  static IntelShard? decode(String text) {
    try {
      final j = jsonDecode(text);
      if (j is! Map) return null;
      final v = j['v'];
      if (v is! num || v.toInt() > _shardFormat) return null;
      final raw = j['records'];
      final n = j['n'];
      if (raw is! List || n is! num || raw.length != n.toInt()) return null;
      final out = <TrackFeatures>[];
      for (final r in raw) {
        final f = TrackFeatures.fromJson(r);
        if (f != null) out.add(f);
      }
      return IntelShard((j['dev'] as String?) ?? '', out);
    } catch (_) {
      return null;
    }
  }

  /// Имя файла шарда
  static String nameFor(String device, int ms) => 'ai-$device-$ms.json';

  /// Устройство, записавшее шард, по имени файла; null — не наше имя
  static String? deviceOf(String name) {
    final m = RegExp(r'^ai-([0-9a-f]+)-(\d+)\.json$').firstMatch(name);
    return m?.group(1);
  }
}

class IntelSync {
  final DriveApi drive;
  final LibraryController lib;
  final IntelStore store;
  IntelSync(this.drive, this.lib, this.store);

  /// Сколько шардов скачиваем за один обмен: остальные — в следующий раз, чтобы не держать сеть и процессор надолго
  static const maxDownloads = 40;

  /// Сколько записей кладём в один шард
  static const shardSize = 150;

  /// Сколько шардов публикуем за один обмен
  static const maxPublish = 6;

  bool _busy = false;
  bool get busy => _busy;

  /// Шарды, которые не удалось разобрать (повреждены или от более новой версии): id файла → время его изменения.
  /// Пока файл не изменился, в этом запуске его больше не качаем — иначе те же файлы скачивались бы при каждом
  /// обмене и занимали собой весь лимит загрузок, не пропуская остальные
  final Map<String, String> _unreadable = {};

  /// Обмен с Диском: сначала читаем чужое, потом публикуем своё. [publish] = false — только читать
  Future<IntelSyncReport> sync({bool publish = true}) async {
    if (_busy) return const IntelSyncReport(error: 'Обмен уже идёт');
    if (!lib.hasHub) return const IntelSyncReport(error: 'Библиотека не подключена');
    _busy = true;
    try {
      final data = await lib.dataFolder();
      return await lib.withHub((email) => _run(email, data, publish));
    } catch (e) {
      return IntelSyncReport(error: '$e');
    } finally {
      _busy = false;
    }
  }

  Future<IntelSyncReport> _run(String email, String dataFolder, bool publish) async {
    // Папок с таким именем может оказаться несколько, если два устройства создали её одновременно: читаем из всех,
    // а пишем в самую старую (при равенстве — по id), чтобы выбор был одинаковым у всех
    final found = (await drive.listChildren(email, dataFolder, nameEquals: intelFolderName)).where((f) => f.isFolder).toList()
      ..sort((a, b) {
        final c = a.createdTime.compareTo(b.createdTime);
        return c != 0 ? c : a.id.compareTo(b.id);
      });
    final target = found.isNotEmpty ? found.first.id : await drive.createFolder(email, intelFolderName, parent: dataFolder);
    final folders = found.isNotEmpty ? [for (final f in found) f.id] : [target];

    var read = 0, merged = 0, skipped = 0;
    final shards = <DriveFile>[];
    for (final folder in folders) {
      for (final f in await drive.listChildren(email, folder)) {
        if (f.isFolder || IntelShard.deviceOf(f.name) == null) continue;
        shards.add(f);
      }
    }
    // Сначала старые: если запись есть в нескольких шардах, итог всё равно решает правило сравнения, но порядок стабильнее
    shards.sort((a, b) => a.name.compareTo(b.name));
    var downloads = 0;
    for (final f in shards) {
      if (store.shards[f.id] == f.modifiedTime) continue;
      if (IntelShard.deviceOf(f.name) == store.deviceId) {
        // Свой шард: его записи уже в индексе
        store.shards[f.id] = f.modifiedTime;
        continue;
      }
      if (_unreadable[f.id] == f.modifiedTime) continue;
      if (downloads >= maxDownloads) break;
      downloads++;
      try {
        final bytes = await drive.download(email, f.id);
        final shard = IntelShard.decode(utf8.decode(bytes, allowMalformed: true));
        if (shard == null) {
          skipped++;
          _unreadable[f.id] = f.modifiedTime;
          continue; // не помечаем слитым: если файл допишут, время изменения станет другим и он прочитается
        }
        for (final r in shard.records) {
          if (store.put(r)) merged++;
        }
        store.shards[f.id] = f.modifiedTime;
        read++;
      } on DriveException catch (e) {
        if (e.notFound) continue; // удалили между списком и загрузкой
        rethrow;
      }
    }

    var shardsOut = 0, recordsOut = 0;
    if (publish) {
      for (var i = 0; i < maxPublish; i++) {
        final batch = boundedIntelBatch(store.pendingRecords(shardSize));
        if (batch.isEmpty) break;
        final now = DateTime.now().millisecondsSinceEpoch;
        final body = IntelShard(store.deviceId, batch).encode();
        final created = await drive.createFile(email, target, IntelShard.nameFor(store.deviceId, now + i), body);
        store.markPublished(batch);
        final id = created['id'];
        if (id is String) store.shards[id] = (created['modifiedTime'] as String?) ?? '';
        shardsOut++;
        recordsOut += batch.length;
      }
    }
    await store.flush();
    return IntelSyncReport(shardsRead: read, recordsMerged: merged, shardsPublished: shardsOut, recordsPublished: recordsOut, skipped: skipped);
  }
}
