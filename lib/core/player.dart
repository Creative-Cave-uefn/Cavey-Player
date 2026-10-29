import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';

import 'auth.dart';
import 'drive.dart';
import 'library.dart';
import 'models.dart';
import 'store.dart';

enum RepeatMode { off, all, one }

/// Очередь и воспроизведение. Звук идёт потоком прямо с Google Диска:
/// плеер (libmpv) сам запрашивает нужные куски файла с токеном в заголовке.
class PlayerController extends ChangeNotifier {
  final LibraryController lib;
  final AccountManager accounts;
  final Settings settings;
  final Player _p = Player();
  final List<StreamSubscription<dynamic>> _subs = [];

  /// Позиция меняется часто, поэтому отдельно — чтобы не перерисовывать всё окно
  final ValueNotifier<Duration> position = ValueNotifier(Duration.zero);
  Duration duration = Duration.zero;
  bool playing = false;
  bool buffering = false;
  bool shuffle = false;
  RepeatMode repeat = RepeatMode.off;
  String? error;

  List<String> _origin = [];
  List<String> queue = [];
  int index = -1;
  DateTime? _openedAt;

  PlayerController(this.lib, this.accounts, this.settings) {
    _subs.add(_p.stream.position.listen((d) => position.value = d));
    _subs.add(_p.stream.duration.listen((d) {
      duration = d;
      notifyListeners();
    }));
    _subs.add(_p.stream.playing.listen((v) {
      playing = v;
      notifyListeners();
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
      notifyListeners();
    }));
    unawaited(_p.setVolume(settings.volume));
  }

  Track? get current => (index >= 0 && index < queue.length) ? lib.data.tracks[queue[index]] : null;
  double get volume => settings.volume;
  List<Track> get upcoming => [
        for (final id in queue.skip(index + 1))
          if (lib.data.tracks[id] != null) lib.data.tracks[id]!
      ];

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
    notifyListeners();
  }

  Future<void> _open({Duration? at, bool play = true}) async {
    final t = current;
    if (t == null) return;
    error = null;
    position.value = Duration.zero;
    duration = Duration.zero;
    notifyListeners();
    try {
      final email = await lib.accessFor(t.source);
      final token = await accounts.token(email);
      await _p.open(
        Media(DriveApi.mediaUrl(t.id).toString(), httpHeaders: {'Authorization': 'Bearer $token'}),
        play: at == null && play,
      );
      _openedAt = DateTime.now();
      if (at != null) {
        await _p.stream.duration
            .firstWhere((d) => d > Duration.zero)
            .timeout(const Duration(seconds: 8), onTimeout: () => Duration.zero);
        await _p.seek(at);
        if (play) await _p.play();
      }
    } catch (e) {
      error = '$e';
      lib.messages.add('Не получилось включить «${t.title}»: $e');
      notifyListeners();
    }
  }

  void _onCompleted() {
    if (repeat == RepeatMode.one) {
      unawaited(_open());
    } else {
      unawaited(next(auto: true));
    }
  }

  Future<void> next({bool auto = false}) async {
    if (queue.isEmpty) return;
    if (index + 1 < queue.length) {
      index++;
    } else if (repeat == RepeatMode.all) {
      index = 0;
    } else {
      if (!auto) await _p.seek(duration);
      return;
    }
    await _open();
  }

  Future<void> previous() async {
    if (position.value > const Duration(seconds: 3) || index <= 0) {
      await _p.seek(Duration.zero);
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
    // Токен живёт час: после долгой паузы переоткрываем трек с того же места
    final opened = _openedAt;
    if (!playing && opened != null && DateTime.now().difference(opened) > const Duration(minutes: 50)) {
      await _open(at: position.value);
      return;
    }
    await _p.playOrPause();
  }

  Future<void> seek(Duration d) => _p.seek(d);

  Future<void> setVolume(double v, {bool save = false}) async {
    settings.volume = v;
    await _p.setVolume(v);
    notifyListeners();
    if (save) await lib.saveSettings();
  }

  void toggleShuffle() {
    shuffle = !shuffle;
    final cur = current?.id;
    if (cur != null) {
      if (shuffle) {
        final rest = List.of(queue)
          ..remove(cur)
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
  }

  void cycleRepeat() {
    repeat = RepeatMode.values[(repeat.index + 1) % RepeatMode.values.length];
    notifyListeners();
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _p.dispose();
    position.dispose();
    super.dispose();
  }
}
