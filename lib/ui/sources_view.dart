import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app.dart';
import '../core/drive.dart';
import '../core/library.dart';
import 'shell.dart';
import 'theme.dart';
import 'widgets.dart';
import 'glass_popup.dart';

/// Папки с музыкой, приглашение друзей и отключение: раздел страницы «Настройки»
class LibrarySection extends StatefulWidget {
  const LibrarySection({super.key});
  @override
  State<LibrarySection> createState() => _LibrarySectionState();
}

class _LibrarySectionState extends State<LibrarySection> {
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
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Папки с музыкой', style: display(20)),
          const SizedBox(height: 10),
          const Text(
            'Библиотека собирается из папок на Google Дисках. Папки могут лежать у разных людей и на разных аккаунтах.',
            style: TextStyle(color: C.muted, fontSize: 15, height: 1.5),
          ),
          const SizedBox(height: 18),
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
              'аккаунта, сначала подключите его в разделе «Аккаунты» выше.',
              style: TextStyle(color: C.faint, fontSize: 13, height: 1.45),
            ),
          ]),
          const SizedBox(height: 18),
          Text(
            'Музыка в библиотеке: ${countTracks(lib.data.tracks.length - lib.data.hidden.length)}, '
            '${formatBytes(lib.data.tracks.values.where((t) => !lib.data.hidden.contains(t.id)).fold(0, (a, t) => a + t.size))}',
            style: const TextStyle(color: C.muted, fontSize: 14),
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
              warning: lib.suspiciousSources[s.id] == null
                  ? null
                  : 'Не нашёл ${lib.suspiciousSources[s.id]} треков. Из общей библиотеки они не убраны — похоже, пропал доступ к папке.',
              onPrune: lib.suspiciousSources[s.id] == null
                  ? null
                  : () async {
                      final ok = await confirm(context,
                          title: 'Убрать пропавшие треки?',
                          text: 'Из «${s.name}» исчезли ${lib.suspiciousSources[s.id]} треков, и они пропадут из библиотеки у всех друзей. '
                              'Делайте это, только если файлы действительно удалены, а не пропал доступ.',
                          action: 'Убрать');
                      if (ok) await lib.rescanAndPrune(s.id);
                    },
              onOpen: () => launchUrl(Uri.parse(folderUrl(s.id))),
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
            'Введите почту друга: Cavey откроет ему общую папку и папки с музыкой, а Google пришлёт письмо. '
            'Друг установит Cavey, войдёт с этой почтой, и библиотека подключится сама.',
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
              Icon(Icons.folder_rounded, color: C.accent),
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
          Text('Отключение', style: display(20)),
          const SizedBox(height: 10),
          const Text(
            'Отключение действует только на этом компьютере. Треки, плейлисты и лайки в общей библиотеке остаются у друзей как были: '
            'ничего не удаляется. Cavey сам к библиотеке больше не подключится, пока вы не подключитесь вручную.',
            style: TextStyle(color: C.muted, height: 1.5),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              style: TextButton.styleFrom(foregroundColor: C.danger),
              onPressed: () async {
                final ok = await confirm(context,
                    title: 'Отключиться от этой библиотеки?',
                    text: 'Библиотека пропадёт только с этого компьютера. У друзей и на Диске всё останется как было, '
                        'никакие треки не удалятся. Сами к библиотеке Cavey больше не подключится: '
                        'подключиться снова можно вручную, по ссылке или кнопкой поиска.',
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

/// Где хранятся данные и удаление папки из общей библиотеки: живёт в «Отладке» на странице настроек
class LibraryDebug extends StatelessWidget {
  const LibraryDebug({super.key});

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    return ListenableBuilder(
      listenable: app.lib,
      builder: (context, _) {
        final lib = app.lib;
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Где хранятся данные', style: display(17)),
          const SizedBox(height: 8),
          const Text(
            'Откуда программа берёт общие плейлисты, друзей и статусы. Если у вас не появляются друзья и плейлисты, '
            'проверьте здесь, в той ли папке вы сидите.',
            style: TextStyle(color: C.muted, height: 1.5),
          ),
          const SizedBox(height: 14),
          const _LocationPanel(),
          const SizedBox(height: 28),
          Text('Убрать папку из библиотеки', style: display(17)),
          const SizedBox(height: 8),
          const Text(
            'Опасно: треки этой папки пропадут из библиотеки у всех друзей. Файлы на Диске останутся. '
            'Чтобы не нажать случайно, нужно ввести название папки.',
            style: TextStyle(color: C.danger, height: 1.5),
          ),
          const SizedBox(height: 8),
          if (lib.data.sources.isEmpty)
            const Text('Папок пока нет.', style: TextStyle(color: C.faint, fontSize: 13)),
          for (final s in lib.data.sources)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(s.name),
              trailing: TextButton(
                style: TextButton.styleFrom(foregroundColor: C.danger),
                onPressed: () async {
                  if (await _confirmByName(context, s.name)) lib.removeSource(s.id);
                },
                child: const Text('Убрать'),
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
  final String? warning;
  final VoidCallback? onPrune;
  const _SourceRow({
    required this.name,
    required this.detail,
    required this.via,
    required this.addedBy,
    required this.onOpen,
    this.warning,
    this.onPrune,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: C.divider))),
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
            if (warning != null) ...[
              const SizedBox(height: 4),
              Text(warning!, style: const TextStyle(color: C.danger, fontSize: 12, height: 1.35)),
            ],
          ]),
        ),
        if (onPrune != null)
          TextButton(onPressed: onPrune, child: const Text('Убрать пропавшие')),
        IconButton(tooltip: 'Открыть на Диске', onPressed: onOpen, icon: const Icon(Icons.open_in_new_rounded, size: 18)),
      ]),
    );
  }
}


