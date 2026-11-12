// Перенос старых треков на диск владельца подписки. Файлы, загруженные друзьями до брокера, принадлежат друзьям и занимают
// их место на Google Диске. Владение передаётся без копирования (id файла не меняется — плейлисты, лайки и статистика целы):
// друг назначает владельца «ожидающим владельцем» своих файлов, а брокер (от имени владельца) принимает владение.

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'broker.dart';
import 'drive.dart';
import 'library.dart';
import 'log.dart';
import 'models.dart';
import 'store.dart';

/// Можно ли перенести трек: он лежит в общей папке, его файл принадлежит не владельцу библиотеки и загружен «по-старому»
/// (у загруженных через брокер есть время загрузки). [owner] — почта владельца библиотеки в нижнем регистре
bool isMigratable(Track t, {required String? hubId, required String owner}) =>
    hubId != null && t.source == hubId && t.by.isNotEmpty && t.by.toLowerCase() != owner && t.uploadedAt.isEmpty;

class MigrationStats {
  final int count;
  final int bytes;
  const MigrationStats(this.count, this.bytes);
}

class LibraryMigration extends ChangeNotifier {
  final LibraryController lib;
  final AppStore store;
  LibraryMigration(this.lib, this.store);

  final Set<String> _done = {};
  DateTime? _snoozeUntil;
  bool _loaded = false;

  bool running = false;

