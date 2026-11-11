import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app.dart';
import '../core/image_tools.dart';
import '../core/log.dart';
import 'crop_dialog.dart';
import 'theme.dart';
import 'glass_popup.dart';

/// Картинка, подготовленная к загрузке на Диск
class PickedCover {
  final Uint8List bytes;
  final String ext;
  const PickedCover(this.bytes, this.ext);
}

const _imageExtensions = ['jpg', 'jpeg', 'jpe', 'jfif', 'png', 'webp', 'bmp', 'gif'];

/// Окно выбора файла с картинкой, затем кадрирование мышью. [aspect] — ширина к высоте рамки.
/// [keepAnimation] (аватарка, баннер): GIF берётся целиком, без кадрирования, чтобы не потерять анимацию
Future<PickedCover?> pickCoverFile(
  BuildContext context, {
  String title = 'Кадрирование обложки',
  double aspect = 1,
  int outWidth = 800,
  bool round = false,
  bool keepAnimation = false,
}) async {
  final f = await openFile(acceptedTypeGroups: const [
    XTypeGroup(label: 'Картинки', extensions: _imageExtensions),
  ]);
  if (f == null || !context.mounted) return null;
  final bytes = await f.readAsBytes();
  if (!context.mounted) return null;
  return prepareCover(context, bytes, f.name,
      title: title, aspect: aspect, outWidth: outWidth, round: round, keepAnimation: keepAnimation);
}

/// Окно «Вставить ссылку на картинку», затем те же шаги, что и для файла. null — отмена или не вышло
Future<PickedCover?> pickCoverFromUrl(
  BuildContext context, {
  String title = 'Кадрирование обложки',
  double aspect = 1,
  int outWidth = 800,
  bool round = false,
  bool keepAnimation = false,
}) async {
  final url = await _askImageUrl(context);
  if (url == null || !context.mounted) return null;
  final app = Services.of(context);
  app.lib.messages.add('Скачиваю картинку…');
  final Uint8List bytes;
  try {
    bytes = await downloadImageBytes(url);
  } catch (e) {
    AppLog.warn('Обложка по ссылке: не скачалась', e);
    final why = e is FormatException ? e.message : (e is TimeoutException ? 'сайт не отвечает' : '$e');
    app.lib.messages.add('Не получилось скачать картинку: $why');
    return null;
  }
  if (!context.mounted) return null;
  final name = Uri.tryParse(url)?.pathSegments.lastOrNull ?? 'картинка';
  return prepareCover(context, bytes, name,
      title: title, aspect: aspect, outWidth: outWidth, round: round, keepAnimation: keepAnimation);
}

/// Картинка из буфера обмена (скопированное изображение или файл), затем те же шаги, что и для файла.
/// Если в буфере ссылка на картинку, берётся она. null — отмена или не вышло
Future<PickedCover?> pickCoverFromClipboard(
  BuildContext context, {
  String title = 'Кадрирование обложки',
  double aspect = 1,
  int outWidth = 800,
  bool round = false,
  bool keepAnimation = false,
}) async {
  final app = Services.of(context);
  Uint8List? bytes;
  var name = 'буфер.png';
  try {
    final clip = await readClipboardImage();
    if (clip != null) {
      bytes = clip.bytes;
      name = clip.name;
    } else {
      final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim() ?? '';
      if (RegExp(r'^https?://\S+$').hasMatch(text)) {
        app.lib.messages.add('Скачиваю картинку по ссылке из буфера…');
        bytes = await downloadImageBytes(text);
        name = Uri.tryParse(text)?.pathSegments.lastOrNull ?? 'картинка';
      }
    }
  } catch (e) {
    AppLog.warn('Обложка из буфера: не вышло', e);
    final why = e is FormatException ? e.message : (e is TimeoutException ? 'не дождался ответа' : '$e');
    app.lib.messages.add('Не получилось взять картинку из буфера: $why');
    return null;
  }
  if (bytes == null) {
    app.lib.messages.add('В буфере нет картинки: скопируйте изображение, файл-картинку или ссылку на неё');
    return null;
  }
  if (!context.mounted) return null;
  return prepareCover(context, bytes, name,
      title: title, aspect: aspect, outWidth: outWidth, round: round, keepAnimation: keepAnimation);
}

