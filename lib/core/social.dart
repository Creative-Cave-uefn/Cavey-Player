// Компания: кто что слушает, лента событий, чарт недели, совместное прослушивание.
// У каждого друга свой файл cave-data/user-<почта>.json — только он его пишет,
// остальные читают. Поэтому одновременные изменения не конфликтуют.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding, WidgetsBindingObserver;

import '../config.dart';
import 'drive.dart';
import 'library.dart';
import 'log.dart';
import 'models.dart';
import 'notices.dart';
import 'player.dart';

class NowPlaying {
  final String trackId;
  final String title;
  final String artist;
  final bool playing;
  final Duration pos;
  final DateTime at;

  /// Какое устройство пишет статус (пусто у старых версий): по нему видно, что человек играет на другом своём устройстве
  final String device;
  const NowPlaying(this.trackId, this.title, this.artist, this.playing, this.pos, this.at, [this.device = '']);

  /// Где трек сейчас, с учётом времени, прошедшего с последнего сохранения
  Duration estimate() => playing ? pos + Member.nowSynced.difference(at) : pos;

  Map<String, dynamic> toJson() =>
      {'id': trackId, 't': title, 'a': artist, 'p': playing, 'pos': pos.inMilliseconds, 'at': at.toIso8601String(), if (device.isNotEmpty) 'd': device};

  static NowPlaying? fromJson(dynamic j) {
    if (j is! Map || j['id'] == null) return null;
    return NowPlaying(
      '${j['id']}',
      '${j['t'] ?? ''}',
      '${j['a'] ?? ''}',
      j['p'] == true,
      Duration(milliseconds: (j['pos'] as num?)?.toInt() ?? 0),
      DateTime.tryParse('${j['at']}')?.toUtc() ?? DateTime.now().toUtc(),
      '${j['d'] ?? ''}',
    );
  }
}

class FeedEvent {
  final String email;
  final DateTime at;
  final Map<String, dynamic> data;
  FeedEvent(this.email, this.at, this.data);
  String get kind => '${data['k']}';
}

class Member {
  final String email;
  String name;
  DateTime updated;
  NowPlaying? now;
  List<Map<String, dynamic>> events;
  Map<String, Map<String, int>> plays; // день → трек → сколько раз

  /// Сколько раз всего человек слушал каждый трек (за всё время, с версии, где появился учёт)
  Map<String, int> totals;

  /// Сколько миллисекунд человек реально слушал: день → трек → мс
  Map<String, Map<String, int>> time;

  /// Реально прослушанное время по трекам за всё время, мс
  Map<String, int> timeTotals;

  /// Версия приложения у человека (пишется в статус; у старых версий пусто)
  String version;
  Member(this.email, this.name, this.updated, this.now, this.events, this.plays,
      [this.version = '', Map<String, int>? totals, Map<String, Map<String, int>>? time, Map<String, int>? timeTotals])
      : totals = totals ?? playTotalsFrom(plays),
        time = time ?? {},
        timeTotals = timeTotals ?? {};

  /// На сколько часы этого компьютера уходят от часов Google Диска. Статусы друзей мы сверяем
  /// со временем Диска, поэтому чужие или свои неточные часы больше не прячут «слушает сейчас».
  static Duration skew = Duration.zero;

  static DateTime get nowSynced => DateTime.now().toUtc().add(skew);

  /// Слушает прямо сейчас
  bool get live => now != null && now!.playing && nowSynced.difference(updated) < const Duration(seconds: 100);

  /// Недавно был, но на паузе
  bool get recent => now != null && nowSynced.difference(updated) < const Duration(minutes: 15);

