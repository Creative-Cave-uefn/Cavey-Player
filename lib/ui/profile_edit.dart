import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../app.dart';
import 'cover_picker.dart';
import 'theme.dart';
import 'widgets.dart';
import 'glass_popup.dart';
import 'profile_view.dart' show bannerPicture;
import '../core/library.dart' show LibraryController;

/// Окно «Мой профиль»: ник, аватарка и баннер. Картинки кадрируются мышью и ложатся в общую папку на Диске.
Future<void> editProfileDialog(BuildContext context) async {
  final app = Services.of(context);
  final lib = app.lib;
  final me = lib.me;
  if (me == null) return;
  final nick = TextEditingController(text: lib.profileNick(me) ?? '');
  final avatar = CoverChoice();
  final banner = CoverChoice();
  final startBlur = lib.profileBannerBlur(me);
  final blur = ValueNotifier<double>(startBlur);
  final googleName = lib.data.members[me] ?? me.split('@').first;
  final ok = await showGlassDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Мой профиль', style: display(18)),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            TextField(
              controller: nick,
              maxLength: 32,
              decoration: InputDecoration(
                labelText: 'Ник',
                hintText: googleName,
                helperText: 'Его увидят все друзья. Если оставить пустым, будет имя из Google.',
                counterText: '',
              ),
            ),
            const SizedBox(height: 22),
            const Text('Аватарка', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 10),
            _ImageField(
              choice: avatar,
              width: 96,
              height: 96,
              round: true,
              aspect: 1,
              outWidth: 512,
              cropTitle: 'Кадрирование аватарки',
              canReset: lib.profileAvatar(me) != null,
              current: Avatar(email: me, name: googleName, size: 96),
            ),
            const SizedBox(height: 22),
            const Text('Баннер', style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            const Text('Фон шапки вашей страницы. JPG, JFIF, PNG, WebP или GIF: GIF будет двигаться, но не кадрируется (до 10 МБ).',
                style: TextStyle(color: C.faint, fontSize: 12)),
            const SizedBox(height: 10),
            _ImageField(
              choice: banner,
              blur: blur,
              width: 270,
              height: 90,
              round: false,
              aspect: 3,
              outWidth: 1600,
              cropTitle: 'Кадрирование баннера',
              canReset: lib.profileBanner(me) != null,
              current: lib.profileBanner(me) == null
                  ? Container(
                      color: C.raised,
                      alignment: Alignment.center,
                      child: const Text('Баннера нет', style: TextStyle(color: C.muted, fontSize: 12)),
                    )
                  : CoverImage(track: null, fileId: lib.profileBanner(me), label: '', size: 270, radius: 0),
            ),
            const SizedBox(height: 14),
            // Предпросмотр — сам баннер выше: он меняется вместе с ползунком
            ListenableBuilder(
              listenable: Listenable.merge([blur, banner]),
              builder: (context, _) {
                final hasBanner = banner.picked != null || (lib.profileBanner(me) != null && !banner.reset);
                return Opacity(
                  opacity: hasBanner ? 1 : 0.45,
                  child: Row(children: [
                    const Text('Размытие', style: TextStyle(color: C.muted, fontSize: 13)),
                    Expanded(
                      child: Slider(
                        value: blur.value,
                        min: 0,
                        max: LibraryController.maxBannerBlur,
                        divisions: 24,
                        label: blur.value == 0 ? 'нет' : blur.value.toStringAsFixed(0),
                        onChanged: hasBanner ? (v) => blur.value = v : null,
                      ),
                    ),
                    SizedBox(
                      width: 34,
                      child: Text(blur.value == 0 ? 'нет' : blur.value.toStringAsFixed(0),
                          textAlign: TextAlign.right, style: const TextStyle(color: C.faint, fontSize: 12.5)),
                    ),
                  ]),
                );
              },
            ),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена', style: TextStyle(color: C.muted))),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Сохранить')),
      ],
    ),
  );
  final text = nick.text.trim();
  final newBlur = blur.value;
  nick.dispose();
  blur.dispose();
  if (ok != true || !context.mounted) return;
  final blurChanged = (newBlur - startBlur).abs() > 0.01;
  final nickChanged = text != (lib.profileNick(me) ?? '');
  lib.setProfile(
    nick: text,
    bannerBlur: blurChanged ? newBlur : null,
    label: nickChanged || blurChanged ? 'Профиль' : null,
  );
  // Картинки видны сразу, а на Диск грузятся в фоне; не вышло — вернётся прежняя
  avatar.save(context,
      label: 'Аватарка',
      shown: [('u:$me', 'av')],
      apply: (id, token) => lib.setProfile(avatar: id, token: token, label: token == null ? 'Аватарка' : null));
  banner.save(context,
      label: 'Баннер профиля',
      shown: [('u:$me', 'bn')],
      apply: (id, token) => lib.setProfile(banner: id, token: token, label: token == null ? 'Баннер профиля' : null));
}

