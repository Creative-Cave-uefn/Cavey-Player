import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart' show Media, Player;

import 'audio_cache.dart';
import 'automix.dart';
import 'auth.dart';
import 'crossfade.dart';
import 'crossfade_handoff.dart';
import 'dj_eq.dart';
import 'dj_transition.dart';
import 'dj_effects.dart';
import 'intel/adaptive_dj.dart';
import 'intel/record.dart';
import 'intel/set_context.dart';
import 'intel/dj_journal.dart';
import 'intel/transition_verifier.dart';
import 'drive.dart';
import 'library.dart';
import 'mixbook.dart';
import 'log.dart';
import 'models.dart';
import 'store.dart';
import 'stream_proxy.dart';

enum RepeatSetting { off, all, one }

/// Хвост полосы осветления после смены трека: полоса уходящего трека доезжает до края с прежней скоростью
/// (при плавном переходе) и растворяется, пока у нового растёт своя. Нужен и без плавного перехода:
/// при обычной смене трека полоса просто растворяется на месте
class CrossfadeInfo {
  /// Быстрее полоса не гаснет: даже без движения она растворяется не резче, чем за это время, мс
  static const minFadeMs = 900;

  final double fromFraction;
  final DateTime started;

  /// Длина плавного перехода, мс; 0 — полоса не движется, только растворяется
  final int lengthMs;

  /// Длина уходящего трека, мс: по ней полоса продолжает идти с той же скоростью, что и весь трек
  final int oldDurationMs;
  const CrossfadeInfo(this.fromFraction, this.started, this.lengthMs, {this.oldDurationMs = 0});

  /// Ход перехода 0…1
  double progress(DateTime now) => lengthMs <= 0 ? 1.0 : (now.difference(started).inMilliseconds / lengthMs).clamp(0.0, 1.0);

  /// За сколько полоса дошла бы до края, если бы шла с прежней скоростью (с ограничением самим переходом не связано)
  int get reachMs {
    if (oldDurationMs > 0) return ((1 - fromFraction) * oldDurationMs).round().clamp(0, 1 << 30).toInt();
    return lengthMs;
  }

  /// Сколько растворяется полоса: время перехода, но не дольше, чем ей оставалось бы идти до края.
  /// Полностью растворяется ещё в пути, поэтому у края ей нечего «допрыгивать»
  int get fadeMs {
    final limit = lengthMs > 0 ? lengthMs : minFadeMs;
    final reach = reachMs;
    final t = reach > 0 && reach < limit ? reach : limit;
    return t < minFadeMs ? minFadeMs : t;
  }

  /// Сколько всего живёт хвост
  int get totalMs => fadeMs;

  /// Скорость полосы, долей ширины в миллисекунду: та же, с какой слайдер шёл весь трек
  double get _speed {
    if (oldDurationMs > 0) return 1 / oldDurationMs;
    return lengthMs > 0 ? (1 - fromFraction) / lengthMs : 0.0;
  }

  /// Где полоса уходящего трека: идёт дальше с прежней скоростью, без разгона, остановки и прыжка к краю
  double fraction(DateTime now) {
    final t = now.difference(started).inMilliseconds;
    return (fromFraction + _speed * t).clamp(0.0, 1.0).toDouble();
  }

  /// Прозрачность полосы: ровно гаснет от полной до нуля за [fadeMs]
  double alpha(DateTime now) {
    final t = now.difference(started).inMilliseconds;
    return (1 - t / fadeMs).clamp(0.0, 1.0).toDouble();
  }
}

/// Источник бесконечной очереди («Моя волна»): даёт следующие треки и узнаёт, как их слушали
abstract class QueueFeeder {
  List<String> more(int n);

  /// Заголовок раздела очереди, который пополняется из этого источника («Далее в волне», «Далее в радио»)
  String get label;

  /// Трек сменился: [listened] — сколько он играл, [skipped] — переключили сами, а не доиграл
  void heard(Track t, Duration listened, {required bool skipped});
}

/// Очередь и воспроизведение. Звук идёт потоком прямо с Google Диска:
/// плеер (libmpv) сам запрашивает нужные куски файла с токеном в заголовке.
class PlayerController extends ChangeNotifier {
  final LibraryController lib;
  final AccountManager accounts;
  final Settings settings;
  final AudioCache cache;
  Player _p = Player();

  /// Второй проигрыватель для плавного перехода: на нём включается следующий трек, пока затихает текущий
  Player? _q;

  /// Панель с текстом песни открыта
  final ValueNotifier<bool> lyricsOpen = ValueNotifier(false);

  /// Панель очереди открыта. Справа показывается одна панель: текст песни или очередь
  final ValueNotifier<bool> queueOpen = ValueNotifier(false);

  void toggleLyricsPanel() {
    final open = !lyricsOpen.value;
    if (open) queueOpen.value = false;
    lyricsOpen.value = open;
  }

  void toggleQueuePanel() {
    final open = !queueOpen.value;
    if (open) lyricsOpen.value = false;
    queueOpen.value = open;
  }
  final List<StreamSubscription<dynamic>> _subs = [];

  /// Позиция меняется часто, поэтому отдельно — чтобы не перерисовывать всё окно
  final ValueNotifier<Duration> position = ValueNotifier(Duration.zero);
  Duration duration = Duration.zero;
  bool playing = false;
  bool buffering = false;
  bool shuffle = false;
  RepeatSetting repeat = RepeatSetting.off;
  String? error;

  List<String> _origin = [];
  List<String> queue = [];
  int _index = -1;

  /// Сколько следующих за текущим треков человек поставил в очередь сам («Добавить в очередь»).
  /// Они стоят сразу после текущего и играют раньше всего остального
  int userAhead = 0;

  int get index => _index;
  set index(int v) {
    // Прошли вперёд — пользовательские треки заканчиваются по одному; назад или с нуля — очередь снова обычная
    if (v > _index) {
      userAhead = userAhead - (v - _index) < 0 ? 0 : userAhead - (v - _index);
    } else if (v < _index) {
      userAhead = 0;
    }
    _index = v;
  }

  /// Пока не null, очередь сама пополняется из него, когда заканчивается
  QueueFeeder? feeder;

  /// Что человек сам поставил в очередь волны: при пересборке не выбрасываем
  final Set<String> _userAdded = {};
  DateTime? _openedAt;

  /// Трек восстановлен из прошлой сессии, но ещё не открыт: откроем по первому нажатию
  Duration? _resumeAt;
  Timer? _saveTimer;
  double _volumeBeforeMute = 80;

  /// Трек, который сейчас открываем: если за это время открыли другой, старый не трогаем
  int _openSeq = 0;

  /// Человек сам поставил паузу после открытия трека — не включаем за него
  bool _userPaused = false;

  /// Стриминг с Диска идёт через локальный прокси (быстрее старт, свежий токен)
  final StreamProxy _proxy = StreamProxy(urlFor: DriveApi.mediaUrl);

  /// Трек открыт и известна длительность — например, чтобы сразу искать текст
  void Function(Track track, Duration duration)? onTrackReady;

