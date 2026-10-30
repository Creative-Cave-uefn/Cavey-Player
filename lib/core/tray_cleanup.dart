import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'log.dart';

// «Призраки» значков в трее. Когда процесс закрыт принудительно (установщик, диспетчер задач, сбой),
// Windows не убирает его значок, пока над ним не проведёшь курсор. После обновлений они копятся.
// Лечится тем, что над областью уведомлений «проводят курсор»: Проводник сам проверяет значки и выбрасывает мёртвые.

typedef _FindC = IntPtr Function(IntPtr parent, IntPtr after, Pointer<Utf16> cls, Pointer<Utf16> title);
typedef _FindD = int Function(int parent, int after, Pointer<Utf16> cls, Pointer<Utf16> title);
typedef _RectC = Int32 Function(IntPtr hwnd, Pointer<Int32> rect);
typedef _RectD = int Function(int hwnd, Pointer<Int32> rect);
typedef _PostC = Int32 Function(IntPtr hwnd, Uint32 msg, IntPtr wParam, IntPtr lParam);
typedef _PostD = int Function(int hwnd, int msg, int wParam, int lParam);

const _wmMouseMove = 0x0200;

/// Шаг, с которым «проводим курсор» по панели значков, в пикселях
const trayStep = 8;

/// Точки (x, y), через которые надо «провести курсор» по панели размером [width] × [height]
List<(int, int)> sweepPoints(int width, int height, {int step = trayStep}) {
  if (width <= 0 || height <= 0 || step <= 0) return const [];
  final y = height ~/ 2;
  return [for (var x = 0; x < width; x += step) (x, y)];
}

/// Просит Проводник выбросить значки закрытых программ. Ничего не ломает, если что-то не нашлось.
void sweepGhostTrayIcons() {
  if (!Platform.isWindows) return;
  try {
    final user32 = DynamicLibrary.open('user32.dll');
    final find = user32.lookupFunction<_FindC, _FindD>('FindWindowExW');
    final getRect = user32.lookupFunction<_RectC, _RectD>('GetClientRect');
    final post = user32.lookupFunction<_PostC, _PostD>('PostMessageW');

    int child(int parent, String cls) {
      final c = cls.toNativeUtf16();
      try {
        return find(parent, 0, c, nullptr);
      } finally {
        malloc.free(c);
      }
    }

    final bars = <int>[];
    final tray = child(0, 'Shell_TrayWnd');
    if (tray != 0) {
      final notify = child(tray, 'TrayNotifyWnd');
      final pager = notify == 0 ? 0 : child(notify, 'SysPager');
      final bar = pager == 0 ? 0 : child(pager, 'ToolbarWindow32');
      if (bar != 0) bars.add(bar);
    }
    final overflow = child(0, 'NotifyIconOverflowWindow');
    if (overflow != 0) {
      final bar = child(overflow, 'ToolbarWindow32');
      if (bar != 0) bars.add(bar);
    }

    final rect = malloc<Int32>(4);
    try {
      for (final bar in bars) {
        if (getRect(bar, rect) == 0) continue;
        final w = rect[2] - rect[0];
        final h = rect[3] - rect[1];
        for (final (x, y) in sweepPoints(w, h)) {
          post(bar, _wmMouseMove, 0, (y << 16) | (x & 0xFFFF));
        }
      }
    } finally {
      malloc.free(rect);
    }
  } catch (e) {
    AppLog.warn('Не получилось почистить значки в трее', e);
  }
}