  static Member fromJson(Map j) {
    final plays = <String, Map<String, int>>{};
    final p = j['plays'];
    if (p is Map) {
      p.forEach((day, m) {
        if (m is Map) plays['$day'] = m.map((k, v) => MapEntry('$k', (v as num?)?.toInt() ?? 0));
      });
    }
    // Учёт переделан: раньше за прослушивание считался весь трек целиком. Данные без метки версии
    // учёта (и самой метки) не берём — статистика начинается с нуля
    final fresh = ((j['lv'] as num?)?.toInt() ?? 0) >= kListenVersion;
    final time = <String, Map<String, int>>{};
    final lt = j['lt'];
    if (fresh && lt is Map) {
      lt.forEach((day, m) {
        if (m is Map) time['$day'] = m.map((k, v) => MapEntry('$k', (v as num?)?.toInt() ?? 0));
      });
    }
    final ltc = j['ltc'];
    final tc = j['tc'];
    if (!fresh) plays.clear();
    return Member(
      '${j['email']}',
      '${j['name'] ?? ''}',
      DateTime.tryParse('${j['updated']}')?.toUtc() ?? DateTime.fromMillisecondsSinceEpoch(0),
      NowPlaying.fromJson(j['now']),
      [for (final e in (j['events'] as List? ?? const [])) if (e is Map) e.cast<String, dynamic>()],
      plays,
      '${j['v'] ?? ''}',
      // Старые версии счётчика за всё время не пишут: считаем по прослушиваниям за последние дни
      fresh && tc is Map ? tc.map((k, v) => MapEntry('$k', (v as num?)?.toInt() ?? 0)) : null,
      time,
      fresh && ltc is Map ? ltc.map((k, v) => MapEntry('$k', (v as num?)?.toInt() ?? 0)) : null,
    );
  }
}

/// Сколько раз слушали каждый трек по прослушиваниям за дни
Map<String, int> playTotalsFrom(Map<String, Map<String, int>> plays) {
  final out = <String, int>{};
  for (final day in plays.values) {
    day.forEach((id, n) => out[id] = (out[id] ?? 0) + n);
  }
  return out;
}

/// Версия учёта прослушивания. Со второй считаем реально прослушанное время, а не «трек включили — засчитали целиком»
const kListenVersion = 2;

/// Дольше этого между двумя отметками позиции — перемотка, а не воспроизведение: время не засчитываем
const maxListenStep = Duration(milliseconds: 2500);

/// Сколько прибавить к наслушанному между двумя отметками позиции. Только пока идёт звук и позиция
/// сдвинулась вперёд на обычный шаг; перемотка, пауза и пересев на другой трек ничего не дают
Duration listenStep({required bool playing, required Duration before, required Duration now}) {
  if (!playing) return Duration.zero;
  final d = now - before;
  if (d <= Duration.zero || d > maxListenStep) return Duration.zero;
  return d;
}

/// Сумма прослушанного времени (миллисекунды по трекам)
Duration listenedSum(Iterable<int> ms) => Duration(milliseconds: ms.fold(0, (a, b) => a + b));

/// «12 ч», «45 мин», «1 ч 20 мин» — для «Наслушал» и статистики
String formatListened(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  if (h == 0) return '${d.inMinutes} мин';
  if (h >= 10 || m == 0) return '$h ч';
  return '$h ч $m мин';
}

class ChartEntry {
  final Track track;
  final int plays;
  final Set<String> listeners;
  ChartEntry(this.track, this.plays, this.listeners);
}

/// Е5: окно вернулось из свёрнутого состояния — сразу обновляем статусы
class _ResumeWatcher with WidgetsBindingObserver {
  final VoidCallback onResume;
  _ResumeWatcher(this.onResume);
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) onResume();
  }
}

class SocialController extends ChangeNotifier {
  final LibraryController lib;
  final DriveApi drive;
  final PlayerController player;

  final Map<String, Member> members = {};
  final Map<String, String> _fileModified = {}; // fileId → modifiedTime
  final Map<String, String> _fileOwner = {}; // email → fileId
  String? _myFileId;

  /// В какой папке лежит [_myFileId]: писать свой файл можно только в текущую cave-data
  String? _myFileFolder;

  /// Для какой библиотеки собраны сведения о файлах: сменили библиотеку — всё собираем заново
  String? _hubSeen;
  bool _loadedMine = false;

  /// Своя история уже подтянулась с Диска (а с ней и друзья)
  bool get loaded => _loadedMine;

  List<Map<String, dynamic>> _myEvents = [];
  Map<String, Map<String, int>> _myPlays = {};
  Map<String, int> _myTotals = {};
  Map<String, Map<String, int>> _myTime = {};
  Map<String, int> _myTimeTotals = {};
  String? _tickKey;
  Duration _tickPos = Duration.zero;
  Duration _tickHeard = Duration.zero;