/// Общие шаги для файла и ссылки: проверка, кадрирование, сжатие в JPEG (GIF без кадрирования, если [keepAnimation])
Future<PickedCover?> prepareCover(
  BuildContext context,
  Uint8List bytes,
  String name, {
  required String title,
  required double aspect,
  required int outWidth,
  required bool round,
  required bool keepAnimation,
}) async {
  if (keepAnimation && isGifBytes(bytes)) {
    final app = Services.of(context);
    if (!await _decodes(bytes)) {
      app.lib.messages.add('Не получилось открыть «$name» как картинку');
      return null;
    }
    if (bytes.length > maxGifBytes) {
      app.lib.messages.add('GIF больше 10 МБ: возьмите файл поменьше');
      return null;
    }
    // Анимация сохраняется: кадрировать GIF нельзя, на странице он показывается по центру (аватарка — кругом)
    return PickedCover(bytes, 'gif');
  }
  final cropped = await cropImageDialog(context, bytes, title: title, aspect: aspect, outWidth: outWidth, round: round);
  if (cropped == null) {
    // Либо отмена, либо файл не картинка; отличить по результату нельзя, сообщаем только про не-картинку
    if (context.mounted && !await _decodes(bytes)) {
      Services.of(context).lib.messages.add('Не получилось открыть «$name» как картинку');
    }
    return null;
  }
  // На Диск уходит сжатый JPEG: аватарка около 50 КБ, баннер около 250 КБ вместо мегабайт PNG
  final jpeg = await compressImage(cropped, maxSide: outWidth, quality: outWidth >= 1200 ? 82 : 85);
  return PickedCover(jpeg, identical(jpeg, cropped) ? 'png' : 'jpg');
}

/// Окно с полем для ссылки на картинку; подставляет ссылку из буфера обмена, если она там есть
Future<String?> _askImageUrl(BuildContext context) async {
  final field = TextEditingController();
  try {
    final clip = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim() ?? '';
    if (RegExp(r'^https?://\S+$').hasMatch(clip)) field.text = clip;
  } catch (_) {}
  if (!context.mounted) return null;
  final ok = await showGlassDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Картинка по ссылке', style: display(18)),
      content: SizedBox(
        width: 460,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(
            controller: field,
            autofocus: true,
            decoration: const InputDecoration(hintText: 'https://…/картинка.jpg', prefixIcon: Icon(Icons.link_rounded, size: 18)),
            onSubmitted: (_) => Navigator.pop(ctx, true),
          ),
          const SizedBox(height: 10),
          const Text('Прямая ссылка на файл: JPG, JFIF, PNG, WebP, GIF.', style: TextStyle(color: C.faint, fontSize: 12.5)),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена', style: TextStyle(color: C.muted))),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Загрузить')),
      ],
    ),
  );
  final text = field.text.trim();
  return ok == true && text.isNotEmpty ? text : null;
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
    app.lib.messages.add('Загружаю обложку…');
    // Первая попытка нередко упирается в разовый сбой Диска (тогда обложку приходилось отправлять второй раз):
    // повторяем сами до трёх раз с паузой
    Object? last;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        if (attempt > 0) await Future<void>.delayed(Duration(seconds: attempt * 2));
        final id = await app.lib.uploadCover(p.bytes, p.ext).timeout(coverUploadTimeout(p.bytes.length) + const Duration(seconds: 15));
        await app.covers.seed(id, p.bytes);
        return id;
      } catch (e) {
        last = e;
        AppLog.warn('Загрузка обложки: попытка ${attempt + 1} не удалась', e);
      }
    }
    app.lib.messages.add('Обложку загрузить не вышло: $last');
    return null;
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
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () async {
                    final p = await pickCoverFromUrl(context);
                    if (p != null) choice.pick(p);
                  },
                  icon: const Icon(Icons.link_rounded, size: 18),
                  label: const Text('Вставить ссылку…'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () async {
                    final p = await pickCoverFromClipboard(context);
                    if (p != null) choice.pick(p);
                  },
                  icon: const Icon(Icons.content_paste_rounded, size: 18),
                  label: const Text('Вставить из буфера'),
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
  final ok = await showGlassDialog<bool>(
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
