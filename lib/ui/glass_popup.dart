import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'theme.dart';

/// Матовое стекло для всего, что всплывает поверх страниц: окна, меню, уведомления.
/// Под панелью всё размывается, сама панель полупрозрачная — сквозь неё видны цвета фона,
/// но не текст страницы
class GlassPanel extends StatelessWidget {
  final Widget child;
  final double radius;
  final EdgeInsetsGeometry? padding;
  final double blur;
  final Color tint;
  final Color? border;
  final List<BoxShadow>? shadow;
  const GlassPanel({
    super.key,
    required this.child,
    this.radius = 18,
    this.padding,
    this.blur = 28,
    this.tint = C.glass,
    this.border,
    this.shadow,
  });

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(radius);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: r,
        boxShadow: shadow ?? const [BoxShadow(color: Color(0x59000000), blurRadius: 30, offset: Offset(0, 12))],
      ),
      child: ClipRRect(
        borderRadius: r,
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur, tileMode: TileMode.mirror),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: r,
              // Лёгкий блик сверху — стекло, а не просто тёмная плашка
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color.alphaBlend(const Color(0x14FFFFFF), tint), tint],
              ),
              border: Border.all(color: border ?? C.line),
            ),
            child: padding == null ? child : Padding(padding: padding!, child: child),
          ),
        ),
      ),
    );
  }
}

/// Окно поверх приложения: всё позади мягко размывается, само окно — стеклянное (цвет и форма из темы)
Future<T?> showGlassDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool barrierDismissible = true,
}) =>
    showDialog<T>(
      context: context,
      barrierDismissible: barrierDismissible,
      barrierColor: const Color(0x33000000),
      builder: (ctx) => BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16, tileMode: TileMode.mirror),
        child: builder(ctx),
      ),
    );

/// Стеклянное меню в заданной точке. Пункты — обычные PopupMenuItem / CheckedPopupMenuItem / PopupMenuDivider,
/// поэтому построители пунктов не меняются
Future<T?> showGlassMenu<T>({
  required BuildContext context,
  required RelativeRect position,
  required List<PopupMenuEntry<T>> items,
}) {
  if (items.isEmpty) return Future.value(null);
  return Navigator.of(context).push(_GlassMenuRoute<T>(position: position, items: items));
}

class _GlassMenuRoute<T> extends PopupRoute<T> {
  final RelativeRect position;
  final List<PopupMenuEntry<T>> items;
  _GlassMenuRoute({required this.position, required this.items});