  Timer? _pollTimer;
  _ResumeWatcher? _resume;
  Timer? _heartbeat;
  Timer? _writeTimer;
  Timer? _followTimer;
  bool _polling = false;
  bool _writing = false;
  bool _dirty = false;

  /// Для раздела «Компания»: когда статусы обновлялись и что пошло не так
  DateTime? lastPoll;
  DateTime? lastWrite;
  String? pollError;
  bool _loggedPoll = false;

  /// С кем слушаем вместе
  String? following;
  bool _syncing = false;
  String? _lastTrack;
  String? _countedFor;

  SocialController(this.lib, this.drive, this.player);

  String? get me => lib.me;

  void start() {
    lib.onEvent = _addEvent;
    player.addListener(_onPlayer);
    player.position.addListener(_onPosition);
    // Часто: по этому опросу приходят уведомления от друзей. Один короткий список файлов — Диску это не в тягость
    _pollTimer = Timer.periodic(const Duration(seconds: 6), (_) {
      // Е5: музыка не играет и окно скрыто — опрашиваем раз в минуту
      final st = WidgetsBinding.instance.lifecycleState;
      final hidden = st == AppLifecycleState.hidden || st == AppLifecycleState.paused;
      if (hidden && !player.playing && DateTime.now().difference(lastPoll ?? DateTime(2000)) < const Duration(seconds: 60)) return;
      unawaited(poll());
    });
    _resume = _ResumeWatcher(() => unawaited(poll()));
    WidgetsBinding.instance.addObserver(_resume!);
    _heartbeat = Timer.periodic(const Duration(seconds: 30), (_) {
      if (player.playing) _markDirty();
    });
    unawaited(poll());
  }

  /// Пауза или перемотка — сохраняем статус быстрее, чтобы друзья увидели
  void onUserAction() => _markDirty(soon: true);

  // ---------- что я слушаю ----------

  /// Идентификатор этого устройства; приложение на телефоне задаёт свой, на ПК пусто
  static String deviceId = '';

  /// Что играет на другом моём устройстве (того же аккаунта): по этому статусу телефон предлагает «продолжить здесь»
  NowPlaying? otherDevice;

  NowPlaying? _myNow() {
    final t = player.current;
    if (t == null) return null;
    return NowPlaying(t.id, t.title, t.displayArtist, player.playing, player.position.value, DateTime.now().toUtc(), deviceId);
  }

  void _onPlayer() {
    final id = player.current?.id;
    if (id != _lastTrack) {
      _lastTrack = id;
      // Сам выбрал другой трек — значит, больше не слушаем вместе
      if (following != null && !_syncing) stopFollowing();
      _markDirty(soon: true);
    }
  }

  /// Засчитываем прослушивание, когда трек действительно играл хотя бы 30 секунд (перемотка на 30-ю секунду не считается)
  void _onPosition() {
    final t = player.current;
    if (t == null) return;
    final key = '${t.id}@${player.openedAt?.millisecondsSinceEpoch}';
    // Реально прослушанное время: копим шаги позиции, пока трек играет
    final pos = player.position.value;
    if (key != _tickKey) {
      _tickKey = key;
      _tickHeard = Duration.zero;
    } else {
      final step = listenStep(playing: player.playing, before: _tickPos, now: pos);
      if (step > Duration.zero) {
        final ms = step.inMilliseconds;
        final m = _myTime.putIfAbsent(_day(DateTime.now()), () => {});
        m[t.id] = (m[t.id] ?? 0) + ms;
        _myTimeTotals[t.id] = (_myTimeTotals[t.id] ?? 0) + ms;
        _tickHeard += step;
      }
    }
    _tickPos = pos;
    if (_countedFor == key || _tickHeard < const Duration(seconds: 30)) return;
    _countedFor = key;
    final day = _day(DateTime.now());
    final m = _myPlays.putIfAbsent(day, () => {});
    m[t.id] = (m[t.id] ?? 0) + 1;
    _myTotals[t.id] = (_myTotals[t.id] ?? 0) + 1;
    _markDirty();
  }

