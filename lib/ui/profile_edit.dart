import 'package:flutter/material.dart';

import '../app.dart';
import 'cover_picker.dart';
import 'theme.dart';
import 'widgets.dart';
import 'glass_popup.dart';

/// Окно «Мой профиль»: ник, аватарка и баннер. Картинки кадрируются мышью и ложатся в общую папку на Диске.
Future<void> editProfileDialog(BuildContext context) async {
  final app = Services.of(context);
  final lib = app.lib;
  final me = lib.me;
  if (me == null) return;
  final nick = TextEditingController(text: lib.profileNick(me) ?? '');
  final avatar = CoverChoice();
  final banner = CoverChoice();
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
            const Text('Фон шапки вашей страницы.', style: TextStyle(color: C.faint, fontSize: 12)),
            const SizedBox(height: 10),
            _ImageField(
              choice: banner,
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
  nick.dispose();
  if (ok != true || !context.mounted) return;
  final av = await avatar.commit(context);
  if (!context.mounted) return;
  final bn = await banner.commit(context);
  lib.setProfile(nick: text, avatar: av, banner: bn);
}

class _ImageField extends StatelessWidget {
  final CoverChoice choice;
  final double width;
  final double height;
  final bool round;
  final double aspect;
  final int outWidth;
  final String cropTitle;
  final bool canReset;
  final Widget current;
  const _ImageField({
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
        final box = SizedBox(width: width, height: height, child: preview);
        return Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          round ? ClipOval(child: box) : ClipRRect(borderRadius: BorderRadius.circular(8), child: box),
          const SizedBox(width: 18),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              OutlinedButton.icon(
                onPressed: () async {
                  final p = await pickCoverFile(context, title: cropTitle, aspect: aspect, outWidth: outWidth, round: round);
                  if (p != null) choice.pick(p);
                },
                icon: const Icon(Icons.image_outlined, size: 18),
                label: const Text('Выбрать файл…'),
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
