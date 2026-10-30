import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app.dart';
import '../config.dart';
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
                          text: 'Аккаунт отключится только на этом компьютере. Папки, которые открывались только через него, перестанут играть здесь, '
                              'но треки в общей библиотеке и у друзей останутся как были: ничего не удаляется.',
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
          const _DiscordSection(),
          const SizedBox(height: 44),
          const _TraySection(),
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

class _UpdatesSection extends StatefulWidget {
  const _UpdatesSection();
  @override
  State<_UpdatesSection> createState() => _UpdatesSectionState();
}

class _UpdatesSectionState extends State<_UpdatesSection> {
  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    final up = Services.of(context).updater;
    // После кадра: список сам сообщает о загрузке, а во время сборки виджетов это запрещено
    if (up.enabled) WidgetsBinding.instance.addPostFrameCallback((_) => up.loadTestBuilds());
  }

  Future<void> _install(BuildInfo b) async {
    final up = Services.of(context).updater;
    final older = !Updater.isNewer(b.version, kAppVersion);
    final ok = await confirm(
      context,
      title: b.stable ? 'Вернуться на обычную версию ${b.version}?' : 'Поставить тестовую сборку ${b.version}?',
      text: [
        if (!b.stable) 'Ветка «${b.branch}». Тестовые сборки могут работать с ошибками.',
        if (!b.stable) 'Дальше Cave Player будет обновляться сборками этой ветки, а когда её удалят — вернётся к обычным версиям.',
        if (older) 'Эта версия старее установленной — Cave Player поставит её поверх.',
        'Cave Player закроется и откроется уже с новой версией.',
      ].join('\n\n'),
      action: 'Поставить',
    );
    if (ok) await up.install(b);
  }

  @override
  Widget build(BuildContext context) {
    final up = Services.of(context).updater;
    return ListenableBuilder(
      listenable: up,
      builder: (context, _) {
        final last = up.lastCheck;
        final busy = up.state == UpdateState.checking || up.state == UpdateState.downloading;
        final status = switch (up.state) {
          UpdateState.checking => 'Проверяю…',
          UpdateState.downloading => 'Скачиваю версию ${up.latest} (${(up.progress * 100).round()}%)',
          UpdateState.ready => 'Версия ${up.latest} скачана и готова к установке',
          UpdateState.upToDate => up.isTestBuild ? 'У вас последняя сборка этой ветки' : 'У вас последняя версия',
          UpdateState.error => up.error ?? 'Не получилось проверить',
          UpdateState.idle => 'Обновления проверяются сами раз в 4 часа',
        };
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Обновления', style: display(20)),
          const SizedBox(height: 10),
          Text(
            up.isTestBuild
                ? 'Установлена тестовая сборка ${up.currentVersion} ветки «${up.channel}»'
                : up.isBeta
                    ? 'Установлена бета-версия ${up.currentVersion}'
                    : 'Установлена версия ${up.currentVersion}',
            style: TextStyle(color: up.isTestBuild || up.isBeta ? C.accent : C.muted, fontSize: 15),
          ),
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
              onPressed: busy ? null : up.check,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Проверить обновления'),
            ),
            // С тестовой сборки или с беты, когда галочку сняли, — можно вернуться сразу
            if (up.isTestBuild || (up.isBeta && !up.beta))
              OutlinedButton.icon(
                onPressed: busy || !up.enabled
                    ? null
                    : () async {
                        final ok = await confirm(
                          context,
                          title: 'Вернуться на обычную версию?',
                          text: 'Cave Player поставит последнюю обычную версию и дальше будет обновляться как у всех.',
                          action: 'Вернуться',
                        );
                        if (ok) await up.installStable();
                      },
                icon: const Icon(Icons.undo_rounded, size: 18),
                label: const Text('Вернуться на обычную версию'),
              ),
          ]),
          const SizedBox(height: 12),
          SizedBox(
            width: 560,
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: up.beta,
              onChanged: !up.enabled
                  ? null
                  : (v) async {
                      final app = Services.of(context);
                      app.settings.betaUpdates = v;
                      await app.lib.saveSettings();
                      await up.setBeta(v);
                    },
              title: const Text('Получать бета-версии'),
              subtitle: Text(
                up.beta
                    ? 'Новые функции приходят раньше, но могут работать с ошибками.'
                        '${up.latestBeta == null ? '' : ' Последняя бета: ${up.latestBeta}.'}'
                    : 'Новые функции раньше всех. Бета ставится так же сама, как обычные обновления.',
                style: const TextStyle(color: C.faint, fontSize: 13, height: 1.4),
              ),
            ),
          ),
          const SizedBox(height: 26),
          Row(children: [
            Text('Тестовые сборки', style: display(17)),
            const SizedBox(width: 8),
            IconButton(
              tooltip: 'Обновить список',
              visualDensity: VisualDensity.compact,
              onPressed: up.loadingBuilds || !up.enabled ? null : up.loadTestBuilds,
              icon: up.loadingBuilds
                  ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh_rounded, size: 18),
            ),
          ]),
          const SizedBox(height: 4),
          const Text(
            'Сборки из веток, которые ещё не попали в основную версию. Можно поставить, чтобы проверить новое до выхода для всех.',
            style: TextStyle(color: C.faint, fontSize: 13, height: 1.45),
          ),
          const SizedBox(height: 10),
          if (!up.enabled)
            const Text('Доступно в версии, установленной через CavePlayer-Setup.exe.', style: TextStyle(color: C.faint, fontSize: 13))
          else if (up.buildsError != null)
            Text(up.buildsError!, style: const TextStyle(color: C.danger, fontSize: 13))
          else if (up.testBuilds.isEmpty && !up.loadingBuilds)
            const Text('Сейчас тестовых сборок нет.', style: TextStyle(color: C.faint, fontSize: 13))
          else
            for (final b in up.testBuilds)
              _BuildRow(
                info: b,
                current: up.isTestBuild && b.version == kAppVersion,
                busy: busy,
                installing: up.installing == b,
                onInstall: () => _install(b),
              ),
        ]);
      },
    );
  }
}

