import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart' show Media, NativePlayer, Player;

import 'audio_cache.dart';
import 'auth.dart';
import 'drive.dart';
import 'library.dart';
import 'log.dart';
import 'models.dart';
import 'store.dart';
import 'stream_proxy.dart';

enum RepeatSetting { off, all, one }

/// Очередь и воспроизведение. Звук идёт потоком прямо с Google Диска:
/// плеер (libmpv) сам запрашивает нужные куски файла с токеном в заголовке.
class PlayerController extends ChangeNotifier {
  final LibraryController lib;
  final AccountManager accounts;
  final Settings settings;
  final AudioCache cache;
  final Player _p = Player();

  /// Панель с текстом песни открыта
  final ValueNotifier<bool> lyricsOpen = ValueNotifier(false);
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
  int index = -1;
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
    _subs.add(_p.stream.position.listen((d) {
      if (_resumeAt == null) position.value = d;
    }));
    _subs.add(_p.stream.duration.listen((d) {
      if (_resumeAt != null && d == Duration.zero) return;
      duration = d;
      notifyListeners();
    }));
    _subs.add(_p.stream.playing.listen((v) {
      playing = v;
      notifyListeners();
      _saveSession();
    }));
    _subs.add(_p.stream.buffering.listen((v) {
      buffering = v;
      notifyListeners();
    }));
    _subs.add(_p.stream.completed.listen((done) {
      if (done) _onCompleted();
    }));
    _subs.add(_p.stream.error.listen((e) {
      error = e;
      AppLog.warn('Плеер: ${current?.title ?? ''}', e);
      notifyListeners();
    }));
    unawaited(_p.setVolume(settings.volume));
    unawaited(_applyNormalize());
    // Пока играет, раз в 15 секунд запоминаем позицию — на случай, если окно закроют
    _saveTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (playing) _saveSession();
    });
  }

  Track? get current => (index >= 0 && index < queue.length) ? lib.data.tracks[queue[index]] : null;
  double get volume => settings.volume;
  bool get normalize => settings.normalize;
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
            'current': cur.id,
            'index': index,
            'pos': (_resumeAt ?? position.value).inMilliseconds,
            'dur': duration.inMilliseconds,
            'shuffle': shuffle,
            'repeat': repeat.name,
          };
    return lib.saveSettings();
  }

  // ---------- очередь ----------

  Future<void> playTracks(List<Track> list, int start) async {
    if (list.isEmpty) return;
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
    await _open();
  }

  void playNext(Track t) {
    if (current == null) {
      unawaited(playTracks([t], 0));
      return;
    }
    queue.insert(index + 1, t.id);
    // И в исходный порядок — иначе после выключения перемешивания трек пропадёт
    final oi = _origin.indexOf(current!.id);
    _origin.insert(oi < 0 ? _origin.length : oi + 1, t.id);
    _queueChanged();
  }

  /// В конец очереди
  void addToQueue(Track t) {
    if (current == null) {
      unawaited(playTracks([t], 0));
      return;
    }
    queue.add(t.id);
    _origin.add(t.id);
    _queueChanged();
  }

  /// Убирает трек из очереди (текущий не трогаем)
  void removeAt(int queueIndex) {
    if (queueIndex <= index || queueIndex >= queue.length) return;
    final id = queue.removeAt(queueIndex);
    if (shuffle) {
      _origin.remove(id);
    } else {
      _origin = List.of(queue);
    }
    _queueChanged();
  }

  /// Переставляет трек из следующих: индексы — позиции в [queue]
  void moveInQueue(int from, int to) {
    if (from <= index || from >= queue.length) return;
    to = to.clamp(index + 1, queue.length - 1);
    if (from == to) return;
    final id = queue.removeAt(from);
    queue.insert(to, id);
    if (!shuffle) _origin = List.of(queue);
    _queueChanged();
  }

  /// Оставляет только то, что играет сейчас
  void clearUpcoming() {
    final cur = current;
    if (cur == null) return;
    queue = [cur.id];
    _origin = [cur.id];
    index = 0;
    _queueChanged();
  }

  void _queueChanged() {
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
        .prefetch(t.id, size: t.size, token: () async => accounts.token(await lib.accessFor(t.source)))
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

  // ---------- воспроизведение ----------

  Future<void> _open({Duration? at, bool play = true}) async {
    final t = current;
    if (t == null) return;
    final seq = ++_openSeq;
    _resumeAt = null;
    _userPaused = false;
    error = null;
    position.value = at ?? Duration.zero;
    duration = Duration.zero;
    notifyListeners();
    final started = DateTime.now();
    try {
      // Сохранённый трек играет с диска, остальные — потоком с Google Диска через прокси
      final local = cache.fileFor(t.id);
      Media media;
      final fromDisk = cache.has(t.id) && local.existsSync();
      AppLog.info('Включаю «${t.title}» ${fromDisk ? 'с компьютера' : 'с Google Диска'}');
      if (fromDisk) {
        media = Media(local.path);
      } else {
        try {
          final url = await _proxy.register(
            t.id,
            size: t.size,
            token: () async => accounts.token(await lib.accessFor(t.source)),
          );
          media = Media(url.toString());
        } catch (e) {
          // Прокси не запустился — по-старому, напрямую с Диска
          AppLog.warn('Прокси стриминга недоступен', e);
          final token = await accounts.token(await lib.accessFor(t.source));
          media = Media(DriveApi.mediaUrl(t.id).toString(), httpHeaders: {'Authorization': 'Bearer $token'});
        }
      }
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
    if (index + 1 < queue.length) {
      index++;
    } else if (repeat == RepeatSetting.all) {
      index = 0;
    } else {
      if (!auto && _resumeAt == null) await _p.seek(duration);
      return;
    }
    await _open();
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
    index = queueIndex;
    await _open();
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
    _userPaused = true;
    return _p.pause();
  }
  Future<void> play() => _p.play();

  /// Перемотка или пауза пользователем — чтобы друзья, слушающие вместе, сразу это увидели
  void Function()? onUserAction;

  /// Время, когда трек был открыт (для подсчёта прослушиваний)
  DateTime? get openedAt => _openedAt;

  // ---------- звук ----------

  Future<void> setVolume(double v, {bool save = false}) async {
    v = v.clamp(0.0, 100.0).toDouble();
    settings.volume = v;
    await _p.setVolume(v);
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

  /// Выравнивание громкости: треки с разных источников звучат одинаково громко
  Future<void> setNormalize(bool on) async {
    settings.normalize = on;
    notifyListeners();
    await _applyNormalize();
    await lib.saveSettings();
  }

  Future<void> _applyNormalize() async {
    final native = _p.platform;
    if (native is! NativePlayer) return;
    try {
      // loudnorm в однопроходном режиме работает на лету; после него возвращаем обычную частоту
      await native.setProperty('af', settings.normalize ? 'lavfi=[loudnorm=I=-16:LRA=11:TP=-1.5,aresample=48000]' : '');
    } catch (e) {
      AppLog.warn('Не получилось включить выравнивание громкости', e);
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
    _p.dispose();
    unawaited(_proxy.close());
    position.dispose();
    lyricsOpen.dispose();
    super.dispose();
  }
}