  @override
  Color? get barrierColor => null;
  @override
  bool get barrierDismissible => true;
  @override
  String? get barrierLabel => 'Закрыть меню';
  @override
  Duration get transitionDuration => const Duration(milliseconds: 140);

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) {
    final size = MediaQuery.sizeOf(context);
    return CustomSingleChildLayout(
      delegate: _MenuLayout(position, size),
      child: FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
        child: ScaleTransition(
          alignment: Alignment.topLeft,
          scale: Tween(begin: 0.96, end: 1.0).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: 200, maxWidth: 340, maxHeight: size.height - 24),
            child: IntrinsicWidth(
              child: GlassPanel(
                radius: 16,
                tint: C.glassLight,
                blur: 32,
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: SingleChildScrollView(
                  child: Material(
                    type: MaterialType.transparency,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [for (final e in items) _entry(context, e)],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _entry(BuildContext context, PopupMenuEntry<T> e) {
    if (e is PopupMenuItem<T>) {
      final checked = e is CheckedPopupMenuItem<T> ? e.checked : null;
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          hoverColor: C.hoverOverlay,
          onTap: e.enabled ? () => Navigator.of(context).pop(e.value) : null,
          child: Container(
            constraints: const BoxConstraints(minHeight: 38),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            alignment: Alignment.centerLeft,
            child: DefaultTextStyle.merge(
              style: TextStyle(color: e.enabled ? C.text : C.faint, fontSize: 14),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              child: Row(children: [
                if (checked != null) ...[
                  SizedBox(width: 20, child: checked ? Icon(Icons.check_rounded, size: 18, color: C.accent) : null),
                  const SizedBox(width: 10),
                ],
                Flexible(child: e.child ?? const SizedBox.shrink()),
              ]),
            ),
          ),
        ),
      );
    }
    if (e is PopupMenuDivider) {
      return const Padding(padding: EdgeInsets.symmetric(vertical: 5), child: Divider(height: 1, color: C.divider));
    }
    return e;
  }
}

/// Ставит меню у точки/кнопки и не даёт ему вылезти за окно
class _MenuLayout extends SingleChildLayoutDelegate {
  final RelativeRect position;
  final Size screen;
  _MenuLayout(this.position, this.screen);

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) => BoxConstraints.loose(constraints.biggest);

  @override
  Offset getPositionForChild(Size size, Size child) {
    const m = 8.0;
    var x = position.left;
    var y = position.top;
    if (x + child.width > size.width - m) x = size.width - position.right - child.width; // справа места нет — к правому краю якоря
    if (y + child.height > size.height - m) y = size.height - position.bottom - child.height; // снизу места нет — вверх
    return Offset(x.clamp(m, size.width - child.width - m).toDouble(), y.clamp(m, size.height - child.height - m).toDouble());
  }

  @override
  bool shouldRelayout(_MenuLayout old) => old.position != position;
}

/// Кнопка «…» со стеклянным меню — замена PopupMenuButton
class GlassMenuButton<T> extends StatelessWidget {
  final String? tooltip;
  final Widget icon;
  final List<PopupMenuEntry<T>> Function(BuildContext) itemBuilder;
  final void Function(T value)? onSelected;
  const GlassMenuButton({super.key, this.tooltip, required this.icon, required this.itemBuilder, this.onSelected});

  Future<void> _open(BuildContext context) async {
    final box = context.findRenderObject() as RenderBox;
    final overlay = Navigator.of(context).overlay!.context.findRenderObject() as RenderBox;
    final rect = Rect.fromPoints(
      box.localToGlobal(box.size.bottomLeft(Offset.zero), ancestor: overlay),
      box.localToGlobal(box.size.bottomRight(Offset.zero), ancestor: overlay),
    );
    final v = await showGlassMenu<T>(
      context: context,
      position: RelativeRect.fromRect(rect, Offset.zero & overlay.size),
      items: itemBuilder(context),
    );
    if (v != null && context.mounted) onSelected?.call(v);
  }

  @override
  Widget build(BuildContext context) => IconButton(tooltip: tooltip, icon: icon, onPressed: () => _open(context));
}

/// Стеклянное окошко у кнопки, которое не закрывается от нажатий внутри: только от нажатия снаружи или Esc.
/// Содержимое само перестраивается (builder вызывается один раз), поэтому меняться может и размер окошка
Future<void> showGlassPopover({required BuildContext context, required WidgetBuilder builder, double width = 240}) {
  final box = context.findRenderObject() as RenderBox;
  final overlay = Navigator.of(context).overlay!.context.findRenderObject() as RenderBox;
  final rect = Rect.fromPoints(
    box.localToGlobal(box.size.bottomLeft(Offset.zero), ancestor: overlay),
    box.localToGlobal(box.size.bottomRight(Offset.zero), ancestor: overlay),
  );
  return Navigator.of(context).push(_GlassPopoverRoute(
    position: RelativeRect.fromRect(rect, Offset.zero & overlay.size),
    builder: builder,
    width: width,
  ));
}

class _GlassPopoverRoute extends PopupRoute<void> {
  final RelativeRect position;
  final WidgetBuilder builder;
  final double width;
  _GlassPopoverRoute({required this.position, required this.builder, required this.width});

  @override
  Color? get barrierColor => null;
  @override
  bool get barrierDismissible => true;
  @override
  String? get barrierLabel => 'Закрыть';
  @override
  Duration get transitionDuration => const Duration(milliseconds: 160);

  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) {
    final size = MediaQuery.sizeOf(context);
    return CustomSingleChildLayout(
      delegate: _MenuLayout(position, size),
      child: FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
        child: ScaleTransition(
          alignment: Alignment.topLeft,
          scale: Tween(begin: 0.96, end: 1.0).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
          child: SizedBox(
            width: width,
            child: GlassPanel(
              radius: 16,
              tint: C.glassLight,
              blur: 32,
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Material(type: MaterialType.transparency, child: Builder(builder: builder)),
            ),
          ),
        ),
      ),
    );
  }
}
