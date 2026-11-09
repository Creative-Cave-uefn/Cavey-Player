import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'drive.dart';
import 'library.dart';
import 'log.dart';
import 'models.dart';
import 'notices.dart';
import 'ntfy.dart';
import 'player.dart';
import 'social.dart';

/// Сколько треков очереди помещаем в одно сообщение джема: у быстрого канала лимит 4 КБ
const jamQueueWindow = 80;

/// Общее состояние джем-сессии: очередь, текущий трек, пауза и позиция.
/// Это «регистр с последней записью»: любое действие участника создаёт полный снимок,
/// а побеждает снимок с более поздним временем. Поэтому состояние сходится у всех при любом порядке получения.
class JamSnapshot {
  final String jam;

  /// Кто сделал это действие (почта)
  final String by;

  /// Время действия по часам Диска, мс; по нему выбираем более свежий снимок
  final int at;
  final List<String> queue;
  final int index;
  final bool playing;

  /// Позиция трека на момент [at], мс
  final int posMs;

  /// Кто добавил каждый трек очереди (почта, параллельно [queue]); пусто — неизвестно
  final List<String> adders;

  /// Организатор джема и когда он назначен (по часам Диска): у кого отметка новее, тот и прав
  final String? host;
  final int hostAt;

  /// Настройки плавного перехода организатора: секунды (0 — выключен) и умный переход. Только в снимках самого организатора
  final int? xf;
  final bool? smart;
  const JamSnapshot({
    required this.jam,
    required this.by,
    required this.at,
    required this.queue,
    required this.index,
    required this.playing,
    required this.posMs,
    this.adders = const [],
    this.host,
    this.hostAt = 0,
    this.xf,
    this.smart,
  });

  /// Свежее ли этот снимок, чем [other]: по времени, при равенстве — по почте, чтобы все выбрали одно и то же
  bool newerThan(JamSnapshot? other) {
    if (other == null) return true;
    if (at != other.at) return at > other.at;
    return by.compareTo(other.by) > 0;
  }

  String? get trackId => index >= 0 && index < queue.length ? queue[index] : null;

  /// Где сейчас должна быть позиция трека, если действие было [at], а сейчас [nowMs]
  Duration positionAt(int nowMs) {
    final ms = playing ? posMs + math.max<int>(0, nowMs - at) : posMs;
    return Duration(milliseconds: ms);
  }

  Map<String, dynamic> toJson() {
    final j = <String, dynamic>{'jam': jam, 'by': by, 'at': at, 'q': queue, 'i': index, 'p': playing, 'pos': posMs};
    // Кто добавил трек: список разных людей и по одному знаку на трек (номер человека в 36-ричной записи, «-» — неизвестно).
    // Так очередь в 80 треков занимает считанные байты, а лимит быстрого канала — 4 КБ
    if (adders.length == queue.length && adders.any((a) => a.isNotEmpty)) {
      final names = <String>[];
      final sb = StringBuffer();
      for (final a in adders) {
        if (a.isEmpty) {
          sb.write('-');
          continue;
        }
        var i = names.indexOf(a);
        if (i < 0) {
          names.add(a);
          i = names.length - 1;
        }
        sb.write(i < 36 ? i.toRadixString(36) : '-');
      }
      j['w'] = sb.toString();
      j['wl'] = names;
    }
    if (host != null) {
      j['h'] = host;
      j['ha'] = hostAt;
    }
    if (xf != null) j['xf'] = xf;
    if (smart != null) j['sm'] = smart;
    return j;
  }

  static JamSnapshot? fromJson(Object? j) {
    if (j is! Map) return null;
    final q = j['q'];
    if (q is! List || j['jam'] == null || j['by'] == null) return null;
    var adders = const <String>[];
    final w = j['w'], wl = j['wl'];
    if (w is String && wl is List && w.length == q.length) {
      final names = [for (final x in wl) '$x'];
      adders = [
        for (var i = 0; i < w.length; i++)
          () {
            final k = int.tryParse(w[i], radix: 36);
            return k != null && k < names.length ? names[k] : '';
          }()
      ];
    }
    final h = j['h'];
    return JamSnapshot(
      jam: '${j['jam']}',
      by: '${j['by']}',
      at: (j['at'] as num?)?.toInt() ?? 0,
      queue: [for (final x in q) '$x'],
      index: (j['i'] as num?)?.toInt() ?? -1,
      playing: j['p'] == true,
      posMs: (j['pos'] as num?)?.toInt() ?? 0,
      adders: adders,
      host: h == null || '$h'.isEmpty ? null : '$h',
      hostAt: (j['ha'] as num?)?.toInt() ?? 0,
      xf: (j['xf'] as num?)?.toInt(),
      smart: j['sm'] is bool ? j['sm'] as bool : null,
    );
  }

  /// То же состояние без привязки к автору: нужно ли что-то менять у слушателя
  bool sameQueueAs(List<String> ids, int idx) => idx == index && listEquals(ids, queue);
}

/// Окно очереди для сообщения: от трека чуть раньше текущего и не больше [jamQueueWindow] треков.
/// Возвращает (список, индекс текущего в нём)
(List<String>, int) jamWindow(List<String> queue, int index) {
  if (queue.isEmpty || index < 0) return (const [], -1);
  final from = math.max(0, index - 3);
  final to = math.min(queue.length, from + jamQueueWindow);
  return (queue.sublist(from, to), index - from);
}

