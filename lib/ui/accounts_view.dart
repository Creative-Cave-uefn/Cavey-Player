import 'dart:io';
import '../core/dl/sockseek.dart';
import '../core/dl/deezer.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app.dart';
import '../config.dart';
import '../core/log.dart';
import '../core/updater.dart';
import 'sources_view.dart';
import 'ambient.dart';
import 'theme.dart';
import 'widgets.dart';
import 'glass_popup.dart';

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
            'Можно подключить несколько аккаунтов Google. Cavey сам выберет, через какой открывать каждую папку. '
            'Лайки и плейлисты подписываются основным аккаунтом.',
            style: TextStyle(color: C.muted, fontSize: 15, height: 1.5),
          ),
          const SizedBox(height: 24),
          for (final a in accounts.accounts)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 14),
              decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: C.divider))),
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
                          child: Text('основной', style: TextStyle(color: C.accent, fontSize: 12)),
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
                GlassMenuButton<String>(
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
          const LibrarySection(),
          const SizedBox(height: 44),
          const _UpdatesSection(),
          const SizedBox(height: 44),
          const _DiscordSection(),
          const SizedBox(height: 44),
          const _PlaybackSection(),
          const SizedBox(height: 44),
          const _AccentSection(),
          const SizedBox(height: 44),
          const _LookSection(),
          const SizedBox(height: 44),
          const _TraySection(),
          const SizedBox(height: 36),
          const _DownloaderSection(),
          const SizedBox(height: 24),
          const _KaraokeSection(),
          const SizedBox(height: 44),
          const _CacheSection(),
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
          const SizedBox(height: 44),
          const _DebugSection(),
        ]);
      },
    );
  }
}

/// Всё, что обычному человеку трогать не нужно: тестовые сборки, хранение данных, журнал
class _DebugSection extends StatelessWidget {
  const _DebugSection();

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 20),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        title: Text('Отладка (не лезь - убьёт)', style: display(20, color: C.muted)),
        children: const [
          _TestBuildsSection(),
          SizedBox(height: 32),
          LibraryDebug(),
          SizedBox(height: 32),
          _LogSection(),
        ],
      ),
    );
  }
}

class _UpdatesSection extends StatefulWidget {
  const _UpdatesSection();
  @override
  State<_UpdatesSection> createState() => _UpdatesSectionState();
}

class _UpdatesSectionState extends State<_UpdatesSection> {
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
                          text: 'Cavey поставит последнюю обычную версию и дальше будет обновляться как у всех.',
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
        ]);
      },
    );
  }
}

class _TestBuildsSection extends StatefulWidget {
  const _TestBuildsSection();
  @override
  State<_TestBuildsSection> createState() => _TestBuildsSectionState();
}

class _TestBuildsSectionState extends State<_TestBuildsSection> {
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
        if (!b.stable) 'Дальше Cavey будет обновляться сборками этой ветки, а когда её удалят — вернётся к обычным версиям.',
        if (older) 'Эта версия старее установленной — Cavey поставит её поверх.',
        'Cavey закроется и откроется уже с новой версией.',
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
        final busy = up.state == UpdateState.checking || up.state == UpdateState.downloading;
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
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
          Text('установлена', style: TextStyle(color: C.accent, fontSize: 13))
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
      Text('Журнал ошибок', style: display(17)),
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

/// Точное караоке: время слов считает Whisper по звуку
class _KaraokeSection extends StatelessWidget {
  const _KaraokeSection();