  /// Первая причина, по которой файл не перенесли (для показа в настройках)
  String? lastProblem;
  int total = 0, moved = 0, failed = 0;
  String status = '';
  String? error;
  bool _askedThisSession = false;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final j = await store.readJson('migration.json');
      if (j is Map) {
        _done.addAll([for (final x in (j['done'] as List? ?? const [])) '$x']);
        final s = DateTime.tryParse('${j['snooze'] ?? ''}');
        if (s != null) _snoozeUntil = s;
      }
    } catch (_) {}
  }

  Future<void> _save() => store.writeJson('migration.json', {
        'done': _done.toList(),
        if (_snoozeUntil != null) 'snooze': _snoozeUntil!.toIso8601String(),
      });

  /// Мои треки, которые ещё можно перенести (файлы моих аккаунтов)
  Future<List<Track>> candidates() async {
    await load();
    final owner = await lib.hubOwnerEmail();
    if (owner == null) return const [];
    return [
      for (final t in lib.data.tracks.values)
        if (!_done.contains(t.id) && lib.isMyAccount(t.by) && isMigratable(t, hubId: lib.settings.hubId, owner: owner)) t
    ];
  }

  static MigrationStats statsOf(Iterable<Track> tracks) => MigrationStats(tracks.length, tracks.fold(0, (s, t) => s + t.size));

  /// У владельца: сколько ещё лежит на дисках каждого участника (почта → число файлов и размер)
  Future<Map<String, MigrationStats>> remainingByPerson() async {
    await load();
    final owner = await lib.hubOwnerEmail();
    if (owner == null) return const {};
    final by = <String, List<Track>>{};
    for (final t in lib.data.tracks.values) {
      if (!_done.contains(t.id) && isMigratable(t, hubId: lib.settings.hubId, owner: owner)) by.putIfAbsent(t.by.toLowerCase(), () => []).add(t);
    }
    return {for (final e in by.entries) e.key: statsOf(e.value)};
  }

  /// Показать ли окно с предложением при запуске: один раз за запуск, не чаще раза в три дня после «Позже»
  Future<MigrationStats?> offerAtStart() async {
    if (_askedThisSession || running) return null;
    await load();
    if (_snoozeUntil != null && DateTime.now().isBefore(_snoozeUntil!)) return null;
    if (!lib.hasHub || lib.me == null) return null;
    final list = await candidates();
    if (list.isEmpty) return null;
    _askedThisSession = true;
    return statsOf(list);
  }

  Future<void> snooze() async {
    _snoozeUntil = DateTime.now().add(const Duration(days: 3));
    await _save();
  }

  /// Переносит все свои старые треки. Можно прервать приложение: перенесённое запоминается, остальное продолжится в следующий раз
  Future<void> run() async {
    if (running) return;
    running = true;
    error = null;
    lastProblem = null;
    moved = 0;
    failed = 0;
    status = 'Готовлюсь…';
    notifyListeners();
    try {
      final owner = await lib.hubOwnerEmail();
      if (owner == null) throw const BrokerException('unavailable', 'Не удалось узнать владельца библиотеки');
      final list = await candidates();
      total = list.length;
      notifyListeners();
      if (list.isEmpty) return;
      final cfg = await lib.brokerConfig();
      // Пачки по BrokerBatch.size файлов; несколько пачек идут параллельно. Сбой одной пачки не останавливает остальные —
      // останавливает только ошибка, которая повторится у всех (брокер устарел, нет доступа к библиотеке)
      final jobs = <(String, List<Track>)>[];
      final byAccount = <String, List<Track>>{};
      for (final t in list) {
        byAccount.putIfAbsent(lib.accounts.accounts.firstWhere((a) => a.email.toLowerCase() == t.by.toLowerCase()).email, () => []).add(t);
      }
      for (final entry in byAccount.entries) {
        for (var i = 0; i < entry.value.length; i += BrokerBatch.size) {
          jobs.add((entry.key, entry.value.sublist(i, (i + BrokerBatch.size).clamp(0, entry.value.length))));
        }
      }
      var next = 0;
      BrokerException? fatal;
      Future<void> worker() async {
        while (fatal == null && next < jobs.length) {
          final job = jobs[next++];
          status = 'Переношу ${moved + failed + 1} из $total…';
          notifyListeners();
          try {
            await _chunk(cfg.url, job.$1, job.$2, owner);
          } on BrokerException catch (e) {
            if (e.code == 'outdated_broker' || e.code == 'not_member' || e.code == 'outdated' || e.code == 'no_broker') {
              fatal = e;
            } else {
              failed += job.$2.length;
              AppLog.warn('Перенос: пачка не перенесена (${e.code})', e);
              lastProblem ??= e.message;
            }
          }
          await _save();
          notifyListeners();
        }
      }

      await Future.wait([for (var k = 0; k < parallelChunks; k++) worker()]);
      if (fatal != null) throw fatal!;
      status = 'Готово';
    } on BrokerException catch (e) {
      error = e.message;
    } catch (e, st) {
      AppLog.error('Перенос треков на диск владельца', e, st);
      error = '$e';
    } finally {
      running = false;
      await _save();
      notifyListeners();
      if (error == null && moved > 0) {
        lib.messages.add('Перенесено на диск владельца: $moved${failed > 0 ? ' (не удалось: $failed${lastProblem == null ? '' : ' — $lastProblem'})' : ''}');
      } else if (error != null) {
        lib.messages.add('Перенос не завершён: $error');
      }
    }
  }

  /// Сколько пачек обрабатывается одновременно
  static const parallelChunks = 3;

  Future<String?> _ownerOf(String account, String id) async {
    try {
      final j = await lib.drive.getFile(account, id, fields: 'id,owners(emailAddress)');
      final owners = j['owners'];
      if (owners is List && owners.isNotEmpty && owners.first is Map) {
        return '${(owners.first as Map)['emailAddress'] ?? ''}'.toLowerCase();
      }
    } catch (_) {}
    return null;
  }

  /// Одна пачка: пропускаем то, что уже у владельца (перенос мог пройти в прошлый раз, пока приложение ждало ответ),
  /// предлагаем владение, просим брокера принять. Если брокер не ответил вовремя — сверяем итог по Диску и пробуем ещё раз
  Future<void> _chunk(String url, String account, List<Track> chunk, String owner) async {
    var todo = <Track>[];
    var cursor = 0;
    Future<void> check() async {
      while (cursor < chunk.length) {
        final t = chunk[cursor++];
        if (await _ownerOf(account, t.id) == owner) {
          _done.add(t.id);
          moved++;
        } else {
          todo.add(t);
        }
      }
    }

    await Future.wait([for (var k = 0; k < 3; k++) check()]);
    if (todo.isEmpty) return;
    // Шаг 1: назначаем владельца библиотеки «ожидающим владельцем» (от имени друга)
    final offered = <String>[];
    cursor = 0;
    final toOffer = todo;
    Future<void> worker() async {
      while (cursor < toOffer.length) {
        final t = toOffer[cursor++];
        try {
          await lib.drive.offerOwnership(account, t.id, owner);
          offered.add(t.id);
        } on DriveException catch (e) {
          AppLog.warn('Перенос: не удалось предложить «${t.title}» (${e.status})', e);
          lastProblem ??= 'Google не разрешил назначить владельца (${e.status}): ${e.message}';
          failed++;
        }
      }
    }

    await Future.wait([for (var k = 0; k < 3; k++) worker()]);
    if (offered.isEmpty) return;
    // Шаг 2: брокер принимает владение
    var pending = offered;
    for (var attempt = 0; attempt < 3 && pending.isNotEmpty; attempt++) {
      try {
        final answer = await lib.broker.adopt(url, account, pending);
        final retry = <String>[];
        for (final id in pending) {
          final r = answer.results[id] ?? 'error';
          if (r == 'ok' || r == 'already') {
            _done.add(id);
            moved++;
          } else if (r == 'error' && attempt < 2) {
            retry.add(id);
          } else {
            failed++;
            final why = answer.details[id];
            AppLog.warn('Перенос: брокер ответил «$r» для $id${why == null ? '' : ' ($why)'}');
            lastProblem ??= '${_reasonText(r)}${why == null ? '' : ': $why'}';
          }
        }
        pending = retry;
      } on BrokerException catch (e) {
        if (!e.deferrable || attempt >= 2) rethrow;
        // Брокер мог успеть перенести часть файлов, пока мы ждали: смотрим, у кого владелец уже сменился
        final left = <String>[];
        for (final id in pending) {
          if (await _ownerOf(account, id) == owner) {
            _done.add(id);
            moved++;
          } else {
            left.add(id);
          }
        }
        pending = left;
        await Future<void>.delayed(Duration(seconds: e.code == 'rate_limited' ? 20 : 5));
      }
    }
  }
}

String _reasonText(String code) => switch (code) {
      'transfer_failed' => 'Google не принял передачу владения',
      'not_transferred' => 'Владелец файла не сменился',
      'not_pending' => 'Владелец библиотеки не назначен ожидающим владельцем',
      'not_yours' => 'Файл принадлежит не вам',
      'bad_parent' => 'Файл вне папки библиотеки',
      _ => 'Ошибка переноса ($code)',
    };

/// Сколько файлов за один запрос к брокеру (не больше ADOPT_BATCH в Code.gs). Брокер переносит файлы по одному, по нескольку секунд
/// на каждый, поэтому пачка небольшая — иначе ответ не успевает прийти
class BrokerBatch {
  static const size = 5;
}