/// Нужна ли перемотка у слушателя: расхождение с общей позицией больше [tolerance]
bool jamNeedsSeek(Duration local, Duration target, {Duration tolerance = const Duration(milliseconds: 700)}) =>
    (local - target).abs() > tolerance;

/// Плавный переход у одного из участников: его следующий трек начался раньше общего времени, и он «опережает» остальных.
/// По первому общему снимку этого трека меряем опережение: моя позиция минус общая. null — расхождение слишком большое
/// или отрицательное, значит это не опережение, а перемотка или рассинхрон: нужно подстроиться под общее время
Duration? jamMeasureLead(Duration local, Duration target, {Duration cap = const Duration(seconds: 20)}) {
  final lead = local - target;
  if (lead < const Duration(milliseconds: -700) || lead > cap) return null;
  return lead.isNegative ? Duration.zero : lead;
}

/// Кто организатор: назначенный, пока он в джеме; иначе первый по алфавиту из участников (все считают одинаково)
String? jamPickHost(String? host, List<String> participants) {
  if (host != null && participants.contains(host)) return host;
  if (participants.isEmpty) return host;
  return ([...participants]..sort()).first;
}

/// Джем-сессия: несколько человек слушают одну очередь и управляют ей вместе.
/// Действия идут по быстрому каналу ntfy, а копия последнего снимка каждого участника лежит на Google Диске
/// (файл `jam-<id>-<почта>.json`): так всё работает и без ntfy, только медленнее.
class JamController extends ChangeNotifier {
  final LibraryController lib;
  final DriveApi drive;
  final PlayerController player;
  final SocialController social;

  /// Адрес сервера быстрых сообщений; пусто — без него, только Диск
  final String Function() serverUrl;
  JamController(this.lib, this.drive, this.player, this.social, {required this.serverUrl});

  String? jamId;

  /// Участники: почта → когда в последний раз подавали признаки жизни
  final Map<String, DateTime> _seen = {};
  JamSnapshot? state;
  int _lastAt = 0;
  bool _applying = false;
  DateTime _quietUntil = DateTime.fromMillisecondsSinceEpoch(0);

  NtfyChannel? _ntfy;
  Timer? _tick;
  Timer? _driveWrite;
  DateTime _lastDrivePoll = DateTime.fromMillisecondsSinceEpoch(0);
  bool _polling = false;
  DateTime _lastHello = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastPresenceWrite = DateTime.fromMillisecondsSinceEpoch(0);
  String? _myFileId;
  final Map<String, String> _fileModified = {};

  /// Что человек уже сделал с уведомлением о джеме: id уведомления → подпись
  final Map<String, String> _resolved = {};

  /// Кого уже приняли в чужой джем (jam|почта)
  final Set<String> _admitted = {};

  /// Организатор джема: тот, кто его создал; ему можно передать лидерство. Организатор задаёт всем плавный переход,
  /// решает, кого исключить, и показан в панели сессии
  String? host;

  /// Когда назначен организатор (по часам Диска). Пока 0 — это лишь догадка по приглашению, настоящая отметка придёт от него
  int _hostAt = 0;

  /// Настройки плавного перехода организатора, как их последний раз прислал он сам
  int? _hostXf;
  bool? _hostSm;
  String _lastXfSent = '';
  String _lastSig = '';

  /// Когда я вошёл в этот джем (по часам Диска): старые записи об исключении мне не страшны
  int _joinedAt = 0;

  /// Исключённые организатором: почта → когда. Их сообщения и статус какое-то время не учитываем
  final Map<String, DateTime> _kicked = {};

  /// Из каких джемов меня исключили: id → когда. Старое приглашение в такой джем не принимается
  final Map<String, DateTime> _banned = {};

  /// Кто добавил трек в очередь джема: id трека → почта
  final Map<String, String> _adders = {};

  String? get me => lib.me;
  bool get active => jamId != null;
  bool get fastChannel => _ntfy?.online ?? false;

  /// Участники джема, включая меня: те, от кого было что-то за последние три минуты, и те, кто сам указал этот джем
  /// в своём статусе (так организатор виден и тем, кто вошёл по приглашению, даже если в джеме давно никто ничего не делал)
  List<String> get participants {
    final now = DateTime.now();
    final m = me;
    final set = <String>{
      for (final e in _seen.entries)
        if (e.key == m || now.difference(e.value) < const Duration(minutes: 3)) e.key,
    };
    final id = jamId;
    if (id != null) {
      for (final mem in social.members.values) {
        if (mem.jamId == id && mem.inJam) set.add(mem.email);
      }
    }
    // Исключённых организатором не показываем, пока их старые признаки жизни не остыли
    set.removeWhere((e) => e != m && _isKicked(e));
    final list = set.toList()..sort();
    if (m != null && list.remove(m)) list.insert(0, m);
    return list;
  }

  bool _isKicked(String email) {
    final t = _kicked[email];
    return t != null && DateTime.now().difference(t) < const Duration(minutes: 3);
  }

  /// Кто сейчас организатор. Если назначенного давно не слышно, организатором становится первый по алфавиту из оставшихся:
  /// все считают одинаково, поэтому спорить не о чем
  String? get effectiveHost => jamPickHost(host, participants);

  bool get iAmHost => active && me != null && effectiveHost == me;