  static String _day(DateTime d) => d.toIso8601String().substring(0, 10);

  void _addEvent(Map<String, dynamic> e) {
    _myEvents.add({...e, 'at': DateTime.now().toUtc().toIso8601String()});
    if (_myEvents.length > 80) _myEvents = _myEvents.sublist(_myEvents.length - 80);
    _markDirty(soon: true);
    _refreshMe();
  }

  DateTime? _writeDue;

  /// Отложенная запись своего файла. Новые изменения не отодвигают уже назначенную запись —
  /// иначе частые сигналы плеера держали бы лайк или «поделиться» неотправленными
  void _markDirty({bool soon = false}) {
    _dirty = true;
    final due = DateTime.now().add(Duration(milliseconds: soon ? 1200 : 4000));
    final pending = _writeDue;
    if ((_writeTimer?.isActive ?? false) && pending != null && !pending.isAfter(due)) return;
    _writeTimer?.cancel();
    _writeDue = due;
    _writeTimer = Timer(due.difference(DateTime.now()), () {
      _writeDue = null;
      unawaited(_write());
    });
  }

  Map<String, dynamic> _myJson() {
    // Прослушивания по дням храним 400 дней: этого хватает на статистику за неделю, месяц и год
    final cutoff = _day(DateTime.now().subtract(const Duration(days: 400)));
    _myPlays.removeWhere((day, _) => day.compareTo(cutoff) < 0);
    _myTime.removeWhere((day, _) => day.compareTo(cutoff) < 0);
    return {
      'email': me,
      'name': lib.accounts.primary?.name ?? '',
      'updated': DateTime.now().toUtc().toIso8601String(),
      'v': kAppVersion,
      'now': _myNow()?.toJson(),
      'events': _myEvents,
      'plays': _myPlays,
      'tc': _myTotals,
      'lv': kListenVersion,
      'lt': _myTime,
      'ltc': _myTimeTotals,
    };
  }

  void _refreshMe() {
    final m = me;
    if (m == null) return;
    members[m] = Member.fromJson(_myJson());
    notifyListeners();
  }

  /// Библиотеку сменили (переезд, подключение к другой, отключение): файлы старой cave-data больше не наши.
  /// Без этого статус до перезапуска писался бы в файл старой библиотеки
  void _checkHub() {
    final hub = lib.settings.hubId;
    if (hub == _hubSeen) return;
    final changed = _hubSeen != null;
    _hubSeen = hub;
    if (!changed) return; // первый запуск: сбрасывать нечего
    AppLog.info('Статусы: библиотека сменилась, свой файл в cave-data ищу заново');
    _myFileId = null;
    _myFileFolder = null;
    _loadedMine = false;
    _fileModified.clear();
    _fileOwner.clear();
    members.clear();
    _myEvents = [];
    _myPlays = {};
    _myTotals = {};
    _myTime = {};
    _myTimeTotals = {};
  }

  void _forgetMyFile(String why) {
    AppLog.warn('Свой файл статуса: $why — создам новый в cave-data');
    _myFileId = null;
    _myFileFolder = null;
  }

  /// Своего файла не видно в cave-data. Спрашиваем у Диска напрямую: список файлов может
  /// отставать на несколько секунд после создания, и тогда трогать ничего не нужно
  Future<void> _verifyMine(String main) async {
    final id = _myFileId;
    if (id == null) return;
    try {
      final f = await lib.withHub((e) => drive.getFile(e, id, fields: 'id,parents,trashed'));
      if (_myFileId != id) return;
      final parents = [for (final p in (f['parents'] as List? ?? const [])) '$p'];
      if (f['trashed'] == true) {
        _forgetMyFile('файл в корзине');
      } else if (!parents.contains(main)) {
        _forgetMyFile('файл лежит не в cave-data');
      }
    } on DriveException catch (e) {
      if (e.notFound && _myFileId == id) _forgetMyFile('файла больше нет на Диске');
    } catch (_) {
      // нет сети — проверим в следующий раз
    }
  }

