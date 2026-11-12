import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart' show sha1;
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
      // Больше предела: сжимаем сами, чтобы файл можно было поставить
      app.lib.messages.add('GIF больше 10 МБ, сжимаю — это может занять до минуты…');
      final small = await shrinkGif(bytes, maxGifBytes - 256 * 1024);
      if (small == null) {
        app.lib.messages.add('Не получилось сжать GIF до 10 МБ: возьмите файл поменьше');
        return null;
      }
      app.lib.messages.add('GIF сжат: ${(bytes.length / 1048576).toStringAsFixed(1)} → ${(small.length / 1048576).toStringAsFixed(1)} МБ');
      return PickedCover(small, 'gif');
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

  /// Правка обложки, которую надо сделать после «Сохранить»: возвращает null, если менять нечего.
  /// Картинка сразу показывается у [shown] ('альбом|поле'…), на Диск грузится в фоне, а [apply] получает id загруженной
  /// картинки (или '' для «вернуть исходную») и токен сохранения, который нужно передать в lib.setMeta
  void save(BuildContext context,
      {required String label, required List<(String, String)> shown, required void Function(String coverId, int? token) apply}) {
    if (reset) {
      apply('', null);
      return;
    }
    final p = picked;
    if (p == null) return;
    unawaited(saveCoverInBackground(Services.of(context), p, label: label, shown: shown, apply: apply));
  }
}

/// Меняет обложку «в фоне»: новая картинка сразу видна везде в приложении, внизу справа горит значок сохранения,
/// на Диск картинка грузится позже. Не вышло — прежняя обложка возвращается и приходит сообщение об ошибке
Future<void> saveCoverInBackground(
  AppServices app,
  PickedCover p, {
  required String label,
  required List<(String, String)> shown,
  required void Function(String coverId, int? token) apply,
}) async {
  final lib = app.lib;
  final temp = 'local-${sha1.convert(p.bytes)}';
  final token = lib.beginSave(label);
  try {
    await app.covers.seed(temp, p.bytes);
  } catch (_) {}
  for (final s in shown) {
    lib.showTemporary(s.$1, s.$2, temp);
  }
  try {
    // Первая попытка нередко упирается в разовый сбой Диска: повторяем сами до трёх раз с паузой
    Object? last;
    String? id;
    for (var attempt = 0; attempt < 3 && id == null; attempt++) {
      try {
        if (attempt > 0) await Future<void>.delayed(Duration(seconds: attempt * 2));
        id = await lib.uploadCover(p.bytes, p.ext).timeout(coverUploadTimeout(p.bytes.length) + const Duration(seconds: 15));
      } catch (e) {
        last = e;
        AppLog.warn('Загрузка обложки: попытка ${attempt + 1} не удалась', e);
      }
    }
    if (id == null) {
      lib.saves.end(token);
      lib.messages.add('Не удалось загрузить на Диск: $label. Прежнее вернулось. $last');
      return;
    }
    await app.covers.seed(id, p.bytes);
    apply(id, token);
    lib.finishIfIdle(token);
  } finally {
    for (final s in shown) {
      lib.hideTemporary(s.$1, s.$2);
    }
  }
}

/// Связка между кнопкой «Из Deezer» рядом с обложкой и логикой поиска, которая живёт в другом месте окна
class DeezerCoverHook {
  final ValueNotifier<bool> busy = ValueNotifier(false);
  Future<void> Function()? run;
}

/// Раскладка кнопок рядом с обложкой
enum CoverEditorLayout {
  /// Три кнопки столбиком по высоте обложки: файлом, из буфера, по ссылке (плейлист)
  column,

  /// Две колонки: слева файлом и из буфера, справа по ссылке и поиск в Deezer (альбом, трек)
  twoColumns,
}

/// Превью обложки и кнопки выбора — для окон правки трека, альбома и плейлиста
class CoverEditorView extends StatelessWidget {
  final CoverChoice choice;