  /// Кто добавил трек в очередь джема (почта); null — неизвестно или джема нет
  String? adderOf(String trackId) => active ? _adders[trackId] : null;

  int get _myXf => lib.settings.crossfadeSec.clamp(0, 10).toInt();
  bool get _mySmart => lib.settings.viewOf('mix.smart', '1') == '1';

  int _nextAt() {
    var at = serverNow;
    if (at <= _lastAt) at = _lastAt + 1;
    _lastAt = at;
    return at;
  }

  /// Моя запись состояния с моим именем, организатором, кто что добавил и (у организатора) настройками перехода
  JamSnapshot _snap({required List<String> queue, required int index, required bool playing, required int posMs, required int at}) {
    final mine = iAmHost;
    return JamSnapshot(
      jam: jamId!,
      by: me!,
      at: at,
      queue: queue,
      index: index,
      playing: playing,
      posMs: posMs,
      adders: [for (final id in queue) _adders.putIfAbsent(id, () => me!)],
      host: _hostAt > 0 ? host : null,
      hostAt: _hostAt,
      xf: mine ? _myXf : null,
      smart: mine ? _mySmart : null,
    );
  }

  /// Состояние, как оно есть у всех, с новым временем: нужно, когда поменялось не состояние, а организатор
  void _republish() {
    final st = state;
    if (st == null || me == null) return;
    final at = _nextAt();
    _local(_snap(queue: st.queue, index: st.index, playing: st.playing, posMs: st.positionAt(at).inMilliseconds, at: at));
  }

  // ---------- организатор и настройки ----------

  void _learnHost(String? h, int at) {
    if (h == null || h.isEmpty) return;
    final cur = host;
    final newer = cur == null || at > _hostAt || (at == _hostAt && h != cur && h.compareTo(cur) > 0);
    if (!newer) return;
    host = h;
    _hostAt = at;
    if (h != cur) {
      // Организатор сменился: он сам скоро пришлёт свои настройки; новый организатор сообщает их сразу
      if (h == me) unawaited(_sendHello());
      _applyHostSettings();
      social.touchStatus();
      notifyListeners();
    }
  }

  void _learnSettings(int xf, bool? sm) {
    _hostXf = xf.clamp(0, 10).toInt();
    _hostSm = sm;
    _applyHostSettings();
    notifyListeners();
  }

  /// Плавный переход в джеме задаёт организатор: включён у него — включён у всех, выключен — выключен у всех
  void _applyHostSettings() {
    final use = active && !iAmHost && _hostXf != null;
    player.jamXfSec = use ? _hostXf : null;
    player.jamSmart = use ? _hostSm : null;
  }

  /// Приветствие участникам: что я жив, кто организатор и (если это я) как настроен плавный переход
  Future<void> _sendHello({bool ask = false}) async {
    final m = me, id = jamId;
    if (m == null || id == null) return;
    final msg = <String, dynamic>{'t': 'hello', 'jam': id, 'who': m, 'from': m};
    if (ask) msg['ask'] = true;
    if (_hostAt > 0 && host != null) {
      msg['h'] = host;
      msg['ha'] = _hostAt;
    }
    if (iAmHost) {
      msg['xf'] = _myXf;
      msg['sm'] = _mySmart;
      _lastXfSent = '$_myXf|$_mySmart';
    }
    await _ntfy?.send(msg);
  }

  /// Передать лидерство участнику [who]. Может только организатор
  Future<void> makeHost(String who) async {
    if (!iAmHost || who == me || !participants.contains(who)) return;
    host = who;
    _hostAt = math.max(_nextAt(), _hostAt + 1);
    _applyHostSettings();
    _republish();
    unawaited(_sendHello());
    unawaited(_writeDriveFile());
    social.touchStatus();
    notifyListeners();
  }

  /// Исключить участника [who] из джема. Может только организатор
  Future<void> kick(String who) async {
    final id = jamId, m = me;
    if (id == null || m == null || !iAmHost || who == m) return;
    _kicked[who] = DateTime.now();
    _seen.remove(who);
    unawaited(_ntfy?.send({'t': 'kick', 'jam': id, 'who': who, 'from': m}));
    // Если быстрого канала нет, исключённый узнает из моего файла на Диске
    unawaited(_writeDriveFile());
    notifyListeners();
    social.touchStatus();
  }

  Future<void> _gotKicked() async {
    final id = jamId;
    if (id == null) return;
    _banned[id] = DateTime.now();
    await leave();
    lib.messages.add('Организатор исключил вас из джема');
  }

  int get serverNow => Member.nowSynced.millisecondsSinceEpoch;

  // ---------- быстрый канал ----------

  /// Подключаемся к ntfy, когда известна общая папка библиотеки; безопасно вызывать часто
  Future<void> ensureChannel() async {
    if (_ntfy != null) return;
    final server = serverUrl().trim();
    if (server.isEmpty || !lib.hasHub || me == null) return;
    try {
      final folder = await lib.dataFolder();
      final topic = NtfyChannel.topicFor(folder);
      if (_ntfy != null) return;
      _ntfy = NtfyChannel(
        server: server.endsWith('/') ? server.substring(0, server.length - 1) : server,
        topic: topic,
        onMessage: _onMessage,
        onState: (_) => notifyListeners(),
      )..start();
    } catch (e) {
      AppLog.warn('Быстрый канал: не запустился', e);
    }
  }

