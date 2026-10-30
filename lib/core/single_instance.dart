import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'share_link.dart';

// Окно может быть спрятано в трее, и человек запускает Cave Player ещё раз (например, ярлыком на панели задач).
// Вторая копия не нужна: она бы играла поверх первой и писала в те же файлы. Поэтому вторая копия
// сигналит первой через именованное событие Windows и закрывается, а первая сама показывает своё окно.
// Показывать чужое окно снаружи нельзя: у спрятанного окна Flutter так не оживает.

typedef _OpenMutexC = IntPtr Function(Uint32 access, Int32 inherit, Pointer<Utf16> name);
typedef _OpenMutexD = int Function(int access, int inherit, Pointer<Utf16> name);
typedef _CreateMutexC = IntPtr Function(Pointer<Void> attrs, Int32 owner, Pointer<Utf16> name);
typedef _CreateMutexD = int Function(Pointer<Void> attrs, int owner, Pointer<Utf16> name);

typedef _OpenEventC = IntPtr Function(Uint32 access, Int32 inherit, Pointer<Utf16> name);
typedef _OpenEventD = int Function(int access, int inherit, Pointer<Utf16> name);
typedef _CreateEventC = IntPtr Function(Pointer<Void> attrs, Int32 manual, Int32 initial, Pointer<Utf16> name);
typedef _CreateEventD = int Function(Pointer<Void> attrs, int manual, int initial, Pointer<Utf16> name);
typedef _SetEventC = Int32 Function(IntPtr h);
typedef _SetEventD = int Function(int h);
typedef _WaitC = Uint32 Function(IntPtr h, Uint32 ms);
typedef _WaitD = int Function(int h, int ms);
typedef _AllowFgC = Int32 Function(Uint32 pid);
typedef _AllowFgD = int Function(int pid);

const _mutexName = r'Local\CavePlayerSingleInstance';
const _eventName = r'Local\CavePlayerShowWindow';
const _synchronize = 0x00100000;
const _eventModifyState = 0x0002;
const _asfwAny = 0xFFFFFFFF;

int _showEvent = 0;

/// true — мы первая копия и можно запускаться. false — уже есть другая, ей послан сигнал показаться, надо выходить.
bool claimSingleInstance({String? link}) {
  if (!Platform.isWindows) return true;
  try {
    final k32 = DynamicLibrary.open('kernel32.dll');
    final open = k32.lookupFunction<_OpenMutexC, _OpenMutexD>('OpenMutexW');
    final create = k32.lookupFunction<_CreateMutexC, _CreateMutexD>('CreateMutexW');
    final name = _mutexName.toNativeUtf16();
    try {
      if (open(_synchronize, 0, name) != 0) {
        // Ссылка на трек (caveplayer://…) от второй копии уходит первой через файл
        if (link != null) leavePendingLink(link);
        _signalRunning(k32);
        return false;
      }
      // Ручку намеренно не закрываем: мьютекс живёт, пока жива программа
      create(nullptr, 0, name);
      final createEvent = k32.lookupFunction<_CreateEventC, _CreateEventD>('CreateEventW');
      final ev = _eventName.toNativeUtf16();
      try {
        _showEvent = createEvent(nullptr, 0, 0, ev); // сбрасывается сам после прочтения
      } finally {
        malloc.free(ev);
      }
      return true;
    } finally {
      malloc.free(name);
    }
  } catch (_) {
    return true; // не получилось проверить — лучше запуститься, чем не открыться вовсе
  }
}

/// Первая копия: раз в полсекунды смотрит, не просила ли её показаться вторая. Возвращает таймер для остановки.
Timer? listenForSecondLaunch(void Function() onShow) {
  if (!Platform.isWindows || _showEvent == 0) return null;
  try {
    final wait = DynamicLibrary.open('kernel32.dll').lookupFunction<_WaitC, _WaitD>('WaitForSingleObject');
    return Timer.periodic(const Duration(milliseconds: 400), (_) {
      if (wait(_showEvent, 0) == 0) onShow(); // 0 = WAIT_OBJECT_0, событие было подано
    });
  } catch (_) {
    return null;
  }
}

void _signalRunning(DynamicLibrary k32) {
  try {
    // Разрешаем первой копии выйти на передний план: право на это есть сейчас у нас, у только что запущенной
    DynamicLibrary.open('user32.dll').lookupFunction<_AllowFgC, _AllowFgD>('AllowSetForegroundWindow')(_asfwAny);
  } catch (_) {}
  try {
    final openEvent = k32.lookupFunction<_OpenEventC, _OpenEventD>('OpenEventW');
    final setEvent = k32.lookupFunction<_SetEventC, _SetEventD>('SetEvent');
    final ev = _eventName.toNativeUtf16();
    try {
      final h = openEvent(_eventModifyState, 0, ev);
      if (h != 0) setEvent(h);
    } finally {
      malloc.free(ev);
    }
  } catch (_) {}
}
