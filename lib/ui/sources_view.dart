import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app.dart';
import '../core/drive.dart';
import 'shell.dart';
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
  final _friend = TextEditingController();
  bool _inviting = false;
  String? _inviteResult;
  bool _inviteFailed = false;

  Future<void> _invite() async {
    final app = Services.of(context);
    final email = _friend.text.trim();
    setState(() {
      _inviting = true;
      _inviteResult = null;
    });
    try {
      final failed = await app.lib.invite(email);
      _friend.clear();
      _inviteFailed = false;
      _inviteResult = failed.isEmpty
          ? 'Готово: $email получит письмо от Google со ссылкой.'
          : 'Доступ к общей папке выдан. Не получилось поделиться папками: ${failed.join(', ')}. '
              'Попросите их владельцев пригласить $email.';
    } catch (e) {
      _inviteFailed = true;
      _inviteResult = '$e';
    } finally {
      if (mounted) setState(() => _inviting = false);
    }
  }
  String? _error;

  /// Занятое место на Дисках подключённых аккаунтов: почта → объём или ошибка
  final Map<String, StorageQuota?> _quota = {};
  bool _quotaLoading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadQuota());
  }

  Future<void> _loadQuota() async {
    if (!mounted || _quotaLoading) return;
    final app = Services.of(context);
    setState(() => _quotaLoading = true);
    for (final a in app.accounts.accounts) {
      try {
        _quota[a.email] = await app.drive.storageQuota(a.email);
      } catch (_) {
        _quota[a.email] = null;
      }
      if (!mounted) return;
    }
    if (mounted) setState(() => _quotaLoading = false);
  }

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
          _StoragePanel(
            musicBytes: lib.data.tracks.values.where((t) => !lib.data.hidden.contains(t.id)).fold(0, (a, t) => a + t.size),
            tracks: lib.data.tracks.length - lib.data.hidden.length,
            accounts: [for (final a in app.accounts.accounts) (a.email, a.name, _quota[a.email], _quota.containsKey(a.email))],
            loading: _quotaLoading,
            onRefresh: _loadQuota,
          ),
          const SizedBox(height: 18),
          if (lib.data.sources.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('Папок пока нет.', style: TextStyle(color: C.muted)),
            ),
          for (final s in lib.data.sources)
            _SourceRow(
              name: s.name,
              detail:
                  '${countTracks(lib.tracksIn(s.id))} · ${formatBytes(lib.data.tracks.values.where((t) => t.source == s.id).fold(0, (a, t) => a + t.size))}, добавил(а) ${lib.firstNameOf(s.addedBy)}',
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
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => NavScope.of(context).go(const Nav('duplicates')),
              icon: const Icon(Icons.content_copy_rounded, size: 16),
              label: Text(lib.duplicates.isEmpty
                  ? 'Дубликатов нет'
                  : 'Дубликаты: ${lib.duplicates.length} ${plural(lib.duplicates.length, 'группа', 'группы', 'групп')}'),
            ),
          ),
          const SizedBox(height: 44),
          Text('Пригласить друзей', style: display(20)),
          const SizedBox(height: 10),
          const Text(
            'Введите почту друга: Cave Player откроет ему общую папку и папки с музыкой, а Google пришлёт письмо. '
            'Друг установит Cave Player, войдёт с этой почтой, и библиотека подключится сама.',
            style: TextStyle(color: C.muted, height: 1.5),
          ),
          const SizedBox(height: 14),
          _Panel(children: [
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _friend,
                  enabled: !_inviting,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(
                    hintText: 'Почта друга',
                    prefixIcon: Icon(Icons.mail_outline_rounded, size: 18),
                  ),
                  onSubmitted: (_) => _invite(),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton(onPressed: _inviting ? null : _invite, child: const Text('Пригласить')),
            ]),
            if (_inviteResult != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(_inviteResult!,
                    style: TextStyle(color: _inviteFailed ? C.danger : C.muted, height: 1.4)),
              ),
            const SizedBox(height: 10),
            const Text(
              'Пока приложение Google в режиме тестирования, почту друга нужно ещё добавить в Test users в Google Cloud.',
              style: TextStyle(color: C.faint, fontSize: 13, height: 1.45),
            ),
          ]),
          const SizedBox(height: 14),
          const Text('Или отправьте ссылку на общую папку сами:', style: TextStyle(color: C.faint, fontSize: 13)),
          const SizedBox(height: 8),
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


/// «Хранилище»: сколько занимает музыка библиотеки и сколько места занято на каждом подключённом Google Диске
class _StoragePanel extends StatelessWidget {
  final int musicBytes;
  final int tracks;

  /// (почта, имя, объём или null, если не удалось узнать, был ли ответ)
  final List<(String, String, StorageQuota?, bool)> accounts;
  final bool loading;
  final VoidCallback onRefresh;
  const _StoragePanel({required this.musicBytes, required this.tracks, required this.accounts, required this.loading, required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    return _Panel(children: [
      Row(children: [
        const Icon(Icons.storage_rounded, color: C.accent),
        const SizedBox(width: 12),
        Expanded(child: Text('Хранилище', style: display(18))),
        IconButton(
          tooltip: 'Обновить',
          onPressed: loading ? null : onRefresh,
          icon: loading
              ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.refresh_rounded, size: 18),
        ),
      ]),
      const SizedBox(height: 6),
      Text('Музыка библиотеки занимает ${formatBytes(musicBytes)} (${countTracks(tracks)}). Файлы лежат на Google Дисках друзей.',
          style: const TextStyle(color: C.muted, fontSize: 13, height: 1.4)),
      for (final a in accounts) ...[
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: Text(a.$2.isEmpty ? a.$1 : '${a.$2} · ${a.$1}', overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13))),
          const SizedBox(width: 12),
          Text(
            a.$3 != null
                ? (a.$3!.limit != null ? '${formatBytes(a.$3!.used)} из ${formatBytes(a.$3!.limit!)}' : '${formatBytes(a.$3!.used)} (без лимита)')
                : (a.$4 ? 'не удалось узнать' : 'загружаю…'),
            style: const TextStyle(color: C.muted, fontSize: 13),
          ),
        ]),
        if (a.$3?.limit != null) ...[
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: (a.$3!.used / a.$3!.limit!).clamp(0.0, 1.0).toDouble(),
              minHeight: 6,
              color: a.$3!.used / a.$3!.limit! > 0.9 ? C.danger : C.accent,
              backgroundColor: C.raised,
            ),
          ),
        ],
      ],
      if (accounts.isNotEmpty) ...[
        const SizedBox(height: 10),
        const Text('Занято на Диске всё, что лежит на аккаунте: музыка, почта Gmail и фото, а не только Cave Player.',
            style: TextStyle(color: C.faint, fontSize: 12, height: 1.4)),
      ],
    ]);
  }
}