  void start() {
    player.addListener(_onPlayer);
    player.position.addListener(_onPosition);
    player.jamOnEnded = _onEnded;
    player.onJamCrossfade = _onCrossfade;
    social.onWritten = _sendWake;
    unawaited(ensureChannel());
    _tick = Timer.periodic(const Duration(milliseconds: 1500), (_) => _everySoon());
  }

  /// Друзьям: «в моём файле что-то новое» — пусть не ждут обычного опроса
  void _sendWake() {
    final m = me;
    if (m == null) return;
    unawaited(ensureChannel());
    unawaited(_ntfy?.send({'t': 'wake', 'from': m}));
  }

  void _onMessage(Map<String, dynamic> msg) {
    final m = me;
    if (m == null) return;
    final from = '${msg['from'] ?? msg['who'] ?? msg['by'] ?? ''}';
    if (from == m) return;
    switch ('${msg['t']}') {
      case 'wake':
        social.wake();
      case 'snap':
        final s = JamSnapshot.fromJson(msg['s']);
        if (s == null || s.jam != jamId || _isKicked(s.by)) return;
        _seen[s.by] = DateTime.now();
        _adopt(s);
      case 'hello':
        if (msg['jam'] != jamId || _isKicked(from)) return;
        _seen[from] = DateTime.now();
        _learnHost('${msg['h'] ?? ''}', (msg['ha'] as num?)?.toInt() ?? 0);
        // Настройки перехода принимаем только от организатора
        if (from == host && msg['xf'] is num) _learnSettings((msg['xf'] as num).toInt(), msg['sm'] is bool ? msg['sm'] as bool : null);
        notifyListeners();
        if (msg['ask'] == true) {
          // Отвечает автор последнего действия: остальные молчат, чтобы не слать одно и то же
          if (state?.by == m) _publish(state!, driveToo: false);
          // Организатор сразу говорит о себе: новичок узнаёт, кто он и как настроен переход
          if (iAmHost) unawaited(_sendHello());
        }
      case 'kick':
        if (msg['jam'] != jamId || from != host) return;
        final who = '${msg['who']}';
        if (who == m) {
          unawaited(_gotKicked());
        } else {
          _kicked[who] = DateTime.now();
          _seen.remove(who);
          notifyListeners();
        }
      case 'leave':
        if (msg['jam'] != jamId) return;
        _seen.remove(from);
        notifyListeners();
      case 'admit':
        _admitted.add('${msg['jam']}|${msg['who']}');
        notifyListeners();
    }
  }

  // ---------- вход и выход ----------

  String _newId() {
    final r = math.Random.secure();
    return List.generate(8, (_) => r.nextInt(16).toRadixString(16)).join();
  }

  /// Зовёт людей в джем; если джема ещё нет, он создаётся из того, что играет у меня
  Future<void> invite(List<String> emails) async {
    final m = me;
    if (m == null || emails.isEmpty) return;
    if (!active) _create();
    // Позвали заново — исключение снимается
    for (final e in emails) {
      _kicked.remove(e);
    }
    await social.emitEvent({'k': 'jaminv', 'jam': jamId, 'to': emails, 'host': effectiveHost ?? m});
  }

  void _create() {
    final m = me!;
    jamId = _newId();
    _seen
      ..clear()
      ..[m] = DateTime.now();
    state = null;
    host = m;
    _hostAt = _nextAt();
    _hostXf = null;
    _hostSm = null;
    _joinedAt = serverNow;
    _kicked.clear();
    _adders.clear();
    _applyHostSettings();
    player.feeder = null; // в джеме «Моя волна» не работает: очередь общая
    final snap = _fromPlayer(forceTrackStart: false);
    state = snap;
    _publish(snap);
    _afterJoin();
  }

  /// Войти в джем по приглашению
  Future<void> join(String id, String from, {String? host}) async {
    final m = me;
    if (m == null) return;
    if (jamId != null && jamId != id) await leave();
    if (jamId == id) return;
    jamId = id;
    _seen
      ..[m] = DateTime.now()
      ..[from] = DateTime.now();
    state = null;
    // Организатора называет приглашение; если не назвало — считаем им пригласившего, настоящая отметка придёт от организатора
    this.host = host ?? from;
    // Организатор, названный в приглашении, скорее всего в джеме: сразу считаем его участником, пока он сам не откликнулся
    if (host != null && host != m) _seen[host] = DateTime.now();
    _hostAt = 0;
    _hostXf = null;
    _hostSm = null;
    _joinedAt = serverNow;
    _kicked.clear();
    _adders.clear();
    _applyHostSettings();
    player.feeder = null;
    _afterJoin();
    await ensureChannel();
    unawaited(_sendHello(ask: true));
    unawaited(_pollDrive(force: true));
  }

  void _afterJoin() {
    notifyListeners();
    social.touchStatus();
    unawaited(_writeDriveFile());
  }