  /// Как выглядит обложка сейчас
  final Widget current;

  /// Есть ли что сбрасывать (своя обложка уже стоит)
  final bool canReset;
  final String? note;
  final CoverEditorLayout layout;

  /// Для раскладки [CoverEditorLayout.twoColumns]: кнопка «Из Deezer» (поиск ведёт окно, а кнопка стоит здесь)
  final DeezerCoverHook? deezer;

  /// Что написано на месте обложки после «Удалить»
  final String resetText;
  const CoverEditorView({
    super.key,
    required this.choice,
    required this.current,
    required this.canReset,
    this.note,
    this.layout = CoverEditorLayout.twoColumns,
    this.deezer,
    this.resetText = 'Будет обложка из файлов',
  });

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
            child: Text(resetText, textAlign: TextAlign.center, style: const TextStyle(color: C.muted, fontSize: 12)),
          );
        } else {
          preview = current;
        }
        Widget button(IconData icon, String label, Future<PickedCover?> Function() pick, {double? height}) => SizedBox(
              height: height,
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () async {
                  final p = await pick();
                  if (p != null) choice.pick(p);
                },
                icon: Icon(icon, size: 18),
                label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            );
        final file = (Icons.image_outlined, 'Файлом', () => pickCoverFile(context, keepAnimation: true));
        final clip = (Icons.content_paste_rounded, 'Из буфера', () => pickCoverFromClipboard(context, keepAnimation: true));
        final link = (Icons.link_rounded, 'По ссылке', () => pickCoverFromUrl(context, keepAnimation: true));
        final Widget buttons;
        if (layout == CoverEditorLayout.column) {
          // Три кнопки делят высоту обложки поровну: верх первой на уровне верха обложки, низ последней — низа
          buttons = Column(children: [
            for (final (i, b) in [file, clip, link].indexed) ...[
              if (i > 0) const SizedBox(height: 6),
              Expanded(child: button(b.$1, b.$2, b.$3)),
            ],
          ]);
        } else {
          buttons = Center(
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  button(file.$1, file.$2, file.$3, height: 40),
                  const SizedBox(height: 8),
                  button(clip.$1, clip.$2, clip.$3, height: 40),
                ]),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  button(link.$1, link.$2, link.$3, height: 40),
                  if (deezer != null) ...[
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 40,
                      width: double.infinity,
                      child: ValueListenableBuilder<bool>(
                        valueListenable: deezer!.busy,
                        builder: (_, busy, __) => OutlinedButton.icon(
                          onPressed: busy ? null : () => deezer!.run?.call(),
                          icon: busy
                              ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.image_search_rounded, size: 18),
                          label: const Text('Из Deezer', maxLines: 1, overflow: TextOverflow.ellipsis),
                        ),
                      ),
                    ),
                  ],
                ]),
              ),
            ]),
          );
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              ClipRRect(borderRadius: BorderRadius.circular(10), child: SizedBox.square(dimension: 120, child: preview)),
              if ((canReset && !choice.reset) || choice.changed)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: SizedBox(
                    width: 120,
                    child: Wrap(runSpacing: 2, children: [
                      if (canReset && !choice.reset)
                        InkWell(
                          onTap: choice.clear,
                          borderRadius: BorderRadius.circular(6),
                          child: const Padding(
                            padding: EdgeInsets.symmetric(vertical: 3),
                            child: Text('Удалить', style: TextStyle(color: C.muted, fontSize: 13)),
                          ),
                        ),
                      if (choice.changed)
                        InkWell(
                          onTap: choice.undo,
                          borderRadius: BorderRadius.circular(6),
                          child: const Padding(
                            padding: EdgeInsets.symmetric(vertical: 3),
                            child: Text('Отменить выбор', style: TextStyle(color: C.muted, fontSize: 13)),
                          ),
                        ),
                    ]),
                  ),
                ),
            ]),
            const SizedBox(width: 18),
            Expanded(child: SizedBox(height: 120, child: buttons)),
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