  @override
  Widget build(BuildContext context) {
    final k = Services.of(context).karaoke;
    return ListenableBuilder(
      listenable: k,
      builder: (context, _) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Точное караоке', style: display(20)),
        const SizedBox(height: 10),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: k.enabled,
          activeColor: C.accent,
          title: const Text('Вычислять время каждого слова по звуку'),
          subtitle: const Text(
            'В кинотеатре текст заливается слово за словом точно в такт. Считает программа Whisper на этом компьютере, '
            'в фоне и на половине ядер: около минуты на трек. Посчитанное сохраняется в общей папке — '
            'каждый трек считается один раз на всю компанию. Без этого слова загораются по слогам примерно.',
            style: TextStyle(color: C.faint, fontSize: 13, height: 1.4),
          ),
          onChanged: k.setEnabled,
        ),
        const SizedBox(height: 6),
        Row(children: [
          const Expanded(
            child: Text('Задержка звука устройства (например, Bluetooth-наушники): текст идёт раньше на столько миллисекунд',
                style: TextStyle(color: C.faint, fontSize: 13, height: 1.4)),
          ),
          SizedBox(
            width: 220,
            child: Slider(
              value: k.globalDelayMs.toDouble(),
              min: 0,
              max: 600,
              divisions: 24,
              label: '${k.globalDelayMs} мс',
              onChanged: (v) => k.setGlobalDelay(v.round()),
            ),
          ),
          SizedBox(width: 60, child: Text('${k.globalDelayMs} мс', style: const TextStyle(color: C.muted, fontSize: 13))),
        ]),
        if (k.enabled) ...[
          const SizedBox(height: 6),
          Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            const Text('Модель:', style: TextStyle(color: C.muted)),
            for (final (id, label) in const [('base', 'Быстрая — 142 МБ'), ('small', 'Точная — 466 МБ')])
              ChoiceChip(
                label: Text(label),
                selected: k.model == id,
                onSelected: (_) => k.setModel(id),
                selectedColor: C.accent,
                labelStyle: TextStyle(color: k.model == id ? C.accentInk : C.text),
              ),
          ]),
          const SizedBox(height: 6),
          const Text('Для русского и японского лучше «Точная». Модель скачивается один раз, при первом треке.',
              style: TextStyle(color: C.faint, fontSize: 13)),
          if (k.status.isNotEmpty) ...[
            const SizedBox(height: 10),
            Row(children: [
              k.status.startsWith('Не получилось')
                  ? const Icon(Icons.error_outline_rounded, size: 16, color: C.danger)
                  : SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2, value: k.progress)),
              const SizedBox(width: 10),
              Expanded(child: Text(k.status, style: const TextStyle(color: C.muted, fontSize: 13))),
            ]),
          ],
        ],
      ]),
    );
  }
}

class _PlaybackSection extends StatefulWidget {
  const _PlaybackSection();
  @override
  State<_PlaybackSection> createState() => _PlaybackSectionState();
}

class _PlaybackSectionState extends State<_PlaybackSection> {
  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final sec = app.settings.crossfadeSec;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Плавный переход', style: display(20)),
      const SizedBox(height: 6),
      const Text(
        'Конец трека затихает, а следующий в это время нарастает. Не работает, если вы сами переключили трек, '
        'перемотали в конец или слушаете вместе с другом, а также на коротких треках.',
        style: TextStyle(color: C.faint, fontSize: 13, height: 1.4),
      ),
      const SizedBox(height: 4),
      Row(children: [
        Expanded(
          child: Slider(
            value: sec.toDouble(),
            min: 0,
            max: 10,
            divisions: 10,
            label: sec == 0 ? 'Выключено' : '$sec с',
            onChanged: (v) => setState(() => app.settings.crossfadeSec = v.round()),
            onChangeEnd: (_) => app.lib.saveSettings(),
          ),
        ),
        SizedBox(
          width: 90,
          child: Text(sec == 0 ? 'Выключено' : '$sec с', textAlign: TextAlign.right, style: const TextStyle(color: C.muted)),
        ),
      ]),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: app.player.smartMix,
        onChanged: sec == 0
            ? null
            : (v) {
                setState(() => app.settings.view['mix.smart'] = v ? '1' : '0');
                app.lib.saveSettings();
              },
        title: const Text('Умный переход'),
        subtitle: const Text(
          'Как Automix в Spotify: переход начинается там, где песня на самом деле затихает, тишина в начале следующей '
          'пропускается, громкость двух треков выравнивается, а длина перехода — целое число тактов, если известен темп. '
          'Ползунок выше задаёт самый длинный переход. Звук трека разбирается один раз в фоне; пока не готово — обычный переход.',
          style: TextStyle(color: C.faint, fontSize: 13, height: 1.4),
        ),
      ),
    ]);
  }
}

/// Яркость и контраст фона окна
/// Смена акцентного цвета: кнопки, переключатели, ползунки, выделения. Хранится в настройках вида,
/// применяется сразу и при следующих запусках
class _AccentSection extends StatefulWidget {
  const _AccentSection();
  @override
  State<_AccentSection> createState() => _AccentSectionState();
}

