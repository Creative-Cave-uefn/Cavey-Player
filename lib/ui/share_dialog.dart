import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app.dart';
import '../core/models.dart';
import '../core/share_link.dart';
import '../core/track_tags.dart';
import '../core/library.dart' show LibraryController;
import 'shell.dart' show Nav, shellNav;
import 'theme.dart';
import 'widgets.dart';
import 'glass_popup.dart';

/// Что отправляем: трек, альбом, исполнителя или плейлист
class ShareSubject {
  final ShareKind kind;
  final String key;
  final String title;
  final String? subtitle;
  const ShareSubject(this.kind, this.key, this.title, [this.subtitle]);
}

/// «Поделиться треком»: другу в Cave Player (он получит уведомление) или ссылкой
Future<void> showShareDialog(BuildContext context, Track track) => showShareSubjectDialog(
    context, ShareSubject(ShareKind.track, track.id, track.title, track.displayArtist));

/// «Поделиться» альбомом, исполнителем, плейлистом или треком
Future<void> showShareSubjectDialog(BuildContext context, ShareSubject subject) {
  return showGlassDialog<void>(context: context, builder: (_) => _ShareDialog(subject: subject));
}

/// Куда вести уведомление «поделился»: страница альбома, исполнителя или плейлиста
Nav? navForThing(String thing, String key) => switch (thing) {
      'album' => Nav('album', key),
      'artist' => Nav('artist', key.toLowerCase()),
      'playlist' => Nav('playlist', key),
      'tag' => Nav('tag', key),
      _ => null,
    };

/// Есть ли такая страница в библиотеке этого человека
bool thingExists(LibraryController lib, String thing, String key) => switch (thing) {
      'album' => lib.album(key) != null,
      'artist' => lib.artist(key) != null,
      'playlist' => lib.playlist(key) != null,
      'tag' => () {
          final k = parseTagKey(key, lib.me);
          return k.owner.isNotEmpty && lib.tagBookOf(k.owner).exists(k.id);
        }(),
      _ => false,
    };

/// Открывает страницу, которой поделились; false — такой у этого человека нет
bool openSharedThing(LibraryController lib, String thing, String key) {
  final nav = navForThing(thing, key);
  if (nav == null || !thingExists(lib, thing, key)) return false;
  shellNav.value?.go(nav);
  return true;
}

class _ShareDialog extends StatefulWidget {
  final ShareSubject subject;
  const _ShareDialog({required this.subject});
  @override
  State<_ShareDialog> createState() => _ShareDialogState();
}

class _ShareDialogState extends State<_ShareDialog> {
  final _note = TextEditingController();
  final _picked = <String>{};

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _copy(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    Services.of(context).lib.messages.add('Ссылка скопирована');
  }

  void _send(AppServices app) {
    final s = widget.subject;
    if (s.kind == ShareKind.track) {
      app.lib.shareTrack(s.key, _picked.toList(), note: _note.text);
    } else {
      app.lib.shareThing(s.kind.name, s.key, s.title, _picked.toList(), note: _note.text);
    }
    Navigator.pop(context);
    app.lib.messages.add(_picked.length == 1
        ? 'Отправлено: ${app.lib.firstNameOf(_picked.first)}'
        : 'Отправлено друзьям: ${_picked.length}');
  }

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final s = widget.subject;
    final friends = app.social.friends;
    return AlertDialog(
      title: Text('Поделиться', style: display(20)),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(s.subtitle == null || s.subtitle!.isEmpty ? s.title : '${s.title} — ${s.subtitle}',
                maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
            if (s.kind == ShareKind.playlist && app.lib.playlist(s.key) != null && !app.lib.isPlaylistPublic(s.key)) ...[
              const SizedBox(height: 8),
              const Text('Плейлист приватный: друзья его не увидят, пока вы не сделаете его открытым.',
                  style: TextStyle(color: C.faint, fontSize: 12.5, height: 1.4)),
            ],
            if (s.kind == ShareKind.tag) ...[
              const SizedBox(height: 8),
              const Text('Теги личные: друг увидит этот тег и его треки только по вашей ссылке или отправке. Изменить его он не сможет.',
                  style: TextStyle(color: C.faint, fontSize: 12.5, height: 1.4)),
            ],
            const SizedBox(height: 18),
            const Text('Другу в Cavey', style: TextStyle(color: C.muted)),
            const SizedBox(height: 6),
            if (friends.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('Пока нет друзей с Cavey. Они появятся, когда запустят программу.', style: TextStyle(color: C.faint, fontSize: 13)),
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 220),
                child: ListView(shrinkWrap: true, children: [
                  for (final m in friends)
                    CheckboxListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.trailing,
                      activeColor: C.accent,
                      checkColor: C.accentInk,
                      value: _picked.contains(m.email),
                      onChanged: (v) => setState(() => v == true ? _picked.add(m.email) : _picked.remove(m.email)),
                      secondary: Avatar(email: m.email, name: app.lib.nameOf(m.email, fallback: m.name), size: 30),
                      title: Text(app.lib.nameOf(m.email), overflow: TextOverflow.ellipsis),
                    ),
                ]),
              ),
            if (friends.isNotEmpty) ...[
              const SizedBox(height: 8),
              TextField(
                controller: _note,
                maxLength: 120,
                decoration: const InputDecoration(hintText: 'Подпись (необязательно)', counterText: ''),
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  onPressed: _picked.isEmpty ? null : () => _send(app),
                  icon: const Icon(Icons.send_rounded, size: 16),
                  label: const Text('Отправить'),
                ),
              ),
            ],
            const SizedBox(height: 18),
            const Divider(height: 1, color: C.line),
            const SizedBox(height: 14),
            OutlinedButton.icon(
              onPressed: () => _copy(shareLinkText(s.kind, s.key)),
              icon: const Icon(Icons.link_rounded, size: 16),
              label: const Text('Скопировать ссылку'),
            ),
          ]),
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Закрыть'))],
    );
  }
}
