import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app.dart';
import '../core/log.dart';
import '../core/updater.dart';
import 'theme.dart';
import 'widgets.dart';

class AccountsPage extends StatefulWidget {
  const AccountsPage({super.key});
  @override
  State<AccountsPage> createState() => _AccountsPageState();
}

class _AccountsPageState extends State<AccountsPage> {
  String? _error;

  Future<void> _signIn({String? hint}) async {
    final app = Services.of(context);
    setState(() => _error = null);
    try {
      final acc = await app.accounts.signIn(loginHint: hint);
      app.lib.messages.add('Подключён ${acc.email}');
      // Папки, к которым раньше не было доступа, могли стать доступны
      app.settings.sourceAccess.clear();
      await app.lib.saveSettings();
      await app.lib.scanAll(quiet: true);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([app.accounts, app.lib]),
      builder: (context, _) {
        final accounts = app.accounts;
        final primary = accounts.primary?.email;
        return ListView(padding: const EdgeInsets.fromLTRB(36, 34, 36, 40), children: [
          Text('Настройки', style: display(36, weight: FontWeight.w700)),
          const SizedBox(height: 28),
          Text('Аккаунты', style: display(20)),
          const SizedBox(height: 10),
          const Text(
            'Можно подключить несколько аккаунтов Google. Cave Player сам выберет, через какой открывать каждую папку. '
            'Лайки и плейлисты подписываются основным аккаунтом.',
            style: TextStyle(color: C.muted, fontSize: 15, height: 1.5),
          ),
          const SizedBox(height: 24),
          for (final a in accounts.accounts)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 14),
              decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: C.line))),
              child: Row(children: [
                Avatar(email: a.email, name: a.name, size: 40),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Flexible(
                        child: Text(a.name.isEmpty ? a.email : a.name,
                            overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
                      ),
                      if (a.email == primary) ...[
                        const SizedBox(width: 10),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: C.accent.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: const Text('основной', style: TextStyle(color: C.accent, fontSize: 12)),
                        ),
                      ],
                    ]),
                    const SizedBox(height: 3),
                    Text(a.email, style: const TextStyle(color: C.muted, fontSize: 13)),
                  ]),
                ),
                if (a.needsSignIn)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilledButton(onPressed: () => _signIn(hint: a.email), child: const Text('Войти снова')),
                  ),
                PopupMenuButton<String>(
                  tooltip: 'Действия',
                  icon: const Icon(Icons.more_horiz_rounded),
                  onSelected: (v) async {
                    if (v == 'relogin') {
                      await _signIn(hint: a.email);
                    } else if (v == 'primary') {
                      await accounts.setPrimary(a.email);
                    } else if (v == 'remove') {
                      final ok = await confirm(context,
                          title: 'Отключить ${a.email}?',
                          text: 'Папки, которые открывались только через этот аккаунт, перестанут играть на этом компьютере.',
                          action: 'Отключить');
                      if (ok) await accounts.remove(a.email);
                    }
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'relogin', child: Text('Войти заново')),
                    if (a.email != primary) const PopupMenuItem(value: 'primary', child: Text('Сделать основным')),
                    const PopupMenuItem(value: 'remove', child: Text('Отключить аккаунт')),
                  ],
                ),
              ]),
            ),
          const SizedBox(height: 22),
          Row(children: [
            if (!accounts.signingIn)
              OutlinedButton.icon(
                onPressed: () => _signIn(),
                icon: const Icon(Icons.person_add_alt_rounded, size: 18),
                label: const Text('Добавить аккаунт Google'),
              )
            else ...[
              const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 14),
              const Text('Продолжите вход в браузере', style: TextStyle(color: C.muted)),
              const SizedBox(width: 8),
              TextButton(onPressed: accounts.cancelSignIn, child: const Text('Отменить')),
            ],
          ]),
          if (_error != null)
            Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: const TextStyle(color: C.danger))),
          const SizedBox(height: 44),
          const _UpdatesSection(),
          const SizedBox(height: 44),
          const _CacheSection(),
          const SizedBox(height: 44),
          const _LogSection(),
          if (!app.keysBuiltIn) ...[
            const SizedBox(height: 44),
            Text('Ключ приложения Google', style: display(20)),
            const SizedBox(height: 10),
            Text(
              'Client ID: ${app.settings.clientId}',
              style: const TextStyle(color: C.muted, fontSize: 13),
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () async {
                  final ok = await confirm(context,
                      title: 'Сменить ключ?',
                      text: 'Придётся заново войти во все аккаунты.',
                      action: 'Сменить');
                  if (!ok) return;
                  for (final a in List.of(accounts.accounts)) {
                    await accounts.remove(a.email);
                  }
                  app.settings
                    ..clientId = ''
                    ..clientSecret = '';
                  await app.lib.saveSettings();
                  accounts.configChanged();
                },
                child: const Text('Ввести другой ключ'),
              ),
            ),
          ],
        ]);
      },
    );
  }
}

class _UpdatesSection extends StatelessWidget {
  const _UpdatesSection();

