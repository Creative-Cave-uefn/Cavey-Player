import 'package:flutter/material.dart';

import '../app.dart';
import '../core/models.dart';
import '../core/store.dart' show Settings;
import 'glass_popup.dart';
import 'theme.dart';
import 'widgets.dart';

/// Человек, чьи загрузки есть в списке, и сколько их
class Uploader {
  final String email;
  final int count;
  const Uploader(this.email, this.count);
}

/// Кто загрузил треки из списка: по убыванию числа загрузок, без повторов по регистру почты
List<Uploader> uploadersOf(Iterable<Track> tracks) {
  final counts = <String, int>{};
  for (final t in tracks) {
    final by = t.by.trim().toLowerCase();
    if (by.isEmpty) continue;
    counts[by] = (counts[by] ?? 0) + 1;
  }
  final list = [for (final e in counts.entries) Uploader(e.key, e.value)]
    ..sort((a, b) => b.count != a.count ? b.count.compareTo(a.count) : a.email.compareTo(b.email));
  return list;
}

/// Пустой выбор — фильтр выключен
bool passesUploaders(Set<String> chosen, String by) => chosen.isEmpty || chosen.contains(by.trim().toLowerCase());

Set<String> decodeUploaders(String? raw) =>
    {for (final p in (raw ?? '').split(',')) if (p.trim().isNotEmpty) p.trim().toLowerCase()};

String encodeUploaders(Set<String> chosen) => (chosen.toList()..sort()).join(',');

/// Выбор «Кто загрузил» запоминается отдельно для каждой вкладки
String uploaderFilterKey(String page) => 'filter.by.$page';

Set<String> loadUploaderFilter(Settings settings, String page) => decodeUploaders(settings.view[uploaderFilterKey(page)]);

void saveUploaderFilter(AppServices app, String page, Set<String> chosen) {
  if (chosen.isEmpty) {
    app.settings.view.remove(uploaderFilterKey(page));
  } else {
    app.settings.view[uploaderFilterKey(page)] = encodeUploaders(chosen);
  }
  app.lib.viewChanged();
}

/// Кнопка-переключатель того же вида, что и остальные кнопки ряда; включённая подсвечена цветом акцента
class ToggleOutlineButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool on;
  final VoidCallback? onPressed;
  final String? tooltip;
  const ToggleOutlineButton({super.key, required this.icon, required this.label, required this.on, required this.onPressed, this.tooltip});

  @override
  Widget build(BuildContext context) {
    final button = OutlinedButton.icon(
      onPressed: onPressed,
      style: on
          ? OutlinedButton.styleFrom(
              foregroundColor: C.accent,
              backgroundColor: C.accent.withValues(alpha: 0.14),
              side: BorderSide(color: C.accent.withValues(alpha: 0.7)),
            )
          : null,
      icon: Icon(icon, size: 18),
      label: Text(label),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

/// «Кто загрузил»: окошко с людьми, можно отметить нескольких
class UploaderFilterButton extends StatelessWidget {
  final List<Uploader> people;
  final Set<String> chosen;
  final ValueChanged<Set<String>> onChanged;
  const UploaderFilterButton({super.key, required this.people, required this.chosen, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final lib = Services.of(context).lib;
    final label = chosen.isEmpty
        ? 'Кто загрузил'
        : chosen.length == 1
            ? lib.firstNameOf(chosen.first)
            : 'Загрузили: ${chosen.length}';
    return Builder(
      builder: (btn) => ToggleOutlineButton(
        icon: Icons.people_alt_outlined,
        label: label,
        on: chosen.isNotEmpty,
        onPressed: people.isEmpty
            ? null
            : () => showGlassPopover(
                  context: btn,
                  width: 290,
                  builder: (_) => _UploaderPanel(people: people, initial: chosen, onChanged: onChanged),
                ),
      ),
    );
  }
}

class _UploaderPanel extends StatefulWidget {
  final List<Uploader> people;
  final Set<String> initial;
  final ValueChanged<Set<String>> onChanged;
  const _UploaderPanel({required this.people, required this.initial, required this.onChanged});

  @override
  State<_UploaderPanel> createState() => _UploaderPanelState();
}

class _UploaderPanelState extends State<_UploaderPanel> {
  late Set<String> _chosen = {...widget.initial};

  void _set(Set<String> next) {
    setState(() => _chosen = next);
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final lib = Services.of(context).lib;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 420),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 8, 8, 4),
          child: Row(children: [
            const Expanded(child: Text('Кто загрузил', style: TextStyle(color: C.muted, fontSize: 12.5, fontWeight: FontWeight.w600))),
            if (_chosen.isNotEmpty)
              TextButton(
                style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 10)),
                onPressed: () => _set({}),
                child: const Text('Сбросить'),
              ),
          ]),
        ),
        Flexible(
          child: ListView(
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            children: [
              for (final p in widget.people)
                InkWell(
                  onTap: () => _set(_chosen.contains(p.email) ? ({..._chosen}..remove(p.email)) : {..._chosen, p.email}),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 7),
                    child: Row(children: [
                      Avatar(email: p.email, name: lib.nameOf(p.email), size: 26),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          lib.isMyAccount(p.email) ? '${lib.nameOf(p.email)} (вы)' : lib.nameOf(p.email),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 14),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text('${p.count}', style: const TextStyle(color: C.faint, fontSize: 12.5)),
                      SizedBox(
                        width: 28,
                        child: _chosen.contains(p.email) ? Icon(Icons.check_rounded, size: 18, color: C.accent) : null,
                      ),
                    ]),
                  ),
                ),
            ],
          ),
        ),
      ]),
    );
  }
}