/// Где лежат library.json и cave-data, и как их поменять
class _LocationPanel extends StatefulWidget {
  const _LocationPanel();
  @override
  State<_LocationPanel> createState() => _LocationPanelState();
}

class _LocationPanelState extends State<_LocationPanel> {
  final _hub = TextEditingController();
  final _move = TextEditingController();
  final _data = TextEditingController();
  LocationReport? _report;
  bool _loading = false;
  bool _busy = false;
  String? _error;
  String? _ok;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  @override
  void dispose() {
    _hub.dispose();
    _move.dispose();
    _data.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (!mounted || _loading) return;
    final lib = Services.of(context).lib;
    setState(() => _loading = true);
    final r = await lib.locationReport();
    if (mounted) {
      setState(() {
        _report = r;
        _loading = false;
      });
    }
  }

  Future<void> _act(String done, Future<void> Function() fn, {TextEditingController? clear}) async {
    setState(() {
      _busy = true;
      _error = null;
      _ok = null;
    });
    try {
      await fn();
      clear?.clear();
      _ok = done;
      await _refresh();
    } catch (e) {
      _error = '$e';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _row(String label, String value, {String? link}) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 190, child: Text(label, style: const TextStyle(color: C.muted, fontSize: 13))),
          Expanded(child: SelectableText(value, style: const TextStyle(fontSize: 13))),
          if (link != null)
            InkWell(
              onTap: () => launchUrl(Uri.parse(link)),
              child: Padding(padding: EdgeInsets.only(left: 8), child: Icon(Icons.open_in_new_rounded, size: 15, color: C.accent)),
            ),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final lib = app.lib;
    final r = _report;
    final fmt = r?.libModified == null ? '—' : r!.libModified!.replaceFirst('T', ' ').split('.').first;
    return _Panel(children: [
      if (r == null || _loading && r.hubId == null)
        const LinearProgressIndicator()
      else ...[
        _row('Папка библиотеки', '${r.hubName ?? '—'}  (${r.hubId ?? '—'})', link: r.hubId == null ? null : folderUrl(r.hubId!)),
        _row('Файл library.json', r.libFileId == null ? '—' : '${formatBytes(r.libSize)}, изменён $fmt'),
        if (r.libraryFilesInHub > 1)
          _row('Внимание', 'В этой папке ${r.libraryFilesInHub} файла library.json. Используется самый большой, лишние лучше убрать на Диске.'),
        _row('Папка cave-data', r.dataId == null ? '—' : '${r.dataId}${r.dataOverride ? '  (выбрана вручную)' : ''}',
            link: r.dataId == null ? null : folderUrl(r.dataId!)),
        _row('Статусов друзей в ней', '${r.dataFiles}'),
        if (r.dataFolderCount > 1) _row('Внимание', 'Папок cave-data несколько: ${r.dataFolderCount}. Статусы читаются из всех.'),
        if (r.error != null) _row('Ошибка', r.error!),
      ],
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: _loading ? null : _refresh,
          icon: const Icon(Icons.refresh_rounded, size: 16),
          label: const Text('Проверить ещё раз'),
        ),
      ),
      const Divider(height: 28, color: C.line),
      const Text('Подключить другую папку с библиотекой', style: TextStyle(fontWeight: FontWeight.w600)),
      const SizedBox(height: 4),
      const Text(
        'Ссылка на папку «Cave Player» друга (или прямо на library.json). Это переключит вас на ту библиотеку, ничего в ней не меняя.',
        style: TextStyle(color: C.faint, fontSize: 13, height: 1.4),
      ),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(
          child: TextField(
            controller: _hub,
            enabled: !_busy,
            decoration: const InputDecoration(hintText: 'Ссылка на папку или library.json'),
          ),
        ),
        const SizedBox(width: 12),
        FilledButton(
          onPressed: _busy ? null : () => _act('Подключено к новой библиотеке', () => lib.joinHub(_hub.text), clear: _hub),
          child: const Text('Подключить'),
        ),
      ]),
      const SizedBox(height: 18),
      const Text('Перенести library.json в другую папку', style: TextStyle(fontWeight: FontWeight.w600)),
      const SizedBox(height: 4),
      const Text(
        'В выбранной папке появится library.json с текущим содержимым, и вы будете работать с ним. Старый файл не удаляется. '
        'Друзьям потом нужно подключиться к новой папке. В папке не должно быть своего library.json.',
        style: TextStyle(color: C.faint, fontSize: 13, height: 1.4),
      ),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(
          child: TextField(
            controller: _move,
            enabled: !_busy,
            decoration: const InputDecoration(hintText: 'Ссылка на новую папку'),
          ),
        ),
        const SizedBox(width: 12),
        OutlinedButton(
          onPressed: _busy
              ? null
              : () async {
                  final ok = await confirm(context,
                      title: 'Перенести библиотеку?',
                      text: 'Дальше вы будете сохранять в новый library.json. Друзья, которые остались на старом, ваших правок не увидят, '
                          'пока тоже не подключатся к новой папке.',
                      action: 'Перенести');
                  if (ok) await _act('Библиотека перенесена', () => lib.moveLibraryTo(_move.text), clear: _move);
                },
          child: const Text('Перенести'),
        ),
      ]),
      const SizedBox(height: 18),
      const Text('Папка cave-data (статусы, лента, чарты)', style: TextStyle(fontWeight: FontWeight.w600)),
      const SizedBox(height: 4),
      const Text(
        'Обычно она лежит внутри общей папки. Можно указать свою: ссылка на саму cave-data или на папку, где она есть или будет создана. '
        'Чтобы друзья видели ваш статус, у них должна быть выбрана та же папка.',
        style: TextStyle(color: C.faint, fontSize: 13, height: 1.4),
      ),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(
          child: TextField(
            controller: _data,
            enabled: !_busy,
            decoration: const InputDecoration(hintText: 'Ссылка на папку cave-data'),
          ),
        ),
        const SizedBox(width: 12),
        OutlinedButton(
          onPressed: _busy ? null : () => _act('Папка cave-data изменена', () => lib.setDataFolder(_data.text), clear: _data),
          child: const Text('Выбрать'),
        ),
        if (app.settings.dataFolderOverride != null) ...[
          const SizedBox(width: 8),
          TextButton(
            onPressed: _busy ? null : () => _act('Папка cave-data вернулась на место', lib.resetDataFolder),
            child: const Text('Вернуть обычную'),
          ),
        ],
      ]),
      if (_busy) const Padding(padding: EdgeInsets.only(top: 14), child: LinearProgressIndicator()),
      if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: const TextStyle(color: C.danger))),
      if (_ok != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_ok!, style: TextStyle(color: C.accent))),
    ]);
  }
}


/// Подтверждение опасного действия вводом названия
Future<bool> _confirmByName(BuildContext context, String name) async {
  final ctl = TextEditingController();
  final ok = await showGlassDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: Text('Убрать «$name»?', style: display(18)),
        content: SizedBox(
          width: 380,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Треки из этой папки пропадут из библиотеки у всех друзей. Чтобы подтвердить, введите название папки:',
                style: TextStyle(color: C.muted, height: 1.45)),
            const SizedBox(height: 12),
            TextField(controller: ctl, autofocus: true, onChanged: (_) => setState(() {}), decoration: InputDecoration(hintText: name)),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена', style: TextStyle(color: C.muted))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: C.danger),
            onPressed: ctl.text.trim() == name.trim() ? () => Navigator.pop(ctx, true) : null,
            child: const Text('Убрать'),
          ),
        ],
      ),
    ),
  );
  ctl.dispose();
  return ok ?? false;
}
