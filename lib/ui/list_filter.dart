import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../app.dart';
import '../core/models.dart';
import '../core/store.dart';
import '../core/text_fold.dart' as fold;
import 'glass_popup.dart';
import 'theme.dart';


/// Для поиска и сортировки: без регистра и диакритики, «ё» как «е»
String foldText(String s) => fold.foldText(s);

/// Ключ сортировки по алфавиту: ведущие кавычки, скобки и знаки не мешают
String sortKey(String s) {
  final f = foldText(s).trim();
  final cut = f.replaceFirst(RegExp(r'^[^\p{L}\p{N}]+', unicode: true), '');
  return cut.isEmpty ? f : cut;
}

/// Способ сортировки списка альбомов или исполнителей: по названию, по дате первой загрузки, по числу песен
class ListSort {
  final String mode; // 'name' | 'first' | 'count'
  final bool desc;
  const ListSort(this.mode, this.desc);

  /// Выбор запоминается для каждого списка отдельно: settings.view['sort.<ключ>'] = «режим|1 или 0»
  static ListSort read(Settings s, String key, {bool legacyDesc = false}) {
    final raw = s.view['sort.$key'];
    if (raw == null) return ListSort('name', legacyDesc);
    final i = raw.lastIndexOf('|');
    final mode = i < 0 ? raw : raw.substring(0, i);
    return ListSort(const ['name', 'first', 'count', 'date', 'author'].contains(mode) ? mode : 'name', i >= 0 && raw.substring(i + 1) == '1');
  }

  void write(Settings s, String key) => s.view['sort.$key'] = '$mode|${desc ? 1 : 0}';

  /// Какое направление выбирать у режима при первом переходе на него: новые и самые большие сверху, имена по алфавиту
  static bool defaultDesc(String mode) => mode != 'name' && mode != 'author';
}

/// Самая ранняя дата появления файла на Диске среди треков (ISO-строка; пусто, если дат нет)
String firstUpload(Iterable<Track> tracks) {
  var best = '';
  for (final t in tracks) {
    final s = t.added.isNotEmpty ? t.added : t.modified;
    if (s.isNotEmpty && (best.isEmpty || s.compareTo(best) < 0)) best = s;
  }
  return best;
}

/// Строка «поиск + сортировка» над списками исполнителей и альбомов
class SearchSortBar extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final String hint;
  final bool desc;
  final ValueChanged<String> onChanged;
  final VoidCallback onToggleSort;

  /// Режим сортировки ('name', 'first', 'count') и его смена; без [onMode] только А–Я / Я–А
  final String mode;
  final ValueChanged<String>? onMode;

  /// Справа от кнопки сортировки (например, выбор вида)
  final Widget? trailing;
  const SearchSortBar({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.hint,
    required this.desc,
    required this.onChanged,
    required this.onToggleSort,
    this.mode = 'name',
    this.onMode,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Flexible(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: TextField(
            controller: controller,
            focusNode: focusNode,
            onChanged: onChanged,
            decoration: InputDecoration(
              hintText: hint,
              prefixIcon: const Icon(Icons.search_rounded, size: 18),
              suffixIcon: controller.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close_rounded, size: 16),
                      onPressed: () {
                        controller.clear();
                        onChanged('');
                      },
                    ),
            ),
          ),
        ),
      ),
      const SizedBox(width: 12),
      if (onMode != null)
        GlassMenuButton<String>(
          tooltip: 'Сортировка',
          icon: const Icon(Icons.sort_rounded, size: 20),
          onSelected: onMode!,
          itemBuilder: (_) => [
            for (final (id, label) in const [('name', 'По названию'), ('first', 'По дате первой загрузки'), ('count', 'По числу песен')])
              PopupMenuItem(
                value: id,
                child: Row(children: [
                  SizedBox(width: 22, child: mode == id ? Icon(Icons.check_rounded, size: 16, color: C.accent) : null),
                  Text(label),
                ]),
              ),
          ],
        ),
      Tooltip(
        message: switch (mode) {
          'first' => desc ? 'Сначала новые, нажмите — сначала старые' : 'Сначала старые, нажмите — сначала новые',
          'count' => desc ? 'Сначала где больше песен, нажмите — где меньше' : 'Сначала где меньше песен, нажмите — где больше',
          _ => desc ? 'Сейчас Я–А, нажмите для А–Я' : 'Сейчас А–Я, нажмите для Я–А',
        },
        child: OutlinedButton.icon(
          onPressed: onToggleSort,
          icon: Icon(desc ? Icons.arrow_downward_rounded : Icons.arrow_upward_rounded, size: 16),
          label: Text(switch (mode) {
            'first' => desc ? 'Новые' : 'Старые',
            'count' => desc ? 'Больше' : 'Меньше',
            _ => desc ? 'Я–А' : 'А–Я',
          }),
        ),
      ),
      if (trailing != null) ...[const SizedBox(width: 16), trailing!],
    ]);
  }
}


