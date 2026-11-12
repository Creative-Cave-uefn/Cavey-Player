import 'package:flutter/material.dart';

import '../app.dart';
import 'theme.dart';

/// Значок справа внизу: что именно сейчас сохраняется на Диск (обложка, метаданные, аватарка…).
/// Пока он горит, друзья правку ещё не видят; не вышло — приходит сообщение, а прежнее возвращается
class SaveIndicator extends StatelessWidget {
  const SaveIndicator({super.key});

  /// Высота, которую значок занимает в углу (для башни уведомлений над ним)
  static const height = 46.0;

  @override
  Widget build(BuildContext context) {
    final saves = Services.of(context).lib.saves;
    return ListenableBuilder(
      listenable: saves,
      builder: (context, _) {
        final labels = saves.labels;
        final text = labels.isEmpty
            ? ''
            : labels.length == 1
                ? 'Сохраняю на Диск: ${labels.first}'
                : 'Сохраняю на Диск: ${labels.length} изменения';
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          transitionBuilder: (child, anim) => FadeTransition(
            opacity: anim,
            child: SlideTransition(position: Tween(begin: const Offset(0, 0.3), end: Offset.zero).animate(anim), child: child),
          ),
          child: labels.isEmpty
              ? const SizedBox.shrink(key: ValueKey('idle'))
              : Tooltip(
                  key: const ValueKey('busy'),
                  message: labels.join('\n'),
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 360),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xF0201C26),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: const Color(0x26FFFFFF)),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                      const SizedBox(width: 10),
                      Flexible(child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.muted, fontSize: 13))),
                    ]),
                  ),
                ),
        );
      },
    );
  }
}