  Future<void> _write() async {
    final m = me;
    if (!lib.hasHub || m == null || !_dirty) return;
    _checkHub();
    if (!_loadedMine) {
      await poll(); // сначала подтягиваем свой файл, чтобы не затереть историю с другого компьютера
      if (!_loadedMine) {
        _markDirty();
        return;
      }
    }
    if (_writing) {
      _markDirty();
      return;
    }
    _writing = true;
    _dirty = false;
    try {
      final body = jsonEncode(_myJson());
      final folder = await lib.dataFolder();
      // Папку cave-data сменили (своя папка в настройках или сброс): старый файл не трогаем, пишем в новую
      if (_myFileId != null && _myFileFolder != folder) _forgetMyFile('cave-data сменилась');
      await lib.withHub((email) async {
        final id = _myFileId;
        if (id != null) {
          try {
            _fileModified[id] = await drive.updateFile(email, id, body);
            _measureSkew(_fileModified[id]);
            return;
          } on DriveException catch (e) {
            if (!e.notFound) rethrow;
            _forgetMyFile('файла больше нет на Диске');
          }
        }
        final f = await drive.createFile(email, folder, 'user-$m.json', body);
        _myFileId = f['id'] as String;
        _myFileFolder = folder;
        _fileModified[_myFileId!] = '${f['modifiedTime']}';
        _measureSkew(_fileModified[_myFileId!]);
      });
      if (lastWrite == null) AppLog.info('Статус сохранён в cave-data');
      lastWrite = DateTime.now();
      if (player.playing) otherDevice = null; // теперь играем здесь
      _refreshMe();
    } catch (e) {
      _dirty = true;
      AppLog.warn('Не удалось сохранить статус', e);
    } finally {
      _writing = false;
    }
  }

  /// Время изменения файла на Диске — серверное. Сравнив его с нашими часами, узнаём, насколько они врут
  void _measureSkew(String? serverTime) {
    final srv = serverTime == null ? null : DateTime.tryParse(serverTime)?.toUtc();
    if (srv == null) return;
    final d = srv.difference(DateTime.now().toUtc());
    // Мелкие расхождения (задержка сети) не трогаем
    Member.skew = d.abs() < const Duration(seconds: 3) ? Duration.zero : d;
  }

  // ---------- что слушают друзья ----------

  Future<void> poll() async {
    if (!lib.hasHub || me == null || _polling) return;
    _checkHub();
    _polling = true;
    try {
      final main = await lib.dataFolder();
      // Читаем все папки cave-data и для каждого друга берём самый свежий файл
      final latest = <String, DriveFile>{};
      final where = <String, String>{}; // почта → папка, где лежит выбранный файл
      final mineInMain = <String>{}; // все мои файлы в основной cave-data
      final folders = {main, ...lib.dataFolders}.toList();
      // Е4: папки cave-data читаем параллельно
      final listed = await Future.wait([for (final folder in folders) lib.withHub((email) => drive.listChildren(email, folder))]);
      for (var fi = 0; fi < folders.length; fi++) {
        final folder = folders[fi];
        final files = listed[fi];
        for (final f in files) {
          if (f.isFolder || !f.name.startsWith('user-') || !f.name.endsWith('.json')) continue;
          final email = f.name.substring(5, f.name.length - 5);
          if (email.isEmpty) continue;
          if (email == me && folder == main) mineInMain.add(f.id);
          final prev = latest[email];
          // Свой файл предпочитаем в основной папке, чтобы писать туда же
          final better = prev == null ||
              (email == me ? folder == main && prev.modifiedTime.compareTo(f.modifiedTime) <= 0 : f.modifiedTime.compareTo(prev.modifiedTime) > 0);
          if (better) {
            latest[email] = f;
            where[email] = folder;
          }
        }
      }
      // Свой файл куда-то делся из cave-data (удалили, в корзине, перенесли) — проверяем и пишем заново
      if (_myFileId != null && !mineInMain.contains(_myFileId)) await _verifyMine(main);
      final toLoad = <Future<void> Function()>[];
      for (final entry in latest.entries) {
        final email = entry.key;
        final f = entry.value;
        if (email == me) {
          // Писать свой файл можно только в основную cave-data. Нашёлся только в старой копии папки —
          // историю из него читаем, а писать будем в новый файл в основной
          if (_myFileId == null && where[email] == main) {
            _myFileId = f.id;
            _myFileFolder = main;
          }
          if (_loadedMine && (_fileModified[f.id] == f.modifiedTime || deviceId.isEmpty)) continue;
        }
        if (_fileModified[f.id] == f.modifiedTime && members.containsKey(email)) continue;
        toLoad.add(() async {
          await _load(f.id, email, serverTime: f.modifiedTime);
          _fileModified[f.id] = f.modifiedTime;
        });
      }
      // Е4: файлы друзей читаем по 4 одновременно
      for (var i = 0; i < toLoad.length; i += 4) {
        await Future.wait([for (final job in toLoad.skip(i).take(4)) job()]);
      }
      lastPoll = DateTime.now();
      pollError = null;
      if (!_loggedPoll) {
        _loggedPoll = true;
        AppLog.info('Статусы друзей: файлов ${latest.length}, папок cave-data ${lib.dataFolders.length}');
      }
      if (!_loadedMine) {
        _loadedMine = true;
        _refreshMe();
      }
      _checkNotices();
      notifyListeners();
    } catch (e) {
      pollError = '$e';
      AppLog.warn('Не удалось обновить статусы друзей', e);
      notifyListeners();
    } finally {
      _polling = false;
    }
  }