  Future<void> leave() async {
    final id = jamId, m = me;
    if (id == null) return;
    // Организатор уходит — лидерство переходит к первому по алфавиту из оставшихся (все считают так же)
    if (m != null && iAmHost) {
      final others = participants.where((e) => e != m).toList()..sort();
      if (others.isNotEmpty) {
        host = others.first;
        _hostAt = math.max(_nextAt(), _hostAt + 1);
        _republish();
      }
    }
    jamId = null;
    state = null;
    host = null;
    _hostAt = 0;
    _hostXf = null;
    _hostSm = null;
    _kicked.clear();
    _adders.clear();
    player.jamXfSec = null;
    player.jamSmart = null;
    _seen.clear();
    _driveWrite?.cancel();
    _advanceTimer?.cancel();
    if (m != null) await _ntfy?.send({'t': 'leave', 'jam': id, 'who': m});
    // Файл джема на Диске больше не нужен
    final fid = _myFileId;
    _myFileId = null;
    _fileModified.clear();
    if (fid != null) {
      unawaited(lib.withHub((email) => drive.deleteFile(email, fid)).then<void>((_) {}, onError: (Object _) {}));
    }
    notifyListeners();
    social.touchStatus();
  }

  /// Попроситься в джем человека: запрос получают все его участники, принять может любой
  Future<void> requestJoin(Member host) async {
    final id = host.jamId;
    final m = me;
    if (id == null || m == null) return;
    final to = [for (final e in host.jamMembers) if (e != m) e];
    if (to.isEmpty) to.add(host.email);
    _pendingRequest = id;
    await social.emitEvent({'k': 'jamreq', 'jam': id, 'to': to});
  }

  /// Джем, в который я попросился: когда придёт ответ-приглашение, войду сразу
  String? _pendingRequest;

  // ---------- уведомления о джеме ----------

  /// Что показать вместо кнопок у уведомления, если ответ уже не нужен; null — кнопки нужны
  String? noticeState(Notice n) {
    if (!n.isJam) return null;
    final done = _resolved[n.id];
    if (done != null) return done;
    final ban = n.jam == null ? null : _banned[n.jam!];
    if (n.kind == NoticeKind.jamInvite && ban != null && !n.at.isAfter(ban)) return 'Вас исключили из этого джема';
    if (n.expired(DateTime.now())) return n.kind == NoticeKind.jamInvite ? 'Приглашение устарело' : 'Запрос устарел';
    if (n.kind == NoticeKind.jamInvite) return jamId == n.jam ? 'Вы в джеме' : null;
    // Запрос на вход: принять могут только участники
    if (jamId != n.jam) return 'Вы уже не в этом джеме';
    if (_admitted.contains('${n.jam}|${n.from}') || _seen.containsKey(n.from)) return 'Уже принят(а)';
    return null;
  }

  Future<void> acceptNotice(Notice n) async {
    if (noticeState(n) != null) return;
    final id = n.jam;
    if (id == null) return;
    if (n.kind == NoticeKind.jamInvite) {
      _resolved[n.id] = 'Вы в джеме';
      notifyListeners();
      await join(id, n.from, host: n.host);
      return;
    }
    // Принять запрос: человеку уходит приглашение-ответ, остальные видят, что уже принят
    _resolved[n.id] = 'Принят(а)';
    _admitted.add('$id|${n.from}');
    notifyListeners();
    unawaited(_ntfy?.send({'t': 'admit', 'jam': id, 'who': n.from, 'from': me}));
    await social.emitEvent({'k': 'jaminv', 'jam': id, 'to': [n.from], 're': true, 'host': effectiveHost ?? me});
  }

  void declineNotice(Notice n) {
    _resolved[n.id] = 'Отклонено';
    notifyListeners();
  }

  /// Новое приглашение пришло: если это ответ на мой запрос, входим сразу
  void onFreshNotice(Notice n) {
    if (n.kind == NoticeKind.jamInvite && n.reply && n.jam == _pendingRequest && !n.expired(DateTime.now())) {
      _pendingRequest = null;
      unawaited(acceptNotice(n));
    }
  }

  // ---------- состояние джема ----------

  /// Мой снимок по тому, что сейчас в плеере
  JamSnapshot _fromPlayer({bool forceTrackStart = false, bool? playing}) {
    final (q, i) = jamWindow(player.queue, player.index);
    final at = _nextAt();
    return _snap(
      queue: q,
      index: i,
      playing: playing ?? player.playing,
      posMs: forceTrackStart ? 0 : math.max<int>(0, player.position.value.inMilliseconds - _myLead().inMilliseconds),
      at: at,
    );
  }

  /// Насколько позиция моего текущего трека опережает общую (плавный переход начал трек раньше)
  Duration _myLead() =>
      player.jamLeadTrack != null && player.jamLeadTrack == player.current?.id ? player.jamLead : Duration.zero;

  /// Я ушёл вперёд плавным переходом: общее состояние ещё на одном из прошлых треков очереди
  bool _localAhead(JamSnapshot st) {
    final id = st.trackId, cur = player.current?.id;
    if (id == null || cur == null || player.jamLeadTrack != cur || id == cur) return false;
    final from = math.max(0, player.index - 6);
    return player.queue.sublist(from, player.index).contains(id);
  }

  Timer? _advanceTimer;

  /// У меня начался плавный переход: общий трек для остальных сменится, когда у них кончится прежний.
  /// Если к тому времени никто его не сменил (у других переход тоже свой или они не дошли), общее состояние перевожу я
  void _onCrossfade(Track next, Duration sharedRemaining) {
    if (!active || me == null) return;
    final id = next.id;
    _advanceTimer?.cancel();
    _advanceTimer = Timer(sharedRemaining + const Duration(milliseconds: 300), () {
      if (!active || me == null) return;
      // Человек успел переключить сам или ушёл дальше — не мешаем
      if (player.current?.id != id) return;
      if (state?.trackId == id) return; // кто-то уже перевёл джем на этот трек
      final (q, i) = jamWindow(player.queue, player.index);
      _local(_snap(queue: q, index: i, playing: player.playing, posMs: 0, at: _nextAt()));
    });
  }