  PlayerController(this.lib, this.accounts, this.settings, this.cache) {
    position.addListener(_anchorClock);
    _bind(_p);
    unawaited(_p.setVolume(_scaled(settings.volume)));
    // Пока играет, раз в 15 секунд запоминаем позицию — на случай, если окно закроют
    _saveTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (playing) _saveSession();
    });
  }

  // ---------- общие «часы» воспроизведения ----------

  final Stopwatch _clock = Stopwatch()..start();
  Duration _clockPos = Duration.zero;
  int _clockAtUs = 0;

  /// Запоминает, какая позиция была в этот момент: от неё now() отсчитывает прошедшее время
  void _anchorClock() {
    _clockPos = position.value;
    _clockAtUs = _clock.elapsedMicroseconds;
  }

  /// Сколько времени события позиции от плеера может не приходить, пока now() продолжает идти сам
  static const _maxClockAhead = Duration(seconds: 1);

  /// Текущее время песни — единственный источник «сейчас» для текстов и караоке: позиция от плеера плюс время,
  /// прошедшее с её прихода, с учётом паузы, скорости и перемотки. Позиция приходит раз в несколько десятков
  /// миллисекунд, а экран обновляется чаще, поэтому смена строки и заливка слов читают время только отсюда
  Duration now() {
    final pos = position.value;
    if (!playing || buffering || _resumeAt != null) return pos;
    var rate = _p.state.rate;
    if (!(rate > 0)) rate = 1;
    var ahead = Duration(microseconds: ((_clock.elapsedMicroseconds - _clockAtUs) * rate).round());
    if (ahead > _maxClockAhead) ahead = _maxClockAhead;
    if (ahead < Duration.zero) ahead = Duration.zero;
    return _clockPos + ahead;
  }

  /// Подписывается на события проигрывателя [p] (и отписывается от прежнего)
  void _bind(Player p) {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    _subs.add(p.stream.position.listen((d) {
      if (_resumeAt == null) position.value = d;
      if (d > Duration.zero && duration > Duration.zero) _lastFrac = (d.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0).toDouble();
      _maybeCrossfade(d);
    }));
    _subs.add(p.stream.duration.listen((d) {
      if (_resumeAt != null && d == Duration.zero) return;
      duration = d;
      notifyListeners();
    }));
    _subs.add(p.stream.playing.listen((v) {
      playing = v;
      _anchorClock();
      notifyListeners();
      _saveSession();
    }));
    _subs.add(p.stream.buffering.listen((v) {
      buffering = v;
      _anchorClock();
      notifyListeners();
    }));
    _subs.add(p.stream.completed.listen((done) {
      if (done) _onCompleted();
    }));
    _subs.add(p.stream.error.listen((e) {
      error = e;
      AppLog.warn('Плеер: ${current?.title ?? ''}', e);
      notifyListeners();
      // Ошибка в первые секунды трека — файл не открылся: идём дальше (Г3)
      final t = current;
      final opened = _openedAt;
      if (t != null && opened != null && DateTime.now().difference(opened) < const Duration(seconds: 10)) _skipBroken(t);
    }));
  }

  /// Сколько треков подряд не открылось; после трёх останавливаемся, чтобы не гонять очередь по кругу
  int _failStreak = 0;

  /// Г3: трек не открылся (битый файл, 403) — показываем уведомление и переходим к следующему
  void _skipBroken(Track t) {
    if (_failStreak >= 3 || queue.length < 2) return;
    _failStreak++;
    lib.messages.add('«${t.title}» не открылся, включаю следующий');
    Timer(const Duration(milliseconds: 800), () {
      if (current?.id == t.id) unawaited(next(auto: true));
    });
  }

  Track? get current => (index >= 0 && index < queue.length) ? lib.data.tracks[queue[index]] : null;
  double get volume => settings.volume;
  List<Track> get upcoming => [
        for (final id in queue.skip(index + 1))
          if (lib.data.tracks[id] != null) lib.data.tracks[id]!
      ];

  // ---------- сессия ----------

  /// Возвращает очередь и позицию с прошлого запуска. Трек не открывается сразу:
  /// так при старте не нужен интернет, а играть начнёт по первому нажатию.
  void restoreSession() {
    final s = settings.session;
    if (s == null) return;
    try {
      String fix(Object? x) => lib.data.resolve('$x'); // копию могли объединить с другой
      final q = [for (final x in (s['queue'] as List? ?? const [])) fix(x)].where((id) => lib.data.tracks[id] != null).toList();
      if (q.isEmpty) return;
      final curId = s['current'] == null ? null : fix(s['current']);
      var i = curId == null ? -1 : q.indexOf(curId);
      if (i < 0) i = ((s['index'] as num?)?.toInt() ?? 0).clamp(0, q.length - 1);
      queue = q;
      index = i;
      _origin = [for (final x in (s['origin'] as List? ?? const [])) fix(x)].where((id) => lib.data.tracks[id] != null).toList();
      sourcePlaylist = s['src'] is String ? s['src'] as String : null;
      if (_origin.isEmpty) _origin = List.of(queue);
      shuffle = s['shuffle'] == true;
      repeat = RepeatSetting.values.firstWhere((r) => r.name == s['repeat'], orElse: () => RepeatSetting.off);
      final pos = Duration(milliseconds: (s['pos'] as num?)?.toInt() ?? 0);
      _resumeAt = pos;
      position.value = pos;
      duration = Duration(milliseconds: (s['dur'] as num?)?.toInt() ?? 0);
      notifyListeners();
    } catch (e) {
      AppLog.warn('Не получилось восстановить очередь', e);
    }
  }

  Timer? _saveDebounce;

  void _saveSession() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 600), () => unawaited(_writeSession()));
  }

  /// Записывает очередь и позицию сразу — перед выходом из приложения
  Future<void> flushSession() {
    _saveDebounce?.cancel();
    return _writeSession();
  }

  Future<void> _writeSession() {
    final cur = current;
    settings.session = cur == null
        ? null
        : {
            // Очень длинные очереди обрезаем: хватит того, что вокруг текущего трека
            'queue': queue.length > 2000 ? queue.sublist(index > 500 ? index - 500 : 0).take(2000).toList() : queue,
            'origin': _origin.length > 2000 ? const <String>[] : _origin,
            'src': sourcePlaylist,
            'current': cur.id,
            'index': index,
            'pos': (_resumeAt ?? position.value).inMilliseconds,
            'dur': duration.inMilliseconds,
            'shuffle': shuffle,
            'repeat': repeat.name,
            if (feeder != null) 'wave': true,
          };
    return lib.saveSettings();
  }

  // ---------- очередь ----------

  /// Плейлист, из которого запущено воспроизведение (для пункта «Перейти в плейлист»); null — другой источник
  String? sourcePlaylist;

  /// [inOrder] — альбом: «Вперемешку» выключается, чтобы шла последовательность альбома.
  /// Переключатель остаётся рабочим: его можно включить снова
  Future<void> playTracks(List<Track> list, int start, {String? playlistId, bool inOrder = false}) async {
    if (list.isEmpty) return;
    _previewOverride = null;
    if (inOrder) shuffle = false;
    feeder = null; // выбрали что-то сами — волна выключается
    sourcePlaylist = playlistId;
    _origin = [for (final t in list) t.id];
    if (shuffle) {
      final first = _origin[start];
      final rest = List.of(_origin)
        ..removeAt(start)
        ..shuffle();
      queue = [first, ...rest];
      index = 0;
    } else {
      queue = List.of(_origin);
      index = start;
    }
    userAhead = 0;
    await _open();
  }

  void playNext(Track t) {
    if (current == null) {
      unawaited(playTracks([t], 0));
      return;
    }
    queue.insert(index + 1, t.id);
    userAhead++;
    if (feeder != null) _userAdded.add(t.id);
    // И в исходный порядок — иначе после выключения перемешивания трек пропадёт
    final oi = _origin.indexOf(current!.id);
    _origin.insert(oi < 0 ? _origin.length : oi + 1, t.id);
    _queueChanged();
  }

  /// «Добавить в очередь»: после того, что человек уже добавил, но раньше остального, что подобрал плеер
  void addToQueue(Track t) {
    if (current == null) {
      unawaited(playTracks([t], 0));
      return;
    }
    final at = (index + 1 + userAhead).clamp(0, queue.length);
    queue.insert(at, t.id);
    userAhead++;
    final oi = _origin.indexOf(current!.id);
    _origin.insert(oi < 0 ? _origin.length : (oi + userAhead).clamp(0, _origin.length), t.id);
    if (feeder != null) _userAdded.add(t.id);
    _queueChanged();
  }

  /// Убрать из очереди всё, что поставил человек (остальное остаётся)
  void clearUserQueue() {
    if (userAhead <= 0 || index < 0) return;
    final gone = queue.sublist(index + 1, (index + 1 + userAhead).clamp(0, queue.length));
    queue.removeRange(index + 1, (index + 1 + userAhead).clamp(0, queue.length));
    userAhead = 0;
    for (final id in gone) {
      _origin.remove(id);
      _userAdded.remove(id);
    }
    _queueChanged();
  }

  /// Убирает трек из очереди (текущий не трогаем)
  void removeAt(int queueIndex) {
    if (queueIndex <= index || queueIndex >= queue.length) return;
    if (queueIndex - index <= userAhead) userAhead--;
    final id = queue.removeAt(queueIndex);
    if (shuffle) {
      _origin.remove(id);
    } else {
      _origin = List.of(queue);
    }
    _queueChanged();
  }

  /// Переставляет трек из следующих: индексы — позиции в [queue].
  /// [asUser] — к какому списку трек относится после переноса: true — «добавлено вами», false — «подобрано плеером».
  /// Так трек можно перетащить из одного списка в другой, даже на границу между ними
  void moveInQueue(int from, int to, {bool? asUser}) {
    if (from <= index || from >= queue.length) return;
    to = to.clamp(index + 1, queue.length - 1);
    final wasUser = from - index <= userAhead;
    if (from == to && (asUser == null || asUser == wasUser)) return;
    final id = queue.removeAt(from);
    queue.insert(to, id);
    final z = wasUser ? userAhead - 1 : userAhead;
    if (asUser != null) {
      userAhead = asUser ? z + 1 : z;
    } else {
      userAhead = (to <= index + z || (wasUser && to == index + z + 1)) ? z + 1 : z;
    }
    if (!shuffle) _origin = List.of(queue);
    _queueChanged();
  }

  // ---------- бесконечная очередь ----------

  /// Включает очередь из [f], начиная с [first]
  Future<void> playFeed(QueueFeeder f, List<String> first) async {
    final ids = [for (final id in first) if (lib.data.tracks[id] != null) id];
    if (ids.isEmpty) return;
    feeder = f;
    _userAdded.clear();
    queue = ids;
    _origin = List.of(ids);
    index = 0;
    userAhead = 0;
    await _open();
    _topUpFeed();
  }

  /// После перезапуска: волна снова пополняет восстановленную очередь
  void attachFeeder(QueueFeeder f) {
    feeder = f;
    notifyListeners();
  }

  /// Меняет источник бесконечной очереди, не трогая то, что уже в очереди (радио по очереди, АвтоDJ).
  /// null — очередь больше не пополняется сама
  void useFeeder(QueueFeeder? f) {
    feeder = f;
    if (f != null) _topUpFeed();
    notifyListeners();
  }

  /// Ставит следующие за текущим треки в новом порядке (АвтоDJ выстроил их по темпу и тональности).
  /// Остаётся только то, что в [ids]; прежнее деление на «поставил сам» и «подобрано» сбрасывается
  void reorderUpcoming(List<String> ids) {
    if (index < 0) return;
    final head = queue.take(index + 1).toList();
    queue = [...head, for (final id in ids) if (lib.data.tracks[id] != null) id];
    _origin = List.of(queue);
    userAhead = 0;
    _queueChanged();
  }

  /// Заменяет всё, что дальше видимых следующих треков (например, сменили характер волны)
  void replaceUpcoming(List<String> ids) {
    if (index < 0) return;
    final head = queue.take(index + 1 + visibleAhead).toList();
    queue = [...head, for (final id in ids) if (lib.data.tracks[id] != null && !head.contains(id)) id];
    _origin = List.of(queue);
    _queueChanged();
  }

  /// Ставит трек сразу после двух следующих: их уже видно на странице волны, их не двигаем.
  /// Волна так вставляет только что скачанное
  void insertSoon(String id) {
    if (index < 0 || lib.data.tracks[id] == null || queue.skip(index).contains(id)) return;
    final at = (index + 1 + visibleAhead).clamp(0, queue.length);
    queue.insert(at, id);
    _origin = List.of(queue);
    _queueChanged();
  }

  /// Сколько следующих треков уже видно (страница волны показывает два): при пересборке их не меняем
  static const visibleAhead = 2;

  /// Пересобирает очередь волны после видимых следующих треков — их человек уже видит, они не должны
  /// вдруг смениться. Остаётся то, что поставили руками, и то, что [keep] просит оставить
  void refillFeed({bool Function(String id)? keep}) {
    if (feeder == null || index < 0) return;
    final head = queue.take(index + 1 + visibleAhead).toList();
    final tail = [
      for (final id in queue.skip(index + 1 + visibleAhead))
        if (_userAdded.contains(id) || (keep?.call(id) ?? false)) id
    ];
    queue = [...head, ...tail];
    _origin = List.of(queue);
    _topUpFeed(force: true);
    _queueChanged();
  }

  /// Убирает из следующих треки, подходящие под [test]. [keepVisible] — не трогать уже видимые следующие
  void dropUpcoming(bool Function(String id) test, {bool keepVisible = false}) {
    if (index < 0) return;
    final before = queue.length;
    final keep = index + 1 + (keepVisible ? visibleAhead : 0);
    queue = [...queue.take(keep), ...queue.skip(keep).where((id) => !test(id))];
    if (queue.length == before) return;
    _origin = List.of(queue);
    _queueChanged();
  }

  void _topUpFeed({bool force = false}) {
    final f = feeder;
    if (f == null || index < 0) return;
    final ahead = queue.length - index - 1;
    if (ahead >= 3 && !force) return;
    if (ahead >= 5) return;
    final add = [for (final id in f.more(5 - ahead)) if (lib.data.tracks[id] != null) id];
    if (add.isEmpty) return;
    queue.addAll(add);
    _origin.addAll(add);
    _queueChanged();
  }

  void _reportHeard({required bool skipped}) {
    final f = feeder, cur = current;
    if (f == null || cur == null || _resumeAt != null) return;
    try {
      f.heard(cur, position.value, skipped: skipped);
    } catch (e) {
      AppLog.warn('Моя волна', e);
    }
    _topUpFeed();
  }

  /// Оставляет только то, что играет сейчас
  void clearUpcoming() {
    final cur = current;
    if (cur == null) return;
    feeder = null;
    queue = [cur.id];
    _origin = [cur.id];
    index = 0;
    _queueChanged();
  }

  void _queueChanged() {
    _adaptiveKey = null;
    _adaptiveDecision = null;
    final ahead = queue.length - index - 1;
    if (userAhead > ahead) userAhead = ahead < 0 ? 0 : ahead;
    notifyListeners();
    _saveSession();
    _preloadNext();
  }

  /// Следующий трек заранее скачиваем в кэш: переход будет без паузы на буферизацию.
  /// Пока он качается целиком, его начало и конец уже лежат в памяти прокси.
  void _preloadNext() {
    String? nextId;
    if (index + 1 < queue.length) {
      nextId = queue[index + 1];
    } else if (repeat == RepeatSetting.all && queue.isNotEmpty) {
      nextId = queue.first;
    }
    _prepareMix();
    if (nextId == null || cache.has(nextId)) return;
    cache.enqueue(nextId);
    final t = lib.data.tracks[nextId];
    if (t != null) warmUp(t);
  }

  // ---------- быстрый старт ----------

  Timer? _hoverTimer;
  String? _hovered;

  /// Трек скоро могут включить: заранее скачиваем его начало и конец и открываем
  /// соединение с Диском. Для сохранённых на компьютере ничего не нужно.
  void warmUp(Track t) {
    if (cache.has(t.id)) return;
    _proxy.warmUp();
    unawaited(_proxy
        .prefetch(t.id, size: t.size, version: t.modified, token: () async => accounts.token(await lib.accessFor(t.source)))
        .catchError((Object _) {}));
  }

  /// Мышь над строкой трека: если задержалась, готовим трек к старту.
  /// Быстрый проход мышью по списку ничего не качает.
  void hover(Track t, bool inside) {
    if (!inside) {
      // Ушли со строки — отменяем, только если это та, над которой ждали
      if (_hovered == t.id) {
        _hovered = null;
        _hoverTimer?.cancel();
      }
      return;
    }
    if (_hovered == t.id) return;
    _hovered = t.id;
    _hoverTimer?.cancel();
    _proxy.warmUp();
    _hoverTimer = Timer(const Duration(milliseconds: 250), () => warmUp(t));
  }

  // ---------- плавный переход ----------

  /// Социальные функции (слушаем вместе с другом) могут запретить переход
  /// Идёт ли джем-сессия. Плавный переход в джеме работает у каждого по его настройкам: ушёл вперёд — запоминаем, на сколько
  bool Function()? jamActive;

  /// Джем: на сколько позиция текущего трека у меня опережает общую из-за плавного перехода (трек начался раньше общего времени)
  Duration jamLead = Duration.zero;

  /// Джем: для какого трека действует [jamLead]; null — опережения нет
  String? jamLeadTrack;

  /// Джем: опережение уже уточнено по первому общему снимку этого трека (до этого оно оценено по ходу перехода)
  bool jamLeadSynced = true;

  /// Джем: у меня начался плавный переход, [next] уже звучит, а общее время дойдёт до него через [sharedRemaining]
  void Function(Track next, Duration sharedRemaining)? onJamCrossfade;

  /// Умный переход: профили звука треков и темп трека (если известен)
  MixAnalyzer? mixer;
  double? Function(Track t)? tempoOf;

  /// Уточнение DJ-плана по разбору звука (фразы, вокал, громкость); null — как есть. Аргументы: план, профили, id треков
  MixPlan Function(MixPlan plan, MixProfile a, MixProfile b, String fromId, String toId)? refinePlan;

  /// Автоматический план перехода с учётом разбора звука
  MixPlan _autoPlan(MixProfile a, MixProfile b, String fromId, String toId, {double? bpm}) {
    final plan = MixPlan.make(a, b, maxSec: crossfadeSecNow.clamp(1, 12).toInt(), bpm: bpm, dj: adaptiveStyle ? null : _djMix);
    final r = refinePlan;
    return r == null || adaptiveStyle ? plan : r(plan, a, b, fromId, toId);
  }
  TrackFeatures? Function(String id)? adaptiveFeatures;
  void Function(Map<String, Object?> event)? djTrace;
  Future<TransitionCheck> Function(String from, String to, MixPlan plan, bool eq, TransitionLevels levels)? verifyTransition;
  Future<void>? _adaptiveCheck;
  bool _adaptiveReady = false;
  String? _adaptiveDecisionId;
  TransitionProbe? _transitionProbe;
  Map<String, Object?>? lastDjExecution;
  void _traceDj(Map<String, Object?> event) {
    if (event['kind'] == 'preflight' || event['kind'] == 'fallback' || event['kind'] == 'headroom' || event['kind'] == 'executionAbort') {
      AppLog.info('DJ check: ${jsonEncode(event)}');
    }
    try { djTrace?.call(event); } catch (e) { AppLog.warn('DJ: не удалось записать диагностику', e); }
  }
  final List<DjHistoryEntry> _djHistory = [];
  int _historySeq = -1;
  SetIntent get setIntent => SetIntent.values.firstWhere(
      (i) => i.name == settings.viewOf('mix.intent', 'balanced'), orElse: () => SetIntent.balanced);
  AdaptiveDecision? _adaptiveDecision;
  String? _adaptiveKey;
  String get mixStatus {
    if (!adaptiveStyle) return djStyle ? 'DJ: сведение по доступным сеткам' : 'AutoMix: плавный переход';
    final d = _adaptiveDecision;
    if (d == null) return 'Adaptive: план ещё не выбран; проверьте полный анализ';
    if (!_adaptiveReady) return 'Adaptive: проверяю переход; до результата доступен обычный AutoMix';
    final technique = switch (d.technique) {
      AdaptiveTechnique.autoMix => 'обычный AutoMix',
      AdaptiveTechnique.beatBlend => 'beat blend',
      AdaptiveTechnique.shortFade => 'короткий crossfade',
      AdaptiveTechnique.cut => 'стык на фразе',
      AdaptiveTechnique.atmospheric => 'атмосферный переход',
    };
    return 'Adaptive: $technique, ${(d.plan?.length.inMilliseconds ?? crossfadeSecNow * 1000) / 1000} с. '
        '${d.reasons.isEmpty ? '' : d.reasons.first}';
  }

  void refreshMixSettings() {
    _adaptiveKey = null;
    _adaptiveDecision = null;
    _dropPrepared();
    _prepareMix();
    notifyListeners();
  }

  bool get adaptiveStyle => jamXfSec == null && smartMix && settings.viewOf('mix.style', 'fade') == 'adaptive';

  final Stopwatch _adaptiveChecked = Stopwatch();

  /// Идёт переход между треками или следующая дека прямо сейчас открывается: фоновым задачам лучше подождать
  bool get transitionActive => _fading || _preparing;

  /// Профиль звука явно от другого файла: длительность расходится с тем, что играет
  bool _profileMismatch(MixProfile? p) =>
      p != null && duration > Duration.zero && (p.durationMs - duration.inMilliseconds).abs() > 4000;

  /// Всё, от чего зависит адаптивный план: пока строка та же, план не пересчитывается. В ключе — только профили и
  /// разборы треков, участвующих в выборе: чужой фоновый разбор библиотеки план не сбрасывает
  String _adaptiveKeyOf(bool manual, Track cur, List<String> ids, MixAnalyzer m) {
    final all = [cur.id, ...ids];
    final analysis = all.map((id) => adaptiveFeatures?.call(id)?.analyzedAt ?? 0).join(',');
    final profiles = all.map((id) => identityHashCode(m.profileCached(id))).join(',');
    final cached = (List.of(all)..sort()).map((id) => cache.has(id) ? '1' : '0').join();
    return '$manual:$_openSeq:${cur.id}:${ids.join(",")}:${settings.viewOf('mix.bars', '8')}:${settings.viewOf('mix.range', '8')}:'
        '${settings.viewOf('mix.bass', '1')}:${settings.viewOf('mix.offset', '0')}:${settings.viewOf('mix.transpose', '0')}:${_pitch[_p] ?? 0}:$crossfadeSecNow:$profiles:$analysis:'
        '${setIntent.name}:$normalize:$normLevel:${settings.viewOf('intel.cut', '0')}:$cached:${_profileMismatch(m.profileCached(cur.id))}';
  }

  /// Freeze the first transition before preloading. Never reorder explicit user
  /// additions, a jam queue, or a saved/manual transition. Queue edits replan.
  void _prepareAdaptive({bool manual = false}) {
    final cur = current, m = mixer;
    if (!adaptiveStyle || adaptiveFeatures == null || cur == null || m == null ||
        _fading || (!manual && (_preparing || _preparedId != null)) || index < 0 || index + 1 >= queue.length) return;
    // Вызывается на каждом отсчёте позиции (десятки раз в секунду): сверяем состояние не чаще нескольких раз в секунду
    if (!manual && _adaptiveKey != null && _adaptiveChecked.isRunning && _adaptiveChecked.elapsedMilliseconds < 400) return;
    _adaptiveChecked
      ..reset()
      ..start();
    final ids = queue.skip(index + 1).take(AdaptiveDj.maxCandidates).toList();
    if (_previewOverride != null || ids.any((id) => _prefFor(cur.id, id) != null)) return;
    final key = _adaptiveKeyOf(manual, cur, ids, m);
    if (_adaptiveKey == key) return;
    // Профиль от другого файла (трек заменили): адаптивный план не строим. Проверяем ДО планирования и запоминаем
    // ключ — иначе тяжёлый перебор запускался заново на каждом отсчёте позиции до самого конца трека
    if (_profileMismatch(m.profile(cur.id))) {
      _adaptiveKey = key;
      return;
    }
    AdaptiveTrack track(String id) => AdaptiveTrack(id, m.profile(id), adaptiveFeatures?.call(id),
        artist: lib.data.tracks[id]?.artist.toLowerCase() ?? '', genre: m.profileCached(id)?.genre ?? '');
    try {
      final planningClock = Stopwatch()..start();
      _adaptiveCheck = null;
      final result = AdaptiveDj.choose(track(cur.id), [for (final id in ((userAhead > 0 || _preparing || _preparedId != null) ? ids.take(1) : ids)) track(id)],
          options: _djMix ?? const DjMix(), maxSec: crossfadeSecNow.clamp(1, 12).toInt(),
          earliestMs: position.value.inMilliseconds + 2000,
          manualPositionMs: manual ? position.value.inMilliseconds : null,
          allowCut: settings.viewOf('intel.cut', '0') == '1',
          context: DjSetContext(intent: setIntent, history: List.of(_djHistory)));
      _adaptiveDecision = result;
      _adaptiveReady = result.technique == AdaptiveTechnique.autoMix;
      final selected = ids.indexOf(result.to);
      if (selected > 0 && userAhead == 0) {
        final id = queue.removeAt(index + 1 + selected);
        queue.insert(index + 1, id);
        _origin = List.of(queue);
        _queueChanged();
      }
      _adaptiveDecision = result;
      // Ключ — по очереди ПОСЛЕ перестановки и тем же расчётом, что и при сверке: иначе следующий отсчёт позиции
      // видел «другое» состояние и планирование вместе с проверочным рендером выполнялись второй раз
      _adaptiveKey = _adaptiveKeyOf(manual, cur, queue.skip(index + 1).take(AdaptiveDj.maxCandidates).toList(), m);
      AppLog.info('Adaptive AutoDJ: ${jsonEncode({
            'from': cur.id,
            'candidates': ids,
            ...result.toJson()
          })}');
      final baseline = m.profile(cur.id) != null && m.profile(result.to) != null
          ? MixPlan.make(m.profile(cur.id)!, m.profile(result.to)!, maxSec: crossfadeSecNow.clamp(1, 12).toInt()) : null;
      final normalizationKey = '$normalize:$normLevel';
      final levels = TransitionLevels(
        outAmplitude: normalize ? math.pow(math.max(_normIn, _normFactorFor(cur.id)), 3).toDouble() : 1,
        inAmplitude: normalize ? math.pow(_normFactorFor(result.to), 3).toDouble() : 1, matchGain: normalize ? 1 : null);
      final decisionId = _adaptiveDecisionId = '$_openSeq-${DateTime.now().microsecondsSinceEpoch}';
      _traceDj({'kind': 'decision', 'from': cur.id, 'fromRevision': adaptiveFeatures?.call(cur.id)?.revision,
        'decisionId': decisionId,
        'toRevision': adaptiveFeatures?.call(result.to)?.revision, 'manual': manual,
        'candidates': ids, 'planningMs': planningClock.elapsedMilliseconds, ...result.toJson(),
        if (baseline != null) 'baseline': {'outMs': baseline.start.inMilliseconds,
          'inMs': baseline.inStart.inMilliseconds, 'lengthMs': baseline.length.inMilliseconds,
          'rate': 1.0, 'inGain': baseline.inGain, 'levels': levels.toJson()},
        'inGain': result.plan?.inGain, 'swapMs': result.plan?.swapAt?.inMilliseconds,
        'eqMode': result.plan?.dj == true && result.plan?.swapAt != null ? 'threeBandV1' : 'legacyBass',
        'levels': levels.toJson(), 'preflight': _adaptiveReady ? 'not_required' : 'pending'});
      if (!_adaptiveReady) {
        final seq = _openSeq;
        _adaptiveCheck = () async {
          var checkedDecision = result;
          TransitionCheck check;
          try {
            check = result.plan == null || verifyTransition == null
                ? const TransitionCheck(TransitionVerdict.unavailable, 'verifier_unavailable')
                : await verifyTransition!(cur.id, result.to, result.plan!, result.plan!.dj && result.plan!.swapAt != null, levels);
          } catch (_) { check = const TransitionCheck(TransitionVerdict.unavailable, 'verifier_failed'); }
          final correction = headroomCorrection(check);
          if (correction != null && result.plan != null && verifyTransition != null &&
              seq == _openSeq && identical(_adaptiveDecision, result)) {
            final adjusted = result.plan!.withHeadroom(correction);
            _traceDj({'kind':'headroom','decisionId':decisionId,'measuredPeakDbtp':check.truePeakDb,
              'gain':correction,'attenuationDb':20*math.log(correction)/math.ln10});
            try {
              final retry = await verifyTransition!(cur.id, result.to, adjusted,
                  adjusted.dj && adjusted.swapAt != null, levels);
              check = retry;
              if (retry.verdict == TransitionVerdict.accepted && seq == _openSeq && identical(_adaptiveDecision, result)) {
                _adaptiveDecision = checkedDecision = AdaptiveDecision(result.to, adjusted, result.technique, result.score,
                    [...result.reasons, 'Запас по пикам восстановлен ослаблением'],
                    path:result.path, alternatives:result.alternatives, components:result.components);
              }
            } catch (_) { check = const TransitionCheck(TransitionVerdict.unavailable, 'verifier_failed'); }
          }
          if (seq != _openSeq || current?.id != cur.id || !identical(_adaptiveDecision, checkedDecision) || _fading ||
              '$normalize:$normLevel' != normalizationKey || _autoNextIndex() == null || queue[_autoNextIndex()!] != result.to) return;
          final timely = result.plan != null && result.plan!.start.inMilliseconds > position.value.inMilliseconds + 250;
          _traceDj({'kind': 'preflight', 'from': cur.id, 'to': result.to, 'decisionId': decisionId,
            'cueStillAhead': timely, ...check.toJson()});
          if (check.verdict == TransitionVerdict.accepted && timely) { _adaptiveReady = true; }
          else {
            _traceDj({'kind':'fallback','decisionId':decisionId,'selectedTechnique':result.technique.name,
              'selectedEffect':result.plan?.effect,'reason':!timely?'cue_passed':check.reason,
              'verdict':check.verdict.name,'peakDbtp':check.truePeakDb});
            final normal = AdaptiveDj.fallback(track(cur.id), track(result.to), crossfadeSecNow.clamp(1, 12).toInt());
            _adaptiveDecision = AdaptiveDecision(normal.to, normal.plan, normal.technique, 0,
              [!timely ? 'AutoMix: точка сведения уже пройдена' : switch (check.reason) {
                'originals_not_cached' => 'AutoMix: для проверки перехода нужны оба трека в кэше',
                'true_peak_headroom' => 'AutoMix: у наложения недостаточно запаса по пикам',
                'silent_render' => 'AutoMix: проверка обнаружила тишину',
                _ => 'AutoMix: акустическая проверка перехода не пройдена',
              }]);
            _adaptiveReady = true;
          }
          notifyListeners();
        }();
      }
      notifyListeners();
    } catch (e) {
      _adaptiveKey = key;
      _adaptiveDecision = null;
      AppLog.warn('Adaptive AutoDJ: обычный AutoMix после ошибки планирования', e);
    }
  }

  bool get smartMix => jamSmart ?? settings.viewOf('mix.smart', '1') == '1';

  /// Диджейский стиль перехода: подгонка темпа, переход на целое число тактов, обмен басов (в джеме действует стиль организатора — обычный)
  bool get djStyle => jamXfSec == null && smartMix && const ['dj', 'adaptive'].contains(settings.viewOf('mix.style', 'fade'));

  DjMix? get _djMix => djStyle
      ? DjMix(
          bars: settings.viewNum('mix.bars', 8).round().clamp(1, 32).toInt(),
          range: (settings.viewNum('mix.range', 8) / 100).clamp(0.01, 0.2).toDouble(),
          bass: settings.viewOf('mix.bass', '1') == '1',
          transpose:
              adaptiveStyle && settings.viewOf('mix.transpose', '0') == '1',
          outgoingShift: _pitch[_p] ?? 0,
          offsetMs: settings
              .viewNum('mix.offset', 0)
              .round()
              .clamp(-200, 200)
              .toInt())
      : null;

  /// Джем: настройки плавного перехода организатора (секунды, 0 — выключен; умный переход). null — действуют мои.
  /// Организатор задаёт переход всем: включил у себя — включается у остальных, выключил — выключается
  int? jamXfSec;
  bool? jamSmart;

  /// Длина плавного перехода сейчас: в джеме — у организатора, иначе моя настройка
  int get crossfadeSecNow => jamXfSec ?? settings.crossfadeSec;

  /// Ручные переходы пар треков («Микс»)
  MixBook? mixBook;

  /// Переход, который сейчас предпрослушивается из редактора: пока он не доиграл, берётся вместо сохранённого
  ({String from, String to, TransitionPref pref})? _previewOverride;

  /// Ручная настройка перехода [from] → [to]; null — автоматический. В джеме действуют настройки организатора
  TransitionPref? _prefFor(String from, String to) {
    if (jamXfSec != null) return null;
    final o = _previewOverride;
    if (o != null && o.from == from && o.to == to) return o.pref;
    return mixBook?.get(from, to);
  }

  /// План умного перехода с текущего трека на следующий; null — профили ещё не готовы, переход обычный
  MixPlan? _smartPlan() {
    final m = mixer, cur = current, ni = _autoNextIndex();
    if (m == null || cur == null || ni == null) return null;
    final pref = _prefFor(cur.id, queue[ni]);
    final manual = pref != null && pref.mode == TransitionMode.manual;
    if (!smartMix && !manual) return null;
    final a = m.profile(cur.id), b = m.profile(queue[ni]);
    if (a == null || b == null) return null;
    // Профиль от другого файла (трек заменили) — не доверяем
    if (_profileMismatch(a)) return null;
    final selected = _adaptiveDecision;
    final nextId = queue[ni];
    final bpm = tempoOf?.call(cur);
    // План спрашивают на каждом отсчёте позиции в последние минуты трека. Пока ничего из исходных данных не изменилось,
    // отдаём готовый: раньше расчёт (и строка в журнале от уточнения по разбору звука) повторялись десятки раз в секунду
    final key = (
      cur.id, nextId, a, b, pref, selected, _adaptiveReady, crossfadeSecNow, bpm, smartMix, adaptiveStyle, djStyle,
      settings.viewOf('mix.bars', '8'), settings.viewOf('mix.range', '8'), settings.viewOf('mix.bass', '1'),
      settings.viewOf('mix.offset', '0'),
      settings.viewOf('intel.plan', '1'),
      settings.viewOf('intel.cut', '0'),
      settings.viewOf('mix.transpose', '0'),
      _pitch[_p] ?? 0,
      adaptiveFeatures?.call(cur.id), adaptiveFeatures?.call(nextId),
    );
    if (_planKey == key && _planAge.elapsedMilliseconds < 5000) return _planMemo;
    final auto = adaptiveStyle && !manual && selected?.to == nextId && selected?.plan != null
        ? _adaptiveReady ? selected!.plan! : MixPlan.make(a, b, maxSec: crossfadeSecNow.clamp(1, 12).toInt())
        : _autoPlan(a, b, cur.id, nextId, bpm: bpm);
    final plan = manual ? MixPlan.manual(a, b, pref, auto: auto) : auto;
    _planKey = key;
    _planMemo = plan;
    _planAge
      ..reset()
      ..start();
    return plan;
  }

  Object? _planKey;
  MixPlan? _planMemo;
  final Stopwatch _planAge = Stopwatch();

  /// Переход между текущим треком и следующим настроен вручную (или хоть как-то задан)
  TransitionPref? get _nextPref {
    final cur = current, ni = _autoNextIndex();
    return cur == null || ni == null ? null : _prefFor(cur.id, queue[ni]);
  }

  /// «Свести сейчас»: начать переход на следующий трек прямо сейчас, не дожидаясь конца. Темп и доли — по тем же правилам
  Future<void> mixNow() async {
    if (_fading || !playing || _autoNextIndex() == null) return;
    _prepareAdaptive(manual: true);
    final seq = _openSeq;
    await _adaptiveCheck?.timeout(const Duration(seconds: 2), onTimeout: () {});
    if (seq != _openSeq || _fading || !playing) return;
    if (adaptiveStyle) lib.messages.add(mixStatus);
    var plan = _smartPlan();
    if (plan == null) {
      await _startCrossfade();
      return;
    }
    if (adaptiveStyle && _adaptiveReady && _adaptiveDecision?.components.isNotEmpty == true) {
      await _startCrossfade(plan);
      return;
    }
    var start = position.value + plan.preroll + const Duration(milliseconds: 250);
    final g = plan.grid;
    if (g != null) {
      // Ближайшая доля уходящего трека
      final k = ((start.inMilliseconds - g.$1) / g.$2).ceil();
      start = Duration(milliseconds: (g.$1 + k * g.$2).round());
    }
    final length = plan.dj || adaptiveStyle ? plan.length : Duration(seconds: math.max(4, crossfadeSecNow));
    plan = MixPlan(start, length, plan.inStart, plan.inGain,
        dj: plan.dj,
        rate: plan.rate,
        swapAt: plan.swapAt,
        grid: plan.grid,
        offsetMs: plan.offsetMs,
        preroll: plan.preroll,
        transpose: plan.transpose,
        outgoingShift: plan.outgoingShift,
        tempoRamp: plan.tempoRamp, effect: plan.effect, headroom: plan.headroom);
    await _startCrossfade(plan);
  }

  /// Предпрослушивание перехода из редактора: играет [a] за несколько секунд до перехода и сводит с [b] с настройками [pref]
  Future<bool> previewTransition(Track a, Track b, TransitionPref pref) async {
    final m = mixer;
    final pa = m?.profile(a.id), pb = m?.profile(b.id);
    if (pa == null || pb == null) return false;
    final auto = _autoPlan(pa, pb, a.id, b.id);
    final plan = pref.mode == TransitionMode.manual ? MixPlan.manual(pa, pb, pref, auto: auto) : auto;
    final from = Duration(milliseconds: math.max(0, plan.start.inMilliseconds - plan.preroll.inMilliseconds - 8000));
    await playTracks([a, b], 0, inOrder: true);
    _previewOverride = (from: a.id, to: b.id, pref: pref);
    await seek(from);
    return true;
  }

  /// Профили звука текущего и следующего трека — считаем заранее, пока трек играет
  void _prepareMix() {
    final m = mixer;
    final needMix = (smartMix && crossfadeSecNow > 0) || _nextPref?.mode == TransitionMode.manual;
    if (m == null || !(needMix || normalize)) return;
    final cur = current;
    if (cur != null) {
      // Ровной громкости нужна громкость текущего трека: он должен лежать в кэше, чтобы его можно было разобрать
      if (normalize && !cache.has(cur.id)) cache.enqueue(cur.id);
      m.prepare(cur.id);
    }
    final ni = _autoNextIndex();
    if (ni != null) m.prepare(queue[ni]);
  }

  /// Пока идёт переход, не null; по нему рисуется конец полосы осветления
  final ValueNotifier<CrossfadeInfo?> fadeInfo = ValueNotifier(null);

  /// Следующий трек уже открыт на втором проигрывателе (на паузе, громкость 0): переход начинается без задержки на буферизацию
  String? _preparedId;
  bool _preparing = false;

  /// За сколько секунд до перехода открываем следующий трек заранее
  static const prepareLeadSec = 10;

  Duration _prevPos = Duration.zero;
  bool _fading = false;
  int _fadeGeneration = 0;
  Timer? _fadeTimer;
  double _inGain = 1;
  Timer? _headroomRecovery;
  double _outGain = 1;
  Player? _outgoing;

  // ---------- ровная громкость ----------

  /// Выравнивание громкости треков. Без фильтров внутри проигрывателя (прежний `loudnorm` ломал вывод звука):
  /// громкость каждого трека измеряет [MixAnalyzer], а поправка просто умножает обычную громкость
  bool get normalize => settings.viewOf('norm', '0') == '1';

  /// quiet / normal / loud
  String get normLevel {
    final v = settings.viewOf('norm.level', 'normal');
    return v == 'quiet' || v == 'loud' ? v : 'normal';
  }

  /// Целевая громкость тела трека в дБ (шкала анализатора)
  static double normTargetDb(String level) => switch (level) {
        'quiet' => -19.0,
        'loud' => -13.0,
        _ => -16.0,
      };

  /// Поправка в дБ: подтянуть тихий трек и приглушить громкий, но не больше −12 дБ и +12 дБ.
  /// Тихие записи (например, спокойный эмбиент около −23 LUFS) нужно поднимать на 8–10 дБ; предел подъёма задаёт ещё и
  /// ползунок громкости: выше 100 % громкость не уходит
  static double normGainDb(double trackDb, double targetDb) => (targetDb - trackDb).clamp(-12.0, 12.0).toDouble();

  /// Во сколько раз меняется амплитуда при поправке [db]
  static double dbToFactor(double db) => math.pow(10, db / 20).toDouble();

  /// Множитель для свойства `volume` проигрывателя. У mpv громкость кубическая (volume 50 — это уже −18 дБ),
  /// поэтому чтобы поправка была ровно в [db] децибел, множитель — корень третьей степени из амплитуды
  static double dbToVolumeFactor(double db) => math.pow(10, db / 60).toDouble();

  /// Множитель громкости трека; 1, пока он не разобран или выравнивание выключено
  double _normFactorFor(String? id) {
    if (!normalize || id == null) return 1;
    final pr = mixer?.profile(id);
    if (pr == null) return 1;
    return dbToVolumeFactor(normGainDb(pr.loudDb, normTargetDb(normLevel)));
  }

  double _normIn = 1; // текущий трек
  double _normOut = 1; // уходящий при переходе
  Timer? _normTimer;

  /// Громкость трека стала известна (или поменяли настройку): плавно, за ~1,5 с, переходим к нужной
  void refreshNormalize() {
    final target = _normFactorFor(current?.id);
    _normTimer?.cancel();
    if ((target - _normIn).abs() < 0.005) return;
    _normTimer = Timer.periodic(const Duration(milliseconds: 50), (t) {
      final goal = _normFactorFor(current?.id);
      _normIn += (goal - _normIn) * 0.15;
      if ((goal - _normIn).abs() < 0.005) {
        _normIn = goal;
        t.cancel();
      }
      _applyVolume();
    });
  }

  Future<void> setNormalize(bool on) async {
    settings.view['norm'] = on ? '1' : '0';
    _prepareMix();
    refreshNormalize();
    notifyListeners();
    await lib.saveSettings();
  }

  Future<void> setNormLevel(String level) async {
    settings.view['norm.level'] = level;
    refreshNormalize();
    notifyListeners();
    await lib.saveSettings();
  }

  /// Выше 100 не поднимаем: запас громкости у libmpv зависит от сборки, а переполнение хуже тихого трека
  double _scaled(double v) => v.clamp(0.0, 100.0).toDouble();

  /// Громкость обоих проигрывателей с учётом перехода и выравнивания
  void _applyVolume() {
    unawaited(_p.setVolume(_scaled(volume * _inGain * _normIn)));
    final o = _outgoing;
    if (o != null) unawaited(o.setVolume(_scaled(volume * _outGain * _normOut)));
  }

  /// Есть ли следующий трек для автоматического перехода (индекс, либо null)
  int? _autoNextIndex() {
    if (queue.isEmpty) return null;
    if (index + 1 < queue.length) return index + 1;
    if (repeat == RepeatSetting.all) return 0;
    return null;
  }

  void _maybeCrossfade(Duration d) {
    final prev = _prevPos;
    _prevPos = d;
    if (_fading || _resumeAt != null || !playing || repeat == RepeatSetting.one) return;
    if (_autoNextIndex() == null) return;
    if (adaptiveStyle && duration - d < const Duration(seconds: 180)) _prepareAdaptive();
    final pref = _nextPref;
    if (pref != null && pref.mode == TransitionMode.cut) return; // этот переход — без перехода: трек доиграет сам
    final manual = pref != null && pref.mode == TransitionMode.manual;
    if (crossfadeSecNow <= 0 && !manual) return;
    // Профили смотрим только ближе к концу трека — не на каждом тике позиции. У ручного перехода начало может быть где угодно
    final plan = manual || duration - d < Duration(seconds: djStyle ? 180 : 60) ? _smartPlan() : null;
    _maybePrepare(d, plan);
    final step = d - prev;
    // Диджейский переход запускает следующий трек чуть раньше (без звука), поэтому и отсчёт начинается раньше
    final trigger = plan == null ? Duration.zero : plan.start - plan.preroll;
    final due = plan != null
        ? d >= trigger && prev < trigger && step >= Duration.zero && step < const Duration(seconds: 2)
        : crossfadeDue(seconds: crossfadeSecNow, duration: duration, position: d, previous: prev);
    if (!due) return;
    unawaited(_startCrossfade(plan));
  }

  /// Ближе к переходу открываем следующий трек заранее, чтобы к началу перехода он уже был забуферизован
  void _maybePrepare(Duration d, MixPlan? plan) {
    if (_preparing || _fading || _preparedId != null) return;
    final ni = _autoNextIndex();
    if (ni == null) return;
    final lead = Duration(seconds: prepareLeadSec) + (plan?.length ?? Duration(seconds: crossfadeSecNow));
    final startAt = plan?.start ?? (duration - Duration(seconds: crossfadeSecNow));
    if (duration < Duration(seconds: crossfadeSecNow * 2) || startAt - d > lead) return;
    final t = lib.data.tracks[queue[ni]];
    if (t == null) return;
    _preparing = true;
    final seq = _openSeq;
    unawaited(() async {
      try {
        final media = await _mediaFor(t);
        if (seq != _openSeq || _fading) return;
        final q = _q ??= Player();
        await q.setVolume(0);
        await _applyPitch(q, 0);
        await q.open(media, play: false);
        if (seq != _openSeq) {
          await q.stop();
          return;
        }
        if (!_fading) _preparedId = t.id;
      } catch (e) {
        AppLog.warn('Переход: не получилось заранее открыть следующий трек', e);
      } finally {
        _preparing = false;
      }
    }());
  }

  /// Сбрасывает заранее открытый трек (человек переключил трек сам)
  void _dropPrepared() {
    if (_preparedId == null && !_preparing) return;
    _preparedId = null;
    if (!_fading) unawaited(_q?.stop() ?? Future<void>.value());
  }

  Future<void> _startCrossfade([MixPlan? plan]) async {
    if (adaptiveStyle && !_adaptiveReady && _adaptiveDecision != null) {
      _traceDj({'kind':'fallback','decisionId':_adaptiveDecisionId,
        'selectedTechnique':_adaptiveDecision!.technique.name,
        'selectedEffect':_adaptiveDecision!.plan?.effect,'reason':'preflight_pending_at_start'});
    }
    final nextIndex = _autoNextIndex();
    if (nextIndex == null || _fading) return;
    final nextTrack = lib.data.tracks[queue[nextIndex]];
    if (nextTrack == null) return;
    final fromId = current?.id ?? '';
    final prepareClock = Stopwatch()..start();
    _fading = true;
    _headroomRecovery?.cancel();
    final seq = ++_openSeq;
    final generation = ++_fadeGeneration;
    bool ownsTransition() => seq == _openSeq && generation == _fadeGeneration && _fading;
    final lengthWanted = plan?.length.inMilliseconds ?? crossfadeSecNow.clamp(1, 10).toInt() * 1000;
    final lengthMs0 = lengthWanted;
    var handedOff = false;
    Player? opened;
    // Переход отменили, пока новая дека готовилась: возвращаем ей обычный темп и убираем фильтры, чтобы следующий
    // трек на ней не заиграл со срезанными частотами. Если деку уже занял новый переход или подготовка — не трогаем
    Future<void> release() async {
      final deck = opened;
      if (deck == null || handedOff || _fading || _preparing || _preparedId != null || identical(_p, deck)) return;
      await _clearEq(deck);
      await _applyPitch(deck, 0);
      if (_fxDirty) {
        await _setRate(deck, 1.0);
        await _setLowCut(deck, false);
      }
      if (!_fading && !_preparing && _preparedId == null && !identical(_p, deck)) await deck.stop();
    }
    // С выравниванием громкости оба трека уже приведены к одному уровню — свою подгонку перехода не добавляем
    final match = normalize ? 1.0 : (plan?.inGain ?? 1.0);
    try {
      AppLog.info(plan == null
          ? 'Плавный переход на «${nextTrack.title}» (${lengthMs0 ~/ 1000} с)'
          : 'Умный переход на «${nextTrack.title}»: с ${plan.start.inMilliseconds / 1000} с, ${(lengthMs0 / 1000).toStringAsFixed(1)} с, '
              'следующий с ${plan.inStart.inMilliseconds / 1000} с, громкость ×${match.toStringAsFixed(2)}');
      // Следующий трек как раз открывается заранее — дожидаемся, чтобы не открывать его дважды на одном проигрывателе
      for (var i = 0; _preparing && i < 60; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      if (!ownsTransition()) return;
      final incoming = _q ??= Player();
      await _applyPitch(incoming, 0);
      final prepared = _preparedId == nextTrack.id;
      _preparedId = null;
      await incoming.setVolume(0);
      if (!ownsTransition()) return;
      opened = incoming;
      final djp = plan != null && plan.dj ? plan : null;
      final dj = djp != null;
      var eqBlend = false;
      if (prepared) {
        await incoming.play();
      } else {
        final media = await _mediaFor(nextTrack);
        if (!ownsTransition()) return; // пока готовили, человек сам что-то переключил
        await incoming.open(media, play: true);
      }
      if (!ownsTransition()) return;
      // Configure the already opened, silent deck; open may reset transport FX.
      await _applyPitch(incoming, plan?.transpose ?? 0);
      if (!ownsTransition()) return;
      if (dj) {
        _fxDirty = true;
        await _setRate(incoming, djp.rate);
        if (adaptiveStyle && djp.swapAt != null) {
          final initial = djEqAt(0, djp.swapAt!.inMilliseconds / lengthMs0);
          eqBlend = await _installEq(incoming, initial.$2);
          if (eqBlend) eqBlend = await _installEq(_p, initial.$1);
          if (!eqBlend) {
            await _clearEq(incoming); await _clearEq(_p);
            throw StateError('Three-band EQ unavailable; use AutoMix');
          }
        }
        if (!eqBlend) await _setLowCut(incoming, djp.swapAt != null, force: true);
      } else if (_fxDirty) {
        await _setRate(incoming, 1.0);
        await _setLowCut(incoming, false, force: true);
      }
      if (!ownsTransition()) return;
      // Пустое вступление следующего трека пропускаем
      // Диджейскому следующий трек запускается на preroll раньше, чтобы к началу перехода дойти ровно до своей доли
      final inStart = djp != null
          ? djp.inStart - Duration(microseconds: (djp.preroll.inMicroseconds * djp.rate).round())
          : (plan != null && plan.inStart > const Duration(milliseconds: 300) ? plan.inStart : Duration.zero);
      if (inStart > (djp != null ? const Duration(milliseconds: 20) : Duration.zero)) await incoming.seek(inStart);
      // Уходящий трек остаётся на полной громкости, пока следующая дека не готова к воспроизведению (до 5 с),
      // и оба затихают и нарастают одновременно
      HandoffState readIncoming() => HandoffState(incoming.state.position, incoming.state.duration,
          playing: incoming.state.playing, buffering: incoming.state.buffering);
      final ready = await waitForHandoff(
        read: readIncoming,
        changes: incoming.stream.position.map<void>((_) {}),
        isCurrent: ownsTransition,
        cue: inStart,
      );
      if (!ownsTransition()) return;
      if (!ready) throw StateError('Следующая дека не готова: нет длительности или продвижения воспроизведения');
      if (dj) AppLog.info('DJ execution: rate requested=${djp.rate}, actual=${incoming.state.rate}, '
          'bassCut=${_cut.contains(incoming)}, eq=$eqBlend, swapMs=${djp.swapAt?.inMilliseconds}, envelope=phrase');
      if (dj) {
        // Ждём, пока уходящий дойдёт до начала перехода (следующий всё это время уже играет без звука),
        // и сверяем доли: если расходятся заметно, один раз подтягиваем, дальше подстраиваем скоростью
        _stopClocks();
        final oc = _outClock = _PosClock(_p, 1.0);
        final ic = _inClock = _PosClock(incoming, djp.rate);
        final wait = djp.start - oc.now();
        if (wait > const Duration(milliseconds: 5)) {
          await Future<void>.delayed(wait < const Duration(seconds: 8) ? wait : const Duration(seconds: 8));
        }
        if (!ownsTransition()) {
          return;
        }
        final e = _phaseErr(djp, oc.now(), ic.now());
        if (e != null && e.abs() > 60) {
          final back = Duration(microseconds: ((e - 45) * djp.rate * 1000).round()); // 45 мс — на саму перемотку
          final corrected = ic.now() - back;
          await incoming.seek(corrected < Duration.zero ? Duration.zero : corrected);
        }
      }
      if (!ownsTransition()) return;
      // Уходящему осталось звучать не дольше, чем он ещё длится: переход укорачивается на время ожидания
      if (plan != null && plan.effect != 'none') {
        final effect = DjEffect.values.byName(plan.effect);
        final graph = djEffectGraph(effect, input: '[in]', output: '[out]',
            start: _p.state.position.inMilliseconds / 1000,
            length: lengthWanted / 1000, beat: (plan.grid?.$2 ?? 500) / 1000);
        final effectDeck = _p;
        final native = effectDeck.platform as dynamic;
        await native.command(['af', 'add', '@cave-dj-effect:lavfi=[$graph]']);
        _effectDecks.add(effectDeck);
        AppLog.info('DJ effect: ${plan.effect}');
        if (!ownsTransition()) { await _clearDjEffect(effectDeck); return; }
      }
      final oldRemaining = duration - _p.state.position;
      final lengthMs = oldRemaining > Duration.zero
          ? math.min(lengthWanted, math.max(800, oldRemaining.inMilliseconds))
          : lengthWanted;
      final oldFraction = duration > Duration.zero ? (_p.state.position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0).toDouble() : 1.0;
      final oldDurationMs = duration.inMilliseconds;
      // Джем: общего времени у уходящего трека осталось на опережение больше, чем у меня на часах
      final inJam = jamActive?.call() ?? false;
      final prevLead = jamLeadTrack != null && jamLeadTrack == current?.id ? jamLead : Duration.zero;
      final sharedRemaining = (oldRemaining > Duration.zero ? oldRemaining : Duration.zero) + prevLead;
      // Теперь «главный» проигрыватель — новый, а прежний доигрывает затихая
      final old = _p;
      _transitionProbe = TransitionProbe(from: fromId, to: nextTrack.id,
          effect:plan?.effect ?? 'none',headroomGain:plan?.headroom ?? 1,
          decisionId: adaptiveStyle && identical(plan, _adaptiveDecision?.plan) ? _adaptiveDecisionId : null,
          eqMode: eqBlend ? 'threeBandV1_installed' : djp?.swapAt != null ? 'legacyBass' : 'none',
          technique: dj ? 'beatBlend' : plan == null ? 'autoMix' :
              _adaptiveDecision?.to == nextTrack.id && _adaptiveDecision?.technique != AdaptiveTechnique.beatBlend
                  ? _adaptiveDecision!.technique.name : 'autoMix',
          requestedStartMs: plan?.start.inMilliseconds ?? old.state.position.inMilliseconds,
          actualStartMs: old.state.position.inMilliseconds, cueInMs: incoming.state.position.inMilliseconds,
          plannedLengthMs: lengthWanted, actualLengthMs: lengthMs, prepareMs: prepareClock.elapsedMilliseconds,
          requestedRate: djp?.rate ?? 1, actualRate: incoming.state.rate);
      handedOff = true;
      _p = incoming;
      _q = old;
      _outgoing = old;
      _bind(_p);
      _reportHeard(skipped: false); // волна учитывает дослушанный трек, как при обычном переходе
      index = nextIndex;
      cache.touch(nextTrack);
      error = null;
      _userPaused = false;
      _prevPos = Duration.zero;
      _openedAt = DateTime.now();
      // Новый проигрыватель уже сообщил длительность до того, как мы подписались на него: берём её из его состояния,
      // иначе полоса перемотки считает трек нулевой длины и перематывать нельзя
      position.value = _p.state.position;
      duration = _p.state.duration > Duration.zero
          ? _p.state.duration
          : Duration(milliseconds: nextTrack.durationMs ?? mixer?.profile(nextTrack.id)?.durationMs ?? 0);
      buffering = _p.state.buffering;
      playing = _p.state.playing;
      _inGain = 0;
      _outGain = math.pow(plan?.headroom ?? 1, 1/3).toDouble();
      _normTimer?.cancel();
      _normOut = _normIn;
      _normIn = _normFactorFor(nextTrack.id);
      _applyVolume();
      _pendingRate = djp?.rate ?? 1.0;
      _startTail(CrossfadeInfo(oldFraction, DateTime.now(), lengthMs, oldDurationMs: oldDurationMs));
      // Задаём до notifyListeners: джем по нему отличает мой переход от того, что человек переключил трек сам
      if (inJam) {
        jamLead = _p.state.position + sharedRemaining;
        jamLeadTrack = nextTrack.id;
        jamLeadSynced = false;
      } else {
        jamLeadTrack = null;
        jamLead = Duration.zero;
      }
      notifyListeners();
      if (inJam) onJamCrossfade?.call(nextTrack, sharedRemaining);
      unawaited(_whenReady(seq, nextTrack));
      _preloadNext();
      _saveSession();
      _topUpFeed();
      if (!ownsTransition()) return;
      final started = DateTime.now();
      final swapAt = djp?.swapAt;
      var swapped = false;
      var phaseCheckedMs = 0;
      var cmdRate = djp?.rate ?? 1.0;
      var cmdOutRate = 1.0;
      var rateBusy = false;
      final sourceStart = _outClock?.now().inMicroseconds;
      // Громкость меняется ступеньками. На длинном переходе десяти шагов в секунду хватает, а короткий (стык на фразе —
      // четверть секунды, короткий crossfade — пара секунд) состоял бы из двух-трёх слышимых скачков: шаг делаем мельче
      final stepMs = lengthMs < 1500 ? 25 : (lengthMs < 4000 ? 50 : 100);
      _fadeTimer = Timer.periodic(Duration(milliseconds: stepMs), (timer) {
        if (!ownsTransition()) {
          timer.cancel();
          return;
        }
        final elapsed = DateTime.now().difference(started);
        // With a shared tempo ramp, envelopes and EQ follow consumed source
        // audio, not wall time: both planned phrase endpoints remain exact.
        final t =
            djp?.tempoRamp == true && sourceStart != null && _outClock != null
                ? (_outClock!.now().inMicroseconds - sourceStart) /
                    (lengthMs * 1000)
                : elapsed.inMilliseconds / lengthMs;
        if (t >= 1) {
          _endFade(reason: 'completed');
          return;
        }
        // Подстройка скоростью: раз в 200 мс смотрим, не уехали ли доли, и чуть ускоряем или замедляем следующий трек
        if (djp != null && elapsed.inMilliseconds - phaseCheckedMs >= 200) {
          phaseCheckedMs = elapsed.inMilliseconds;
          final oc = _outClock, ic = _inClock;
          final e = oc == null || ic == null ? null : _phaseErr(djp, oc.now(), ic.now());
          if (e != null || djp.tempoRamp) {
            final rates =
                djp.tempoRamp ? djTempoAt(t, djp.rate) : (1.0, djp.rate);
            final correction = e == null || e.abs() < 10
                ? 1.0
                : 1 + (-e / 1500).clamp(-0.02, 0.02);
            final want = rates.$2 * correction;
            if (e != null) _transitionProbe?.phase(e);
            if (!rateBusy &&
                ((want - cmdRate).abs() > 0.0005 ||
                    (rates.$1 - cmdOutRate).abs() > 0.0005)) {
              cmdRate = want;
              cmdOutRate = rates.$1;
              _pendingRate = want;
              _inClock?.speed = want;
              _outClock?.speed = rates.$1;
              rateBusy = true;
              unawaited(() async {
                await Future.wait(
                    [_setRate(incoming, want), _setRate(old, rates.$1)]);
                rateBusy = false;
              }());
            }
          }
        }
        // Обмен басов: низы переходят от уходящего к следующему на сильной доле посередине перехода
        if (swapAt != null &&
            !swapped &&
            t * lengthMs >= swapAt.inMilliseconds) {
          swapped = true;
          _transitionProbe?.bassSwapMs = elapsed.inMilliseconds;
          AppLog.info('DJ execution: bass swap at ${elapsed.inMilliseconds} ms');
          if (!eqBlend) { unawaited(_setLowCut(incoming, false)); unawaited(_setLowCut(old, true)); }
        }
        if (eqBlend && swapAt != null) {
          final eq = djEqAt(t, swapAt.inMilliseconds / lengthMs);
          _eq[old]?.update(eq.$1); _eq[incoming]?.update(eq.$2);
        }
        final g = dj ? phraseBlendGains(t) : fadeGains(t);
        _outGain = dj ? amplitudeToMpvVolume(g.$1) : g.$1;
        // DJ envelopes are amplitudes; convert to the cubic mpv slider once.
        final inAmplitude = g.$2 * (match + (1 - match) * t);
        _inGain = dj ? math.pow(math.max(0.0, inAmplitude), 1 / 3).toDouble() : inAmplitude;
        final reserve = math.pow(plan?.headroom ?? 1, 1/3).toDouble();
        _outGain *= reserve;
        _inGain *= reserve;
        _applyVolume();
      });
    } catch (e) {
      AppLog.warn('Плавный переход не получился, трек доиграет как обычно', e);
      _traceDj({'kind': 'executionAbort', 'from': fromId, 'to': nextTrack.id,
        'cause': e.runtimeType.toString(), 'cancelled': !ownsTransition(), 'hadHandoff': _transitionProbe != null});
      if (ownsTransition()) {
        _endFade(stopIncoming: true);
        if (plan?.dj == true && playing) {
          AppLog.info('DJ-переход: пробую обычный crossfade без синхронизации');
          await _startCrossfade();
        } else {
          lib.messages.add('Переход отменён: следующая дека не готова. Текущий трек продолжает играть; подробности в журнале.');
        }
      }
    } finally {
      if (!handedOff && !ownsTransition()) await release();
    }
  }

  Timer? _tailTimer;

  /// До какой доли трека дошла полоса перед концом: в конце плеер может сбросить позицию, а полоса не должна прыгать
  double _lastFrac = 0;

  /// Следующая смена трека — оттого, что прошлый доиграл до конца
  bool _autoEnd = false;

  /// Запускает хвост полосы осветления и убирает его, когда он растворится
  void _startTail(CrossfadeInfo info) {
    _tailTimer?.cancel();
    fadeInfo.value = info;
    _tailTimer = Timer(Duration(milliseconds: info.totalMs + 80), () {
      _tailTimer = null;
      fadeInfo.value = null;
    });
  }

  /// Завершает переход: уходящий трек останавливается, у нового обычная громкость
  // ---------- темп и басы в диджейском переходе ----------

  /// Темп или фильтр басов у какого-то проигрывателя менялся: после перехода их нужно вернуть
  bool _fxDirty = false;
  double _pendingRate = 1.0;
  Timer? _rateTimer;
  final Set<Player> _cut = {};
  final Map<Player, int> _pitch = {};
  final Set<Player> _effectDecks = {};
  Future<void> _clearDjEffect(Player p) async {
    if (!_effectDecks.remove(p)) return;
    try { await (p.platform as dynamic).command(['af', 'remove', '@cave-dj-effect']); }
    catch (e) { AppLog.warn('DJ: сброс эффекта', e); }
  }
  Future<void> _applyPitch(Player p, int semitones) async {
    if (semitones.abs() > 1) throw ArgumentError.value(semitones, 'semitones');
    const label = 'cave-dj-pitch';
    final native = p.platform as dynamic;
    if ((_pitch[p] ?? 0) == semitones) return;
    try {
      if (_pitch.containsKey(p))
        await native.command(['af', 'remove', '@$label']);
      _pitch.remove(p);
      if (semitones != 0) {
        _fxDirty = true;
        await native.command([
          'af',
          'add',
          '@$label:lavfi=[${pitchFilter(semitones)}]'
        ]);
        final filters = '${await native.getProperty('af')}';
        if (!filters.contains(label))
          throw StateError('Pitch filter unavailable');
        _pitch[p] = semitones;
      }
    } catch (_) {
      try {
        await native.command(['af', 'remove', '@$label']);
      } catch (_) {}
      _pitch.remove(p);
      _traceDj(
          {'kind': 'capability', 'effect': 'pitchShift', 'supported': false});
      rethrow;
    }
  }

  final Map<Player, DjEqDriver> _eq = {};
  final Map<Player, StreamSubscription<dynamic>> _eqLogs = {};
  int _eqSequence = 0;
  Future<bool> _installEq(Player p, DjEq initial) async {
    await _clearEq(p);
    final label = 'cave-dj-eq-${++_eqSequence}';
    final driver = DjEqDriver(label, (args) async { await (p.platform as dynamic).command(args); }, () {
      _traceDj({'kind': 'capability', 'effect': 'threeBandEq', 'supported': false});
    });
    _eq[p] = driver;
    // Native command() reports errors on its log stream, rather than throwing.
    _eqLogs[p] = p.stream.log.listen((log) {
      if ((log.level == 'error' || log.level == 'fatal') &&
          (log.text.contains(label) || log.prefix.startsWith('af') || log.text.contains('af-command'))) driver.fail();
    });
    if (!await driver.install(initial)) { await _clearEq(p); return false; }
    try {
      final filters = await (p.platform as dynamic).getProperty('af');
      if (!'$filters'.contains(label)) { await _clearEq(p); return false; }
    } catch (_) { await _clearEq(p); return false; }
    _traceDj({'kind': 'capability', 'effect': 'threeBandEq', 'installed': true, 'verification': 'filter_presence_not_output_pcm'});
    return driver.active;
  }
  Future<void> _clearEq(Player p) async {
    final driver = _eq.remove(p); await _eqLogs.remove(p)?.cancel(); await driver?.close();
  }

  _PosClock? _outClock;
  _PosClock? _inClock;

  void _stopClocks() {
    _outClock?.dispose();
    _inClock?.dispose();
    _outClock = null;
    _inClock = null;
  }

  /// Насколько следующий трек «впереди» доли уходящего, мс (— отстаёт); нужен период, на который доли совпадают.
  /// Время доли отсчитывается от сетки: у каждого трека время с последней доли, пересчитанное в часы уходящего
  double? _phaseErr(MixPlan plan, Duration pOut, Duration pIn) {
    final g = plan.grid;
    if (g == null || plan.rate <= 0) return null;
    final outBeat = g.$2;
    final inBeat = g.$4 / plan.rate; // доля следующего в часах уходящего
    final per = math.min(outBeat, inBeat);
    final tOut = (pOut.inMicroseconds / 1000 - g.$1) % outBeat;
    final tIn = ((pIn.inMicroseconds / 1000 - g.$3) % g.$4) / plan.rate;
    var d = (tIn - tOut + plan.offsetMs) % per;
    if (d > per / 2) d -= per;
    return d;
  }

  /// Скорость проигрывателя; высота звука не меняется (mpv сам подтягивает её обратно)
  Future<void> _setRate(Player p, double r) async {
    try {
      await p.setRate(r);
    } catch (e) {
      AppLog.warn('Переход: не удалось изменить темп', e);
    }
  }

  /// Срезает низкие частоты (фильтр высоких) у проигрывателя или возвращает как было. Если сборка mpv без фильтров — молча пропускаем
  Future<void> _setLowCut(Player p, bool on, {bool force = false}) async {
    if (!force && on == _cut.contains(p)) return;
    try {
      const label = 'cave-dj-lowcut'; final native = p.platform as dynamic;
      var filters = '${await native.getProperty('af')}';
      if (on && !filters.contains(label)) { await native.command(['af', 'add', '@$label:lavfi=[highpass=f=220]']); }
      else if (!on && filters.contains(label)) { await native.command(['af', 'remove', '@$label']); }
      filters = '${await native.getProperty('af')}';
      if (on != filters.contains(label)) throw StateError('Bass filter not installed');
      if (on) {
        _cut.add(p);
      } else {
        _cut.remove(p);
      }
      AppLog.info('DJ execution: bass filter ${on ? 'on' : 'off'} applied');
    } catch (e) {
      // Never record an unsupported filter as successfully enabled.
      AppLog.warn('Переход: не удалось поменять фильтр басов', e);
      _traceDj({'kind': 'capability', 'effect': 'bassFilter', 'requested': on, 'supported': false});
    }
  }

  /// За несколько секунд возвращает темп играющего трека от [from] к родному
  void _rampRate(double from) {
    _rateTimer?.cancel();
    final p = _p;
    if ((from - 1).abs() < 0.002) {
      unawaited(_setRate(p, 1.0));
      return;
    }
    final started = DateTime.now();
    const rampMs = 8000;
    _rateTimer = Timer.periodic(const Duration(milliseconds: 250), (timer) {
      if (!identical(_p, p)) {
        timer.cancel();
        return;
      }
      final x = DateTime.now().difference(started).inMilliseconds / rampMs;
      if (x >= 1) {
        timer.cancel();
        _rateTimer = null;
        unawaited(_setRate(p, 1.0));
        return;
      }
      unawaited(_setRate(p, from + (1 - from) * x));
    });
  }

  void _endFade({bool stopIncoming = false, String reason = 'interrupted'}) {
    final probe = _transitionProbe;
    _transitionProbe = null;
    if (probe != null) {
      lastDjExecution = probe.finish(stopIncoming ? 'error' : reason);
      _traceDj(lastDjExecution!);
      AppLog.info('DJ result: ${jsonEncode(lastDjExecution)}');
    }
    _fadeGeneration++;
    _previewOverride = null;
    _stopClocks();
    _fadeTimer?.cancel();
    _fadeTimer = null;
    _preparedId = null;
    final wasFading = _fading;
    _fading = false;
    final old = _outgoing;
    for (final deck in _effectDecks.toList()) { unawaited(_clearDjEffect(deck)); }
    _outgoing = null;
    final recoverFrom = reason == 'completed' ? _inGain.clamp(0.0, 1.0).toDouble() : 1.0;
    _headroomRecovery?.cancel();
    _inGain = recoverFrom;
    if (recoverFrom < 0.999) {
      var step = 0;
      _headroomRecovery = Timer.periodic(const Duration(milliseconds: 100), (timer) {
        if (_fading) { timer.cancel(); return; }
        _inGain = recoverFrom + (1-recoverFrom) * (++step / 10).clamp(0.0, 1.0);
        _applyVolume();
        if (step >= 10) timer.cancel();
      });
    }
    _outGain = 1;
    if (old != null) {
      unawaited(_applyPitch(old, 0).catchError((Object e) {
        AppLog.warn('DJ: сброс тональности', e);
      }));
      unawaited(_clearEq(old));
      unawaited(old.stop());
      if (_fxDirty) {
        unawaited(_setRate(old, 1.0));
        unawaited(_setLowCut(old, false));
      }
    }
    if (_fxDirty) {
      unawaited(_clearEq(_p));
      if (_q != null) unawaited(_clearEq(_q!));
      unawaited(_setLowCut(_p, false));
      // Следующий трек играл с подогнанным темпом: возвращаем его к родному плавно, а не рывком
      if (stopIncoming) {
        unawaited(_setRate(_p, 1.0));
      } else {
        _rampRate(_pendingRate);
      }
    }
    _pendingRate = 1.0;
    _normOut = 1;
    if (wasFading || old != null) _applyVolume();
    // Переход отменён до передачи звука новой деке (пауза, перемотка, выбран другой трек): она уже открыта и играет
    // без звука. Останавливаем её всегда — иначе неслышный трек доигрывал до конца, занимая процессор и сеть
    if ((stopIncoming || wasFading) && old == null) {
      final q = _q;
      if (q != null) {
        unawaited(_applyPitch(q, 0).catchError((Object e) {
          AppLog.warn('DJ: сброс тональности', e);
        }));
        if (_fxDirty) {
          unawaited(_setRate(q, 1.0));
          unawaited(_setLowCut(q, false));
        }
        unawaited(q.stop());
      }
    }
  }

  // ---------- воспроизведение ----------

  /// После замены аудио под тем же ID не используем старые байты прокси.
  void invalidateStream(String id) => _proxy.invalidate(id);

  /// Что открывать в проигрывателе: сохранённый трек играет с диска, остальные — потоком с Google Диска через прокси
  /// Authorized media source for the two independent live DJ decks.
  /// Reuses the existing local cache and streaming proxy.
  Future<Media> mediaForDj(Track t) => _mediaFor(t);

  Future<Media> _mediaFor(Track t) async {
    final local = cache.fileFor(t.id);
    if (cache.has(t.id) && local.existsSync()) return Media(local.path);
    try {
      final url = await _proxy.register(
        t.id,
        size: t.size,
        version: t.modified,
        token: () async => accounts.token(await lib.accessFor(t.source)),
      );
      return Media(url.toString());
    } catch (e) {
      // Прокси не запустился — по-старому, напрямую с Диска
      AppLog.warn('Прокси стриминга недоступен', e);
      final token = await accounts.token(await lib.accessFor(t.source));
      return Media(DriveApi.mediaUrl(t.id).toString(), httpHeaders: {'Authorization': 'Bearer $token'});
    }
  }

  Future<void> _open({Duration? at, bool play = true}) async {
    final t = current;
    if (t == null) return;
    final seq = ++_openSeq;
    _adaptiveKey = null;
    _adaptiveDecision = null;
    jamLeadTrack = null;
    jamLead = Duration.zero;
    // Обычная смена трека без плавного перехода: полоса старого трека растворяется
    // (дослушанный до конца — сразу, переключённый вручную — на месте)
    final natural = _autoEnd;
    _autoEnd = false;
    if (at == null && duration > Duration.zero && (natural || position.value > Duration.zero) && !_fading) {
      // Дошёл до конца сам: полоса стояла на последней показанной доле (если позицию сбросили — на краю) и плавно
      // доезжает до края, а потом растворяется. Переключили вручную — растворяется там, где была
      final f = natural
          ? (_lastFrac > 0.5 ? _lastFrac : 1.0)
          : (position.value.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0).toDouble();
      final run = natural && f < 0.995 ? 450 : 0;
      _startTail(CrossfadeInfo(f, DateTime.now(), run));
    }
    _lastFrac = 0;
    _endFade();
    _dropPrepared();
    _normTimer?.cancel();
    _normIn = _normFactorFor(t.id);
    _applyVolume();
    _prevPos = Duration.zero;
    _resumeAt = null;
    _userPaused = false;
    error = null;
    position.value = at ?? Duration.zero;
    duration = Duration.zero;
    notifyListeners();
    final started = DateTime.now();
    try {
      final fromDisk = cache.has(t.id) && cache.fileFor(t.id).existsSync();
      AppLog.info('Включаю «${t.title}» ${fromDisk ? 'с компьютера' : 'с Google Диска'}');
      final media = await _mediaFor(t);
      if (seq != _openSeq) return; // пока готовили, включили другой трек
      cache.touch(t);
      if (_fxDirty) {
        _rateTimer?.cancel();
        _rateTimer = null;
        await _setRate(_p, 1.0);
        await _setLowCut(_p, false);
      }
      await _applyPitch(_p, 0);
      await _p.open(media, play: at == null && play);
      _openedAt = DateTime.now();
      if (at != null) {
        await _p.stream.duration
            .firstWhere((d) => d > Duration.zero)
            .timeout(const Duration(seconds: 8), onTimeout: () => Duration.zero);
        await _p.seek(at);
        if (play) await _p.play();
      }
      if (play) unawaited(_ensurePlaying(seq, t, started));
      unawaited(_whenReady(seq, t));
      _preloadNext();
      _saveSession();
    } catch (e) {
      error = '$e';
      AppLog.warn('Не получилось включить «${t.title}»', e);
      lib.messages.add(cache.has(t.id)
          ? 'Не получилось включить «${t.title}»: $e'
          : 'Не получилось включить «${t.title}». Если нет интернета, играют только сохранённые треки.');
      notifyListeners();
      _skipBroken(t);
    }
  }

  /// Новый трек должен заиграть сам. Если открыть его прямо в момент окончания
  /// предыдущего, пауза от старого трека иногда приходит позже и останавливает
  /// новый — тогда включаем ещё раз. Заодно пишем в журнал, сколько ждали звука.
  Future<void> _ensurePlaying(int seq, Track t, DateTime started) async {
    var kicked = false;
    for (final wait in const [300, 700, 1500, 3000]) {
      await Future<void>.delayed(Duration(milliseconds: wait));
      if (seq != _openSeq || _userPaused) return;
      if (_p.state.playing) break;
      if (!kicked) AppLog.info('«${t.title}» встал на паузу сам — включаю');
      kicked = true;
      await _p.play();
    }
    // Время до первого звука: позиция сдвинулась с нуля
    final heard = await _p.stream.position
        .firstWhere((d) => d > const Duration(milliseconds: 50))
        .timeout(const Duration(seconds: 20), onTimeout: () => Duration.zero);
    if (seq != _openSeq) return;
    final ms = DateTime.now().difference(started).inMilliseconds;
    AppLog.info(heard == Duration.zero ? '«${t.title}»: звука нет 20 с' : '«${t.title}»: звук через $ms мс');
  }

  /// Длительность известна — сообщаем (для поиска текста)
  Future<void> _whenReady(int seq, Track t) async {
    final d = duration > Duration.zero
        ? duration
        : await _p.stream.duration
            .firstWhere((d) => d > Duration.zero)
            .timeout(const Duration(seconds: 15), onTimeout: () => Duration.zero);
    if (seq != _openSeq) return;
    if (_historySeq != seq && _p.state.playing) {
      _historySeq = seq;
      final f = adaptiveFeatures?.call(t.id), p = mixer?.profileCached(t.id);
      _djHistory.add(DjHistoryEntry(t.id, artist: t.artist.toLowerCase(), genre: p?.genre ?? '',
          technique: _transitionProbe?.to == t.id ? _transitionProbe!.technique : '',
          energyDb: f?.rmsDb ?? p?.loudDb ?? -20));
      if (_djHistory.length > 8) _djHistory.removeAt(0);
    }
    if (d > Duration.zero) _failStreak = 0; // трек открылся — серия неудач прервана
    onTrackReady?.call(t, d);
  }

  /// Джем-сессия: трек доиграл — решает джем, а не плеер. true — плеер сам ничего не переключает
  bool Function()? jamOnEnded;

  /// Джем задаёт очередь, текущий трек, паузу и позицию
  Future<void> jamSet(List<String> ids, int idx, {required bool play, required Duration at}) async {
    if (ids.isEmpty || idx < 0 || idx >= ids.length) return;
    feeder = null;
    sourcePlaylist = null;
    queue = List.of(ids);
    _origin = List.of(ids);
    userAhead = 0;
    _index = idx;
    _queueChanged();
    await _open(at: at > const Duration(milliseconds: 300) ? at : null, play: play);
  }

  /// Джем поменял только очередь, а текущий трек тот же: список обновляется, музыка играет дальше без перезапуска
  void jamSetQueueOnly(List<String> ids, int idx) {
    if (ids.isEmpty || idx < 0 || idx >= ids.length) return;
    feeder = null;
    sourcePlaylist = null;
    queue = List.of(ids);
    _origin = List.of(ids);
    userAhead = 0;
    _index = idx;
    _dropPrepared();
    _queueChanged();
  }

  void _onCompleted() {
    if (jamOnEnded?.call() ?? false) return;
    // Даём плееру закончить старый трек, иначе его пауза может догнать новый
    Future<void>.delayed(const Duration(milliseconds: 60), () {
      if (repeat == RepeatSetting.one) {
        _autoEnd = true;
        unawaited(_open());
      } else {
        unawaited(next(auto: true));
      }
    });
  }

  Future<void> next({bool auto = false}) async {
    if (queue.isEmpty) return;
    _reportHeard(skipped: !auto);
    _autoEnd = auto;
    if (index + 1 < queue.length) {
      index++;
    } else if (repeat == RepeatSetting.all) {
      index = 0;
    } else {
      _autoEnd = false;
      if (!auto && _resumeAt == null) await _p.seek(duration);
      return;
    }
    await _open();
    _topUpFeed();
  }

  Future<void> previous() async {
    if (position.value > const Duration(seconds: 3) || index <= 0) {
      await seek(Duration.zero);
      return;
    }
    index--;
    await _open();
  }

  Future<void> jumpTo(int queueIndex) async {
    if (queueIndex < 0 || queueIndex >= queue.length) return;
    final target = queue[queueIndex];
    if (queueIndex > index) _reportHeard(skipped: true);
    final at = queue.indexOf(target); // волна могла убрать треки перед ним
    index = at >= 0 ? at : queueIndex.clamp(0, queue.length - 1);
    await _open();
    _topUpFeed();
  }

  Future<void> toggle() async {
    if (current == null) return;
    // Восстановленный после перезапуска трек ещё не открыт
    final resume = _resumeAt;
    if (resume != null) {
      await _open(at: resume > Duration.zero ? resume : null);
      onUserAction?.call();
      return;
    }
    // Токен живёт час: после долгой паузы переоткрываем трек с того же места
    final opened = _openedAt;
    if (!playing && opened != null && DateTime.now().difference(opened) > const Duration(minutes: 50)) {
      await _open(at: position.value);
      return;
    }
    _endFade(stopIncoming: _fading && _outgoing == null, reason: 'pause');
    if (playing) _userPaused = true;
    await _p.playOrPause();
    onUserAction?.call();
  }

  Future<void> seek(Duration d) async {
    if (_fading) _endFade(stopIncoming: _outgoing == null, reason: 'seek');
    _adaptiveKey = null;
    _adaptiveDecision = null;
    _dropPrepared();
    if (_resumeAt != null) {
      _resumeAt = d;
      position.value = d;
      _saveSession();
      return;
    }
    await _p.seek(d);
    onUserAction?.call();
  }

  /// Перемотка на [delta] от текущего места (стрелки ← →)
  Future<void> seekBy(Duration delta) async {
    if (current == null) return;
    var to = position.value + delta;
    if (to < Duration.zero) to = Duration.zero;
    if (duration > Duration.zero && to > duration) to = duration - const Duration(milliseconds: 500);
    await seek(to);
  }

  Future<void> pause() {
    _endFade();
    _userPaused = true;
    return _p.pause();
  }
  Future<void> play() {
    _endFade();
    return _p.play();
  }

  /// Перемотка или пауза пользователем — чтобы друзья, слушающие вместе, сразу это увидели
  void Function()? onUserAction;

  /// Время, когда трек был открыт (для подсчёта прослушиваний)
  DateTime? get openedAt => _openedAt;

  // ---------- звук ----------

  Future<void> setVolume(double v, {bool save = false}) async {
    v = v.clamp(0.0, 100.0).toDouble();
    settings.volume = v;
    _applyVolume();
    notifyListeners();
    if (save) await lib.saveSettings();
  }

  Future<void> toggleMute() async {
    if (volume > 0) {
      _volumeBeforeMute = volume;
      await setVolume(0, save: true);
    } else {
      await setVolume(_volumeBeforeMute > 0 ? _volumeBeforeMute : 80, save: true);
    }
  }

  // ---------- режимы ----------

  void toggleShuffle() {
    shuffle = !shuffle;
    final cur = current?.id;
    if (cur != null) {
      if (shuffle) {
        final rest = List.of(queue)
          ..removeAt(index)
          ..shuffle();
        queue = [cur, ...rest];
        index = 0;
      } else {
        queue = List.of(_origin.isNotEmpty ? _origin : queue);
        index = queue.indexOf(cur);
        if (index < 0) {
          queue.insert(0, cur);
          index = 0;
        }
      }
      userAhead = 0; // порядок перемешан или возвращён — «своих» треков в начале очереди больше нет
    }
    notifyListeners();
    _saveSession();
    _preloadNext();
  }

  void cycleRepeat() {
    repeat = RepeatSetting.values[(repeat.index + 1) % RepeatSetting.values.length];
    notifyListeners();
    _saveSession();
  }

  @override
  void dispose() {
    _headroomRecovery?.cancel();
    if (_transitionProbe != null) {
      _traceDj(_transitionProbe!.finish('disposed'));
      _transitionProbe = null;
    }
    _openSeq++;
    _fadeGeneration++;
    _fading = false;
    _stopClocks();
    _rateTimer?.cancel();
    _normTimer?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    _saveTimer?.cancel();
    _saveDebounce?.cancel();
    _hoverTimer?.cancel();
    _fadeTimer?.cancel();
    _tailTimer?.cancel();
    for (final p in _eq.keys.toList()) { unawaited(_clearEq(p)); }
    _p.dispose();
    _q?.dispose();
    unawaited(_proxy.close());
    position.dispose();
    lyricsOpen.dispose();
    super.dispose();
  }
}

/// Позиция проигрывателя с поправкой на время с последнего отсчёта: события позиции приходят редко, а доли считаются в миллисекундах
class _PosClock {
  final Player p;
  double _speed;
  double get speed => _speed;
  set speed(double value) {
    _pos = now();
    _at = DateTime.now();
    _speed = value;
  }

  Duration _pos;
  DateTime _at = DateTime.now();
  StreamSubscription<Duration>? _sub;

  _PosClock(this.p, this._speed) : _pos = p.state.position {
    _sub = p.stream.position.listen((d) {
      _pos = d;
      _at = DateTime.now();
    });
  }

  Duration now() => _pos + Duration(microseconds: (DateTime.now().difference(_at).inMicroseconds * speed).round());

  void dispose() => _sub?.cancel();
}