  @override
  Widget build(BuildContext context) {
    final up = Services.of(context).updater;
    return ListenableBuilder(
      listenable: up,
      builder: (context, _) {
        final last = up.lastCheck;
        final status = switch (up.state) {
          UpdateState.checking => 'Проверяю…',
          UpdateState.downloading => 'Скачиваю версию ${up.latest} (${(up.progress * 100).round()}%)',
          UpdateState.ready => 'Версия ${up.latest} скачана и готова к установке',
          UpdateState.upToDate => 'У вас последняя версия',
          UpdateState.error => up.error ?? 'Не получилось проверить',
          UpdateState.idle => 'Обновления проверяются сами раз в 4 часа',
        };
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Обновления', style: display(20)),
          const SizedBox(height: 10),
          Text('Установлена версия ${up.currentVersion}', style: const TextStyle(color: C.muted, fontSize: 15)),
          const SizedBox(height: 6),
          Text(
            last == null ? status : '$status. Проверено в ${TimeOfDay.fromDateTime(last).format(context)}.',
            style: TextStyle(color: up.state == UpdateState.error ? C.danger : C.faint, fontSize: 13, height: 1.45),
          ),
          if (up.state == UpdateState.downloading) ...[
            const SizedBox(height: 10),
            SizedBox(width: 320, child: LinearProgressIndicator(value: up.progress)),
          ],
          const SizedBox(height: 16),
          Wrap(spacing: 12, runSpacing: 10, children: [
            if (up.state == UpdateState.ready)
              FilledButton.icon(
                onPressed: up.installNow,
                icon: const Icon(Icons.system_update_alt_rounded, size: 18),
                label: const Text('Перезапустить и обновить'),
              ),
            OutlinedButton.icon(
              onPressed: up.state == UpdateState.checking || up.state == UpdateState.downloading ? null : up.check,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Проверить обновления'),
            ),
          ]),
        ]);
      },
    );
  }
}

String _size(int bytes) {
  if (bytes >= 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} ГБ';
  return '${(bytes / (1024 * 1024)).round()} МБ';
}

class _CacheSection extends StatelessWidget {
  const _CacheSection();

  @override
  Widget build(BuildContext context) {
    final cache = Services.of(context).cache;
    const limits = [1024, 2048, 5120, 10240, 20480];
    return ListenableBuilder(
      listenable: cache,
      builder: (context, _) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Кэш и офлайн', style: display(20)),
        const SizedBox(height: 10),
        const Text(
          'Прослушанные треки сохраняются на компьютере и в следующий раз играют сразу, даже без интернета. '
          'Любимое и плейлисты можно сохранить целиком кнопкой «Сохранить офлайн» на их странице.',
          style: TextStyle(color: C.muted, fontSize: 15, height: 1.5),
        ),
        const SizedBox(height: 16),
        Wrap(spacing: 16, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text('Занято ${_size(cache.sizeBytes)}', style: const TextStyle(fontSize: 15)),
          Row(mainAxisSize: MainAxisSize.min, children: [
            const Text('Предел:', style: TextStyle(color: C.muted)),
            const SizedBox(width: 10),
            DropdownButton<int>(
              value: limits.contains(cache.settings.cacheLimitMb) ? cache.settings.cacheLimitMb : 2048,
              dropdownColor: C.raised,
              underline: const SizedBox.shrink(),
              items: [for (final l in limits) DropdownMenuItem(value: l, child: Text(_size(l * 1024 * 1024)))],
              onChanged: (v) {
                if (v != null) cache.setLimit(v);
              },
            ),
          ]),
          OutlinedButton(
            onPressed: () async {
              final ok = await confirm(context,
                  title: 'Очистить кэш?',
                  text: 'Удалятся сохранённые треки, кроме отмеченных «Сохранить офлайн». Музыка на Диске не пострадает.',
                  action: 'Очистить');
              if (ok) await cache.clear();
            },
            child: const Text('Очистить кэш'),
          ),
        ]),
        if (cache.pending > 0) ...[
          const SizedBox(height: 8),
          Text('Скачивается в фоне: ${countTracks(cache.pending)}', style: const TextStyle(color: C.faint, fontSize: 13)),
        ],
      ]),
    );
  }
}

class _LogSection extends StatefulWidget {
  const _LogSection();
  @override
  State<_LogSection> createState() => _LogSectionState();
}

class _LogSectionState extends State<_LogSection> {
  bool _sending = false;

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final errors = AppLog.recentErrors();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Журнал ошибок', style: display(20)),
      const SizedBox(height: 10),
      Text(
        errors == 0
            ? 'За последние три дня ошибок не было.'
            : 'За последние три дня: ${errors} ${plural(errors, 'ошибка', 'ошибки', 'ошибок')}. '
                'Если что-то сломалось, отправьте журнал: он попадёт в общую папку, в cave-data.',
        style: const TextStyle(color: C.muted, fontSize: 15, height: 1.5),
      ),
      const SizedBox(height: 16),
      Wrap(spacing: 12, runSpacing: 10, children: [
        OutlinedButton.icon(
          onPressed: _sending
              ? null
              : () async {
                  setState(() => _sending = true);
                  try {
                    await app.lib.uploadLog(AppLog.tail(2000));
                    app.lib.messages.add('Журнал отправлен в общую папку, в cave-data');
                  } catch (e) {
                    app.lib.messages.add('Не получилось отправить журнал: $e');
                  } finally {
                    if (mounted) setState(() => _sending = false);
                  }
                },
          icon: const Icon(Icons.upload_file_rounded, size: 18),
          label: Text(_sending ? 'Отправляю…' : 'Отправить журнал'),
        ),
        OutlinedButton.icon(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: AppLog.tail()));
            app.lib.messages.add('Журнал скопирован');
          },
          icon: const Icon(Icons.copy_rounded, size: 18),
          label: const Text('Скопировать'),
        ),
        if (AppLog.dir != null)
          OutlinedButton.icon(
            onPressed: () => launchUrl(Uri.file(AppLog.dir!.path)),
            icon: const Icon(Icons.folder_open_rounded, size: 18),
            label: const Text('Открыть папку'),
          ),
      ]),
    ]);
  }
}
