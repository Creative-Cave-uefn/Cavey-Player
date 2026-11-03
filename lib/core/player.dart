import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart' show Media, NativePlayer, Player;

import 'audio_cache.dart';
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
    _bind(_p);
    unawaited(_p.setVolume(settings.volume));
    // Пока играет, раз в 15 секунд запоминаем позицию — на случай, если окно закроют
    _saveTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (playing) _saveSession();
    });
  }

  /// Подписывается на события проигрывателя [p] (и отписывается от прежнего)
  void _bind(Player p) {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    _subs.add(p.stream.position.listen((d) {
      if (_resumeAt == null) position.value = d;
      _maybeCrossfade(d);
    }));
    _subs.add(p.stream.duration.listen((d) {
      if (_resumeAt != null && d == Duration.zero) return;
      duration = d;
      notifyListeners();
    }));
    _subs.add(p.stream.playing.listen((v) {
      playing = v;
      notifyListeners();
      _saveSession();
    }));
    _subs.add(p.stream.buffering.listen((v) {
      buffering = v;
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

  Future<void> playTracks(List<Track> list, int start, {String? playlistId}) async {
    if (list.isEmpty) return;
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
  bool Function()? crossfadeBlocked;

  /// Умный переход: профили звука треков и темп трека (если известен)
  MixAnalyzer? mixer;
  double? Function(Track t)? tempoOf;
  bool get smartMix => settings.viewOf('mix.smart', '1') == '1';

  /// План умного перехода с текущего трека на следующий; null — профили ещё не готовы, переход обычный
  MixPlan? _smartPlan() {
    final m = mixer, cur = current, ni = _autoNextIndex();
    if (!smartMix || m == null || cur == null || ni == null) return null;
    final a = m.profile(cur.id), b = m.profile(queue[ni]);
    if (a == null || b == null) return null;
    // Профиль от другого файла (трек заменили) — не доверяем
    if (duration > Duration.zero && (a.durationMs - duration.inMilliseconds).abs() > 4000) return null;
    return MixPlan.make(a, b, maxSec: settings.crossfadeSec.clamp(1, 12).toInt(), bpm: tempoOf?.call(cur));
  }

  /// Профили звука текущего и следующего трека — считаем заранее, пока трек играет
  void _prepareMix() {
    final m = mixer;
    if (m == null || !smartMix || settings.crossfadeSec <= 0) return;
    final cur = current;
    if (cur != null) m.prepare(cur.id);
    final ni = _autoNextIndex();
    if (ni != null) m.prepare(queue[ni]);
  }

  Duration _prevPos = Duration.zero;
  bool _fading = false;
  Timer? _fadeTimer;
  double _inGain = 1;
  double _outGain = 1;
  Player? _outgoing;

  /// Громкость обоих проигрывателей с учётом перехода
  void _applyVolume() {
    unawaited(_p.setVolume(volume * _inGain));
    final o = _outgoing;
    if (o != null) unawaited(o.setVolume(volume * _outGain));
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
    if (crossfadeBlocked?.call() ?? false) return;
    if (settings.crossfadeSec <= 0 || _autoNextIndex() == null) return;
    // Профили смотрим только ближе к концу трека — не на каждом тике позиции
    final plan = duration - d < const Duration(seconds: 60) ? _smartPlan() : null;
    final step = d - prev;
    final due = plan != null
        ? d >= plan.start && prev < plan.start && step >= Duration.zero && step < const Duration(seconds: 2)
        : crossfadeDue(seconds: settings.crossfadeSec, duration: duration, position: d, previous: prev);
    if (!due) return;
    unawaited(_startCrossfade(plan));
  }

  Future<void> _startCrossfade([MixPlan? plan]) async {
    final nextIndex = _autoNextIndex();
    if (nextIndex == null || _fading) return;
    final nextTrack = lib.data.tracks[queue[nextIndex]];
    if (nextTrack == null) return;
    _fading = true;
    final seq = ++_openSeq;
    final lengthMs = plan?.length.inMilliseconds ?? settings.crossfadeSec.clamp(1, 10).toInt() * 1000;
    final match = plan?.inGain ?? 1.0;
    try {
      AppLog.info(plan == null
          ? 'Плавный переход на «${nextTrack.title}» (${lengthMs ~/ 1000} с)'
          : 'Умный переход на «${nextTrack.title}»: с ${plan.start.inMilliseconds / 1000} с, ${(lengthMs / 1000).toStringAsFixed(1)} с, '
              'следующий с ${plan.inStart.inMilliseconds / 1000} с, громкость ×${match.toStringAsFixed(2)}');
      final media = await _mediaFor(nextTrack);
      if (seq != _openSeq || !_fading) return; // пока готовили, человек сам что-то переключил
      final incoming = _q ??= Player();
      await incoming.setVolume(0);
      await incoming.open(media, play: true);
      // Пустое вступление следующего трека пропускаем
      if (plan != null && plan.inStart > const Duration(milliseconds: 300)) await incoming.seek(plan.inStart);
      if (seq != _openSeq || !_fading) {
        await incoming.stop();
        return;
      }
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
      position.value = Duration.zero;
      duration = Duration.zero;
      playing = true;
      _inGain = 0;
      _outGain = 1;
      _applyVolume();
      notifyListeners();
      unawaited(_whenReady(seq, nextTrack));
      _preloadNext();
      _saveSession();
      _topUpFeed();
      final started = DateTime.now();
      _fadeTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
        final t = DateTime.now().difference(started).inMilliseconds / lengthMs;
        if (t >= 1) {
          _endFade();
          return;
        }
        final g = fadeGains(t);
        _outGain = g.$1;
        // Следующий трек входит на громкости уходящего и к концу перехода выходит на свою
        _inGain = g.$2 * (match + (1 - match) * t);
        _applyVolume();
      });
    } catch (e) {
      AppLog.warn('Плавный переход не получился, трек доиграет как обычно', e);
      _endFade(stopIncoming: seq == _openSeq);
    }
  }

  /// Завершает переход: уходящий трек останавливается, у нового обычная громкость
  void _endFade({bool stopIncoming = false}) {
    _fadeTimer?.cancel();
    _fadeTimer = null;
    final wasFading = _fading;
    _fading = false;
    final old = _outgoing;
    _outgoing = null;
    _inGain = 1;
    _outGain = 1;
    if (old != null) unawaited(old.stop());
    if (wasFading || old != null) unawaited(_p.setVolume(volume));
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
    _endFade();
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

  void _onCompleted() {
    // Даём плееру закончить старый трек, иначе его пауза может догнать новый
    Future<void>.delayed(const Duration(milliseconds: 60), () {
      if (repeat == RepeatSetting.one) {
        unawaited(_open());
      } else {
        unawaited(next(auto: true));
      }
    });
  }

  Future<void> next({bool auto = false}) async {
    if (queue.isEmpty) return;
    _reportHeard(skipped: !auto);
    if (index + 1 < queue.length) {
      index++;
    } else if (repeat == RepeatSetting.all) {
      index = 0;
    } else {
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
    _p.dispose();
    _q?.dispose();
    unawaited(_proxy.close());
    position.dispose();
    lyricsOpen.dispose();
    super.dispose();
  }
}