  Future<void> _load(String fileId, String email, {String? serverTime}) async {
    _fileOwner[email] = fileId;
    final bytes = await lib.withHub((e) => drive.download(e, fileId));
    final j = jsonDecode(utf8.decode(bytes));
    if (j is! Map) return;
    final m = Member.fromJson(j);
    // Часы у друга могут врать: за время берём момент записи файла на Диске
    final srv = serverTime == null ? null : DateTime.tryParse(serverTime)?.toUtc();
    if (srv != null) {
      final off = srv.difference(m.updated);
      if (off.abs() > const Duration(seconds: 10)) {
        final n = m.now;
        if (n != null) m.now = NowPlaying(n.trackId, n.title, n.artist, n.playing, n.pos, n.at.add(off), n.device);
        m.updated = srv;
      }
    }
    if (email == me) {
      final n = m.now;
      final other = n != null && deviceId.isNotEmpty && n.device != deviceId ? n : null;
      if (other != otherDevice || other != null) {
        otherDevice = other;
        notifyListeners();
      }
      // История с другого компьютера: объединяем с тем, что накопилось здесь
      final known = {for (final e in _myEvents) '${e['at']}${e['k']}'};
      _myEvents = [...m.events.where((e) => !known.contains('${e['at']}${e['k']}')), ..._myEvents]
        ..sort((a, b) => '${a['at']}'.compareTo('${b['at']}'));
      m.plays.forEach((day, tracks) {
        final mine = _myPlays.putIfAbsent(day, () => {});
        tracks.forEach((id, n) {
          if ((mine[id] ?? 0) < n) mine[id] = n;
        });
      });
      m.totals.forEach((id, n) {
        if ((_myTotals[id] ?? 0) < n) _myTotals[id] = n;
      });
      m.time.forEach((day, tracks) {
        final mine = _myTime.putIfAbsent(day, () => {});
        tracks.forEach((id, n) {
          if ((mine[id] ?? 0) < n) mine[id] = n;
        });
      });
      m.timeTotals.forEach((id, n) {
        if ((_myTimeTotals[id] ?? 0) < n) _myTimeTotals[id] = n;
      });
      _loadedMine = true;
      _refreshMe();
      return;
    }
    members[email] = m;
    if (following == email) _syncFollow();
  }

  /// Друзья, кроме меня: сначала те, кто слушает прямо сейчас
  List<Member> get friends {
    final list = members.values.where((m) => m.email != me).toList()
      ..sort((a, b) {
        if (a.live != b.live) return a.live ? -1 : 1;
        return b.updated.compareTo(a.updated);
      });
    return list;
  }

  List<Member> get listeningNow => friends.where((m) => m.live || m.recent).toList();

  // ---------- уведомления «Вам» ----------

  /// Новые уведомления для показа (старые первыми). Окно решает, как их показать
  final StreamController<Notice> noticeStream = StreamController<Notice>.broadcast();

