import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'theme.dart';

/// Своя «шапка» окна вместо системной: прозрачная полоса поверх стеклянного фона.
/// За неё окно перетаскивается, двойной клик разворачивает, справа — свернуть, развернуть, закрыть
class WindowBar extends StatefulWidget {
  const WindowBar({super.key});

  static const height = 34.0;

  /// Своя шапка только на Windows: там системную мы прячем
  static bool get enabled => Platform.isWindows;

  @override
  State<WindowBar> createState() => _WindowBarState();
}

class _WindowBarState extends State<WindowBar> with WindowListener {
  bool _max = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    windowManager.isMaximized().then((v) {
      if (mounted) setState(() => _max = v);
    }).catchError((Object _) {});
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
    return SizedBox(
      height: WindowBar.height,
      child: Row(children: [
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onPanStart: (_) => windowManager.startDragging(),
            onDoubleTap: _toggleMax,
            child: const SizedBox.expand(),
          ),
        ),
        _CaptionButton(icon: Icons.remove_rounded, tooltip: 'Свернуть', onTap: () => windowManager.minimize()),
        _CaptionButton(
          icon: _max ? Icons.filter_none_rounded : Icons.crop_square_rounded,
          iconSize: _max ? 13 : 15,
          tooltip: _max ? 'Восстановить' : 'Развернуть',
          onTap: _toggleMax,
        ),
        _CaptionButton(icon: Icons.close_rounded, tooltip: 'Закрыть', danger: true, onTap: () => windowManager.close()),
      ]),
    );
  }
}

class _CaptionButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool danger;
  final double iconSize;
  const _CaptionButton({required this.icon, required this.tooltip, required this.onTap, this.danger = false, this.iconSize = 16});

  @override
  State<_CaptionButton> createState() => _CaptionButtonState();
}

class _CaptionButtonState extends State<_CaptionButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final bg = !_hover ? Colors.transparent : (widget.danger ? const Color(0xFFC42B1C) : C.hoverOverlay);
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 700),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: 46,
            height: WindowBar.height,
            color: bg,
            child: Icon(widget.icon, size: widget.iconSize, color: _hover && widget.danger ? Colors.white : C.muted),
          ),
        ),
      ),
    );
  }
}
