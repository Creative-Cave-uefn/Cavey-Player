import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'log.dart';
import 'player.dart';
import 'store.dart';

// Медиаклавиши (⏮ ⏯ ⏭) для окна, которое не в фокусе или спрятано в трее.
// Flutter получает клавиши, только пока его окно активно, поэтому состояние клавиш спрашиваем у Windows сами,
// несколько раз в секунду. Клавиши при этом не перехватываются: другие программы тоже их видят.

typedef _KeyStateC = Int16 Function(Int32 vk);
typedef _KeyStateD = int Function(int vk);

const _vkMediaNext = 0xB0;
const _vkMediaPrev = 0xB1;
const _vkMediaPlayPause = 0xB3;

class MediaKeys {
  final PlayerController player;
  final Settings settings;
  MediaKeys(this.player, this.settings);

  Timer? _timer;
  _KeyStateD? _state;
  final _down = <int, bool>{};

  /// Работает ли перехват (тогда обычная обработка в окне эти клавиши пропускает, чтобы они не сработали дважды)
  static bool running = false;

  void start() {
    if (!Platform.isWindows || _timer != null) return;
    try {
      _state = DynamicLibrary.open('user32.dll').lookupFunction<_KeyStateC, _KeyStateD>('GetAsyncKeyState');
    } catch (e) {
      AppLog.warn('Медиаклавиши без фокуса не заработают', e);
      return;
    }
    _timer = Timer.periodic(const Duration(milliseconds: 60), (_) => _poll());
    running = settings.globalMediaKeys;
  }

  /// Вызывается при смене настройки
  void refresh() {
    running = _timer != null && settings.globalMediaKeys;
  }

  void _poll() {
    final read = _state;
    if (read == null) return;
    running = settings.globalMediaKeys;
    for (final vk in const [_vkMediaNext, _vkMediaPrev, _vkMediaPlayPause]) {
      final down = read(vk) & 0x8000 != 0;
      final was = _down[vk] ?? false;
      _down[vk] = down;
      if (!down || was || !settings.globalMediaKeys) continue;
      switch (vk) {
        case _vkMediaNext:
          unawaited(player.next());
        case _vkMediaPrev:
          unawaited(player.previous());
        default:
          unawaited(player.toggle());
      }
    }
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    running = false;
  }
}
