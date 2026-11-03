import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app.dart';
import '../core/models.dart';
import '../core/store.dart';
import 'glass_popup.dart';
import 'theme.dart';


/// Для поиска и сортировки: без регистра, «ё» как «е»
String foldText(String s) => s.toLowerCase().replaceAll('ё', 'е');

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

/// Сетка плиток с подгонкой под ширину: плитки не уже [tile], под картинкой остаётся место [extra] на подписи
class AdaptiveGridSliver extends StatelessWidget {
  final double tile;
  final double extra;
  final double gap;
  final int count;
  final IndexedWidgetBuilder builder;
  const AdaptiveGridSliver({super.key, required this.tile, required this.extra, required this.count, required this.builder, this.gap = 20});

  @override
  Widget build(BuildContext context) {
    return SliverLayoutBuilder(builder: (context, c) {
      final w = c.crossAxisExtent;
      final n = math.max(1, ((w + gap) / (tile + gap)).floor());
      final tw = (w - gap * (n - 1)) / n;
      return SliverGrid(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: n,
          mainAxisSpacing: 20,
          crossAxisSpacing: gap,
          mainAxisExtent: tw + extra,
        ),
        delegate: SliverChildBuilderDelegate(builder, childCount: count),
      );
    });
  }
}
