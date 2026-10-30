// 30-секундные отрывки треков из интернета (Deezer). Свой маленький плеер,
// чтобы не трогать очередь: основной на время отрывка встаёт на паузу.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart' show Media, Player;

import 'log.dart';
import 'player.dart';
import 'web_info.dart';

class PreviewPlayer extends ChangeNotifier {
  final PlayerController main;
  final Player _p = Player();
  final List<StreamSubscription<dynamic>> _subs = [];

  /// Какой отрывок играет (id трека Deezer)
  int? current;
  double progress = 0;

  PreviewPlayer(this.main) {
    _subs.add(_p.stream.completed.listen((done) {
      if (done) stop();
    }));
    _subs.add(_p.stream.position.listen((pos) {
      if (current == null) return;
      final total = _p.state.duration.inMilliseconds;
      final p = total > 0 ? pos.inMilliseconds / total : 0.0;
      if ((p - progress).abs() > 0.01) {
        progress = p;
        notifyListeners();
      }
    }));
    // Включили что-то в основном плеере — отрывок замолкает
    main.addListener(() {
      if (current != null && main.playing) stop();
    });
  }

  Future<void> toggle(WebTrack t) async {
    if (current == t.id) {
      await stop();
      return;
    }
    if (t.preview.isEmpty) return;
    if (main.playing) await main.pause();
    current = t.id;
    progress = 0;
    notifyListeners();
    try {
      await _p.setVolume(main.volume);
      await _p.open(Media(t.preview));
    } catch (e) {
      AppLog.warn('Отрывок «${t.title}»', e);
      await stop();
    }
  }

  Future<void> stop() async {
    if (current == null) return;
    current = null;
    progress = 0;
    notifyListeners();
    await _p.stop();
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _p.dispose();
    super.dispose();
  }
}
