import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../app.dart';
import '../core/image_tools.dart';
import 'crop_dialog.dart';
import 'theme.dart';

/// Картинка, подготовленная к загрузке на Диск
class PickedCover {
  final Uint8List bytes;
  final String ext;
  const PickedCover(this.bytes, this.ext);
}

/// Окно выбора файла с картинкой, затем кадрирование мышью. [aspect] — ширина к высоте рамки.
Future<PickedCover?> pickCoverFile(
  BuildContext context, {
  String title = 'Кадрирование обложки',
  double aspect = 1,
  int outWidth = 800,
  bool round = false,
}) async {
  final f = await openFile(acceptedTypeGroups: const [
    XTypeGroup(label: 'Картинки', extensions: ['jpg', 'jpeg', 'png', 'webp', 'bmp', 'gif']),
  ]);
  if (f == null || !context.mounted) return null;
  final bytes = await f.readAsBytes();
  if (!context.mounted) return null;
  final cropped = await cropImageDialog(context, bytes, title: title, aspect: aspect, outWidth: outWidth, round: round);
  if (cropped == null) {
    // Либо отмена, либо файл не картинка; отличить по результату нельзя, сообщаем только про не-картинку
    if (context.mounted && !await _decodes(bytes)) {
      Services.of(context).lib.messages.add('Не получилось открыть «${f.name}» как картинку');
    }
    return null;
  }
  // На Диск уходит сжатый JPEG: аватарка около 50 КБ, баннер около 250 КБ вместо мегабайт PNG
  final jpeg = await compressImage(cropped, maxSide: outWidth, quality: outWidth >= 1200 ? 82 : 85);
  return PickedCover(jpeg, identical(jpeg, cropped) ? 'png' : 'jpg');
}

Future<bool> _decodes(Uint8List b) async {
  try {
    final codec = await ui.instantiateImageCodec(b, targetWidth: 8);
    codec.dispose();
    return true;
  } catch (_) {
    return false;
  }
}

/// Что человек выбрал в окне правки: новую картинку, «вернуть исходную» или ничего
class CoverChoice extends ChangeNotifier {
  PickedCover? picked;
  bool reset = false;

  bool get changed => picked != null || reset;

  void pick(PickedCover p) {
    picked = p;
    reset = false;
    notifyListeners();
  }

  void clear() {
    picked = null;
    reset = true;
    notifyListeners();
  }

  void undo() {
    picked = null;
    reset = false;
    notifyListeners();
  }

  /// Загружает выбранное на Диск. Возвращает значение для поля обложки:
  /// id картинки, пустую строку («вернуть исходную») или null, если менять нечего или загрузка не вышла
  Future<String?> commit(BuildContext context) async {
    if (reset) return '';
    final p = picked;
    if (p == null) return null;
    final app = Services.of(context);
    try {
      app.lib.messages.add('Загружаю обложку…');
      final id = await app.lib.uploadCover(p.bytes, p.ext);
      await app.covers.seed(id, p.bytes);
      return id;
    } catch (e) {
      app.lib.messages.add('Обложку загрузить не вышло: $e');
      return null;
    }
  }
}

/// Превью обложки и кнопки выбора — для окон правки трека, альбома и плейлиста
class CoverEditorView extends StatelessWidget {
  final CoverChoice choice;

  /// Как выглядит обложка сейчас
  final Widget current;

  /// Есть ли что сбрасывать (своя обложка уже стоит)
  final bool canReset;
  final String? note;
  const CoverEditorView({super.key, required this.choice, required this.current, required this.canReset, this.note});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: choice,
      builder: (context, _) {
        final Widget preview;
        if (choice.picked != null) {
          preview = Image.memory(choice.picked!.bytes, fit: BoxFit.cover);
        } else if (choice.reset) {
          preview = Container(
            color: C.raised,
            alignment: Alignment.center,
            padding: const EdgeInsets.all(10),
            child: const Text('Будет обложка из файлов', textAlign: TextAlign.center, style: TextStyle(color: C.muted, fontSize: 12)),
          );
        } else {
          preview = current;
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            ClipRRect(borderRadius: BorderRadius.circular(10), child: SizedBox.square(dimension: 120, child: preview)),
            const SizedBox(width: 18),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                OutlinedButton.icon(
                  onPressed: () async {
                    final p = await pickCoverFile(context);
                    if (p != null) choice.pick(p);
                  },
                  icon: const Icon(Icons.image_outlined, size: 18),
                  label: const Text('Выбрать файл…'),
                ),
                if (canReset && !choice.reset) ...[
                  const SizedBox(height: 8),
                  TextButton(onPressed: choice.clear, child: const Text('Вернуть исходную', style: TextStyle(color: C.muted))),
                ],
                if (choice.changed) ...[
                  const SizedBox(height: 4),
                  TextButton(onPressed: choice.undo, child: const Text('Отменить выбор', style: TextStyle(color: C.muted))),
                ],
              ]),
            ),
          ]),
          if (note != null) ...[
            const SizedBox(height: 10),
            Text(note!, style: const TextStyle(color: C.faint, fontSize: 12, height: 1.4)),
          ],
        ]);
      },
    );
  }
}

/// Отдельное окно «Изменить обложку» (альбом, плейлист).
/// Возвращает значение для поля обложки: id картинки, '' — вернуть исходную, null — отмена.
Future<String?> coverDialog(
  BuildContext context, {
  required String title,
  required Widget current,
  required bool canReset,
  String? note,
}) async {
  final choice = CoverChoice();
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title, style: display(18)),
      content: SizedBox(width: 380, child: CoverEditorView(choice: choice, current: current, canReset: canReset, note: note)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена', style: TextStyle(color: C.muted))),
        ListenableBuilder(
          listenable: choice,
          builder: (_, __) => FilledButton(
            onPressed: choice.changed ? () => Navigator.pop(ctx, true) : null,
            child: const Text('Сохранить'),
          ),
        ),
      ],
    ),
  );
  if (ok != true || !context.mounted) return null;
  return choice.commit(context);
}