class _AccentSectionState extends State<_AccentSection> {
  Future<void> _pick(Color? c) async {
    final app = Services.of(context);
    setState(() {
      if (c == null) {
        app.settings.view.remove('accent');
      } else {
        app.settings.view['accent'] = C.accentHex(c);
      }
    });
    C.setAccent(c ?? C.defaultAccent);
    rebuildEverything();
    await app.lib.saveSettings();
  }

  @override
  Widget build(BuildContext context) {
    final current = C.accent.value;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Text('Акцентный цвет', style: display(20))),
        if (current != C.defaultAccent.value) TextButton(onPressed: () => _pick(null), child: const Text('Как было')),
      ]),
      const SizedBox(height: 6),
      const Text('Цвет кнопок, переключателей, ползунков и выделений.', style: TextStyle(color: C.faint, fontSize: 13)),
      const SizedBox(height: 14),
      Wrap(spacing: 12, runSpacing: 12, children: [
        for (final (name, color) in accentChoices)
          Tooltip(
            message: name,
            child: Semantics(
              button: true,
              selected: current == color.value,
              label: name,
              child: GestureDetector(
                onTap: () => _pick(color),
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: Border.all(color: current == color.value ? C.text : C.line, width: current == color.value ? 2.5 : 1),
                    ),
                    child: current == color.value
                        ? Icon(Icons.check_rounded, size: 20, color: color.computeLuminance() > 0.42 ? const Color(0xFF241C06) : Colors.white)
                        : null,
                  ),
                ),
              ),
            ),
          ),
      ]),
    ]);
  }
}

class _LookSection extends StatefulWidget {
  const _LookSection();
  @override
  State<_LookSection> createState() => _LookSectionState();
}

class _LookSectionState extends State<_LookSection> {
  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final (bright, contrast) = AmbientScope.lookOf(app.settings);
    void set(String key, double v) {
      setState(() => app.settings.view[key] = v.toStringAsFixed(2));
      AmbientScope.look.value = AmbientScope.lookOf(app.settings);
    }

    Widget row(String label, String key, double v, double min, double max) => Row(children: [
          SizedBox(width: 110, child: Text(label, style: const TextStyle(color: C.muted))),
          Expanded(
            child: Slider(
              value: v,
              min: min,
              max: max,
              onChanged: (x) => set(key, x),
              onChangeEnd: (_) => app.lib.saveSettings(),
            ),
          ),
          SizedBox(width: 56, child: Text('${(v * 100).round()}%', textAlign: TextAlign.right, style: const TextStyle(color: C.muted))),
        ]);

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Text('Фон', style: display(20))),
        if (bright != 1 || contrast != 1)
          TextButton(
            onPressed: () {
              setState(() {
                app.settings.view.remove('ambient.bright');
                app.settings.view.remove('ambient.contrast');
              });
              AmbientScope.look.value = AmbientScope.lookOf(app.settings);
              app.lib.saveSettings();
            },
            child: const Text('Как было'),
          ),
      ]),
      const SizedBox(height: 6),
      const Text('Цвета фона из обложки трека или фото профиля: сделайте их ярче или контрастнее.',
          style: TextStyle(color: C.faint, fontSize: 13, height: 1.4)),
      const SizedBox(height: 4),
      row('Яркость', 'ambient.bright', bright, 0.4, 1.8),
      row('Контраст', 'ambient.contrast', contrast, 0.5, 1.8),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        const Text('Движение:', style: TextStyle(color: C.muted)),
        for (final (id, label) in const [('live', 'Живой'), ('calm', 'Спокойный'), ('still', 'Неподвижный')])
          ChoiceChip(
            label: Text(label),
            selected: AmbientScope.modeOf(app.settings) == id,
            onSelected: (_) {
              setState(() => app.settings.view['ambient.mode'] = id);
              AmbientScope.mode.value = id;
              app.lib.saveSettings();
            },
          ),
      ]),
      const Padding(
        padding: EdgeInsets.only(top: 4),
        child: Text('Неподвижный и спокойный фон меньше нагружают процессор.', style: TextStyle(color: C.faint, fontSize: 13)),
      ),
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
          'Музыка играет дальше, а Cavey остаётся значком у часов. Закрыть совсем можно пунктом «Выйти» в меню значка.',
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
          '⏮ ⏯ ⏭ на клавиатуре (в том числе Fn+F-клавиши ноутбука) работают, даже если Cavey свёрнут или спрятан в трей.',
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



class _DownloaderSection extends StatefulWidget {
  const _DownloaderSection();
  @override
  State<_DownloaderSection> createState() => _DownloaderSectionState();
}

