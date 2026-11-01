import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../ui/theme.dart';
import 'log.dart';

// Верхняя полоса окна в цвет фона приложения.
// Windows 11: система умеет красить полосу и рамку — просим её через DwmSetWindowAttribute, кнопки остаются системными
// (меню «привязки окон», двойной клик и перетаскивание работают как раньше).
// Windows 10: покрасить системную полосу нельзя, поэтому прячем её и рисуем свою с кнопками «Свернуть / Развернуть / Закрыть».

/// Номер сборки Windows (22000 и выше — это Windows 11), 0 — не Windows или не удалось узнать
int windowsBuild() {
  if (!Platform.isWindows) return 0;
  final m = RegExp(r'Build (\d+)').firstMatch(Platform.operatingSystemVersion);
  return m == null ? 0 : int.parse(m.group(1)!);
}

/// Достаточно ли новая система, чтобы красить полосу окна
bool canTintCaption([int? build]) => (build ?? windowsBuild()) >= 22000;

/// Свою полосу рисуем только на Windows старше 11 (десятка и ниже)
bool needsCustomCaption([int? build]) {
  final b = build ?? windowsBuild();
  return Platform.isWindows && b > 0 && b < 22000;
}

/// Цвет в формате Windows COLORREF: 0x00BBGGRR
int colorRef(Color c) {
  final r = (c.r * 255).round() & 0xFF;
  final g = (c.g * 255).round() & 0xFF;
  final b = (c.b * 255).round() & 0xFF;
  return (b << 16) | (g << 8) | r;
}

typedef _FindWindowC = IntPtr Function(Pointer<Utf16> cls, Pointer<Utf16> title);
typedef _FindWindowD = int Function(Pointer<Utf16> cls, Pointer<Utf16> title);
typedef _DwmSetC = Int32 Function(IntPtr hwnd, Uint32 attr, Pointer<Uint32> value, Uint32 size);
typedef _DwmSetD = int Function(int hwnd, int attr, Pointer<Uint32> value, int size);

const _dwmaUseDarkMode = 20;
const _dwmaBorderColor = 34;
const _dwmaCaptionColor = 35;
const _dwmaTextColor = 36;

/// Тёмная системная рамка и (в Windows 11) полоса заголовка в цвет фона приложения.
/// Нужна и при своей шапке: при наведении на угол с кнопками окна Windows иногда проступает
/// системная полоса, и без этого она светло-серая
void tintCaption() {
  if (!Platform.isWindows) return;
  final build = windowsBuild();
  try {
    final user32 = DynamicLibrary.open('user32.dll');
    final find = user32.lookupFunction<_FindWindowC, _FindWindowD>('FindWindowW');
    final cls = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
    int hwnd;
    try {
      hwnd = find(cls, nullptr);
    } finally {
      malloc.free(cls);
    }
    if (hwnd == 0) return;
    _paintBackdrop(user32, hwnd);
    if (build < 17763) return;
    final dwm = DynamicLibrary.open('dwmapi.dll');
    final set = dwm.lookupFunction<_DwmSetC, _DwmSetD>('DwmSetWindowAttribute');
    final v = malloc<Uint32>();
    try {
      void put(int attr, int value) {
        v.value = value;
        set(hwnd, attr, v, 4);
      }

      // До Windows 10 20H1 тёмный режим рамки включался атрибутом 19
      put(build < 18985 ? 19 : _dwmaUseDarkMode, 1);
      if (canTintCaption(build)) {
        put(_dwmaCaptionColor, colorRef(C.bg));
        put(_dwmaBorderColor, colorRef(C.bg));
        put(_dwmaTextColor, colorRef(C.text));
      }
    } finally {
      malloc.free(v);
    }
  } catch (e) {
    AppLog.warn('Не удалось покрасить полосу окна', e);
  }
}

int _backdropBrush = 0;
int _backdropColor = -1;

