import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app.dart';
import '../core/models.dart';
import '../core/share_link.dart';
import 'theme.dart';
import 'widgets.dart';
import 'glass_popup.dart';

/// «Поделиться треком»: другу в Cave Player (он получит уведомление) или ссылкой
Future<void> showShareDialog(BuildContext context, Track track) {
  return showGlassDialog<void>(context: context, builder: (_) => _ShareDialog(track: track));
}

class _ShareDialog extends StatefulWidget {
  final Track track;
  const _ShareDialog({required this.track});
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

  Future<void> _copy(String text, String message) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    Services.of(context).lib.messages.add(message);
  }

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final t = widget.track;
    final friends = app.social.friends;
    final web = webLinkFor(t.id);
    return AlertDialog(
      title: Text('Поделиться', style: display(20)),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text('${t.title} — ${t.displayArtist}', maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 18),
            const Text('Другу в Cave Player', style: TextStyle(color: C.muted)),
            const SizedBox(height: 6),
            if (friends.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('Пока нет друзей с Cave Player. Они появятся, когда запустят программу.', style: TextStyle(color: C.faint, fontSize: 13)),
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
                      secondary: Avatar(email: m.email, name: m.name, size: 30),
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
                  onPressed: _picked.isEmpty
                      ? null
                      : () {
                          app.lib.shareTrack(t.id, _picked.toList(), note: _note.text);
                          Navigator.pop(context);
                          app.lib.messages.add(_picked.length == 1
                              ? 'Отправлено: ${app.lib.firstNameOf(_picked.first)}'
                              : 'Отправлено друзьям: ${_picked.length}');
                        },
                  icon: const Icon(Icons.send_rounded, size: 16),
                  label: const Text('Отправить'),
                ),
              ),
            ],
            const SizedBox(height: 18),
            const Divider(height: 1, color: C.line),
            const SizedBox(height: 14),
            const Text('Ссылкой', style: TextStyle(color: C.muted)),
            const SizedBox(height: 8),
            Wrap(spacing: 10, runSpacing: 8, children: [
              if (web != null)
                OutlinedButton.icon(
                  onPressed: () => _copy(web, 'Ссылка скопирована'),
                  icon: const Icon(Icons.link_rounded, size: 16),
                  label: const Text('Для мессенджеров'),
                ),
              OutlinedButton.icon(
                onPressed: () => _copy(appLinkFor(t.id), 'Ссылка для Cave Player скопирована'),
                icon: const Icon(Icons.link_rounded, size: 16),
                label: Text(web == null ? 'Скопировать ссылку' : 'Для Cave Player'),
              ),
            ]),
            const SizedBox(height: 8),
            Text(
              web == null
                  ? 'Ссылка открывает трек в Cave Player (у друга он должен быть установлен). В мессенджерах она может не нажиматься — тогда вставьте её в адресную строку браузера.'
                  : 'Ссылка «Для мессенджеров» нажимается в Telegram и Discord и открывает трек в Cave Player.',
              style: const TextStyle(color: C.faint, fontSize: 12, height: 1.4),
            ),
          ]),
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Закрыть'))],
    );
  }
}