  /// Раз в полторы секунды: подтягиваем файлы с Диска, обновляем свои признаки жизни
  void _everySoon() {
    if (!active) return;
    unawaited(ensureChannel());
    final m = me;
    if (m != null) _seen[m] = DateTime.now();
    // Быстрый канал работает — Диск лишь страховка (раз в 10 с), иначе опрашиваем часто
    final gap = (_ntfy?.canSend ?? false) ? const Duration(seconds: 10) : const Duration(milliseconds: 1200);
    if (DateTime.now().difference(_lastDrivePoll) >= gap) unawaited(_pollDrive());
    // Признаки жизни идут через файл на Диске (раз в минуту): сообщения быстрого канала ограничены сервером в сутки,
    // и частые «я здесь» выбирали лимит, после чего джем шёл через Диск с задержкой
    final now = DateTime.now();
    // Организатор поменял плавный переход у себя — остальные узнают сразу, а не через двадцать секунд
    if (iAmHost && _lastXfSent != '$_myXf|$_mySmart') {
      _lastHello = now;
      unawaited(_sendHello());
    }
    _applyHostSettings();
    // Состав джема или организатор изменились — обновляем статус, чтобы друзья видели, кто в джеме
    final sig = '${participants.join(',')}|${effectiveHost ?? ''}';
    if (sig != _lastSig) {
      _lastSig = sig;
      social.touchStatus();
    }
    if (now.difference(_lastPresenceWrite) >= const Duration(seconds: 60)) {
      _lastPresenceWrite = now;
      unawaited(_writeDriveFile());
    }
    notifyListeners();
  }

  void _publish(JamSnapshot s, {bool driveToo = true}) {
    final ch = _ntfy;
    // Быстрый канал недоступен (нет связи, лимит сервера, слишком длинное сообщение): остальным нужен Диск, причём сразу
    if (ch == null || !ch.canSend) {
      if (driveToo) _scheduleDriveWrite(urgent: true);
      return;
    }
    unawaited(ch.send({'t': 'snap', 'from': s.by, 's': s.toJson()}).then((ok) {
      if (!ok && driveToo && active) _scheduleDriveWrite(urgent: true);
    }));
    if (driveToo) _scheduleDriveWrite();
  }

  void _scheduleDriveWrite({bool urgent = false}) {
    // Срочная запись обгоняет отложенную: пока быстрый канал не подвёл, Диск лишь страховка
    if (_driveWrite?.isActive ?? false) {
      if (!urgent || _driveUrgent) return;
      _driveWrite!.cancel();
    }
    _driveUrgent = urgent;
    _driveWrite = Timer(Duration(milliseconds: urgent ? 120 : (fastChannel ? 2500 : 500)), () {
      _driveUrgent = false;
      unawaited(_writeDriveFile());
    });
  }

  bool _driveUrgent = false;

  /// Как сейчас доходят действия до остальных: быстрым каналом, через Диск или канал ограничен сервером
  String get linkState {
    final ch = _ntfy;
    if (ch == null || !ch.online) return 'через Диск (медленнее)';
    if (ch.limited) return 'через Диск: быстрый сервер ограничил число сообщений';
    return 'быстрая';
  }

  String get _fileName => 'jam-$jamId-${me ?? ''}.json';

  Future<void> _writeDriveFile() async {
    final id = jamId, m = me;
    if (id == null || m == null || !lib.hasHub) return;
    final mine = state != null && state!.by == m ? state : null;
    final amHost = iAmHost;
    final body = jsonEncode({
      'jam': id,
      'who': m,
      'seen': serverNow,
      'snap': mine?.toJson(),
      if (_hostAt > 0 && host != null) ...{'host': host, 'ha': _hostAt},
      // Настройки перехода и исключённые: так их получит и тот, у кого нет быстрого канала
      if (amHost) ...{
        'xf': _myXf,
        'sm': _mySmart,
        'kick': {
          for (final e in _kicked.entries)
            if (DateTime.now().difference(e.value) < const Duration(minutes: 3)) e.key: serverNow - DateTime.now().difference(e.value).inMilliseconds
        },
      },
    });
    try {
      final folder = await lib.dataFolder();
      await lib.withHub((email) async {
        final fid = _myFileId;
        if (fid != null) {
          _fileModified[fid] = await drive.updateFile(email, fid, body);
          return;
        }
        final f = await drive.createFile(email, folder, _fileName, body);
        _myFileId = f['id'] as String;
        _fileModified[_myFileId!] = '${f['modifiedTime']}';
      });
    } catch (e) {
      AppLog.warn('Джем: не записался файл на Диск', e);
    }
  }

