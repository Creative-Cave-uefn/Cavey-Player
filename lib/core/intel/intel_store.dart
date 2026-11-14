import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'record.dart';

// Локальный индекс признаков на диске. Работает без сети: последний валидный индекс всегда читается с диска.
//
// • features.jsonl — по записи на строку. В файл попадают только принятые записи, поэтому при чтении побеждает последняя
//   строка трека. Дописывается по мере разбора, а когда в файле много устаревших строк, переписывается целиком (через временный файл).
// • state.json — id этого устройства, какие общие файлы с Диска уже слиты и какие результаты ещё не опубликованы.
// Битая или оборванная строка пропускается: потеряется одна запись, которая потом посчитается заново.

class IntelStore {
  final Directory dir;
  IntelStore(this.dir);

  final Map<String, TrackFeatures> _records = {};

  /// Результаты этого устройства, которые ещё не попали на Диск: id трека → analyzedAt записи
  final Map<String, int> _pending = {};

  /// Общие файлы, уже слитые в индекс: id файла на Диске → время его изменения
  final Map<String, String> shards = {};

  String deviceId = '';

  /// Какая версия файла сейчас у трека в библиотеке (запись со своей версией файла выигрывает у «лучшей» от старого файла)
  String? Function(String id)? wantRevision;

  /// Растёт при каждом изменении индекса: по нему видно, что пора пересобрать векторы похожести
  int version = 0;

  int _fileLines = 0;
  final List<String> _buffer = [];
  Future<void> _io = Future<void>.value();
  Timer? _flushTimer;
  bool _loaded = false;

  File get _features => File('${dir.path}${Platform.pathSeparator}features.jsonl');
  File get _state => File('${dir.path}${Platform.pathSeparator}state.json');

  int get count => _records.length;
  Iterable<TrackFeatures> get records => _records.values;
  TrackFeatures? get(String id) => _records[id];
  int get pendingCount => _pending.length;

  /// Читает индекс с диска. Безопасно вызывать один раз при запуске
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    await dir.create(recursive: true);
    try {
      if (await _state.exists()) {
        final j = jsonDecode(await _state.readAsString());
        if (j is Map) {
          deviceId = (j['device'] as String?) ?? '';
          final sh = j['shards'];
          if (sh is Map) {
            sh.forEach((k, v) => shards['$k'] = '$v');
          }
          final pe = j['pending'];
          if (pe is Map) {
            pe.forEach((k, v) {
              if (v is num) _pending['$k'] = v.toInt();
            });
          }
        }
      }
    } catch (_) {
      // состояние не прочиталось: общие файлы просто слиются заново, а id устройства создастся новый
    }
    if (deviceId.isEmpty) {
      final r = math.Random.secure();
      deviceId = List<String>.generate(8, (_) => r.nextInt(16).toRadixString(16)).join();
    }
    try {
      if (await _features.exists()) {
        final lines = await _features.readAsLines();
        _fileLines = lines.length;
        for (final line in lines) {
          if (line.isEmpty) continue;
          try {
            // В файл попадают только принятые записи, поэтому порядок строк — порядок принятия: побеждает последняя
            final f = TrackFeatures.fromJson(jsonDecode(line));
            if (f != null) _records[f.trackId] = f;
          } catch (_) {
            // оборванная строка
          }
        }
      }
    } catch (_) {
      // файл не читается: начнём с пустого индекса
    }
    // Результаты, которых уже нет в индексе, публиковать нечего
    _pending.removeWhere((id, at) => _records[id]?.analyzedAt != at);
    if (_fileLines > _records.length * 1.5 + 100) await _compact();
    version++;
  }

  /// Кладёт запись в индекс, если она лучше имеющейся
  bool _take(TrackFeatures f) {
    final cur = _records[f.trackId];
    if (cur != null && TrackFeatures.compare(f, cur, wantRevision: wantRevision?.call(f.trackId)) <= 0) return false;
    _records[f.trackId] = f;
    return true;
  }

  /// Добавляет запись. [local] — посчитана на этом устройстве (её нужно опубликовать). [force] — заменить имеющуюся запись
  /// в любом случае (повторный разбор по просьбе человека). Возвращает true, если индекс изменился
  bool put(TrackFeatures f, {bool local = false, bool force = false}) {
    if (force) {
      _records[f.trackId] = f;
    } else if (!_take(f)) {
      return false;
    }
    if (local) {
      _pending[f.trackId] = f.analyzedAt;
    } else {
      _pending.remove(f.trackId);
    }
    _buffer.add(jsonEncode(f.toJson()));
    version++;
    _scheduleFlush();
    return true;
  }

  /// Убирает запись (например, трек удалён из библиотеки)
  void remove(String id) {
    if (_records.remove(id) == null) return;
    _pending.remove(id);
    version++;
    // Строка остаётся в файле до сжатия; при загрузке такая запись вернётся, а потом уйдёт при чистке по библиотеке
    _scheduleFlush();
  }

  /// Результаты, ожидающие публикации (не больше [max])
  List<TrackFeatures> pendingRecords(int max) {
    final out = <TrackFeatures>[];
    for (final e in _pending.entries) {
      final f = _records[e.key];
      if (f != null && f.analyzedAt == e.value) out.add(f);
      if (out.length >= max) break;
    }
    return out;
  }

  /// Эти записи опубликованы. Если за время загрузки запись обновилась, она остаётся в очереди
  void markPublished(Iterable<TrackFeatures> published) {
    for (final f in published) {
      if (_pending[f.trackId] == f.analyzedAt) _pending.remove(f.trackId);
    }
    _scheduleFlush();
  }

  void _scheduleFlush() {
    _flushTimer ??= Timer(const Duration(seconds: 2), () {
      _flushTimer = null;
      unawaited(flush());
    });
  }

  /// Сбрасывает накопленное на диск. Записи идут по очереди, чтобы два сброса подряд не мешали друг другу
  Future<void> flush() {
    _flushTimer?.cancel();
    _flushTimer = null;
    final lines = List<String>.of(_buffer);
    _buffer.clear();
    final state = jsonEncode({'device': deviceId, 'shards': shards, 'pending': _pending});
    _io = _io.catchError((Object _) {}).then((_) async {
      try {
        await dir.create(recursive: true);
        if (lines.isNotEmpty) {
          await _features.writeAsString('${lines.join('\n')}\n', mode: FileMode.append, flush: true);
          _fileLines += lines.length;
        }
        await _writeAtomic(_state, state);
        if (_fileLines > _records.length * 1.5 + 100) await _compact();
      } catch (_) {
        // диск занят или полон: записи останутся в памяти, следующий сброс попробует снова
        _buffer.insertAll(0, lines);
      }
    });
    return _io;
  }

  Future<void> _compact() async {
    final text = StringBuffer();
    for (final f in _records.values) {
      text.writeln(jsonEncode(f.toJson()));
    }
    await _writeAtomic(_features, text.toString());
    _fileLines = _records.length;
  }

  static Future<void> _writeAtomic(File f, String text) async {
    final tmp = File('${f.path}.tmp');
    for (var attempt = 0;; attempt++) {
      try {
        await tmp.writeAsString(text, flush: true);
        try {
          await tmp.rename(f.path);
        } on FileSystemException {
          if (await f.exists()) await f.delete();
          await tmp.rename(f.path);
        }
        return;
      } on FileSystemException {
        if (attempt >= 4) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 150 * (attempt + 1)));
      }
    }
  }

  /// Закрытие: дописывает всё, что осталось
  Future<void> close() => flush();
}