class _ImageField extends StatelessWidget {
  final CoverChoice choice;

  /// Для баннера: размытие, которое сейчас выбрано, — предпросмотр показывает итог (с тем же затемнением, что на странице)
  final ValueListenable<double>? blur;
  final double width;
  final double height;
  final bool round;
  final double aspect;
  final int outWidth;
  final String cropTitle;
  final bool canReset;
  final Widget current;
  const _ImageField({
    this.blur,
    required this.choice,
    required this.width,
    required this.height,
    required this.round,
    required this.aspect,
    required this.outWidth,
    required this.cropTitle,
    required this.canReset,
    required this.current,
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
            child: const Text('Будет по умолчанию', textAlign: TextAlign.center, style: TextStyle(color: C.muted, fontSize: 12)),
          );
        } else {
          preview = current;
        }
        final b = blur;
        final shown = b == null || choice.reset || (choice.picked == null && !canReset)
            ? preview
            : ValueListenableBuilder<double>(
                valueListenable: b,
                builder: (_, v, __) => Stack(fit: StackFit.expand, children: [
                  // в окне баннер в три раза меньше, чем на странице, — размытие уменьшаем так же
                  ClipRect(child: bannerPicture(blur: v * 0.35, child: preview)),
                  ColoredBox(color: Colors.black.withValues(alpha: 0.4)),
                ]),
              );
        final box = SizedBox(width: width, height: height, child: shown);
        return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          round ? ClipOval(child: box) : ClipRRect(borderRadius: BorderRadius.circular(8), child: box),
          const SizedBox(width: 18),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              OutlinedButton.icon(
                onPressed: () async {
                  final p = await pickCoverFile(context,
                      title: cropTitle, aspect: aspect, outWidth: outWidth, round: round, keepAnimation: true);
                  if (p != null) choice.pick(p);
                },
                icon: const Icon(Icons.image_outlined, size: 18),
                label: const Text('Выбрать файл…'),
              ),
              const SizedBox(height: 6),
              OutlinedButton.icon(
                onPressed: () async {
                  final p = await pickCoverFromUrl(context,
                      title: cropTitle, aspect: aspect, outWidth: outWidth, round: round, keepAnimation: true);
                  if (p != null) choice.pick(p);
                },
                icon: const Icon(Icons.link_rounded, size: 18),
                label: const Text('Вставить ссылку…'),
              ),
              const SizedBox(height: 6),
              OutlinedButton.icon(
                onPressed: () async {
                  final p = await pickCoverFromClipboard(context,
                      title: cropTitle, aspect: aspect, outWidth: outWidth, round: round, keepAnimation: true);
                  if (p != null) choice.pick(p);
                },
                icon: const Icon(Icons.content_paste_rounded, size: 18),
                label: const Text('Вставить из буфера'),
              ),
              if (canReset && !choice.reset)
                TextButton(onPressed: choice.clear, child: const Text('Убрать', style: TextStyle(color: C.muted))),
              if (choice.changed)
                TextButton(onPressed: choice.undo, child: const Text('Отменить выбор', style: TextStyle(color: C.muted))),
            ]),
          ),
        ]);
      },
    );
  }
}