class _DownloaderSectionState extends State<_DownloaderSection> {
  bool _installing = false;
  bool _checking = false;
  String _installLog = '';
  String _matchResult = '';

  Future<void> _installSockseek() async {
    final app = Services.of(context);
    setState(() { _installing = true; _installLog = 'Устанавливаю Sockseek…'; });
    try {
      await Sockseek.install(app.downloads.tools, (line) {
        if (mounted) setState(() => _installLog = '$_installLog\n$line');
      });
      app.settings.downloadProvider = 'sockseek';
      await app.lib.saveSettings();
    } catch (e) {
      if (mounted) setState(() => _installLog += '\nОшибка: $e');
    } finally { if (mounted) setState(() => _installing = false); }
  }

  Future<void> _configureSockseek() async {
    final app = Services.of(context);
    try {
      await Sockseek.prepareConfig(app.downloads.tools);
      final path = Sockseek.config(app.downloads.tools).absolute.path;
      if (Platform.isWindows) {
        await Process.start('notepad.exe', [path], mode: ProcessStartMode.detached);
      } else {
        await launchUrl(Uri.file(path));
      }
    } catch (e) {
      if (mounted) setState(() => _installLog = 'Не удалось открыть конфиг: $e');
    }
  }

  Future<void> _installDeezer() async {
    final app = Services.of(context);
    setState(() { _installing = true; _installLog = 'Устанавливаю Deezer…'; });
    try {
      await DeezerMusic.install(app.downloads.tools, (line) {
        if (mounted) setState(() => _installLog += '\n$line');
      });
      app.settings.downloadProvider = 'deezer';
      await app.lib.saveSettings();
    } catch (e) {
      if (mounted) setState(() => _installLog += '\nОшибка: $e');
    } finally { if (mounted) setState(() => _installing = false); }
  }

  Future<void> _configureDeezer() async {
    final app = Services.of(context);
    try {
      await DeezerMusic.prepareConfig(app.downloads.tools);
      final path = DeezerMusic.config(app.downloads.tools).absolute.path;
      if (Platform.isWindows) {
        await Process.start('notepad.exe', [path], mode: ProcessStartMode.detached);
      } else {
        await launchUrl(Uri.file(path));
      }
    } catch (e) {
      if (mounted) setState(() => _installLog = 'Не удалось открыть конфиг Deezer: $e');
    }
  }

