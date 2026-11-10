import 'package:flutter/material.dart';

import 'glass_popup.dart';
import 'theme.dart';

/// Причины удаления трека. Ключ уходит в общую библиотеку, подпись видит загрузивший.
const deleteReasons = <String, String>{
  'dup': 'Дубликат',
  'bad': 'Битый файл или плохое качество',
  'tags': 'Неверные теги или не тот трек',
  'other': 'Другое',
};

String deleteReasonLabel(String key) => deleteReasons[key] ?? deleteReasons['other']!;

class DeleteChoice {
  final String reason;
  final String note;
  const DeleteChoice(this.reason, this.note);
}

/// Спрашивает, удалять ли, и почему. Причину увидит друг, если файл загружал он (ему придёт предложение удалить).
/// null — человек передумал.
Future<DeleteChoice?> askDeleteReason(
  BuildContext context, {
  required String title,
  required String text,
  String action = 'Удалить',
  String initial = 'other',
}) {
  var reason = initial;
  final note = TextEditingController();
  return showGlassDialog<DeleteChoice>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: Text(title, style: display(18)),
        content: SizedBox(
          width: 400,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(text, style: const TextStyle(color: C.muted, height: 1.45)),
            const SizedBox(height: 14),
            const Text('Почему удаляете?', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            for (final e in deleteReasons.entries)
              InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => setState(() => reason = e.key),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
                  child: Row(children: [
                    Icon(reason == e.key ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                        size: 20, color: reason == e.key ? C.accent : C.faint),
                    const SizedBox(width: 10),
                    Expanded(child: Text(e.value)),
                  ]),
                ),
              ),
            const SizedBox(height: 8),
            TextField(
              controller: note,
              maxLength: 200,
              maxLines: 2,
              minLines: 1,
              decoration: const InputDecoration(hintText: 'Комментарий (необязательно)', counterText: ''),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена', style: TextStyle(color: C.muted))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: C.danger),
            onPressed: () => Navigator.pop(ctx, DeleteChoice(reason, note.text.trim())),
            child: Text(action),
          ),
        ],
      ),
    ),
  );
}
