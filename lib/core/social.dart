// Компания: кто что слушает, лента событий, чарт недели, совместное прослушивание.
// У каждого друга свой файл cave-data/user-<почта>.json — только он его пишет,
// остальные читают. Поэтому одновременные изменения не конфликтуют.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'drive.dart';
import 'library.dart';
import 'log.dart';
import 'models.dart';
import 'player.dart';

class NowPlaying {
  final String trackId;
  final String title;
  final String artist;
  final bool playing;
  final Duration pos;
  final DateTime at;
  const NowPlaying(this.trackId, this.title, this.artist, this.playing, this.pos, this.at);

  /// Где трек сейчас, с учётом времени, прошедшего с последнего сохранения
  Duration estimate() => playing ? pos + DateTime.now().toUtc().difference(at) : pos;

  Map<String, dynamic> toJson() =>
      {'id': trackId, 't': title, 'a': artist, 'p': playing, 'pos': pos.inMilliseconds, 'at': at.toIso8601String()};

  static NowPlaying? fromJson(dynamic j) {
    if (j is! Map || j['id'] == null) return null;
    return NowPlaying(
      '${j['id']}',
      '${j['t'] ?? ''}',
      '${j['a'] ?? ''}',
      j['p'] == true,
      Duration(milliseconds: (j['pos'] as num?)?.toInt() ?? 0),
      DateTime.tryParse('${j['at']}')?.toUtc() ?? DateTime.now().toUtc(),
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
  Member(this.email, this.name, this.updated, this.now, this.events, this.plays);

  /// Слушает прямо сейчас
  bool get live => now != null && now!.playing && DateTime.now().toUtc().difference(updated) < const Duration(seconds: 100);

  /// Недавно был, но на паузе
  bool get recent => now != null && DateTime.now().toUtc().difference(updated) < const Duration(minutes: 15);

  static Member fromJson(Map j) {
    final plays = <String, Map<String, int>>{};
    final p = j['plays'];
    if (p is Map) {
      p.forEach((day, m) {
        if (m is Map) plays['$day'] = m.map((k, v) => MapEntry('$k', (v as num?)?.toInt() ?? 0));
      });
    }
    return Member(
      '${j['email']}',
      '${j['name'] ?? ''}',
      DateTime.tryParse('${j['updated']}')?.toUtc() ?? DateTime.fromMillisecondsSinceEpoch(0),
      NowPlaying.fromJson(j['now']),
      [for (final e in (j['events'] as List? ?? const [])) if (e is Map) e.cast<String, dynamic>()],
      plays,
    );
  }
}

class ChartEntry {
  final Track track;
  final int plays;
  final Set<String> listeners;
  ChartEntry(this.track, this.plays, this.listeners);
}

class SocialController extends ChangeNotifier {
  final LibraryController lib;
  final DriveApi drive;
  final PlayerController player;

  final Map<String, Member> members = {};
  final Map<String, String> _fileModified = {}; // fileId → modifiedTime
  final Map<String, String> _fileOwner = {}; // email → fileId
  String? _myFileId;
  bool _loadedMine = false;

  List<Map<String, dynamic>> _myEvents = [];
  Map<String, Map<String, int>> _myPlays = {};

  Timer? _pollTimer;
  Timer? _heartbeat;
  Timer? _writeTimer;
  Timer? _followTimer;
  bool _polling = false;
  bool _writing = false;
  bool _dirty = false;

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
    _pollTimer = Timer.periodic(const Duration(seconds: 15), (_) => poll());
    _heartbeat = Timer.periodic(const Duration(seconds: 30), (_) {
      if (player.playing) _markDirty();
    });
    unawaited(poll());
  }

  /// Пауза или перемотка — сохраняем статус быстрее, чтобы друзья увидели
  void onUserAction() => _markDirty(soon: true);

  // ---------- что я слушаю ----------

  NowPlaying? _myNow() {
    final t = player.current;
    if (t == null) return null;
    return NowPlaying(t.id, t.title, t.displayArtist, player.playing, player.position.value, DateTime.now().toUtc());
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

  /// Засчитываем прослушивание, когда трек играл хотя бы 30 секунд
  void _onPosition() {
    final t = player.current;
    if (t == null) return;
    final key = '${t.id}@${player.openedAt?.millisecondsSinceEpoch}';
    if (_countedFor == key || player.position.value < const Duration(seconds: 30)) return;
    _countedFor = key;
    final day = _day(DateTime.now());
    final m = _myPlays.putIfAbsent(day, () => {});
    m[t.id] = (m[t.id] ?? 0) + 1;
    _markDirty();
  }

  static String _day(DateTime d) => d.toIso8601String().substring(0, 10);

  void _addEvent(Map<String, dynamic> e) {
    _myEvents.add({...e, 'at': DateTime.now().toUtc().toIso8601String()});
    if (_myEvents.length > 80) _myEvents = _myEvents.sublist(_myEvents.length - 80);
    _markDirty(soon: true);
    _refreshMe();
  }

  void _markDirty({bool soon = false}) {
    _dirty = true;
    _writeTimer?.cancel();
    _writeTimer = Timer(Duration(milliseconds: soon ? 1200 : 4000), _write);
  }

  Map<String, dynamic> _myJson() {
    // Храним прослушивания только за две недели
    final cutoff = _day(DateTime.now().subtract(const Duration(days: 14)));
    _myPlays.removeWhere((day, _) => day.compareTo(cutoff) < 0);
    return {
      'email': me,
      'name': lib.accounts.primary?.name ?? '',
      'updated': DateTime.now().toUtc().toIso8601String(),
      'now': _myNow()?.toJson(),
      'events': _myEvents,
      'plays': _myPlays,
    };
  }

  void _refreshMe() {
    final m = me;
    if (m == null) return;
    members[m] = Member.fromJson(_myJson());
    notifyListeners();
  }

  Future<void> _write() async {
    final m = me;
    if (!lib.hasHub || m == null || !_dirty) return;
    if (!_loadedMine) {
      await poll(); // сначала подтягиваем свой файл, чтобы не затереть историю с другого компьютера
      if (!_loadedMine) return;
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
      await lib.withHub((email) async {
        final id = _myFileId;
        if (id == null) {
          final f = await drive.createFile(email, folder, 'user-$m.json', body);
          _myFileId = f['id'] as String;
          _fileModified[_myFileId!] = '${f['modifiedTime']}';
        } else {
          _fileModified[id] = await drive.updateFile(email, id, body);
        }
      });
      _refreshMe();
    } catch (e) {
      _dirty = true;
      AppLog.warn('Не удалось сохранить статус', e);
    } finally {
      _writing = false;
    }
  }

  // ---------- что слушают друзья ----------

  Future<void> poll() async {
    if (!lib.hasHub || me == null || _polling) return;
    _polling = true;
    try {
      final folder = await lib.dataFolder();
      final files = await lib.withHub((email) => drive.listChildren(email, folder));
      for (final f in files) {
        if (!f.name.startsWith('user-') || !f.name.endsWith('.json')) continue;
        final email = f.name.substring(5, f.name.length - 5);
        if (email == me) {
          _myFileId ??= f.id;
          if (_loadedMine) continue;
        }
        if (_fileModified[f.id] == f.modifiedTime && members.containsKey(email)) continue;
        await _load(f.id, email);
        _fileModified[f.id] = f.modifiedTime;
      }
      if (!_loadedMine) {
        _loadedMine = true;
        _refreshMe();
      }
      notifyListeners();
    } catch (e) {
      AppLog.warn('Не удалось обновить статусы друзей', e);
    } finally {
      _polling = false;
    }
  }

  Future<void> _load(String fileId, String email) async {
    _fileOwner[email] = fileId;
    final bytes = await lib.withHub((e) => drive.download(e, fileId));
    final j = jsonDecode(utf8.decode(bytes));
    if (j is! Map) return;
    final m = Member.fromJson(j);
    if (email == me) {
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

  List<ChartEntry> chart({int days = 7, int limit = 30}) {
    final since = _day(DateTime.now().subtract(Duration(days: days - 1)));
    final plays = <String, int>{};
    final who = <String, Set<String>>{};
    for (final m in members.values) {
      m.plays.forEach((day, tracks) {
        if (day.compareTo(since) < 0) return;
        tracks.forEach((id, n) {
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
        await _load(id, email);
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
    _heartbeat?.cancel();
    _writeTimer?.cancel();
    _followTimer?.cancel();
    super.dispose();
  }
}