  /// Читает файлы других участников с Диска: их снимки и признаки жизни
  Future<void> _pollDrive({bool force = false}) async {
    final id = jamId;
    if (id == null || _polling || !lib.hasHub) return;
    _polling = true;
    _lastDrivePoll = DateTime.now();
    try {
      final folder = await lib.dataFolder();
      final files = await lib.withHub((email) => drive.listChildren(email, folder));
      final prefix = 'jam-$id-';
      for (final f in files) {
        if (f.isFolder || !f.name.startsWith(prefix) || !f.name.endsWith('.json')) continue;
        final who = f.name.substring(prefix.length, f.name.length - 5);
        if (who == me || _isKicked(who)) continue;
        if (!force && _fileModified[f.id] == f.modifiedTime) continue;
        _fileModified[f.id] = f.modifiedTime;
        final bytes = await lib.withHub((email) => drive.download(email, f.id));
        final j = jsonDecode(utf8.decode(bytes));
        if (j is! Map) continue;
        final seenAt = (j['seen'] as num?)?.toInt() ?? 0;
        // Файл давно не обновлялся — участник уже ушёл
        if (serverNow - seenAt < 180000) _seen[who] = DateTime.now();
        final h = j['host'];
        if (h is String) _learnHost(h, (j['ha'] as num?)?.toInt() ?? 0);
        // Настройки перехода и исключения читаем только из файла организатора
        if (who == host) {
          if (j['xf'] is num) _learnSettings((j['xf'] as num).toInt(), j['sm'] is bool ? j['sm'] as bool : null);
          final kl = j['kick'];
          if (kl is Map) {
            for (final e in kl.entries) {
              final target = '${e.key}';
              final at = (e.value as num?)?.toInt() ?? 0;
              if (target == me) {
                // Старая запись, сделанная до моего входа, не в счёт
                if (at > _joinedAt) {
                  unawaited(_gotKicked());
                  return;
                }
              } else if (!_isKicked(target)) {
                _kicked[target] = DateTime.now();
                _seen.remove(target);
              }
            }
          }
        }
        final s = JamSnapshot.fromJson(j['snap']);
        if (s != null && s.jam == id && serverNow - s.at < 6 * 3600 * 1000) _adopt(s);
      }
      notifyListeners();
    } catch (e) {
      AppLog.warn('Джем: не прочитались файлы участников', e);
    } finally {
      _polling = false;
    }
  }

  /// Принимаем чужой снимок, если он свежее нашего, и приводим плеер в соответствие
  void _adopt(JamSnapshot s) {
    // Организатор и «кто добавил» учитываем из любого снимка, даже если он не новее нашего
    _learnHost(s.host, s.hostAt);
    if (s.by == host && s.xf != null) _learnSettings(s.xf!, s.smart);
    _learnAdders(s, newer: s.newerThan(state));
    if (!s.newerThan(state)) return;
    state = s;
    if (s.at > _lastAt) _lastAt = s.at;
    unawaited(_applyToPlayer(s));
    notifyListeners();
  }

  void _learnAdders(JamSnapshot s, {required bool newer}) {
    for (var i = 0; i < s.queue.length && i < s.adders.length; i++) {
      final a = s.adders[i];
      if (a.isEmpty) continue;
      if (newer || !_adders.containsKey(s.queue[i])) _adders[s.queue[i]] = a;
    }
    // Старые записи (трека давно нет в очереди) не копим
    if (_adders.length > 600) {
      final keep = player.queue.toSet()..addAll(s.queue);
      _adders.removeWhere((id, _) => !keep.contains(id));
    }
  }

  Future<void> _applyToPlayer(JamSnapshot s) async {
    if (_applying) {
      // Предыдущее применение ещё идёт: после него применим самое свежее состояние.
      // Но если оно зависло (плеер не открыл трек), оно не должно навсегда лишать меня права что-то менять в джеме
      final stuck = DateTime.now().difference(_applyStarted) > const Duration(seconds: 20);
      if (!stuck) {
        _applyAgain = true;
        return;
      }
      AppLog.warn('Джем: применение состояния зависло, начинаю заново');
    }
    _applying = true;
    _applyStarted = DateTime.now();
    try {
      do {
        _applyAgain = false;
        final snap = state ?? s;
        if (snap.trackId == null) {
          if (player.playing) await player.pause();
          continue;
        }
        // Трека, которого нет в моей библиотеке (ещё не загрузилась), не включаем
        if (lib.data.tracks[snap.trackId!] == null) continue;
        // Мой плавный переход начал следующий трек раньше остальных: назад не откатываемся и очередь не пересоздаём
        if (player.jamLeadTrack != null && player.jamLeadTrack == player.current?.id) {
          if (snap.trackId == player.current?.id) {
            var shared = snap.positionAt(serverNow);
            if (!player.jamLeadSynced) {
              // Первый общий снимок этого трека: по нему уточняем, насколько я впереди
              player.jamLeadSynced = true;
              final measured = jamMeasureLead(player.position.value, shared);
              if (measured == null) {
                player.jamLeadTrack = null;
                player.jamLead = Duration.zero;
              } else {
                player.jamLead = measured;
              }
            }
            if (player.jamLeadTrack != null) {
              shared += player.jamLead;
              if (jamNeedsSeek(player.position.value, shared)) await player.seek(shared);
              if (snap.playing && !player.playing) await player.play();
              if (!snap.playing && player.playing) await player.pause();
              continue;
            }
          } else if (_localAhead(snap)) {
            // Общий трек ещё прежний: меняю только паузу и продолжение
            if (snap.playing && !player.playing) await player.play();
            if (!snap.playing && player.playing) await player.pause();
            continue;
          }
        }
        final target = snap.positionAt(serverNow);
        final (ids, idx) = jamWindow(player.queue, player.index);
        if (!snap.sameQueueAs(ids, idx)) {
          if (player.current?.id == snap.trackId) {
            // Тот же трек, поменялась только очередь (кто-то добавил или убрал трек): музыку не перезапускаем
            player.jamSetQueueOnly(snap.queue, snap.index);
            if (jamNeedsSeek(player.position.value, target)) await player.seek(target);
            if (snap.playing && !player.playing) await player.play();
            if (!snap.playing && player.playing) await player.pause();
          } else {
            await player.jamSet(snap.queue, snap.index, play: snap.playing, at: target).timeout(const Duration(seconds: 25));
          }
        } else {
          if (jamNeedsSeek(player.position.value, target)) await player.seek(target);
          if (snap.playing && !player.playing) await player.play();
          if (!snap.playing && player.playing) await player.pause();
        }
      } while (_applyAgain);
    } catch (e) {
      AppLog.warn('Джем: не применилось состояние', e);
    } finally {
      _applying = false;
      // Всё, что плеер успел «сам» натворить при переключении, действием человека не считаем
      _quietUntil = DateTime.now().add(const Duration(milliseconds: 1500));
    }
  }

