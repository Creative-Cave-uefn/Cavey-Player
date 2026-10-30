import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

// Окно может быть спрятано в трее, и человек запускает Cave Player ещё раз. Вторая копия не нужна:
// она бы играла поверх первой и писала в те же файлы. Поэтому вторая копия находит первую,
// показывает её окно и закрывается.

typedef _OpenMutexC = IntPtr Function(Uint32 access, Int32 inherit, Pointer<Utf16> name);
typedef _OpenMutexD = int Function(int access, int inherit, Pointer<Utf16> name);
typedef _CreateMutexC = IntPtr Function(Pointer<Void> attrs, Int32 owner, Pointer<Utf16> name);
typedef _CreateMutexD = int Function(Pointer<Void> attrs, int owner, Pointer<Utf16> name);
typedef _FindWindowC = IntPtr Function(Pointer<Utf16> cls, Pointer<Utf16> title);
typedef _FindWindowD = int Function(Pointer<Utf16> cls, Pointer<Utf16> title);
typedef _ShowWindowC = Int32 Function(IntPtr hwnd, Int32 cmd);
typedef _ShowWindowD = int Function(int hwnd, int cmd);
typedef _SetForegroundC = Int32 Function(IntPtr hwnd);
typedef _SetForegroundD = int Function(int hwnd);

const _mutexName = r'Local\CavePlayerSingleInstance';
const _synchronize = 0x00100000;

/// true — мы первая копия и можно запускаться. false — уже есть другая, её окно показано, надо выходить.
bool claimSingleInstance() {
  if (!Platform.isWindows) return true;
  try {
    final k32 = DynamicLibrary.open('kernel32.dll');
    final open = k32.lookupFunction<_OpenMutexC, _OpenMutexD>('OpenMutexW');
    final create = k32.lookupFunction<_CreateMutexC, _CreateMutexD>('CreateMutexW');
    final name = _mutexName.toNativeUtf16();
    try {
      if (open(_synchronize, 0, name) != 0) {
        _showRunning();
        return false;
      }
      // Ручку намеренно не закрываем: мьютекс живёт, пока жива программа
      create(nullptr, 0, name);
      return true;
    } finally {
      malloc.free(name);
    }
  } catch (_) {
    return true; // не получилось проверить — лучше запуститься, чем не открыться вовсе
  }
}

void _showRunning() {
  try {
    final u32 = DynamicLibrary.open('user32.dll');
    final find = u32.lookupFunction<_FindWindowC, _FindWindowD>('FindWindowW');
    final show = u32.lookupFunction<_ShowWindowC, _ShowWindowD>('ShowWindow');
    final front = u32.lookupFunction<_SetForegroundC, _SetForegroundD>('SetForegroundWindow');
    final cls = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
    final title = 'Cave Player'.toNativeUtf16();
    try {
      final hwnd = find(cls, title);
      if (hwnd != 0) {
        show(hwnd, 5); // SW_SHOW: окно было спрятано
        show(hwnd, 9); // SW_RESTORE: или свёрнуто
        front(hwnd);
      }
    } finally {
      malloc.free(cls);
      malloc.free(title);
    }
  } catch (_) {}
}
