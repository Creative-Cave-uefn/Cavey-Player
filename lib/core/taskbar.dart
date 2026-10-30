import 'dart:async';
import 'dart:io';

import 'package:windows_taskbar/windows_taskbar.dart';

import 'log.dart';
import 'player.dart';

/// Кнопки «Назад / Пауза / Дальше» в превью окна на панели задач Windows.
class TaskbarController {
  final PlayerController player;

  bool _started = false;
  bool _disposed = false;
  bool _lastPlaying = false;
  bool _lastHasTrack = false;
  bool _applying = false;
  bool _again = false;
  Timer? _retry;

  TaskbarController(this.player);

  Future<void> start() async {
    if (!Platform.isWindows || _started) return;
    _started = true;
    // Windows сообщает, что кнопка окна на панели задач появилась (при запуске и после показа из трея),
    // и только после этого кнопки миниатюры можно ставить
    WindowsTaskbar.onTaskbarButtonCreated = () => unawaited(_apply(force: true));
    player.addListener(_onPlayer);
    unawaited(_apply(force: true));
    // Если окно ещё не было видно, сообщение могло прийти раньше нас: пробуем ещё несколько раз
    _retry = Timer.periodic(const Duration(seconds: 3), (t) {
      if (_disposed || t.tick > 10 || _ok) {
        t.cancel();
        return;
      }
      unawaited(_apply(force: true));
    });
  }

  bool _ok = false;

  void dispose() {
    _disposed = true;
    _retry?.cancel();
    if (_started) {
      player.removeListener(_onPlayer);
      WindowsTaskbar.onTaskbarButtonCreated = null;
    }
  }

  void _onPlayer() {
    final has = player.current != null;
    if (has == _lastHasTrack && player.playing == _lastPlaying) return;
    unawaited(_apply());
  }

  Future<void> _apply({bool force = false}) async {
    if (_disposed) return;
    if (_applying) {
      _again = true;
      return;
    }
    _applying = true;
    try {
      do {
        _again = false;
        final has = player.current != null;
        final playing = player.playing;
        if (!force && has == _lastHasTrack && playing == _lastPlaying && _ok) break;
        force = false;
        try {
          await WindowsTaskbar.setThumbnailToolbar([
            ThumbnailToolbarButton(
              ThumbnailToolbarAssetIcon('assets/taskbar/prev.ico'),
              'Предыдущий трек',
              () => unawaited(player.previous()),
              mode: has ? 0 : ThumbnailToolbarButtonMode.disabled,
            ),
            ThumbnailToolbarButton(
              ThumbnailToolbarAssetIcon(playing ? 'assets/taskbar/pause.ico' : 'assets/taskbar/play.ico'),
              playing ? 'Пауза' : 'Играть',
              () => unawaited(player.toggle()),
              mode: has ? 0 : ThumbnailToolbarButtonMode.disabled,
            ),
            ThumbnailToolbarButton(
              ThumbnailToolbarAssetIcon('assets/taskbar/next.ico'),
              'Следующий трек',
              () => unawaited(player.next()),
              mode: has ? 0 : ThumbnailToolbarButtonMode.disabled,
            ),
          ]);
          _ok = true;
          _lastHasTrack = has;
          _lastPlaying = playing;
        } catch (e) {
          // Окно ещё не показано или спрятано в трей: кнопки поставятся, когда оно появится
          if (_ok) AppLog.warn('Кнопки в панели задач не обновились', e);
          _ok = false;
        }
      } while (_again && !_disposed);
    } finally {
      _applying = false;
    }
  }
}
