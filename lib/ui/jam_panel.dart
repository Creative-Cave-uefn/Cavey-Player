import 'package:flutter/material.dart';

import '../app.dart';
import 'company_view.dart' show JamStrip;
import 'shell.dart' show Nav, NavController, NavScope;
import 'theme.dart';
import 'widgets.dart';

/// Панель джем-сессии: кто в ней сидит (нажатие открывает профиль), кто организатор, как настроен плавный переход.
/// Организатор может передать лидерство другому участнику или исключить его из джема
Future<void> showJamPanel(BuildContext context) {
  final app = Services.of(context);
  final nav = NavScope.of(context);
  return showDialog<void>(
    context: context,
    builder: (ctx) => _JamPanel(app: app, nav: nav),
  );
}

class _JamPanel extends StatelessWidget {
  final AppServices app;
  final NavController nav;
  const _JamPanel({required this.app, required this.nav});

  Future<bool> _confirm(BuildContext context, String title, String text, String ok) async {
    final v = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Text(text),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: Text(ok)),
        ],
      ),
    );
    return v ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final jam = app.jam;
    return Dialog(
      backgroundColor: C.panel,
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: const BorderSide(color: C.line)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440, maxHeight: 620),
        child: ListenableBuilder(
          listenable: Listenable.merge([jam, app.social, app.lib]),
          builder: (context, _) {
            // Джем закончился (я вышел или меня исключили): панель закрывается сама
            if (!jam.active) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (context.mounted) Navigator.maybePop(context);
              });
              return const SizedBox(height: 80);
            }
            final people = jam.participants;
            final host = jam.effectiveHost;
            final imHost = jam.iAmHost;
            final me = app.lib.me;
            final sec = app.player.crossfadeSecNow;
            return Padding(
              padding: const EdgeInsets.fromLTRB(22, 18, 14, 14),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  Icon(Icons.headphones_rounded, color: C.accent),
                  const SizedBox(width: 10),
                  Expanded(child: Text('Джем-сессия', style: display(20))),
                  IconButton(
                    tooltip: 'Закрыть',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close_rounded, size: 20),
                    onPressed: () => Navigator.pop(context),
                  ),
                ]),
                const SizedBox(height: 6),
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    _Info(
                      'Организатор',
                      host == null ? '—' : (host == me ? 'вы' : app.lib.firstNameOf(host)),
                    ),
                    _Info('Участников', '${people.length}'),
                    _Info('Связь', jam.linkState),
                    _Info(
                      'Плавный переход',
                      sec > 0 ? '$sec ${plural(sec, 'секунда', 'секунды', 'секунд')}' : 'выключен',
                      note: imHost ? 'ваша настройка действует для всех' : 'задаёт организатор',
                    ),
                  ]),
                ),
                const SizedBox(height: 14),
                const Padding(
                  padding: EdgeInsets.only(right: 8),
                  child: Text('Участники', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                ),
                const SizedBox(height: 6),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.only(right: 8),
                    child: Column(children: [
                      for (final e in people)
                        _PersonRow(
                          key: ValueKey('jp-$e'),
                          email: e,
                          app: app,
                          isHost: e == host,
                          isMe: e == me,
                          canManage: imHost && e != me,
                          onOpen: () {
                            Navigator.pop(context);
                            nav.go(Nav('user', e));
                          },
                          onMakeHost: () async {
                            final name = app.lib.firstNameOf(e);
                            final ok = await _confirm(context, 'Передать лидерство?',
                                '$name станет организатором джема: плавный переход будет по его настройке, и исключать участников сможет уже он.', 'Передать');
                            if (ok) await jam.makeHost(e);
                          },
                          onKick: () async {
                            final name = app.lib.firstNameOf(e);
                            final ok = await _confirm(context, 'Исключить из джема?', '$name выйдет из джем-сессии. Позвать его обратно можно приглашением.', 'Исключить');
                            if (ok) await jam.kick(e);
                          },
                        ),
                    ]),
                  ),
                ),
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Row(children: [
                    OutlinedButton.icon(
                      onPressed: () => JamStrip.invite(context),
                      icon: const Icon(Icons.person_add_alt_1_rounded, size: 18),
                      label: const Text('Позвать'),
                    ),
                    const Spacer(),
                    TextButton(
                      style: TextButton.styleFrom(foregroundColor: C.danger),
                      onPressed: () async {
                        await jam.leave();
                        if (context.mounted) Navigator.maybePop(context);
                      },
                      child: const Text('Выйти из джема'),
                    ),
                  ]),
                ),
              ]),
            );
          },
        ),
      ),
    );
  }
}

class _Info extends StatelessWidget {
  final String label, value;
  final String? note;
  const _Info(this.label, this.value, {this.note});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
          SizedBox(width: 132, child: Text(label, style: const TextStyle(color: C.muted, fontSize: 13))),
          Flexible(
            child: Text.rich(TextSpan(children: [
              TextSpan(text: value, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
              if (note != null) TextSpan(text: '  ·  $note', style: const TextStyle(color: C.faint, fontSize: 12)),
            ])),
          ),
        ]),
      );
}

class _PersonRow extends StatefulWidget {
  final String email;
  final AppServices app;
  final bool isHost, isMe, canManage;
  final VoidCallback onOpen, onMakeHost, onKick;
  const _PersonRow({
    super.key,
    required this.email,
    required this.app,
    required this.isHost,
    required this.isMe,
    required this.canManage,
    required this.onOpen,
    required this.onMakeHost,
    required this.onKick,
  });

  @override
  State<_PersonRow> createState() => _PersonRowState();
}

class _PersonRowState extends State<_PersonRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final lib = widget.app.lib;
    final name = lib.firstNameOf(widget.email);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Tooltip(
        message: 'Открыть профиль',
        waitDuration: const Duration(milliseconds: 700),
        child: Material(
          color: _hover ? C.hoverOverlay : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: widget.onOpen,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
              child: Row(children: [
                Avatar(email: widget.email, name: name, size: 38),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(widget.isMe ? '$name (вы)' : name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                    Row(children: [
                      if (widget.isHost) ...[
                        Icon(Icons.workspace_premium_rounded, size: 14, color: C.accent),
                        const SizedBox(width: 4),
                      ],
                      Text(widget.isHost ? 'Организатор' : 'Участник',
                          style: TextStyle(color: widget.isHost ? C.accent : C.faint, fontSize: 12)),
                    ]),
                  ]),
                ),
                if (widget.canManage) ...[
                  IconButton(
                    tooltip: 'Передать лидерство',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.workspace_premium_outlined, size: 20),
                    onPressed: widget.onMakeHost,
                  ),
                  IconButton(
                    tooltip: 'Исключить из джема',
                    visualDensity: VisualDensity.compact,
                    icon: Icon(Icons.person_remove_alt_1_rounded, size: 20, color: C.danger),
                    onPressed: widget.onKick,
                  ),
                ],
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
