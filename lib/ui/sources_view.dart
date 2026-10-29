import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app.dart';
import '../core/drive.dart';
import 'theme.dart';
import 'widgets.dart';

class SourcesPage extends StatefulWidget {
  const SourcesPage({super.key});
  @override
  State<SourcesPage> createState() => _SourcesPageState();
}

class _SourcesPageState extends State<SourcesPage> {
  final _link = TextEditingController();
  bool _adding = false;
  String? _error;

  Future<void> _add() async {
    final app = Services.of(context);
    setState(() {
      _adding = true;
      _error = null;
    });
    try {
      await app.lib.addSource(_link.text);
      _link.clear();
    } catch (e) {
      _error = '$e';
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    return ListenableBuilder(
      listenable: app.lib,
      builder: (context, _) {
        final lib = app.lib;
        final hubLink = folderUrl(app.settings.hubId ?? '');
        final last = DateTime.tryParse(app.settings.lastScan ?? '');
        return ListView(padding: const EdgeInsets.fromLTRB(36, 34, 36, 40), children: [
          Text('Папки с музыкой', style: display(36, weight: FontWeight.w700)),
          const SizedBox(height: 10),
          const Text(
            'Библиотека собирается из папок на Google Дисках. Папки могут лежать у разных людей и на разных аккаунтах.',
            style: TextStyle(color: C.muted, fontSize: 15, height: 1.5),
          ),
          const SizedBox(height: 28),
          _Panel(children: [
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _link,
                  enabled: !_adding,
                  decoration: const InputDecoration(
                    hintText: 'Ссылка на папку Google Диска',
                    prefixIcon: Icon(Icons.link_rounded, size: 18),
                  ),
                  onSubmitted: (_) => _add(),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton(onPressed: _adding ? null : _add, child: const Text('Добавить папку')),
            ]),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(_error!, style: const TextStyle(color: C.danger)),
              ),
            const SizedBox(height: 10),
            const Text(
              'Подойдёт своя папка или та, которой с вами поделились. Если она открыта для другого вашего '
              'аккаунта, сначала подключите его на вкладке «Аккаунты».',
              style: TextStyle(color: C.faint, fontSize: 13, height: 1.45),
            ),
          ]),
          const SizedBox(height: 18),
          if (lib.data.sources.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('Папок пока нет.', style: TextStyle(color: C.muted)),
            ),
          for (final s in lib.data.sources)
            _SourceRow(
              name: s.name,
              detail: '${countTracks(lib.tracksIn(s.id))}, добавил(а) ${lib.firstNameOf(s.addedBy)}',
              via: app.settings.sourceAccess[s.id],
              addedBy: s.addedBy,
              onOpen: () => launchUrl(Uri.parse(folderUrl(s.id))),
              onRemove: () async {
                final ok = await confirm(context,
                    title: 'Убрать «${s.name}»?',
                    text: 'Треки из этой папки пропадут из библиотеки у всех друзей. Файлы на Диске останутся.',
                    action: 'Убрать');
                if (ok) lib.removeSource(s.id);
              },
            ),
          const SizedBox(height: 18),
          Row(children: [
            OutlinedButton.icon(
              onPressed: lib.scan.running || lib.data.sources.isEmpty ? null : () => lib.scanAll(),
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Обновить библиотеку'),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: lib.scan.running
                  ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(
                        lib.scan.total > 0 ? '${lib.scan.text}: ${lib.scan.done} из ${lib.scan.total}' : lib.scan.text,
                        style: const TextStyle(color: C.muted, fontSize: 13),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 6),
                      LinearProgressIndicator(value: lib.scan.total > 0 ? lib.scan.done / lib.scan.total : null),
                    ])
                  : Text(
                      last == null
                          ? 'Новые файлы подхватываются сами раз в 10 минут'
                          : 'Проверено в ${TimeOfDay.fromDateTime(last.toLocal()).format(context)}. Дальше — само, раз в 10 минут.',
                      style: const TextStyle(color: C.faint, fontSize: 13),
                    ),
            ),
          ]),
          const SizedBox(height: 44),
          Text('Пригласить друзей', style: display(20)),
          const SizedBox(height: 10),
          const Text(
            'Плейлисты и лайки хранятся в папке «Cave Player». Откройте её на Диске, нажмите «Поделиться», '
            'добавьте почты друзей с правами редактора и отправьте им эту ссылку.',
            style: TextStyle(color: C.muted, height: 1.5),
          ),
          const SizedBox(height: 14),
          _Panel(children: [
            Row(children: [
              const Icon(Icons.folder_rounded, color: C.accent),
              const SizedBox(width: 12),
              Expanded(child: SelectableText(hubLink, style: const TextStyle(fontSize: 13))),
              const SizedBox(width: 12),
              TextButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: hubLink));
                  lib.messages.add('Ссылка скопирована');
                },
                icon: const Icon(Icons.copy_rounded, size: 16),
                label: const Text('Скопировать'),
              ),
              TextButton.icon(
                onPressed: () => launchUrl(Uri.parse(hubLink)),
                icon: const Icon(Icons.open_in_new_rounded, size: 16),
                label: const Text('Открыть на Диске'),
              ),
            ]),
          ]),
          const SizedBox(height: 44),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              style: TextButton.styleFrom(foregroundColor: C.danger),
              onPressed: () async {
                final ok = await confirm(context,
                    title: 'Отключиться от этой библиотеки?',
                    text: 'Библиотека пропадёт с этого компьютера. На Диске всё останется, подключиться снова можно по ссылке.',
                    action: 'Отключиться');
                if (ok) await lib.leaveHub();
              },
              child: const Text('Отключиться от этой библиотеки'),
            ),
          ),
        ]);
      },
    );
  }
}

class _Panel extends StatelessWidget {
  final List<Widget> children;
  const _Panel({required this.children});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: C.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: C.line),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
      );
}

class _SourceRow extends StatelessWidget {
  final String name;
  final String detail;
  final String? via;
  final String addedBy;
  final VoidCallback onOpen;
  final VoidCallback onRemove;
  const _SourceRow({
    required this.name,
    required this.detail,
    required this.via,
    required this.addedBy,
    required this.onOpen,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: C.line))),
      child: Row(children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(color: C.raised, borderRadius: BorderRadius.circular(8)),
          child: Icon(Icons.folder_rounded, color: friendColor(addedBy)),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
            const SizedBox(height: 3),
            Text(detail, style: const TextStyle(color: C.muted, fontSize: 13)),
            if (via != null) ...[
              const SizedBox(height: 2),
              Text('Открывается через $via', style: const TextStyle(color: C.faint, fontSize: 12)),
            ],
          ]),
        ),
        IconButton(tooltip: 'Открыть на Диске', onPressed: onOpen, icon: const Icon(Icons.open_in_new_rounded, size: 18)),
        IconButton(tooltip: 'Убрать из библиотеки', onPressed: onRemove, icon: const Icon(Icons.close_rounded, size: 18)),
      ]),
    );
  }
}