/// Вид списка (сетка или список) и размер, отдельно для каждой вкладки. Хранится в настройках на этом компьютере.
class ViewPrefs {
  final Settings settings;
  final String key;
  final bool defaultGrid;
  final double gridMin, gridMax, gridDef, listMin, listMax, listDef;
  const ViewPrefs(
    this.settings,
    this.key, {
    required this.defaultGrid,
    this.gridMin = 120,
    this.gridMax = 260,
    this.gridDef = 170,
    this.listMin = 44,
    this.listMax = 88,
    this.listDef = 56,
  });

  bool get grid => settings.viewOf('$key.mode', defaultGrid ? 'grid' : 'list') == 'grid';
  double get min => grid ? gridMin : listMin;
  double get max => grid ? gridMax : listMax;

  /// Ширина плитки (сетка) или высота строки (список)
  double get size => settings.viewNum('$key.${grid ? 'grid' : 'list'}', grid ? gridDef : listDef).clamp(min, max).toDouble();

  void setGrid(bool v) => settings.view['$key.mode'] = v ? 'grid' : 'list';
  void setSize(double v) => settings.view['$key.${grid ? 'grid' : 'list'}'] = v.round().toString();
}

/// Переключатель «Сетка / Список» и ползунок размера
class ViewControls extends StatelessWidget {
  final ViewPrefs prefs;
  final VoidCallback onChanged;
  const ViewControls({super.key, required this.prefs, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final lib = Services.of(context).lib;
    void change(void Function() f, {bool save = true}) {
      f();
      if (save) lib.saveSettings();
      onChanged();
    }

    Widget mode(bool grid, IconData icon, String tip) {
      final on = prefs.grid == grid;
      return IconButton(
        tooltip: tip,
        visualDensity: VisualDensity.compact,
        onPressed: on ? null : () => change(() => prefs.setGrid(grid)),
        icon: Icon(icon, size: 20, color: on ? C.accent : C.muted),
      );
    }

    return Row(mainAxisSize: MainAxisSize.min, children: [
      mode(true, Icons.grid_view_rounded, 'Сеткой'),
      mode(false, Icons.view_list_rounded, 'Списком'),
      const SizedBox(width: 6),
      Tooltip(
        message: prefs.grid ? 'Размер плиток' : 'Высота строк',
        child: SizedBox(
          width: 130,
          child: Slider(
            value: prefs.size,
            min: prefs.min,
            max: prefs.max,
            onChanged: (v) => change(() => prefs.setSize(v), save: false),
            onChangeEnd: (v) => change(() => prefs.setSize(v)),
          ),
        ),
      ),
    ]);
  }
}

/// Сколько столбцов помещается при ширине [w] и каким тогда будет размер плитки (плитки не уже [tile], остаток делится поровну)
({int cols, double width}) fitGrid(double w, double tile, double gap) {
  final n = math.max(1, ((w + gap) / (tile + gap)).floor());
  return (cols: n, width: (w - gap * (n - 1)) / n);
}

/// Расположение плиток одной сетки: считается по номеру плитки
class _GridGeom {
  final int n;
  final double tw, th, gap, mainGap;
  const _GridGeom(this.n, this.tw, this.th, this.gap, this.mainGap);

  double get stride => th + mainGap;

  SliverGridGeometry at(int i, bool reverse, double crossExtent) {
    final col = i % n, row = i ~/ n;
    final x = col * (tw + gap);
    return SliverGridGeometry(
      scrollOffset: row * stride,
      crossAxisOffset: reverse ? crossExtent - x - tw : x,
      mainAxisExtent: th,
      crossAxisExtent: tw,
    );
  }