  Future<void> _checkMatch() async {
    final app = Services.of(context);
    final track = app.player.current;
    if (track == null) {
      setState(() => _matchResult = 'Сначала включите трек, который хотите проверить.');
      return;
    }
    setState(() { _checking = true; _matchResult = 'Проверяю ${track.displayArtist} — ${track.title}…'; });
    final diagnostics = <String>[];
    try {
      final duration = app.player.duration > Duration.zero ? app.player.duration : Duration(milliseconds: track.durationMs ?? 0);
      final response = await app.lyrics.betterLyrics.fetch(track, duration, onDiagnostic: diagnostics.add)
          .timeout(const Duration(seconds: 15));
      final result = response?.lyrics;
      if (mounted) setState(() => _matchResult = (result == null
          ? 'Для «${track.title}» текст Better Lyrics не найден. Плеер использует другие источники текста.'
          : 'Better Lyrics, синхронизация ${result.lines.any((l) => l.words?.isNotEmpty == true) ? 'по словам/слогам' : 'по строкам'}: «${track.title}», строк: ${result.lines.length}, '
            'сегментов с таймкодами: ${result.lines.fold<int>(0, (n, line) => n + (line.words?.length ?? 0))}. '
            'Обновите текст в панели песни, чтобы загрузить эту разметку.') + '\n' + diagnostics.join('\n'));
    } catch (e) {
      if (mounted) setState(() => _matchResult = 'Better Lyrics сейчас недоступен: $e. Плеер использует LRCLIB.\n${diagnostics.join('\n')}');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Загрузчик музыки', style: display(20)),
      const SizedBox(height: 10),
      const Text('Deezer загружает через локальную Python-библиотеку. Полный поиск последовательно пробует Deezer → Soulseek → YouTube → Bandcamp для каждого трека. Альбомы обрабатываются параллельно (до 3 треков).',
          style: TextStyle(color: C.faint, fontSize: 12, height: 1.4)),
      const SizedBox(height: 12),
      DropdownButtonFormField<String>(
        value: app.settings.downloadProvider,
        decoration: const InputDecoration(labelText: 'Активный загрузчик'),
        items: const [
          DropdownMenuItem(value: 'youtube', child: Text('YouTube / YouTube Music')),
          DropdownMenuItem(value: 'deezer', child: Text('Deezer (локальный модуль)')),
          DropdownMenuItem(value: 'full', child: Text('Полный поиск (Deezer → Soulseek → YouTube → Bandcamp)')),
          DropdownMenuItem(value: 'sockseek', child: Text('Sockseek (Soulseek)')),
          DropdownMenuItem(value: 'bandcamp', child: Text('Bandcamp (ссылки)')),
        ],
        onChanged: _installing || app.downloads.busy ? null : (value) {
          if (value == null) return;
          setState(() => app.settings.downloadProvider = value);
          app.lib.saveSettings();
        },
      ),
      if (_installLog.isNotEmpty)
        ConstrainedBox(constraints: const BoxConstraints(maxHeight: 180),
          child: SingleChildScrollView(child: SelectableText(_installLog, style: const TextStyle(fontSize: 12)))),
      const SizedBox(height: 10),
      Wrap(spacing: 8, runSpacing: 8, children: [
        FilledButton.icon(
          onPressed: _installing || app.downloads.busy ? null : _installSockseek,
          icon: const Icon(Icons.download_rounded), label: const Text('Установить Sockseek'),
        ),
        OutlinedButton.icon(
          onPressed: _installing || app.downloads.busy ? null : _configureSockseek,
          icon: const Icon(Icons.settings_outlined), label: const Text('Открыть конфиг Soulseek'),
        ),
      ]),
      const SizedBox(height: 10),
      Wrap(spacing: 8, runSpacing: 8, children: [
        FilledButton.icon(
          onPressed: _installing || app.downloads.busy ? null : _installDeezer,
          icon: const Icon(Icons.download_rounded), label: const Text('Установить Deezer'),
        ),
        OutlinedButton.icon(
          onPressed: _installing || app.downloads.busy ? null : _configureDeezer,
          icon: const Icon(Icons.settings_outlined), label: const Text('Открыть конфиг Deezer'),
        ),
      ]),
      const SizedBox(height: 8),
      const Text('Deezer требует Python 3.10+. Авторизация заполняется автоматически, если данные включены в сборку. Файл deezer_auth.ini остаётся на устройстве. '
          'Не публикуйте ARL в GitHub. Качество зависит от подписки и доступности релиза.',
          style: TextStyle(color: C.faint, fontSize: 12, height: 1.4)),
      const SizedBox(height: 8),
      const Text('Sockseek бесплатный. Откройте конфиг, замените username и password на данные отдельного аккаунта Soulseek и сохраните файл. '
          'Пароль хранится локально в этом файле открытым текстом. Данные Spotify не подходят. '
          'Поиск: «Исполнитель - Название» либо ссылки Spotify, Яндекс Музыки и Deezer. '
          'Проверяются название, исполнитель и известная длительность (±3 с). Доступность зависит от пользователей Soulseek. '
          'Скачивайте только файлы, на получение которых у вас есть право.',
          style: TextStyle(color: C.faint, fontSize: 12, height: 1.4)),
      TextButton(onPressed: () => launchUrl(Uri.parse('https://github.com/fiso64/sockseek')),
          child: const Text('Sockseek · исходный код и лицензия AGPL-3.0')),
      const SizedBox(height: 8),
      const Text('Bandcamp: доступно аудио, которое можно прослушать на странице. Это не покупка и не оригинальный FLAC; '           'скачивайте только музыку, на которую у вас есть права.',
          style: TextStyle(color: C.faint, fontSize: 12, height: 1.4)),
      const SizedBox(height: 18),
      OutlinedButton.icon(
        onPressed: _checking ? null : _checkMatch,
        icon: const Icon(Icons.lyrics_outlined),
        label: Text(_checking ? 'Проверяю Better Lyrics…' : 'Проверить Better Lyrics на текущем треке'),
      ),
      TextButton(onPressed: () => launchUrl(Uri.parse('https://better-lyrics.boidu.dev')), child: const Text('Тексты предоставлены Better Lyrics')),
      if (_matchResult.isNotEmpty) SelectableText(_matchResult, style: const TextStyle(color: C.faint, height: 1.5)),
    ]);
  }
}


