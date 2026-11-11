import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../app.dart';
import '../core/window_style.dart';
import 'ambient.dart' show StripTint;
import 'shell.dart';
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
  void onWindowMaximize() {
    setState(() => _max = true);
    tintCaption();
  }

  @override
  void onWindowUnmaximize() {
    setState(() => _max = false);
    tintCaption();
  }

  // Системная рамка после смены фокуса снова может стать светлой — красим заново
  @override
  void onWindowFocus() => tintCaption();

  @override
  void onWindowBlur() => tintCaption();

  Future<void> _toggleMax() async {
    if (await windowManager.isMaximized()) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
  }

  @override
  Widget build(BuildContext context) {
    // RepaintBoundary: полоса перерисовывается отдельным слоем и не тянет за собой остальное окно
    return RepaintBoundary(
        child: SizedBox(
      height: WindowBar.height,
      child: Stack(children: [
        // На странице человека с баннером: полоса подкрашена цветами верхней кромки баннера и продолжает его вверх
        const Positioned.fill(child: _BannerStrip()),
        Row(children: [
        // Слева: настройки, «Назад» и «Вперёд» — на одном уровне с кнопками окна
        const _NavButtons(),
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
      ]),
    ));
  }
}

/// Подкраска верхней полосы окна по баннеру профиля ([StripTint]); без баннера ничего не рисует
class _BannerStrip extends StatelessWidget {
  const _BannerStrip();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ValueListenableBuilder<List<Color>?>(
        valueListenable: StripTint.colors,
        builder: (context, colors, _) {
          return AnimatedSwitcher(
            duration: const Duration(milliseconds: 500),
            child: colors == null
                ? const SizedBox.shrink(key: ValueKey('none'))
                : ValueListenableBuilder<double>(
                    key: ValueKey(colors),
                    valueListenable: StripTint.fade,
                    builder: (context, fade, _) => Opacity(
                      opacity: fade,
                      child: ShaderMask(
                        blendMode: BlendMode.dstIn,
                        shaderCallback: (r) => const LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          // у верхнего края слабее, к баннеру — полный цвет: полоса словно продолжает баннер вверх
                          colors: [Color(0x40FFFFFF), Colors.white],
                          stops: [0.0, 1.0],
                        ).createShader(r),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(colors: [for (final c in colors) c.withValues(alpha: 0.9)]),
                          ),
                        ),
                      ),
                    ),
                  ),
          );
        },
      ),
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
    // Без всплывающей подсказки: через ~0,7 с она заставляла окно перерисоваться, и вся полоса на миг заливалась серым.
    // Названия кнопок известны всем, а для чтения с экрана подпись остаётся
    return Semantics(
      button: true,
      label: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: Container(
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

/// Шестерёнка «Настройки» и стрелки истории. Видны, когда открыт основной экран
class _NavButtons extends StatelessWidget {
  const _NavButtons();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<NavController?>(
      valueListenable: shellNav,
      builder: (context, nav, _) {
        if (nav == null) return const SizedBox(width: 8);
        final app = Services.of(context);
        return AnimatedBuilder(
          animation: Listenable.merge([nav, app.accounts, app.lib]),
          builder: (context, _) {
            final inSettings = nav.value.kind == 'accounts' || nav.value.kind == 'sources';
            final needSignIn = app.accounts.accounts.any((a) => a.needsSignIn);
            return Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                _BarIcon(
                  icon: Icons.settings_outlined,
                  tooltip: needSignIn ? 'Настройки: нужно снова войти в аккаунт' : 'Настройки',
                  active: inSettings,
                  onTap: () => nav.go(const Nav('accounts')),
                  badge: needSignIn
                      ? const Icon(Icons.error_rounded, size: 11, color: C.danger)
                      : null,
                ),
                const SizedBox(width: 2),
                _BarIcon(
                  icon: Icons.chevron_left_rounded,
                  tooltip: 'Назад (Alt+←)',
                  size: 22,
                  onTap: nav.canBack ? nav.back : null,
                ),
                _BarIcon(
                  icon: Icons.chevron_right_rounded,
                  tooltip: 'Вперёд (Alt+→)',
                  size: 22,
                  onTap: nav.canForward ? nav.forward : null,
                ),
              ]),
            );
          },
        );
      },
    );
  }
}

class _BarIcon extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final bool active;
  final double size;
  final Widget? badge;
  const _BarIcon({required this.icon, required this.tooltip, required this.onTap, this.active = false, this.size = 17, this.badge});

  @override
  State<_BarIcon> createState() => _BarIconState();
}

class _BarIconState extends State<_BarIcon> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final on = widget.onTap != null;
    final color = !on ? C.line : (widget.active ? C.accent : (_hover ? C.text : C.muted));
    // Без Tooltip: шапка стоит выше навигатора приложения, у неё нет своего Overlay, и через 0,6 с наведения подсказка
    // падала с ошибкой, а в сборке без отладки на её месте появлялась серая плашка. Для чтения с экрана подпись остаётся
    return Semantics(
      button: true,
      label: widget.tooltip,
      child: MouseRegion(
        cursor: on ? SystemMouseCursors.click : MouseCursor.defer,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: 34,
            height: WindowBar.height - 6,
            decoration: BoxDecoration(
              color: _hover && on ? C.hoverOverlay : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Stack(alignment: Alignment.center, children: [
              Icon(widget.icon, size: widget.size, color: color),
              if (widget.badge != null) Positioned(right: 5, top: 4, child: widget.badge!),
            ]),
          ),
        ),
      ),
    );
  }
}
