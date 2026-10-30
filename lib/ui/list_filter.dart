import 'package:flutter/material.dart';


/// Для поиска и сортировки: без регистра, «ё» как «е»
String foldText(String s) => s.toLowerCase().replaceAll('ё', 'е');

/// Ключ сортировки по алфавиту: ведущие кавычки, скобки и знаки не мешают
String sortKey(String s) {
  final f = foldText(s).trim();
  final cut = f.replaceFirst(RegExp(r'^[^\p{L}\p{N}]+', unicode: true), '');
  return cut.isEmpty ? f : cut;
}

/// Строка «поиск + сортировка А–Я / Я–А» над списками исполнителей и альбомов
class SearchSortBar extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final String hint;
  final bool desc;
  final ValueChanged<String> onChanged;
  final VoidCallback onToggleSort;
  const SearchSortBar({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.hint,
    required this.desc,
    required this.onChanged,
    required this.onToggleSort,
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
      Tooltip(
        message: desc ? 'Сейчас Я–А, нажмите для А–Я' : 'Сейчас А–Я, нажмите для Я–А',
        child: OutlinedButton.icon(
          onPressed: onToggleSort,
          icon: Icon(desc ? Icons.arrow_downward_rounded : Icons.arrow_upward_rounded, size: 16),
          label: Text(desc ? 'Я–А' : 'А–Я'),
        ),
      ),
    ]);
  }
}