  /// Всё, что касается меня: чужие лайки и добавления в плейлисты моих треков, а также треки, которыми поделились со мной
  List<Notice> get notices {
    final m = me;
    if (m == null) return const [];
    return collectNotices(
      me: m,
      events: [
        for (final member in members.values)
          for (final e in member.events)
            if (DateTime.tryParse('${e['at']}') case final at?) (member.email, at.toUtc(), e)
      ],
      uploaderOf: (id) => lib.data.tracks[lib.data.resolve(id)]?.by ?? '',
    );
  }

  /// После каждого опроса: что появилось нового с прошлого раза. При первом запуске лишь ставим отметку.
  void _checkNotices() {
    if (me == null || !_loadedMine) return;
    final seen = lib.settings.noticeSeen;
    final now = DateTime.now().toUtc();
    // Колокольчик: всё, что было до этого момента, считается прочитанным
    if (lib.settings.bellSeen == null) {
      lib.settings.bellSeen = seen ?? now.toIso8601String();
      unawaited(lib.saveSettings());
    }
    if (seen == null) {
      lib.settings.noticeSeen = now.toIso8601String();
      unawaited(lib.saveSettings());
      return;
    }
    final fresh = freshNotices(notices, seen);
    if (fresh.isEmpty) return;
    // Отметка не уходит в будущее: у друга часы могут спешить
    final newest = fresh.first.at.isAfter(now) ? now : fresh.first.at;
    lib.settings.noticeSeen = newest.toIso8601String();
    unawaited(lib.saveSettings());
    for (final n in fresh.take(5).toList().reversed) {
      noticeStream.add(n);
    }
  }

  /// Текст уведомления для показа
  String noticeLine(Notice n) => noticeText(
        n,
        who: lib.firstNameOf(n.from),
        title: (id) => lib.data.tracks[lib.data.resolve(id)]?.title ?? 'трек',
        label: (id) {
          final t = lib.data.tracks[lib.data.resolve(id)];
          return t == null ? 'трек' : '${t.title} — ${t.displayArtist}';
        },
      );

  // ---------- лента и чарт ----------

  List<FeedEvent> get feed {
    final list = <FeedEvent>[];
    for (final m in members.values) {
      for (final e in m.events) {
        final at = DateTime.tryParse('${e['at']}');
        if (at != null) list.add(FeedEvent(m.email, at, e));
      }
    }
    list.sort((a, b) => b.at.compareTo(a.at));
    return list.length > 100 ? list.sublist(0, 100) : list;
  }

  /// Сколько раз трек прослушан: всей компанией или одним человеком [email].
  /// История хранится две недели, поэтому считается за этот срок.
  /// Сколько раз трек слушал каждый человек за всё время (с этой версии; раньше — за последние дни)
  Map<String, int> playsByUser(String trackId) {
    final out = <String, int>{};
    for (final m in members.values) {
      var n = 0;
      m.totals.forEach((id, c) {
        if (id == trackId || lib.data.resolve(id) == trackId) n += c;
      });
      if (n > 0) out[m.email] = n;
    }
    return out;
  }

  /// Сколько реально наслушал человек: всего или с дня [since]
  Duration listened(String email, {DateTime? since}) {
    final m = members[email];
    if (m == null) return Duration.zero;
    if (since == null) return listenedSum(m.timeTotals.values);
    final from = _day(since);
    var ms = 0;
    m.time.forEach((day, tracks) {
      if (day.compareTo(from) < 0) return;
      for (final v in tracks.values) {
        ms += v;
      }
    });
    return Duration(milliseconds: ms);
  }

  /// Наслушанное по дням за последние [days] дней (старые первыми) — для графика в профиле
  List<(DateTime, Duration)> listenedByDay(String email, {int days = 30}) {
    final m = members[email];
    final today = DateTime.now();
    return [
      for (var i = days - 1; i >= 0; i--)
        () {
          final d = DateTime(today.year, today.month, today.day).subtract(Duration(days: i));
          return (d, listenedSum((m?.time[_day(d)] ?? const <String, int>{}).values));
        }(),
    ];
  }

