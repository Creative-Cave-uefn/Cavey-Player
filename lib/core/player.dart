import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:cave_mix/cave_mix.dart' show DeckStatus, MixParam, rankNextTracks;
import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart' show Media;

import 'audio_cache.dart';
import 'audio_deck.dart';
import 'automix.dart';
import 'auth.dart';
import 'crossfade.dart';
import 'drive.dart';
import 'library.dart';
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
  late HybridDeck _p = _newDeck();

  /// Второй проигрыватель для плавного перехода: на нём включается следующий трек, пока затихает текущий
  HybridDeck? _q;

  /// Деки проигрывателя: треки с диска играют через аудиодвижок Cavey Mix (если он включён в настройках),
  /// остальное — через mpv. Первая созданная дека — 0-я дека движка, вторая — 1-я
  int _decksMade = 0;
  HybridDeck _newDeck() {
    // ffmpeg из папки инструментов: им движок читает M4A, Opus и Ogg. Если его ещё нет — докачиваем в фоне
    // (тот же ffmpeg нужен анализатору переходов); пока качается, такие треки играют через mpv
    SharedMix.ffmpegPath ??= () {
      final tools = mixer?.tools;
      if (tools == null) return null;
      if (tools.ffmpeg.existsSync()) return tools.ffmpeg.path;
      if (useMixEngine && !_ffmpegRequested) {
        _ffmpegRequested = true;
        unawaited(tools.ensure((l) => AppLog.info(l)).catchError((Object e) => AppLog.warn('FFmpeg не скачался', e)));
      }
      return null;
    };
    return HybridDeck(_decksMade++ % 2, () => useMixEngine);
  }

  bool _ffmpegRequested = false;

  /// Играть сохранённые треки через новый аудиодвижок (тестовая настройка DJ-режима)
  bool get useMixEngine => settings.viewOf('dj.engine', '0') == '1';

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
  void _bind(HybridDeck p) {
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
  bool get smartMix => jamSmart ?? settings.viewOf('mix.smart', '1') == '1';

  /// Джем: настройки плавного перехода организатора (секунды, 0 — выключен; умный переход). null — действуют мои.
  /// Организатор задаёт переход всем: включил у себя — включается у остальных, выключил — выключается
  int? jamXfSec;
  bool? jamSmart;

  /// Длина плавного перехода сейчас: в джеме — у организатора, иначе моя настройка
  int get crossfadeSecNow => jamXfSec ?? settings.crossfadeSec;

  /// План умного перехода с текущего трека на следующий; null — профили ещё не готовы, переход обычный
  MixPlan? _smartPlan() {
    final m = mixer, cur = current, ni = _autoNextIndex();
    if (!smartMix || m == null || cur == null || ni == null) return null;
    final a = m.profile(cur.id), b = m.profile(queue[ni]);
    if (a == null || b == null) return null;
    // Профиль от другого файла (трек заменили) — не доверяем
    if (duration > Duration.zero && (a.durationMs - duration.inMilliseconds).abs() > 4000) return null;
    return MixPlan.make(a, b, maxSec: crossfadeSecNow.clamp(1, 12).toInt(), bpm: tempoOf?.call(cur));
  }

  /// Профили звука текущего и следующего трека — считаем заранее, пока трек играет
  void _prepareMix() {
    final m = mixer;
    final needMix = smartMix && crossfadeSecNow > 0;
    if (m == null || !(needMix || normalize)) return;
    final cur = current;
    if (cur != null) {
      // Ровной громкости нужна громкость текущего трека: он должен лежать в кэше, чтобы его можно было разобрать
      if (normalize && !cache.has(cur.id)) cache.enqueue(cur.id);
      m.prepare(cur.id);
    }
    final ni = _autoNextIndex();
    if (ni != null) m.prepare(queue[ni]);
    // DJ-порядок выбирает из нескольких следующих: разбираем и их (только уже сохранённые — ради этого не качаем)
    if (useMixEngine && djOrder && (shuffle || feeder != null) && index >= 0) {
      for (final id in queue.skip(index + 2).take(4)) {
        if (cache.has(id)) m.prepare(id);
      }
    }
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
  Timer? _fadeTimer;
  double _inGain = 1;
  double _outGain = 1;
  HybridDeck? _outgoing;

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
    // Идёт DJ-переход: громкости дек ведёт движок по расписанию, ползунок громкости — на мастере
    if (_dj != null) {
      SharedMix.engine?.masterVolume = (volume / 100).clamp(0.0, 1.0).toDouble();
      return;
    }
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
    if (crossfadeSecNow <= 0 || _autoNextIndex() == null) return;
    // DJ-режим: переход планирует движок (доли, фразы, техники); пока готовим — обычный переход не начинаем
    if (_djPending || _dj != null) return;
    // чуть раньше плана — порядок: какой из следующих треков лучше всего ляжет после этого
    if (useMixEngine && duration - d < const Duration(seconds: _djLeadSec + 30) && _orderedFor != current?.id) _djReorder();
    if (duration - d < const Duration(seconds: _djLeadSec) && _djTriedFor != current?.id && _djEligible()) {
      _djTriedFor = current?.id;
      unawaited(_djPrepare());
      return;
    }
    // Профили смотрим только ближе к концу трека — не на каждом тике позиции
    final plan = duration - d < const Duration(seconds: 60) ? _smartPlan() : null;
    _maybePrepare(d, plan);
    final step = d - prev;
    final due = plan != null
        ? d >= plan.start && prev < plan.start && step >= Duration.zero && step < const Duration(seconds: 2)
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
        final q = _q ??= _newDeck();
        await q.setVolume(0);
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
    final nextIndex = _autoNextIndex();
    if (nextIndex == null || _fading) return;
    final nextTrack = lib.data.tracks[queue[nextIndex]];
    if (nextTrack == null) return;
    _fading = true;
    final seq = ++_openSeq;
    final lengthWanted = plan?.length.inMilliseconds ?? crossfadeSecNow.clamp(1, 10).toInt() * 1000;
    final lengthMs0 = lengthWanted;
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
      if (seq != _openSeq || !_fading) return;
      final incoming = _q ??= _newDeck();
      final prepared = _preparedId == nextTrack.id;
      _preparedId = null;
      await incoming.setVolume(0);
      if (prepared) {
        await incoming.play();
      } else {
        final media = await _mediaFor(nextTrack);
        if (seq != _openSeq || !_fading) return; // пока готовили, человек сам что-то переключил
        await incoming.open(media, play: true);
      }
      // Пустое вступление следующего трека пропускаем
      final inStart = plan != null && plan.inStart > const Duration(milliseconds: 300) ? plan.inStart : Duration.zero;
      if (inStart > Duration.zero) await incoming.seek(inStart);
      // Уходящий трек остаётся на полной громкости, пока у следующего не пошёл звук (до 3 с),
      // и оба затихают и нарастают одновременно
      await incoming.stream.position
          .firstWhere((d) => d > inStart + const Duration(milliseconds: 40))
          .timeout(const Duration(seconds: 3), onTimeout: () => Duration.zero);
      if (seq != _openSeq || !_fading) {
        await incoming.stop();
        return;
      }
      // Уходящему осталось звучать не дольше, чем он ещё длится: переход укорачивается на время ожидания
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
      duration = _p.state.duration;
      playing = true;
      _inGain = 0;
      _outGain = 1;
      _normTimer?.cancel();
      _normOut = _normIn;
      _normIn = _normFactorFor(nextTrack.id);
      _applyVolume();
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
      final started = DateTime.now();
      // Следующий трек входит на громкости уходящего и к концу перехода выходит на свою
      double inCurve(double t) => fadeGains(t).$2 * (match + (1 - match) * t);
      // Обе деки на аудиодвижке: кривые громкости уходят в движок целиком и идут по сэмплам, с равной мощностью
      // по амплитуде. Иначе (хотя бы один трек на mpv) громкость, как раньше, пересчитывает таймер
      final engineRamp = _rampOnEngine(old, incoming, lengthMs, inCurve);
      _fadeTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
        final t = DateTime.now().difference(started).inMilliseconds / lengthMs;
        if (t >= 1) {
          _endFade();
          return;
        }
        _outGain = fadeGains(t).$1;
        _inGain = inCurve(t);
        if (!engineRamp) _applyVolume();
      });
    } catch (e) {
      AppLog.warn('Плавный переход не получился, трек доиграет как обычно', e);
      _endFade(stopIncoming: seq == _openSeq);
    }
  }

  /// Переход по часам аудиодвижка: обе кривые громкости заранее, с точностью до сэмпла. false — не на движке
  bool _rampOnEngine(HybridDeck old, HybridDeck incoming, int lengthMs, double Function(double) inCurve) {
    if (!old.onEngine || !incoming.onEngine) return false;
    final s = incoming.engineState();
    if (s == null || s.sampleRate <= 0) return false;
    final from = s.clock + s.sampleRate ~/ 50; // +20 мс: команда успеет дойти до аудиопотока
    final frames = (lengthMs * s.sampleRate / 1000).round();
    final ok = old.rampVolume(baseVolume: volume * _normOut, fromClock: from, frames: frames, f: (t) => fadeGains(t).$1) &&
        incoming.rampVolume(baseVolume: volume * _normIn, fromClock: from, frames: frames, f: inCurve);
    if (ok) AppLog.info('Переход идёт по часам аудиодвижка: ${(lengthMs / 1000).toStringAsFixed(1)} с, по сэмплам');
    return ok;
  }


  // ---------- DJ-режим: автомикс движка ----------

  /// За сколько секунд до конца трека планировать DJ-переход (самый длинный — 32 такта, около минуты)
  static const _djLeadSec = 150;

  _DjMix? _dj;
  bool _djPending = false;
  String? _djTriedFor;
  int _djPrevTech = 0;
  final math.Random _djRandom = math.Random();

  /// Стиль автомикса: smooth / balanced / energetic
  String get djStyle {
    final v = settings.viewOf('dj.style', 'balanced');
    return v == 'smooth' || v == 'energetic' ? v : 'balanced';
  }

  Map<String, dynamic>? _beatProfile(String id) => mixer?.beat?.profile(id);

  /// Порядок треков подбирается (только при «Вперемешку» или волне: порядок альбома и плейлиста не трогаем)
  bool get djOrder => settings.viewOf('dj.order', '1') == '1';

  /// Характер сета: balanced — энергия ровная, rise — нарастает, relax — спадает
  String get djIntent {
    final v = settings.viewOf('dj.intent', 'balanced');
    return v == 'rise' || v == 'relax' ? v : 'balanced';
  }

  String? _orderedFor;
  final List<String> _djPlayed = [];

  double _energyOf(Map<String, dynamic>? p) {
    final e = p?['energy'];
    if (e is! List || e.isEmpty) return 5;
    var sum = 0.0;
    for (final x in e) {
      sum += x is num ? x.toDouble() : 0;
    }
    return sum / e.length;
  }

  /// Ставит следующим тот из ближайших треков очереди, что лучше всего сводится с играющим (темп, тональность,
  /// энергия, точки сведения) и подходит характеру сета. Только разобранные и сохранённые треки; что человек
  /// поставил сам («Играть следующим», «В очередь»), не трогаем
  void _djReorder() {
    final cur = current;
    if (cur == null) return;
    _orderedFor = cur.id;
    if (_djPlayed.isEmpty || _djPlayed.last != cur.id) {
      _djPlayed.add(cur.id);
      if (_djPlayed.length > 16) _djPlayed.removeAt(0);
    }
    if (!djOrder || !(shuffle || feeder != null) || userAhead > 0 || repeat == RepeatSetting.one) return;
    if (jamActive?.call() ?? false) return;
    final pa = _beatProfile(cur.id);
    if (pa == null) return;
    final cands = <Map<String, Object?>>[];
    for (final id in queue.skip(index + 1).take(5)) {
      final p = _beatProfile(id);
      if (p == null || !cache.has(id)) continue;
      cands.add({'id': id, 'artist': lib.data.tracks[id]?.artist.toLowerCase() ?? '', 'profile': p});
    }
    if (cands.length < 2) return;
    try {
      final history = [
        for (final id in _djPlayed.skip(math.max(0, _djPlayed.length - 8)))
          {'id': id, 'artist': lib.data.tracks[id]?.artist.toLowerCase() ?? '', 'energy': _energyOf(_beatProfile(id))},
      ];
      final r = jsonDecode(rankNextTracks(jsonEncode(pa), jsonEncode(cands), jsonEncode({'intent': djIntent, 'history': history})))
          as Map<String, dynamic>;
      final best = r['best'] as String?;
      if (best == null) return;
      final at = queue.indexOf(best, index + 1);
      if (at <= index + 1) return; // и так следующий
      queue.removeAt(at);
      queue.insert(index + 1, best);
      if (!shuffle) _origin = List.of(queue);
      _queueChanged();
      String why = '';
      for (final c in (r['candidates'] as List? ?? const [])) {
        if (c is Map && c['id'] == best) why = '${c['why'] ?? ''}';
      }
      AppLog.info('DJ: следующим ставлю «${lib.data.tracks[best]?.title ?? best}» — $why');
    } catch (e) {
      AppLog.warn('DJ: порядок треков не посчитан', e);
    }
  }

  /// Можно ли сделать переход движком: обе деки на нём, оба трека разобраны, не джем
  bool _djEligible() {
    final cur = current, ni = _autoNextIndex();
    if (!useMixEngine || cur == null || ni == null || !_p.onEngine) return false;
    if (jamActive?.call() ?? false) return false;
    final nextId = queue[ni];
    if (!cache.has(nextId) || !cache.fileFor(nextId).existsSync()) return false;
    final a = _beatProfile(cur.id), b = _beatProfile(nextId);
    if (a == null || b == null) return false;
    // профиль от другого файла (трек заменили) — не доверяем
    final ms = a['durationMs'];
    if (ms is num && duration > Duration.zero && (ms - duration.inMilliseconds).abs() > 4000) return false;
    return true;
  }

  /// Громкость деки при DJ-переходе: ползунок уходит на мастер, на деке — выравнивание громкости
  double _djGain(double norm) {
    final v = (volume / 100).clamp(0.0, 1.0).toDouble();
    final both = math.pow((v * norm).clamp(0.0, 1.0), 3).toDouble();
    if (v < 0.001) return math.pow(norm.clamp(0.0, 1.0), 3).toDouble();
    return both / math.pow(v, 3);
  }

  /// Открывает следующий трек на второй деке и просит движок спланировать переход.
  /// Не вышло — следующий трек остаётся открытым, и переход будет обычным
  Future<void> _djPrepare() async {
    final ni = _autoNextIndex();
    final cur = current;
    final e = SharedMix.engine;
    if (ni == null || cur == null || e == null) return;
    final t = lib.data.tracks[queue[ni]];
    if (t == null) return;
    final seq = _openSeq;
    _djPending = true;
    _preparing = true;
    HybridDeck? q;
    var keepPrepared = false;
    try {
      q = _q ??= _newDeck();
      if (_preparedId != t.id) {
        await q.setVolume(0);
        await q.open(Media(cache.fileFor(t.id).path), play: false);
      }
      keepPrepared = true;
      if (!q.onEngine) throw StateError('следующий трек не открылся в движке');
      for (var i = 0; i < 200 && !q.engineReady(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        if (seq != _openSeq || !_djPending) return;
      }
      if (!q.engineReady()) throw StateError('следующий трек не загрузился вовремя');
      if (seq != _openSeq || !_djPending || !playing) return;
      final pa = _beatProfile(cur.id), pb = _beatProfile(t.id);
      if (pa == null || pb == null) throw StateError('нет профиля трека');
      final gA = _djGain(_normIn), gB = _djGain(_normFactorFor(t.id));
      final options = jsonEncode({
        'style': djStyle,
        'maxBars': 32,
        'gainA': gA,
        'gainB': gB,
        'seed': _djRandom.nextInt(1 << 30),
        'prev': _djPrevTech,
      });
      final plan = jsonDecode(e.automix(_p.engineDeck, q.engineDeck, jsonEncode(pa), jsonEncode(pb), options)) as Map<String, dynamic>;
      // Громкость: ползунок — на мастер, уходящей деке — её доля (в ту же команду, без скачка)
      e.masterVolume = (volume / 100).clamp(0.0, 1.0).toDouble();
      e.set(_p.engineDeck, MixParam.gain, gA);
      q.armScheduledPlay();
      final st = e.state();
      final dj = _DjMix(
        from: _p,
        to: q,
        nextIndex: ni,
        track: t,
        startClock: (plan['startClock'] as num).toInt(),
        endClock: (plan['endClock'] as num).toInt(),
        sampleRate: st.sampleRate,
        technique: plan['technique'] as String? ?? '',
      );
      _dj = dj;
      _fading = true;
      _preparedId = null;
      keepPrepared = false;
      _djPrevTech = int.tryParse(dj.technique.replaceFirst('T', '')) ?? 0;
      final inSec = ((dj.startClock - st.clock) / st.sampleRate).toStringAsFixed(1);
      AppLog.info('DJ-переход на «${t.title}»: ${plan['name']}, ${plan['bars']} тактов, через $inSec с, '
          'темп ×${(plan['tempoRatio'] as num).toStringAsFixed(3)}; ${plan['reason']}');
      dj.timer = Timer.periodic(const Duration(milliseconds: 30), (_) => _djTick());
    } catch (err) {
      AppLog.warn('DJ-переход не получился, будет обычный', err);
      if (keepPrepared && seq == _openSeq) _preparedId = t.id;
    } finally {
      _preparing = false;
      _djPending = false;
    }
  }

  void _djTick() {
    final dj = _dj;
    final e = SharedMix.engine;
    if (dj == null || e == null) return;
    final s = e.state();
    final d = s.decks[dj.to.engineDeck];
    if (d.status == DeckStatus.error) {
      AppLog.warn('DJ-переход: следующий трек не играет', e.lastError);
      _djCancel();
      return;
    }
    if (!dj.swapped && s.clock >= dj.startClock) _djSwap(dj);
    if (dj.swapped && s.clock >= dj.endClock + dj.sampleRate ~/ 10) _djFinish(dj);
  }

  /// Начало перехода: следующий трек становится текущим, прежний доигрывает по расписанию
  void _djSwap(_DjMix dj) {
    dj.swapped = true;
    ++_openSeq;
    final seq = _openSeq;
    final lengthMs = math.max(300, ((dj.endClock - dj.startClock) * 1000 / dj.sampleRate).round());
    final oldFraction =
        duration > Duration.zero ? (_p.state.position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0).toDouble() : 1.0;
    final oldDurationMs = duration.inMilliseconds;
    final old = _p;
    _p = dj.to;
    _q = old;
    _outgoing = old;
    _bind(_p);
    _reportHeard(skipped: false);
    index = dj.nextIndex;
    cache.touch(dj.track);
    error = null;
    _userPaused = false;
    _prevPos = Duration.zero;
    _openedAt = DateTime.now();
    position.value = _p.state.position;
    duration = _p.state.duration;
    playing = true;
    _normTimer?.cancel();
    _normOut = _normIn;
    _normIn = _normFactorFor(dj.track.id);
    jamLeadTrack = null;
    jamLead = Duration.zero;
    _startTail(CrossfadeInfo(oldFraction, DateTime.now(), lengthMs, oldDurationMs: oldDurationMs));
    notifyListeners();
    unawaited(_whenReady(seq, dj.track));
    _preloadNext();
    _saveSession();
    _topUpFeed();
  }

  /// Конец перехода: прежняя дека выгружается, громкость — снова обычная
  void _djFinish(_DjMix dj) {
    dj.timer?.cancel();
    _dj = null;
    _fading = false;
    final old = _outgoing;
    _outgoing = null;
    if (old != null && old != _p) unawaited(old.stop());
    _normOut = 1;
    _inGain = 1;
    _outGain = 1;
    SharedMix.engine?.masterVolume = 1.0;
    _applyVolume();
  }

  /// Отменить DJ-переход (пауза, перемотка, переключение): расписание снимается, играет то, что сейчас текущее.
  /// [retry] — после перемотки переход можно спланировать заново
  void _djCancel({bool retry = false}) {
    final dj = _dj;
    final wasPending = _djPending;
    _djPending = false;
    if (dj == null) {
      // ещё готовили следующий трек: он не нужен (подготовка сама увидит отмену и выйдет)
      if (wasPending) {
        _preparedId = null;
        unawaited(_q?.stop() ?? Future<void>.value());
      }
      if (retry) _djTriedFor = null;
      return;
    }
    dj.timer?.cancel();
    _dj = null;
    _fading = false;
    SharedMix.engine?.automixCancel(dj.from.engineDeck, dj.to.engineDeck, 0, 0);
    if (dj.swapped) {
      final old = _outgoing;
      _outgoing = null;
      if (old != null && old != _p) unawaited(old.stop());
    } else {
      unawaited(dj.to.stop());
      if (retry) _djTriedFor = null;
    }
    _preparedId = null;
    _normOut = 1;
    _inGain = 1;
    _outGain = 1;
    SharedMix.engine?.masterVolume = 1.0;
    _applyVolume();
    AppLog.info('DJ-переход отменён');
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
  void _endFade({bool stopIncoming = false}) {
    if (_dj != null || _djPending) {
      _djCancel();
      return;
    }
    _fadeTimer?.cancel();
    _fadeTimer = null;
    _preparedId = null;
    final wasFading = _fading;
    _fading = false;
    final old = _outgoing;
    _outgoing = null;
    _inGain = 1;
    _outGain = 1;
    if (old != null) unawaited(old.stop());
    _normOut = 1;
    if (wasFading || old != null) unawaited(_p.setVolume(_scaled(volume * _normIn)));
    if (stopIncoming && old == null) unawaited(_q?.stop() ?? Future<void>.value());
  }

  // ---------- воспроизведение ----------

  /// После замены аудио под тем же ID не используем старые байты прокси.
  void invalidateStream(String id) => _proxy.invalidate(id);

  /// Что открывать в проигрывателе: сохранённый трек играет с диска, остальные — потоком с Google Диска через прокси
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
    _endFade();
    if (playing) _userPaused = true;
    await _p.playOrPause();
    onUserAction?.call();
  }

  Future<void> seek(Duration d) async {
    if (_resumeAt != null) {
      _resumeAt = d;
      position.value = d;
      _saveSession();
      return;
    }
    // Перемотка ломает расписание DJ-перехода (оно привязано к позиции трека): снимаем, после перемотки спланируем заново
    if (_dj != null || _djPending) _djCancel(retry: true);
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
    for (final s in _subs) {
      s.cancel();
    }
    _saveTimer?.cancel();
    _saveDebounce?.cancel();
    _hoverTimer?.cancel();
    _fadeTimer?.cancel();
    _tailTimer?.cancel();
    unawaited(_p.dispose());
    unawaited(_q?.dispose() ?? Future<void>.value());
    unawaited(_proxy.close());
    position.dispose();
    lyricsOpen.dispose();
    super.dispose();
  }
}

/// Запланированный движком DJ-переход
class _DjMix {
  _DjMix({
    required this.from,
    required this.to,
    required this.nextIndex,
    required this.track,
    required this.startClock,
    required this.endClock,
    required this.sampleRate,
    required this.technique,
  });

  final HybridDeck from, to;
  final int nextIndex;
  final Track track;
  final int startClock, endClock, sampleRate;
  final String technique;
  bool swapped = false;
  Timer? timer;
}
