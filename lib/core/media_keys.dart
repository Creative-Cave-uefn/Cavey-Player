import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'log.dart';
import 'player.dart';
import 'store.dart';

// Медиаклавиши (⏮ ⏯ ⏭, в том числе Fn+F-клавиши ноутбука и кнопки жестов мыши Logitech) по всей системе.
//
// Низкоуровневый перехват клавиатуры (WH_KEYBOARD_LL) стоит в отдельном потоке (изолят с циклом сообщений).
// Пока Cave Player «главный» (трек играет или недавно стоял на паузе), он забирает эти клавиши себе:
// браузер или другой плеер их уже не получает. Когда Cave Player молчит, клавиши идут дальше как обычно.

typedef _HookProcC = IntPtr Function(Int32 code, IntPtr wParam, IntPtr lParam);
typedef _SetHookC = IntPtr Function(Int32 id, Pointer<NativeFunction<_HookProcC>> proc, IntPtr module, Uint32 thread);
typedef _SetHookD = int Function(int id, Pointer<NativeFunction<_HookProcC>> proc, int module, int thread);
typedef _CallNextC = IntPtr Function(IntPtr hook, Int32 code, IntPtr wParam, IntPtr lParam);
typedef _CallNextD = int Function(int hook, int code, int wParam, int lParam);
typedef _GetMsgC = Int32 Function(Pointer<Void> msg, IntPtr hwnd, Uint32 min, Uint32 max);
typedef _GetMsgD = int Function(Pointer<Void> msg, int hwnd, int min, int max);
typedef _MsgC = Int32 Function(Pointer<Void> msg);
typedef _MsgD = int Function(Pointer<Void> msg);

const _vkMediaNext = 0xB0;
const _vkMediaPrev = 0xB1;
const _vkMediaPlayPause = 0xB3;
const _whKeyboardLl = 13;

/// Сколько после паузы Cave Player ещё считается главным (чтобы клавишей можно было продолжить)
const mediaKeysStickyAfterPause = Duration(minutes: 10);

/// Забирает ли Cave Player медиаклавиши прямо сейчас
bool mediaKeysOwned({
  required bool enabled,
  required bool hasTrack,
  required bool playing,
  required DateTime? pausedAt,
  required DateTime now,
}) {
  if (!enabled || !hasTrack) return false;
  if (playing) return true;
  return pausedAt != null && now.difference(pausedAt) < mediaKeysStickyAfterPause;
}

/// Рабочий поток: ставит перехват и крутит цикл сообщений. [args]: порт для ответов и адрес общего флага.
void _hookMain(List<Object> args) {
  final port = args[0] as SendPort;
  final flag = Pointer<Int32>.fromAddress(args[1] as int);
  try {
    final user32 = DynamicLibrary.open('user32.dll');
    final setHook = user32.lookupFunction<_SetHookC, _SetHookD>('SetWindowsHookExW');
    final callNext = user32.lookupFunction<_CallNextC, _CallNextD>('CallNextHookEx');
    final getMessage = user32.lookupFunction<_GetMsgC, _GetMsgD>('GetMessageW');
    final translate = user32.lookupFunction<_MsgC, _MsgD>('TranslateMessage');
    final dispatch = user32.lookupFunction<_MsgC, _MsgD>('DispatchMessageW');

    int proc(int code, int wParam, int lParam) {
      if (code == 0 && flag.value == 1) {
        // lParam указывает на KBDLLHOOKSTRUCT, первое поле — код клавиши
        final vk = Pointer<Uint32>.fromAddress(lParam).value;
        if (vk == _vkMediaNext || vk == _vkMediaPrev || vk == _vkMediaPlayPause) {
          final down = wParam == 0x100 || wParam == 0x104; // WM_KEYDOWN, WM_SYSKEYDOWN
          if (down) port.send(vk);
          return 1; // клавишу не отдаём ни окну, ни другим программам
        }
      }
      return callNext(0, code, wParam, lParam);
    }

    final callable = NativeCallable<_HookProcC>.isolateLocal(proc, exceptionalReturn: 0);
    final hook = setHook(_whKeyboardLl, callable.nativeFunction, 0, 0);
    if (hook == 0) {
      port.send('error:не удалось поставить перехват клавиш');
      return;
    }
    port.send('ready');
    final msg = malloc<Uint8>(64).cast<Void>();
    // Пока поток ждёт сообщение, Windows сама вызывает наш обработчик клавиш
    while (getMessage(msg, 0, 0, 0) > 0) {
      translate(msg);
      dispatch(msg);
    }
  } catch (e) {
    port.send('error:$e');
  }
}

class MediaKeys {
  final PlayerController player;
  final Settings settings;
  MediaKeys(this.player, this.settings);

  ReceivePort? _port;
  Pointer<Int32>? _flag;
  DateTime? _pausedAt;
  bool _wasPlaying = false;
  Timer? _tick;

  /// Работает ли перехват в данный момент (тогда обычная обработка этих клавиш в окне отключена, чтобы не сработать дважды)
  static bool running = false;

  void start() {
    if (!Platform.isWindows || _port != null) return;
    try {
      final flag = malloc<Int32>()..value = 0;
      _flag = flag;
      final port = ReceivePort();
      _port = port;
      port.listen(_onMessage);
      unawaited(Isolate.spawn(_hookMain, <Object>[port.sendPort, flag.address]).catchError((Object e) {
        AppLog.warn('Перехват медиаклавиш не запустился', e);
        return Isolate.current;
      }));
      player.addListener(_update);
      // Срок «недавно на паузе» истекает сам, без событий от плеера
      _tick = Timer.periodic(const Duration(seconds: 30), (_) => _update());
      _update();
    } catch (e) {
      AppLog.warn('Перехват медиаклавиш не запустился', e);
    }
  }

  DateTime _lastKey = DateTime.fromMillisecondsSinceEpoch(0);

  void _onMessage(Object? m) {
    if (m is int) {
      // Зажатая клавиша шлёт повторы — один щелчок должен дать одно действие
      final now = DateTime.now();
      if (now.difference(_lastKey) < const Duration(milliseconds: 250)) return;
      _lastKey = now;
      switch (m) {
        case _vkMediaNext:
          unawaited(player.next());
        case _vkMediaPrev:
          unawaited(player.previous());
        default:
          unawaited(player.toggle());
      }
    } else if (m is String && m.startsWith('error:')) {
      AppLog.warn('Медиаклавиши без фокуса не заработают', m.substring(6));
      _flag?.value = 0;
      running = false;
    }
  }

  void _update() {
    final flag = _flag;
    if (flag == null) return;
    final now = DateTime.now();
    if (_wasPlaying && !player.playing) _pausedAt = now;
    _wasPlaying = player.playing;
    final owned = mediaKeysOwned(
      enabled: settings.globalMediaKeys,
      hasTrack: player.current != null,
      playing: player.playing,
      pausedAt: _pausedAt,
      now: now,
    );
    flag.value = owned ? 1 : 0;
    running = owned;
  }

  /// Вызывается при смене настройки
  void refresh() => _update();

  void dispose() {
    _tick?.cancel();
    player.removeListener(_update);
    _flag?.value = 0;
    running = false;
    _port?.close();
  }
}