  /// Любимый исполнитель за последние [days] дней: чьи треки слушали дольше всего
  String? topArtist(String email, {int days = 30}) {
    final m = members[email];
    if (m == null) return null;
    final from = _day(DateTime.now().subtract(Duration(days: days - 1)));
    final byArtist = <String, int>{};
    final shown = <String, String>{};
    m.time.forEach((day, tracks) {
      if (day.compareTo(from) < 0) return;
      tracks.forEach((id, ms) {
        final t = lib.data.tracks[lib.data.resolve(id)];
        if (t == null) return;
        final name = t.artists.first;
        final k = name.toLowerCase();
        shown.putIfAbsent(k, () => name);
        byArtist[k] = (byArtist[k] ?? 0) + ms ~/ 1000;
      });
    });
    if (byArtist.isEmpty) return null;
    final best = byArtist.entries.reduce((a, b) => a.value >= b.value ? a : b);
    return shown[best.key];
  }

  int playsOf(String trackId, {String? email}) {
    var n = 0;
    for (final m in members.values) {
      if (email != null && m.email != email) continue;
      for (final day in m.plays.values) {
        n += day[trackId] ?? 0;
      }
    }
    return n;
  }

  List<ChartEntry> chart({int days = 7, int limit = 30}) {
    final since = _day(DateTime.now().subtract(Duration(days: days - 1)));
    final plays = <String, int>{};
    final who = <String, Set<String>>{};
    for (final m in members.values) {
      m.plays.forEach((day, tracks) {
        if (day.compareTo(since) < 0) return;
        tracks.forEach((raw, n) {
          final id = lib.data.resolve(raw); // объединённые копии считаем вместе
          plays[id] = (plays[id] ?? 0) + n;
          who.putIfAbsent(id, () => {}).add(m.email);
        });
      });
    }
    final list = <ChartEntry>[];
    plays.forEach((id, n) {
      final t = lib.data.tracks[id];
      if (t != null && !lib.data.hidden.contains(id)) list.add(ChartEntry(t, n, who[id] ?? {}));
    });
    list.sort((a, b) => b.plays.compareTo(a.plays));
    return list.length > limit ? list.sublist(0, limit) : list;
  }

  // ---------- слушать вместе ----------

  void follow(String email) {
    following = email;
    _followTimer?.cancel();
    _followTimer = Timer.periodic(const Duration(seconds: 4), (_) => _pollHost());
    _syncFollow();
    notifyListeners();
  }

  void stopFollowing() {
    following = null;
    _followTimer?.cancel();
    _followTimer = null;
    notifyListeners();
  }

  Future<void> _pollHost() async {
    final email = following;
    final id = email == null ? null : _fileOwner[email];
    if (email == null || id == null) return;
    try {
      final meta = await lib.withHub((e) => drive.getFile(e, id, fields: 'id,modifiedTime'));
      if (meta['modifiedTime'] != _fileModified[id]) {
        await _load(id, email, serverTime: '${meta['modifiedTime']}');
        _fileModified[id] = '${meta['modifiedTime']}';
        notifyListeners();
      } else {
        _syncFollow(); // поправляем расхождение, даже если хост ничего не менял
      }
    } catch (e) {
      AppLog.warn('Не удалось обновить статус друга', e);
    }
  }

  Future<void> _syncFollow() async {
    final host = following == null ? null : members[following];
    final now = host?.now;
    if (host == null || now == null || _syncing) return;
    final t = lib.data.tracks[now.trackId];
    if (t == null) return;
    _syncing = true;
    try {
      final target = now.estimate();
      if (player.current?.id != t.id) {
        await player.playTracks([t], 0);
        await Future<void>.delayed(const Duration(milliseconds: 800));
        await player.seek(now.estimate());
      } else if ((player.position.value - target).abs() > const Duration(seconds: 3)) {
        await player.seek(target);
      }
      if (now.playing && !player.playing) await player.play();
      if (!now.playing && player.playing) await player.pause();
    } catch (e) {
      AppLog.warn('Совместное прослушивание', e);
    } finally {
      _syncing = false;
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    if (_resume != null) WidgetsBinding.instance.removeObserver(_resume!);
    _heartbeat?.cancel();
    _writeTimer?.cancel();
    _followTimer?.cancel();
    noticeStream.close();
    super.dispose();
  }
}