class _BuildRow extends StatelessWidget {
  final BuildInfo info;
  final bool current;
  final bool busy;
  final bool installing;
  final VoidCallback onInstall;
  const _BuildRow({required this.info, required this.current, required this.busy, required this.installing, required this.onInstall});

  @override
  Widget build(BuildContext context) {
    final b = info;
    final when = b.published?.toLocal();
    final date = when == null ? '' : ' · ${when.day.toString().padLeft(2, '0')}.${when.month.toString().padLeft(2, '0')} ${TimeOfDay.fromDateTime(when).format(context)}';
    return Container(
      constraints: const BoxConstraints(maxWidth: 640),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
      decoration: BoxDecoration(
        color: current ? C.raised : null,
        border: Border.all(color: current ? C.accent : C.line),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(children: [
        const Icon(Icons.science_outlined, size: 20, color: C.muted),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(b.branch, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text('Версия ${b.version}$date', style: const TextStyle(color: C.faint, fontSize: 12)),
            if (b.summary.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(b.summary, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.muted, fontSize: 13)),
            ],
          ]),
        ),
        const SizedBox(width: 12),
        if (current)
          const Text('установлена', style: TextStyle(color: C.accent, fontSize: 13))
        else if (installing)
          const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
        else
          OutlinedButton(onPressed: busy ? null : onInstall, child: const Text('Поставить')),
      ]),
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

class _TraySection extends StatefulWidget {
  const _TraySection();
  @override
  State<_TraySection> createState() => _TraySectionState();
}

class _TraySectionState extends State<_TraySection> {
  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Работа в фоне', style: display(20)),
      const SizedBox(height: 10),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: app.settings.trayOnClose,
        activeColor: C.accent,
        title: const Text('Сворачивать в трей при закрытии окна'),
        subtitle: const Text(
          'Музыка играет дальше, а Cave Player остаётся значком у часов. Закрыть совсем можно пунктом «Выйти» в меню значка.',
          style: TextStyle(color: C.faint, fontSize: 13, height: 1.4),
        ),
        onChanged: (v) async {
          setState(() {
            app.settings
              ..trayOnClose = v
              ..trayAsked = true;
          });
          await app.lib.saveSettings();
        },
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: app.settings.globalMediaKeys,
        activeColor: C.accent,
        title: const Text('Медиаклавиши, когда окно не активно'),
        subtitle: const Text(
          '⏮ ⏯ ⏭ на клавиатуре (в том числе Fn+F-клавиши ноутбука) работают, даже если Cave Player свёрнут или спрятан в трей.',
          style: TextStyle(color: C.faint, fontSize: 13, height: 1.4),
        ),
        onChanged: (v) async {
          setState(() => app.settings.globalMediaKeys = v);
          app.mediaKeys.refresh();
          await app.lib.saveSettings();
        },
      ),
    ]);
  }
}

class _DiscordSection extends StatefulWidget {
  const _DiscordSection();
  @override
  State<_DiscordSection> createState() => _DiscordSectionState();
}

class _DiscordSectionState extends State<_DiscordSection> {
  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Статус в Discord', style: display(20)),
      const SizedBox(height: 10),
      if (kDiscordClientId.isEmpty)
        const Text(
          'В этой сборке статус в Discord выключен: не задан ID приложения Discord (переменная DISCORD_CLIENT_ID в сборке).',
          style: TextStyle(color: C.faint, fontSize: 13, height: 1.45),
        )
      else
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: app.settings.discord,
          activeColor: C.accent,
          title: const Text('Показывать в Discord, что я слушаю'),
          subtitle: const Text('Друзья в Discord увидят название трека и исполнителя, пока музыка играет.',
              style: TextStyle(color: C.faint, fontSize: 13)),
          onChanged: (v) async {
            setState(() => app.settings.discord = v);
            await app.lib.saveSettings();
            app.discord.update(app.player.current,
                playing: app.player.playing,
                position: app.player.position.value,
                duration: app.player.duration,
                enabled: v);
          },
        ),
    ]);
  }
}
