import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../app.dart';
import 'theme.dart';

/// Картинка, подготовленная к загрузке на Диск
class PickedCover {
  final Uint8List bytes;
  final String ext;
  const PickedCover(this.bytes, this.ext);
}

const _maxSide = 800; // больше обложке не нужно, а друзьям качать меньше
const _keepOriginalBytes = 700 * 1024;

String _sniffExt(Uint8List b) {
  if (b.length > 12) {
    if (b[0] == 0x89 && b[1] == 0x50) return 'png';
    if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) return 'gif';
    if (b[0] == 0x42 && b[1] == 0x4D) return 'bmp';
    if (b[0] == 0x52 && b[1] == 0x49 && b[8] == 0x57 && b[9] == 0x45) return 'webp';
  }
  return 'jpg';
}

/// Проверяет, что это картинка, и уменьшает слишком большую до 800 пикселей.
/// Маленькие файлы остаются как есть, большие превращаются в PNG. null — не картинка.
Future<PickedCover?> prepareCover(Uint8List src) async {
  try {
    final codec = await ui.instantiateImageCodec(src);
    final frame = await codec.getNextFrame();
    final w = frame.image.width;
    final h = frame.image.height;
    frame.image.dispose();
    codec.dispose();
    if (w <= 0 || h <= 0) return null;
    if (w <= _maxSide && h <= _maxSide && src.length <= _keepOriginalBytes) return PickedCover(src, _sniffExt(src));

    final long = w > h ? w : h;
    final scale = long > _maxSide ? _maxSide / long : 1.0;
    final codec2 = await ui.instantiateImageCodec(
      src,
      targetWidth: (w * scale).round().clamp(1, 100000).toInt(),
      targetHeight: (h * scale).round().clamp(1, 100000).toInt(),
    );
    final frame2 = await codec2.getNextFrame();
    final data = await frame2.image.toByteData(format: ui.ImageByteFormat.png);
    frame2.image.dispose();
    codec2.dispose();
    if (data == null) return null;
    return PickedCover(data.buffer.asUint8List(), 'png');
  } catch (_) {
    return null;
  }
}

/// Окно выбора файла с картинкой
Future<PickedCover?> pickCoverFile(BuildContext context) async {
  final f = await openFile(acceptedTypeGroups: const [
    XTypeGroup(label: 'Картинки', extensions: ['jpg', 'jpeg', 'png', 'webp', 'bmp', 'gif']),
  ]);
  if (f == null) return null;
  final picked = await prepareCover(await f.readAsBytes());
  if (picked == null && context.mounted) {
    Services.of(context).lib.messages.add('Не получилось открыть «${f.name}» как картинку');
  }
  return picked;
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