  int minIndex(double s) => stride > 0 ? n * (s ~/ stride) : 0;
  int maxIndex(double s) => stride > 0 ? math.max(0, n * (s / stride).ceil() - 1) : 0;
  double maxScroll(int count) => count == 0 ? 0 : stride * (((count - 1) ~/ n) + 1) - mainGap;
}

/// Раскладка «между двумя сетками»: плитки плавно переезжают с прежних мест на новые
class _LerpLayout extends SliverGridLayout {
  final _GridGeom a, b;
  final double t;
  final bool reverse;
  final double crossExtent;
  const _LerpLayout(this.a, this.b, this.t, this.reverse, this.crossExtent);

  @override
  SliverGridGeometry getGeometryForChildIndex(int i) {
    final x = a.at(i, reverse, crossExtent), y = b.at(i, reverse, crossExtent);
    double l(double p, double q) => p + (q - p) * t;
    return SliverGridGeometry(
      scrollOffset: l(x.scrollOffset, y.scrollOffset),
      crossAxisOffset: l(x.crossAxisOffset, y.crossAxisOffset),
      mainAxisExtent: l(x.mainAxisExtent, y.mainAxisExtent),
      crossAxisExtent: l(x.crossAxisExtent, y.crossAxisExtent),
    );
  }

  @override
  int getMinChildIndexForScrollOffset(double s) => math.min(a.minIndex(s), b.minIndex(s));

  @override
  int getMaxChildIndexForScrollOffset(double s) => math.max(a.maxIndex(s), b.maxIndex(s));

  @override
  double computeMaxScrollOffset(int count) {
    final x = a.maxScroll(count), y = b.maxScroll(count);
    return x + (y - x) * t;
  }
}

class _LerpDelegate extends SliverGridDelegate {
  final _GridGeom from, to;
  final double t;
  const _LerpDelegate(this.from, this.to, this.t);

  @override
  SliverGridLayout getLayout(SliverConstraints c) =>
      _LerpLayout(from, to, t, axisDirectionIsReversed(c.crossAxisDirection), c.crossAxisExtent);

  @override
  bool shouldRelayout(_LerpDelegate old) =>
      old.t != t || old.to.n != to.n || old.to.tw != to.tw || old.to.th != th || old.from.n != from.n || old.from.tw != from.tw;

  double get th => to.th;
}

/// Сетка плиток с подгонкой под ширину: плитки не уже [tile], под картинкой остаётся место [extra] на подписи.
///
/// Плитки следуют за шириной страницы, пока разворачивается левая или правая панель (CoverImage при этом
/// не перерисовывает картинку на каждом кадре). Как только последняя плитка перестала помещаться (или, наоборот, освободилось
/// место для ещё одного столбца), число столбцов меняется сразу, а плитки за ~250 мс плавно переезжают на новые места.
class AdaptiveGridSliver extends StatefulWidget {
  final double tile;
  final double extra;
  final double gap;
  final int count;
  final IndexedWidgetBuilder builder;
  const AdaptiveGridSliver({
    super.key,
    required this.tile,
    required this.extra,
    required this.count,
    required this.builder,
    this.gap = 20,
  });

  @override
  State<AdaptiveGridSliver> createState() => _AdaptiveGridSliverState();
}

class _AdaptiveGridSliverState extends State<AdaptiveGridSliver> with SingleTickerProviderStateMixin {
  late final AnimationController _ctl = AnimationController(vsync: this, duration: const Duration(milliseconds: 260))
    ..addListener(() => setState(() {}));
  _GridGeom? _from; // откуда плитки переезжают
  int? _cols; // сколько столбцов сейчас целевое
  _GridGeom? _lastTo; // последний показанный целевой расклад
  bool _retargetQueued = false;

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(AdaptiveGridSliver old) {
    super.didUpdateWidget(old);
    // Размер плиток поменяли ползунком — это не переезд, пересчитываем сразу
    if (old.tile != widget.tile || old.gap != widget.gap || old.extra != widget.extra) {
      _from = null;
      _cols = null;
      _ctl.value = 1;
    }
  }

  /// Расклад, который сейчас на экране между [_from] и целью
  _GridGeom _target(double w) {
    final f = fitGrid(w, widget.tile, widget.gap);
    return _GridGeom(f.cols, f.width, f.width + widget.extra, widget.gap, 20);
  }