/// Кисть, которой Windows закрашивает участки окна, куда Flutter ещё не успел нарисовать. По умолчанию она светло-серая:
/// при наведении на кнопки в верхней полосе на кадр проступал серый прямоугольник. Красим её в цвет фона
void _paintBackdrop(DynamicLibrary user32, int hwnd) {
  final color = colorRef(C.bg);
  if (_backdropBrush == 0 || _backdropColor != color) {
    final gdi = DynamicLibrary.open('gdi32.dll');
    final create = gdi.lookupFunction<IntPtr Function(Uint32), int Function(int)>('CreateSolidBrush');
    final del = gdi.lookupFunction<Int32 Function(IntPtr), int Function(int)>('DeleteObject');
    final brush = create(color);
    if (brush == 0) return;
    final setClass = user32.lookupFunction<IntPtr Function(IntPtr, Int32, IntPtr), int Function(int, int, int)>('SetClassLongPtrW');
    const gclpHbrBackground = -10;
    setClass(hwnd, gclpHbrBackground, brush);
    // Старую кисть класса окна не трогаем — она системная; свою прошлую удаляем
    if (_backdropBrush != 0) del(_backdropBrush);
    _backdropBrush = brush;
    _backdropColor = color;
  }
}

/// Настраивает окно при запуске: Windows 11 — красим систему, Windows 10 — прячем системную полосу
Future<void> setupWindowStyle() async {
  if (!Platform.isWindows) return;
  try {
    if (needsCustomCaption()) {
      await windowManager.setTitleBarStyle(TitleBarStyle.hidden, windowButtonVisibility: false);
    } else {
      tintCaption();
    }
  } catch (e) {
    AppLog.warn('Окно: стиль полосы не применился', e);
  }
}

/// Оборачивает приложение: на Windows 10 сверху своя полоса, в остальных случаях ничего не меняет
class CaptionFrame extends StatelessWidget {
  final Widget child;
  const CaptionFrame({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    if (!needsCustomCaption()) return child;
    return Column(
      children: [
        const _CaptionBar(),
        Expanded(child: child),
      ],
    );
  }
}

class _CaptionBar extends StatefulWidget {
  const _CaptionBar();

  @override
  State<_CaptionBar> createState() => _CaptionBarState();
}

class _CaptionBarState extends State<_CaptionBar> with WindowListener {
  bool _max = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    windowManager.isMaximized().then((v) {
      if (mounted) setState(() => _max = v);
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() => setState(() => _max = true);
  @override
  void onWindowUnmaximize() => setState(() => _max = false);

  Future<void> _toggleMax() async {
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: C.bg,
      child: SizedBox(
        height: 32,
        child: Row(
          children: [
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onPanStart: (_) => windowManager.startDragging(),
                onDoubleTap: _toggleMax,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 12),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Image.asset('assets/logo.png', width: 16, height: 16, filterQuality: FilterQuality.medium),
                      const SizedBox(width: 8),
                      const Text('Cavey', style: TextStyle(color: C.muted, fontSize: 12)),
                    ]),
                  ),
                ),
              ),
            ),
            _CaptionButton(icon: Icons.remove, onTap: () => windowManager.minimize()),
            _CaptionButton(icon: _max ? Icons.filter_none : Icons.crop_square, small: _max, onTap: _toggleMax),
            _CaptionButton(icon: Icons.close, danger: true, onTap: () => windowManager.close()),
          ],
        ),
      ),
    );
  }
}

class _CaptionButton extends StatefulWidget {
  final IconData icon;
  final VoidCallback onTap;
  final bool danger;
  final bool small;
  const _CaptionButton({required this.icon, required this.onTap, this.danger = false, this.small = false});

  @override
  State<_CaptionButton> createState() => _CaptionButtonState();
}

class _CaptionButtonState extends State<_CaptionButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: 46,
          height: 32,
          color: _hover ? (widget.danger ? const Color(0xFFE81123) : C.hover) : Colors.transparent,
          child: Icon(widget.icon, size: widget.small ? 12 : 15, color: _hover && widget.danger ? Colors.white : C.text),
        ),
      ),
    );
  }
}