  bool _applyAgain = false;
  DateTime _applyStarted = DateTime.fromMillisecondsSinceEpoch(0);

  // ---------- что делает человек у себя ----------

  Duration _lastPos = Duration.zero;
  String? _lastTrackSeen;

  /// Человек сам что-то поменял: очередь, трек, паузу. Сравниваем плеер с общим состоянием
  void _onPlayer() {
    if (!active || me == null) return;
    if (_applying || DateTime.now().isBefore(_quietUntil)) return;
    final st = state;
    if (st == null) return;
    final (ids, idx) = jamWindow(player.queue, player.index);
    if (player.current == null) return;
    // Мой плавный переход уже начал следующий трек, а общий ещё прежний: не публикую «смену трека», только паузу
    if (_localAhead(st)) {
      if (player.playing != st.playing) {
        final at = _nextAt();
        _local(_snap(queue: st.queue, index: st.index, playing: player.playing, posMs: st.positionAt(at).inMilliseconds, at: at));
      }
      return;
    }
    final queueChanged = !st.sameQueueAs(ids, idx);
    if (queueChanged) {
      // Новый трек или изменённая очередь: у всех начинается с начала, если трек другой
      final trackChanged = st.trackId != player.current?.id;
      _local(_fromPlayer(forceTrackStart: trackChanged, playing: trackChanged ? true : player.playing));
      return;
    }
    if (player.playing != st.playing) _local(_fromPlayer());
  }

  /// Перемотка: позиция прыгнула, а не сдвинулась обычным ходом
  void _onPosition() {
    final pos = player.position.value;
    final prev = _lastPos;
    _lastPos = pos;
    if (!active || _applying || DateTime.now().isBefore(_quietUntil)) return;
    final st = state;
    if (st == null || player.current == null || player.current?.id != st.trackId) return;
    // Трек только что сменился: нулевая позиция — не перемотка
    if (_lastTrackSeen != player.current?.id) {
      _lastTrackSeen = player.current?.id;
      return;
    }
    final step = (pos - prev).abs();
    final jumped = player.playing ? step > const Duration(milliseconds: 1500) : step > const Duration(milliseconds: 400);
    if (jumped) _local(_fromPlayer());
  }

  void _local(JamSnapshot s) {
    state = s;
    _publish(s);
    notifyListeners();
  }

  /// Трек доиграл до конца: переходим к следующему; если кто-то уже перешёл, ничего не делаем.
  /// Возвращает true, если плеер сам не должен переключаться
  bool _onEnded({bool waited = false}) {
    if (!active || me == null) return false;
    final st = state;
    if (st == null) return false;
    // Трек кончился у меня раньше, чем у остальных (я опережаю общее время плавным переходом): подождём их
    if (!waited && player.jamLeadTrack != null && player.jamLeadTrack == player.current?.id && player.jamLead > Duration.zero) {
      final id = player.current?.id;
      Timer(player.jamLead + const Duration(milliseconds: 400), () {
        if (!active || state?.trackId != id) return; // общий джем уже ушёл дальше — меня переключили
        _onEnded(waited: true);
      });
      return true;
    }
    final (ids, idx) = jamWindow(player.queue, player.index);
    // Общее состояние уже ушло дальше этого трека — значит, нас уже переключили
    if (!st.sameQueueAs(ids, idx) && st.trackId != player.current?.id) return true;
    if (idx + 1 >= ids.length) {
      // Очередь закончилась: все останавливаются на конце
      _local(_fromPlayer(playing: false));
      return true;
    }
    final next = _snap(queue: ids, index: idx + 1, playing: true, posMs: 0, at: _nextAt());
    state = next;
    _publish(next);
    unawaited(_applyToPlayer(next));
    notifyListeners();
    return true;
  }

  /// Закрытие программы: сообщаем остальным, что вышли
  Future<void> shutdown() async {
    _tick?.cancel();
    if (active) await leave();
    _ntfy?.stop();
  }

  @override
  void dispose() {
    _tick?.cancel();
    _driveWrite?.cancel();
    _advanceTimer?.cancel();
    _ntfy?.stop();
    super.dispose();
  }
}