  @override
  Widget build(BuildContext context) {
    return SliverLayoutBuilder(builder: (context, c) {
      final to = _target(c.crossAxisExtent);
      final cols = _cols;
      if (cols == null) {
        _cols = to.n;
        _from = to;
        _ctl.value = 1;
      } else if (cols != to.n && !_retargetQueued) {
        // Столбцов стало больше или меньше: запоминаем, как плитки лежат сейчас, и едем к новому раскладу
        final prev = _lastTo ?? to;
        final from = _from ?? prev;
        final t = _ctl.value;
        final dir = axisDirectionIsReversed(c.crossAxisDirection);
        _retargetQueued = true;
        final snapshot = _Snapshot(from, prev, t, dir, c.crossAxisExtent);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _retargetQueued = false;
          if (!mounted) return;
          _from = snapshot.freeze(widget.count);
          _cols = to.n;
          _ctl.forward(from: 0);
        });
      }
      _lastTo = to;
      final from = _from ?? to;
      final t = Curves.easeOutCubic.transform(_ctl.value.clamp(0.0, 1.0));
      return SliverGrid(
        gridDelegate: _LerpDelegate(from, to, t),
        delegate: SliverChildBuilderDelegate(widget.builder, childCount: widget.count),
      );
    });
  }
}

/// Снимок «где плитки лежат сейчас» посреди переезда. Прямоугольная сетка из двух слоёв сводится к одной:
/// если переезд почти закончился, берём конечную, иначе — ближайшую по числу столбцов
class _Snapshot {
  final _GridGeom from, to;
  final double t;
  final bool reverse;
  final double extent;
  const _Snapshot(this.from, this.to, this.t, this.reverse, this.extent);

  _GridGeom freeze(int count) {
    final k = Curves.easeOutCubic.transform(t.clamp(0.0, 1.0));
    return k >= 0.5 ? to : from;
  }
}

/// Обычная (не ленивая) сетка плиток для небольших списков, например «Коллекция»: число столбцов пересчитывается
/// сразу, как только последняя плитка перестала помещаться, и плитки за ~250 мс переезжают на новые места
class AnimatedTileGrid extends StatelessWidget {
  final double tile;
  final double extra;
  final double gap;
  final List<Widget> children;
  const AnimatedTileGrid({super.key, required this.tile, required this.extra, required this.children, this.gap = 20});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final w = box.maxWidth.isFinite ? box.maxWidth : tile;
      final f = fitGrid(w, tile, gap);
      final th = f.width + extra;
      final rows = children.isEmpty ? 0 : ((children.length - 1) ~/ f.cols) + 1;
      final height = rows == 0 ? 0.0 : rows * th + (rows - 1) * 24;
      const dur = Duration(milliseconds: 250);
      return SizedBox(
        height: height,
        child: Stack(clipBehavior: Clip.none, children: [
          for (var i = 0; i < children.length; i++)
            AnimatedPositioned(
              key: children[i].key ?? ValueKey('tg$i'),
              duration: dur,
              curve: Curves.easeOutCubic,
              left: (i % f.cols) * (f.width + gap),
              top: (i ~/ f.cols) * (th + 24),
              width: f.width,
              height: th,
              child: children[i],
            ),
        ]),
      );
    });
  }
}

/// Сетка с твёрдым размером плиток: он не зависит от того, какая ширина у страницы в этот кадр.
/// Если страница стала у́же, лишнее обрезается краем окна; если шире — справа остаётся пустое место.
class FixedTileGridDelegate extends SliverGridDelegate {
  final int columns;
  final double tileWidth, tileHeight, crossSpacing, mainSpacing;
  const FixedTileGridDelegate({
    required this.columns,
    required this.tileWidth,
    required this.tileHeight,
    required this.crossSpacing,
    required this.mainSpacing,
  });

  @override
  SliverGridLayout getLayout(SliverConstraints constraints) => SliverGridRegularTileLayout(
        crossAxisCount: columns,
        mainAxisStride: tileHeight + mainSpacing,
        crossAxisStride: tileWidth + crossSpacing,
        childMainAxisExtent: tileHeight,
        childCrossAxisExtent: tileWidth,
        reverseCrossAxis: axisDirectionIsReversed(constraints.crossAxisDirection),
      );

  @override
  bool shouldRelayout(FixedTileGridDelegate old) =>
      old.columns != columns ||
      old.tileWidth != tileWidth ||
      old.tileHeight != tileHeight ||
      old.crossSpacing != crossSpacing ||
      old.mainSpacing != mainSpacing;
}
