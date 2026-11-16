import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app.dart';
import '../config.dart';
import '../core/audio_format.dart';
import '../core/autostart.dart';
import '../core/log.dart';
import '../core/notices.dart';
import '../core/notify_prefs.dart';
import '../core/store.dart' show Settings;
import '../core/updater.dart';
import 'sources_view.dart';
import 'ambient.dart';
import 'intel_panel.dart';
import 'intel_viz.dart';
import 'player_bar.dart' show SeekEdgeSample, seekEdgeWave, seekWaveLength, seekWaveMin, seekWaveMax;
import 'migration_ui.dart';
import 'theme.dart';
import 'widgets.dart';
import 'glass_popup.dart';
import 'notice_tower.dart' show ToastCard, noticePreviewing;

/// Вкладки настроек: id для ссылок (Nav('accounts', id)) и подпись
const settingsTabs = <(String, String)>[
  ('main', 'Основное'),
  ('playback', 'Воспроизведение'),
  ('look', 'Внешний вид'),
  ('account', 'Аккаунт'),
  ('notify', 'Уведомления'),
  ('library', 'Библиотека'),
  ('debug', 'Отладка'),
];

class AccountsPage extends StatefulWidget {
  /// С какой вкладки открыть; null — с той, что была открыта в прошлый раз
  final String? tab;
  const AccountsPage({super.key, this.tab});
  @override
  State<AccountsPage> createState() => _AccountsPageState();
}

class _AccountsPageState extends State<AccountsPage> {
  String? _error;
  String? _tab;

  String _current(AppServices app) {
    final t = _tab ?? widget.tab ?? app.settings.viewOf('settings.tab', 'main');
    return settingsTabs.any((x) => x.$1 == t) ? t : 'main';
  }

  void _open(AppServices app, String id) {
    setState(() => _tab = id);
    app.settings.view['settings.tab'] = id;
    app.lib.viewChanged();
  }

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
        final tab = _current(app);
        const gap = SizedBox(height: 44);
        final accountsBlock = <Widget>[
          HintHeading('Аккаунты', 'Можно подключить несколько аккаунтов Google. Cavey сам выберет, через какой открывать каждую папку. '
            'Лайки и плейлисты подписываются основным аккаунтом.'),
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
        ];
        final keyBlock = <Widget>[
          if (!app.keysBuiltIn) ...[
            gap,
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
        ];
        final List<Widget> page = switch (tab) {
          'playback' => const [_PlaybackSection(), gap, _AutoDjSection(), gap, _KaraokeSection()],
          'look' => const [_AccentSection(), gap, _SeekEdgeSection(), gap, _LookSection()],
          'account' => [
              ...accountsBlock,
              gap,
              const _DiscordSection(),
              gap,
              const _FastMessagesSection(),
              gap,
              const LibrarySection(parts: {'invite'}),
              ...keyBlock,
            ],
          'library' => const [
              LibrarySection(parts: {'folders'}),
              gap,
              MigrationSection(),
              gap,
              _CacheSection(),
              gap,
              _DownloaderSection(),
              gap,
              _SpotifySettingsSection(),
              gap,
              LibrarySection(parts: {'leave'}),
            ],
          'notify' => const [_NotifySection()],
          'debug' => const [_DebugSection()],
          _ => const [_UpdatesSection(), gap, _AppWorkSection(), gap, _LocalDownloadSection()],
        };
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(36, 18, 36, 0),
            child: Text('Настройки', style: display(36, weight: FontWeight.w700)),
          ),
          const SizedBox(height: 12),
          // Вкладки в ряд сверху: у каждой своя страница без длинной прокрутки
          SizedBox(
            height: 38,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 36),
              children: [
                for (final (id, label) in settingsTabs)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: SettingsTab(
                      label: label,
                      selected: id == tab,
                      danger: id == 'debug',
                      badge: id == 'account' && accounts.accounts.any((a) => a.needsSignIn),
                      onTap: () => _open(app, id),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: LayoutBuilder(builder: (context, box) {
              // Настройки занимают только левую часть окна: на широком экране строки не растягиваются на всю ширину
              final content = (box.maxWidth * 0.52).clamp(520.0, 960.0);
              final right = (box.maxWidth - 36 - content).clamp(36.0, 100000.0);
              return ListView(
                key: PageStorageKey('settings:$tab'),
                padding: EdgeInsets.fromLTRB(36, 28, right, 40),
                children: page,
              );
            }),
          ),
        ]);
      },
    );
  }
}

/// Вкладка настроек: подсвечена выбранная; у «Отладки» — тревожный цвет, у «Аккаунта» — значок, если нужно войти снова
class SettingsTab extends StatelessWidget {
  final String label;
  final bool selected;
  final bool danger;
  final bool badge;
  final VoidCallback onTap;
  const SettingsTab({super.key, required this.label, required this.selected, required this.onTap, this.danger = false, this.badge = false});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? C.text : C.raised,
      shape: StadiumBorder(side: BorderSide(color: selected ? C.text : C.line)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: selected ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(
              label,
              style: TextStyle(
                color: selected ? C.bg : (danger ? C.danger : C.text),
                fontSize: 14,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
            if (badge) ...[
              const SizedBox(width: 6),
              const Icon(Icons.error_rounded, size: 14, color: C.danger),
            ],
          ]),
        ),
      ),
    );
  }
}

/// Всё, что обычному человеку трогать не нужно: тестовые сборки, хранение данных, журнал
class _DebugSection extends StatelessWidget {
  const _DebugSection();

  @override
  Widget build(BuildContext context) {
    return const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Не лезь — убьёт: здесь то, что обычно трогать не нужно.', style: TextStyle(color: C.danger, fontSize: 13)),
      SizedBox(height: 22),
      _TestBuildsSection(),
      SizedBox(height: 32),
      LibraryDebug(),
      SizedBox(height: 32),
      _WaveDebugSection(),
      SizedBox(height: 32),
      _IntelDebugSection(),
      SizedBox(height: 32),
      _LogSection(),
    ]);
  }
}

/// Анализ звука для отладки: карта схожести библиотеки и спектрограмма играющего трека
class _IntelDebugSection extends StatefulWidget {
  const _IntelDebugSection();
  @override
  State<_IntelDebugSection> createState() => _IntelDebugSectionState();
}

class _IntelDebugSectionState extends State<_IntelDebugSection> {
  bool _building = false;
  bool _hashNames = true;

  Future<void> _buildReport() async {
    final app = Services.of(context);
    setState(() => _building = true);
    String text;
    try {
      text = await app.intel.buildQualityReport(hashNames: _hashNames);
    } catch (e) {
      text = 'Не получилось построить отчёт: $e';
    }
    if (!mounted) return;
    setState(() => _building = false);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Отчёт качества — Анализ звука'),
        content: SizedBox(
          width: 640,
          height: 480,
          child: SingleChildScrollView(child: SelectableText(text, style: const TextStyle(fontSize: 13, height: 1.5))),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              final loc = await getSaveLocation(suggestedName: 'quality-report.txt');
              if (loc == null) return;
              try {
                await File(loc.path).writeAsString(text);
                if (ctx.mounted) Services.of(ctx).lib.messages.add('Отчёт сохранён: ${loc.path}');
              } catch (e) {
                if (ctx.mounted) Services.of(ctx).lib.messages.add('Не получилось сохранить: $e');
              }
            },
            child: const Text('Сохранить в файл'),
          ),
          TextButton(onPressed: () => Clipboard.setData(ClipboardData(text: text)), child: const Text('Скопировать')),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Закрыть')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    return ListenableBuilder(
      listenable: app.intel,
      builder: (context, _) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Анализ звука', style: display(17)),
        const SizedBox(height: 8),
        Text(
          'В индексе записей: ${app.intel.indexed}. Карта показывает, как библиотека раскладывается по звучанию, '
          'спектрограмма — один трек с долями, фразами, энергией и вокалом. Отчёт качества — числовая проверка '
          'разбора и подбора (без прослушивания и без переразбора).',
          style: const TextStyle(color: C.muted, fontSize: 13, height: 1.5),
        ),
        const SizedBox(height: 12),
        Wrap(spacing: 10, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          FilledButton.tonalIcon(
            onPressed: () => showSoundMap(context),
            icon: const Icon(Icons.bubble_chart_rounded, size: 18),
            label: const Text('Карта схожести'),
          ),
          OutlinedButton.icon(
            onPressed: () {
              final t = app.player.current;
              if (t == null) {
                app.lib.messages.add('Включите трек: спектрограмма строится для играющего.');
                return;
              }
              showTrackSpectrogram(context, t);
            },
            icon: const Icon(Icons.graphic_eq_rounded, size: 18),
            label: const Text('Спектрограмма играющего трека'),
          ),
          OutlinedButton.icon(
            onPressed: _building ? null : _buildReport,
            icon: const Icon(Icons.fact_check_rounded, size: 18),
            label: Text(_building ? 'Считаю…' : 'Отчёт качества'),
          ),
          FilterChip(
            label: const Text('Хешировать названия'),
            selected: _hashNames,
            onSelected: (v) => setState(() => _hashNames = v),
          ),
        ]),
      ]),
    );
  }
}

/// «Моя волна» для отладки: режим быстрой настройки и проверка связи с Last.fm
class _WaveDebugSection extends StatefulWidget {
  const _WaveDebugSection();
  @override
  State<_WaveDebugSection> createState() => _WaveDebugSectionState();
}

class _WaveDebugSectionState extends State<_WaveDebugSection> {
  bool _checking = false;

  Future<void> _check() async {
    final wave = Services.of(context).wave;
    setState(() => _checking = true);
    String text;
    try {
      text = await wave.lastfm.diagnoseNow();
    } catch (e) {
      text = 'Не получилось проверить: $e';
    }
    if (!mounted) return;
    setState(() => _checking = false);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Связь с Last.fm'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(child: SelectableText(text, style: const TextStyle(fontSize: 13, height: 1.5))),
        ),
        actions: [
          TextButton(onPressed: () => Clipboard.setData(ClipboardData(text: text)), child: const Text('Скопировать')),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Закрыть')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final wave = app.wave;
    return ListenableBuilder(
      listenable: wave,
      builder: (context, _) {
        final st = wave.lastfmStatus;
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Моя волна', style: display(17)),
          const SizedBox(height: 10),
          HintSwitch(
            contentPadding: EdgeInsets.zero,
            value: wave.tuning,
            title: 'Режим настройки',
            hint: 'Для быстрой настройки вкуса. Пропуск ничего не штрафует: ни трек, ни исполнителя, '
                'пробный трек не удаляется. Лайки, «нравится в волне» и дослушивания весят в полтора раза больше. '
                '«Не нравится» работает как обычно. Закончили настраивать — выключите.',
            onChanged: wave.setTuning,
          ),
          const SizedBox(height: 14),
          Text(
            st.isEmpty ? 'Last.fm: проблем сейчас не видно.' : st,
            style: TextStyle(color: st.isEmpty ? C.muted : C.danger, fontSize: 14, height: 1.5),
          ),
          const SizedBox(height: 8),
          const Text(
            'Каждый сбой Last.fm пишется в журнал: причина, время ответа, заголовки и начало ответа. '
            'При паузе волна сама проверяет связь по шагам (DNS, TCP, TLS, запрос), чтобы было видно, где рвётся.',
            style: TextStyle(color: C.muted, fontSize: 13, height: 1.5),
          ),
          const SizedBox(height: 12),
          Wrap(spacing: 12, runSpacing: 10, children: [
            OutlinedButton.icon(
              onPressed: _checking ? null : _check,
              icon: const Icon(Icons.network_check_rounded, size: 18),
              label: Text(_checking ? 'Проверяю…' : 'Проверить связь с Last.fm'),
            ),
            OutlinedButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: wave.lastfm.report()));
                app.lib.messages.add('Отчёт Last.fm скопирован');
              },
              icon: const Icon(Icons.copy_rounded, size: 18),
              label: const Text('Скопировать отчёт'),
            ),
          ]),
        ]);
      },
    );
  }
}

/// «Работа приложения»: автозапуск с Windows (выпадающий список), сворачивание в трей и медиаклавиши
class _AppWorkSection extends StatefulWidget {
  const _AppWorkSection();
  @override
  State<_AppWorkSection> createState() => _AppWorkSectionState();
}

class _AppWorkSectionState extends State<_AppWorkSection> {
  Future<void> _set(String mode) async {
    final app = Services.of(context);
    setState(() => app.settings.view['autostart'] = mode);
    await app.lib.saveSettings();
    final ok = await Autostart.apply(mode);
    if (!ok && mode != 'off') app.lib.messages.add('Не получилось включить автозапуск. Подробности в журнале (Отладка).');
  }

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final mode = app.settings.autostartMode;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Работа приложения', style: display(20)),
      const SizedBox(height: 10),
      if (Platform.isWindows) ...[
        Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          const Expanded(
            child: HintTitle('Автозапуск', null),
          ),
          const SizedBox(width: 16),
          GlassSelect<String>(
            value: mode,
            width: 210,
            options: const [('off', 'Отключен'), ('tray', 'Включен - в трее'), ('show', 'Включен - окно')],
            onChanged: (v) {
              if (v != mode) _set(v);
            },
          ),
        ]),
        const SizedBox(height: 10),
      ],
      const _TraySwitches(),
    ]);
  }
}

/// «Локальная загрузка»: формат по умолчанию для «Скачать на устройство» и вопрос о формате при каждой загрузке
class _LocalDownloadSection extends StatefulWidget {
  const _LocalDownloadSection();
  @override
  State<_LocalDownloadSection> createState() => _LocalDownloadSectionState();
}

class _LocalDownloadSectionState extends State<_LocalDownloadSection> {
  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final format = exportFormatOf(app.settings);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Локальная загрузка', style: display(20)),
      const SizedBox(height: 10),
      Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        const Expanded(
          child: HintTitle('В каком формате скачивать треки по умолчанию?',
              'Относится к «Скачать на устройство». MP3, FLAC и WAV — перекодирование через FFmpeg; «Как есть» сохраняет файл без изменений.'),
        ),
        const SizedBox(width: 16),
        GlassSelect<String>(
          value: format,
          width: 250,
          options: [for (final f in exportFormats) (f, exportFormatLabel(f))],
          onChanged: (v) {
            if (v == format) return;
            setState(() => app.settings.view['export.format'] = v);
            app.lib.viewChanged();
          },
        ),
      ]),
      const SizedBox(height: 6),
      HintSwitch(
        contentPadding: EdgeInsets.zero,
        value: exportAskOf(app.settings),
        title: 'Спрашивать формат при каждой загрузке',
        onChanged: (v) {
          setState(() => app.settings.view['export.ask'] = v ? '1' : '0');
          app.lib.viewChanged();
        },
      ),
    ]);
  }
}

/// Вкладка «Уведомления»: показ, звук (громкость, свой файл, прослушивание), Windows и предпросмотр карточки
class _NotifySection extends StatefulWidget {
  const _NotifySection();
  @override
  State<_NotifySection> createState() => _NotifySectionState();
}

class _NotifySectionState extends State<_NotifySection> {
  Future<void> _save() => Services.of(context).lib.saveSettings();

  Future<void> _pickSound() async {
    final app = Services.of(context);
    final f = await openFile(acceptedTypeGroups: const [
      XTypeGroup(label: 'Звук', extensions: ['mp3', 'wav', 'ogg', 'flac', 'm4a', 'aac', 'opus']),
    ]);
    if (f == null || !mounted) return;
    setState(() => app.settings.view['ntf.file'] = f.path);
    await _save();
    unawaited(NotifySound.play(app.settings, force: true));
  }

  /// Показывает настоящее уведомление: карточка в плеере, звук и (если включено) уведомление Windows
  void _preview() {
    final app = Services.of(context);
    final tracks = app.lib.allTracks;
    final me = app.lib.me ?? '';
    noticePreviewing = true;
    app.social.noticeStream.add(Notice(NoticeKind.like, me, DateTime.now(), tracks.isEmpty ? const [] : [tracks.first.id]));
  }

  /// Таблица: по строке на вид уведомления, справа галочки «Звук» и «Уведомление»
  Widget _kindsTable(Settings st, bool on) {
    const rows = <(String, String, String?)>[
      ('like', 'Лайк на загруженный трек', 'Так же — добавление вашего трека в плейлист'),
      ('share', 'Поделились треком', null),
      ('jam', 'Пригласили в джем', 'Так же — просьба войти в ваш джем'),
    ];
    Widget head(String t) => SizedBox(
          width: 112,
          child: Center(child: Text(t, style: const TextStyle(color: C.muted, fontSize: 13, fontWeight: FontWeight.w600))),
        );
    Widget cell(String group, String what, bool enabled) => SizedBox(
          width: 112,
          child: Center(
            child: Checkbox(
              value: st.noticeFlag(group, what),
              onChanged: enabled
                  ? (v) async {
                      setState(() => st.view['ntf.$group.$what'] = v == true ? '1' : '0');
                      await _save();
                    }
                  : null,
            ),
          ),
        );
    return Opacity(
      opacity: on ? 1 : 0.45,
      child: IgnorePointer(
        ignoring: !on,
        child: Container(
          decoration: BoxDecoration(color: C.surface, border: Border.all(color: C.line), borderRadius: BorderRadius.circular(14)),
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          child: Column(children: [
            Row(children: [const Expanded(child: SizedBox.shrink()), head('Звук'), head('Уведомление')]),
            for (final (i, (group, label, _)) in rows.indexed) ...[
              if (i > 0) const Divider(height: 1, color: C.line),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      HintTitle(label, null, size: 15),
                    ]),
                  ),
                  // Звук ещё и общим выключателем «Звук уведомления» ниже
                  cell(group, 'snd', st.notifySound),
                  cell(group, 'pop', true),
                ]),
              ),
            ],
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final st = app.settings;
    final on = st.notifyOn;
    final soundOn = on && st.notifySound;
    final custom = st.notifyFile;
    final customName = custom.isEmpty ? null : custom.split(RegExp(r'[\\/]')).last;
    final me = app.lib.me == null ? 'Друг' : app.lib.firstNameOf(app.lib.me!);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      HintSwitch(
        contentPadding: EdgeInsets.zero,
        value: on,
        title: 'Показывать уведомления',
        onChanged: (v) async {
          setState(() => st.view['ntf.on'] = v ? '1' : '0');
          await _save();
        },
      ),
      HintSwitch(
        contentPadding: EdgeInsets.zero,
        value: st.notifySystem,
        title: 'Уведомления Windows',
        onChanged: on
            ? (v) async {
                setState(() => st.view['ntf.sys'] = v ? '1' : '0');
                await _save();
              }
            : null,
      ),
      const SizedBox(height: 18),
      const HintHeading('Какие уведомления', null),
      const SizedBox(height: 12),
      _kindsTable(st, on),
      const SizedBox(height: 18),
      Text('Звук', style: display(20)),
      const SizedBox(height: 10),
      HintSwitch(
        contentPadding: EdgeInsets.zero,
        value: st.notifySound,
        title: 'Звук уведомления',
        onChanged: on
            ? (v) async {
                setState(() => st.view['ntf.sound'] = v ? '1' : '0');
                await _save();
              }
            : null,
      ),
      Opacity(
        opacity: soundOn ? 1 : 0.45,
        child: IgnorePointer(
          ignoring: !soundOn,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const SizedBox(width: 120, child: Text('Громкость')),
              Expanded(
                child: Slider(
                  value: st.notifyVolume.toDouble(),
                  min: 0,
                  max: 100,
                  divisions: 20,
                  onChanged: (v) => setState(() => st.view['ntf.vol'] = '${v.round()}'),
                  onChangeEnd: (_) => _save(),
                ),
              ),
              SizedBox(width: 48, child: Text('${st.notifyVolume}%', textAlign: TextAlign.right, style: const TextStyle(color: C.muted, fontSize: 13))),
            ]),
            const SizedBox(height: 6),
            Text(customName == null ? 'Сейчас: стандартный сигнал' : 'Сейчас: $customName',
                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.muted, fontSize: 13)),
            const SizedBox(height: 10),
            Wrap(spacing: 10, runSpacing: 10, children: [
              OutlinedButton.icon(
                onPressed: () => NotifySound.play(st, force: true),
                icon: const Icon(Icons.play_arrow_rounded, size: 20),
                label: const Text('Прослушать'),
              ),
              OutlinedButton.icon(
                onPressed: _pickSound,
                icon: const Icon(Icons.audio_file_rounded, size: 18),
                label: const Text('Выбрать свой звук'),
              ),
              if (customName != null)
                TextButton(
                  onPressed: () async {
                    setState(() => st.view.remove('ntf.file'));
                    await _save();
                  },
                  child: const Text('Вернуть стандартный'),
                ),
            ]),
          ]),
        ),
      ),
      const SizedBox(height: 28),
      Text('Как выглядит уведомление', style: display(20)),
      const SizedBox(height: 12),
      Align(
        alignment: Alignment.centerLeft,
        child: ToastCard(
          title: me,
          leading: app.lib.me == null
              ? ClipOval(child: BrandMark(size: 48))
              : Avatar(email: app.lib.me!, name: me, size: 48),
          text: 'Добавил(а) «Название трека» в любимое',
          onClose: () {},
        ),
      ),
      const SizedBox(height: 12),
      Row(children: [
        FilledButton.icon(
          onPressed: _preview,
          icon: const Icon(Icons.notifications_active_rounded, size: 18),
          label: const Text('Показать пример'),
        ),
        const SizedBox(width: 10),
        const HelpMark('Пример приходит так же, как настоящее: карточка в плеере, звук и уведомление Windows (если окно не в фокусе).'),
      ]),
    ]);
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
          UpdateState.available => 'Вышла новая версия ${up.latest}',
          UpdateState.downloading => 'Скачиваю версию ${up.latest} (${(up.progress * 100).round()}%)',
          UpdateState.ready => 'Версия ${up.latest} скачана и готова к установке',
          UpdateState.upToDate => up.isTestBuild ? 'У вас последняя сборка этой ветки' : 'У вас последняя версия',
          UpdateState.error => up.error ?? 'Не получилось проверить',
          UpdateState.idle => 'Cavey сам проверяет, не вышла ли новая версия, раз в 4 часа. Скачивать и устанавливать её вы решаете сами.',
        };
        final hasNew = up.state == UpdateState.available || up.state == UpdateState.downloading || up.state == UpdateState.ready;
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
          if (hasNew)
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 2),
              child: Text(
                up.state == UpdateState.ready ? 'Версия ${up.latest} скачана и готова к установке' : 'Вышла новая версия ${up.latest}',
                style: display(18, color: C.accent),
              ),
            )
          else
            Text(
              last == null ? status : '$status. Проверено в ${TimeOfDay.fromDateTime(last).format(context)}.',
              style: TextStyle(color: up.state == UpdateState.error ? C.danger : C.faint, fontSize: 13, height: 1.45),
            ),
          if (up.state == UpdateState.downloading) ...[
            const SizedBox(height: 10),
            SizedBox(width: 320, child: LinearProgressIndicator(value: up.progress)),
          ],
          // Нашлось обновление — что в нём нового (по всем версиям между вашей и новой)
          if (hasNew && up.changes.isNotEmpty) ...[
            const SizedBox(height: 16),
            Container(
              constraints: const BoxConstraints(maxWidth: 640, maxHeight: 320),
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              decoration: BoxDecoration(color: C.surface, border: Border.all(color: C.line), borderRadius: BorderRadius.circular(12)),
              child: SingleChildScrollView(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Что нового', style: display(16)),
                  for (final (v, notes) in up.changes) ...[
                    const SizedBox(height: 10),
                    Text('Версия $v', style: TextStyle(color: C.accent, fontSize: 13, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 4),
                    SelectableText(notes.isEmpty ? 'Без описания' : notes, style: const TextStyle(color: C.muted, fontSize: 13, height: 1.45)),
                  ],
                ]),
              ),
            ),
          ],
          const SizedBox(height: 16),
          Wrap(spacing: 12, runSpacing: 10, children: [
            if (up.state == UpdateState.available)
              FilledButton.icon(
                onPressed: up.download,
                icon: const Icon(Icons.download_rounded, size: 18),
                label: const Text('Скачать'),
              ),
            if (up.state == UpdateState.ready)
              FilledButton.icon(
                onPressed: up.installNow,
                icon: const Icon(Icons.system_update_alt_rounded, size: 18),
                label: const Text('Установить и перезапустить'),
              ),
            OutlinedButton.icon(
              onPressed: busy ? null : up.check,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Проверить обновления'),
            ),
            // С тестовой сборки или с беты, когда галочку сняли, — можно вернуться сразу
            if (up.isTestBuild || up.isBeta)
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
        HintHeading('Кэш и офлайн', 'Прослушанные треки сохраняются на компьютере и в следующий раз играют сразу, даже без интернета. '
          'Любимое и плейлисты можно сохранить целиком кнопкой «Сохранить офлайн» на их странице.'),
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
        HintSwitch(
          contentPadding: EdgeInsets.zero,
          value: k.enabled,
          title: 'Вычислять время каждого слова по звуку',
          hint: 'В кинотеатре текст заливается слово за словом точно в такт. Считает программа Whisper на этом компьютере, '
            'в фоне и на половине ядер: около минуты на трек. Посчитанное сохраняется в общей папке — '
            'каждый трек считается один раз на всю компанию. Без этого слова загораются по слогам примерно.',
          onChanged: k.setEnabled,
        ),
        const SizedBox(height: 6),
        Row(children: [
          const Expanded(
            child: HintTitle('Задержка звука устройства', 'Например, Bluetooth-наушники: текст идёт раньше на столько миллисекунд', size: 14),
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
          const HintTitle('Модель распознавания', 'Для русского и японского лучше «Точная». Модель скачивается один раз, при первом треке.', size: 14),
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

/// АвтоDJ (подбор по темпу и тональности) и скробблинг в ListenBrainz
class _AutoDjSection extends StatefulWidget {
  const _AutoDjSection();
  @override
  State<_AutoDjSection> createState() => _AutoDjSectionState();
}

class _AutoDjSectionState extends State<_AutoDjSection> {
  final _token = TextEditingController();
  bool _inited = false;
  bool _busy = false;
  String _msg = '';

  @override
  void dispose() {
    _token.dispose();
    super.dispose();
  }

  Future<void> _saveToken(AppServices app) async {
    final t = _token.text.trim();
    if (t.isEmpty) {
      app.settings.view.remove('lb.token');
      await app.lib.saveSettings();
      if (mounted) setState(() => _msg = 'ListenBrainz отключён');
      return;
    }
    setState(() {
      _busy = true;
      _msg = '';
    });
    final user = await app.listenBrainz.validate(t);
    if (!mounted) return;
    if (user == null) {
      setState(() {
        _busy = false;
        _msg = 'Токен не принят или нет связи с ListenBrainz';
      });
      return;
    }
    app.settings.view['lb.token'] = t;
    await app.lib.saveSettings();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _msg = 'Подключено: ${user.isEmpty ? 'ListenBrainz' : user}';
    });
  }

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    if (!_inited) {
      _inited = true;
      _token.text = app.settings.view['lb.token'] ?? '';
    }
    final bpm = app.settings.viewNum('dj.bpm', 25).clamp(5, 50).toDouble();
    final avoid = app.settings.viewNum('dj.avoid', 60).clamp(0, 240).toDouble();
    final mixer = app.player.mixer;
    final lb = app.listenBrainz;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const HintHeading('АвтоDJ', null),
      const SizedBox(height: 4),
      const Text(
        'Кнопка «АвтоDJ» есть у каждого плейлиста и альбома, а в панели очереди — радио и перестановка. '
        'Следующий трек подбирается по темпу (двойной и половинный считаются своими) и по тональности на круге Camelot. '
        'Темп и тональность берутся из тегов файла, а если их нет — считаются по звуку, когда трек в кэше.',
        style: TextStyle(color: C.muted, fontSize: 13, height: 1.5),
      ),
      const SizedBox(height: 8),
      Row(children: [
        const SizedBox(width: 170, child: Text('Разница в темпе')),
        Expanded(
          child: Slider(
            value: bpm,
            min: 5,
            max: 50,
            divisions: 9,
            label: 'до ${bpm.round()} %',
            onChanged: (v) => setState(() => app.settings.view['dj.bpm'] = '${v.round()}'),
            onChangeEnd: (_) => app.lib.saveSettings(),
          ),
        ),
        SizedBox(width: 80, child: Text('до ${bpm.round()} %', textAlign: TextAlign.right, style: const TextStyle(color: C.muted))),
      ]),
      Row(children: [
        const SizedBox(width: 170, child: Text('Не повторять треки')),
        Expanded(
          child: Slider(
            value: avoid,
            min: 0,
            max: 240,
            divisions: 16,
            label: avoid == 0 ? 'можно сразу' : '${avoid.round()} мин',
            onChanged: (v) => setState(() => app.settings.view['dj.avoid'] = '${v.round()}'),
            onChangeEnd: (_) => app.lib.saveSettings(),
          ),
        ),
        SizedBox(
          width: 80,
          child: Text(avoid == 0 ? 'можно' : '${avoid.round()} мин', textAlign: TextAlign.right, style: const TextStyle(color: C.muted)),
        ),
      ]),
      HintSwitch(
        contentPadding: EdgeInsets.zero,
        value: app.settings.viewOf('dj.key', '1') == '1',
        onChanged: (v) {
          setState(() => app.settings.view['dj.key'] = v ? '1' : '0');
          app.lib.saveSettings();
        },
        title: 'Учитывать тональность',
        hint: 'Тональности рядом на круге Camelot (например, 8A и 9A или 8A и 8B) звучат вместе, дальние «режут слух».',
      ),
      if (mixer != null) ...[
        const SizedBox(height: 4),
        ValueListenableBuilder<int>(
          valueListenable: mixer.pending,
          builder: (context, left, _) => Text(
            left > 0
                ? 'Разбор звука: осталось треков — $left. Идёт в фоне.'
                : 'Разобрано треков: ${mixer.profileCount}. Новые разбираются по мере прослушивания.',
            style: const TextStyle(color: C.faint, fontSize: 12),
          ),
        ),
      ],
      const SizedBox(height: 20),
      const IntelPanel(),
      const SizedBox(height: 20),
      const HintHeading('ListenBrainz', null),
      const SizedBox(height: 4),
      const Text(
        'Открытая история прослушиваний, как Last.fm: по ней строятся рекомендации. Токен — на странице listenbrainz.org/settings. '
        'Трек засчитывается, когда прослушана половина или четыре минуты.',
        style: TextStyle(color: C.muted, fontSize: 13, height: 1.5),
      ),
      const SizedBox(height: 10),
      TextField(
        controller: _token,
        obscureText: true,
        decoration: const InputDecoration(labelText: 'Токен пользователя ListenBrainz', isDense: true),
      ),
      const SizedBox(height: 10),
      Wrap(spacing: 10, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        FilledButton.icon(
          onPressed: _busy ? null : () => _saveToken(app),
          icon: const Icon(Icons.check_rounded, size: 18),
          label: const Text('Сохранить и проверить'),
        ),
        if (_busy) const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
      ]),
      if (_msg.isNotEmpty || lb.status.isNotEmpty) ...[
        const SizedBox(height: 8),
        Text(_msg.isNotEmpty ? _msg : lb.status, style: const TextStyle(color: C.muted, fontSize: 12)),
      ],
      if (lb.token.isNotEmpty)
        HintSwitch(
          contentPadding: EdgeInsets.zero,
          value: app.settings.viewOf('lb.on', '1') == '1',
          onChanged: (v) {
            setState(() => app.settings.view['lb.on'] = v ? '1' : '0');
            app.lib.saveSettings();
          },
          title: 'Отправлять прослушивания',
        ),
    ]);
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
    // В джеме плавный переход задаёт организатор: пока я участник, мои настройки не действуют и ниже не меняются
    return ListenableBuilder(listenable: app.jam, builder: (context, _) => _content(app));
  }

  /// Диджейский стиль перехода и его ручные настройки
  Widget _djBlock(AppServices app, {required bool enabled}) {
    void put(String k, String v) {
      setState(() => app.settings.view[k] = v);
      app.player.refreshMixSettings();
      app.lib.saveSettings();
    }

    final style = app.settings.viewOf('mix.style', 'fade');
    final dj = style == 'dj' || style == 'adaptive';
    const barSteps = [1, 2, 4, 8, 16, 32];
    final bars = app.settings.viewNum('mix.bars', 8).round();
    final barIdx = barSteps.indexOf(bars).clamp(0, barSteps.length - 1).toInt();
    final range = app.settings.viewNum('mix.range', 8).clamp(2, 16).toDouble();
    final offset = app.settings.viewNum('mix.offset', 0).clamp(-150, 150).toDouble();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const HintHeading('Стиль перехода',
          'Плавный: громкость одного трека затихает, другого нарастает. DJ: следующий трек подгоняется по темпу, доли двух треков '
          'совпадают, переход длится целое число тактов, а низкие частоты передаются от одного трека другому на середине. '
          'Диджейский стиль работает, когда у обоих треков известны темп и доли (кнопка «АвтоDJ → Разобрать темп и тональность»); '
          'иначе звучит обычный переход.'),
      const SizedBox(height: 8),
      SegmentedButton<String>(
        segments: const [
          ButtonSegment(value: 'fade', label: Text('Плавный')),
          ButtonSegment(value: 'dj', label: Text('DJ')),
          ButtonSegment(value: 'adaptive', label: Text('Adaptive AutoDJ')),
        ],
        selected: {const ['fade', 'dj', 'adaptive'].contains(style) ? style : 'fade'},
        onSelectionChanged: enabled ? (v) => put('mix.style', v.first) : null,
      ),
      if (style == 'adaptive') const Padding(
        padding: EdgeInsets.only(top: 8),
        child: Text('Экспериментальный: выбирает из следующих пяти треков, планирует до трёх шагов. '
            'При слабом анализе — обычный AutoMix. Решения — в журнале.'),
      ),
      if (style == 'adaptive') Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(children: [
          const SizedBox(width: 150, child: Text('Характер сета')),
          DropdownButton<String>(
            value: const ['balanced', 'rise', 'relax', 'explore'].contains(app.settings.viewOf('mix.intent', 'balanced'))
                ? app.settings.viewOf('mix.intent', 'balanced') : 'balanced',
            items: const [
              DropdownMenuItem(value: 'balanced', child: Text('Ровно')),
              DropdownMenuItem(value: 'rise', child: Text('Нарастание')),
              DropdownMenuItem(value: 'relax', child: Text('Спокойнее')),
              DropdownMenuItem(value: 'explore', child: Text('Больше контрастов')),
            ],
            onChanged: enabled ? (v) { if (v != null) put('mix.intent', v); } : null,
          ),
        ]),
      ),
      if (dj) ...[
        const SizedBox(height: 8),
        Row(children: [
          const SizedBox(width: 150, child: Text('Длина перехода')),
          Expanded(
            child: Slider(
              value: barIdx.toDouble(),
              min: 0,
              max: (barSteps.length - 1).toDouble(),
              divisions: barSteps.length - 1,
              label: '${barSteps[barIdx]} тактов',
              onChanged: enabled ? (v) => setState(() => app.settings.view['mix.bars'] = '${barSteps[v.round()]}') : null,
              onChangeEnd: (_) => app.lib.saveSettings(),
            ),
          ),
          SizedBox(width: 80, child: Text('${barSteps[barIdx]} тактов', textAlign: TextAlign.right, style: const TextStyle(color: C.muted))),
        ]),
        Row(children: [
          const SizedBox(width: 150, child: Text('Подгонка темпа до')),
          Expanded(
            child: Slider(
              value: range,
              min: 2,
              max: 16,
              divisions: 14,
              label: '${range.round()} %',
              onChanged: enabled ? (v) => setState(() => app.settings.view['mix.range'] = '${v.round()}') : null,
              onChangeEnd: (_) => app.lib.saveSettings(),
            ),
          ),
          SizedBox(width: 80, child: Text('${range.round()} %', textAlign: TextAlign.right, style: const TextStyle(color: C.muted))),
        ]),
        Row(children: [
          const SizedBox(width: 150, child: Text('Сдвиг долей')),
          Expanded(
            child: Slider(
              value: offset,
              min: -150,
              max: 150,
              divisions: 60,
              label: '${offset.round()} мс',
              onChanged: enabled ? (v) => setState(() => app.settings.view['mix.offset'] = '${(v / 5).round() * 5}') : null,
              onChangeEnd: (_) => app.lib.saveSettings(),
            ),
          ),
          SizedBox(width: 80, child: Text('${offset.round()} мс', textAlign: TextAlign.right, style: const TextStyle(color: C.muted))),
        ]),
        const Padding(
          padding: EdgeInsets.only(bottom: 4),
          child: Text('Если на слух следующий трек чуть опережает ударные или отстаёт, сдвиньте: «+» — позже, «−» — раньше.',
              style: TextStyle(color: C.muted, fontSize: 12, height: 1.4)),
        ),
        HintSwitch(
          contentPadding: EdgeInsets.zero,
          value: app.settings.viewOf('mix.bass', '1') == '1',
          onChanged: enabled ? (v) => put('mix.bass', v ? '1' : '0') : null,
          title: 'Обмен басов',
          hint: 'У следующего трека сначала срезаны низы, чтобы два баса не сливались в кашу. На середине перехода низы переходят к нему, '
              'а у уходящего пропадают. Если разница в темпе больше допустимой, переход остаётся обычным.',
        ),
        if (style == 'adaptive') HintSwitch(
          contentPadding: EdgeInsets.zero,
          value: app.settings.viewOf('mix.transpose', '0') == '1',
          onChanged: enabled ? (v) => put('mix.transpose', v ? '1' : '0') : null,
          title: 'Подстраивать тональность',
          hint: 'Разрешить адаптивному диджею изменить тональность следующего трека максимум на один полутон для гармоничного сведения. '
              'Изменение сохраняется до конца трека. По умолчанию выключено.',
        ),
      ],
    ]);
  }

  Widget _content(AppServices app) {
    final locked = app.player.jamXfSec != null;
    final sec = locked ? app.player.crossfadeSecNow : app.settings.crossfadeSec;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const HintHeading('Плавный переход', null),
      if (locked)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(children: [
            Icon(Icons.headphones_rounded, size: 16, color: C.accent),
            const SizedBox(width: 8),
            Expanded(
              child: Text('Сейчас вы в джеме: переход ${sec == 0 ? 'выключен' : '$sec с'} по настройке организатора. Ваши настройки вернутся, когда выйдете из джема.',
                  style: TextStyle(color: C.accent, fontSize: 13, height: 1.4)),
            ),
          ]),
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
            onChanged: locked ? null : (v) => setState(() => app.settings.crossfadeSec = v.round()),
            onChangeEnd: (_) => app.lib.saveSettings(),
          ),
        ),
        SizedBox(
          width: 90,
          child: Text(sec == 0 ? 'Выключено' : '$sec с', textAlign: TextAlign.right, style: const TextStyle(color: C.muted)),
        ),
      ]),
      const SizedBox(height: 4),
      HintSwitch(
        contentPadding: EdgeInsets.zero,
        value: app.player.smartMix,
        onChanged: sec == 0 || locked
            ? null
            : (v) {
                setState(() => app.settings.view['mix.smart'] = v ? '1' : '0');
                app.lib.saveSettings();
              },
        title: 'Умный переход',
        hint: 'Как Automix в Spotify: переход начинается там, где песня на самом деле затихает, тишина в начале следующей '
          'пропускается, громкость двух треков выравнивается, а длина перехода — целое число тактов, если известен темп. '
          'Ползунок выше задаёт самый длинный переход. Звук трека разбирается один раз в фоне; пока не готово — обычный переход.',
      ),
      const SizedBox(height: 8),
      _djBlock(app, enabled: sec != 0 && !locked && app.player.smartMix),
      const SizedBox(height: 8),
      HintSwitch(
        contentPadding: EdgeInsets.zero,
        value: app.player.normalize,
        onChanged: (v) async {
          await app.player.setNormalize(v);
          if (mounted) setState(() {});
        },
        title: 'Выравнивание громкости',
      ),
      if (app.player.normalize)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: NormLevelPicker(
              value: app.player.normLevel,
              onChanged: (v) async {
                await app.player.setNormLevel(v);
                if (mounted) setState(() {});
              },
            ),
          ),
        ),
    ]);
  }
}

/// Быстрый канал сообщений для джем-сессий и уведомлений (ntfy)
class _FastMessagesSection extends StatefulWidget {
  const _FastMessagesSection();
  @override
  State<_FastMessagesSection> createState() => _FastMessagesSectionState();
}

class _FastMessagesSectionState extends State<_FastMessagesSection> {
  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Быстрые сообщения', style: display(20)),
      HintSwitch(
        contentPadding: EdgeInsets.zero,
        value: app.settings.viewOf('ntfy', '1') != '0',
        onChanged: (v) {
          setState(() => app.settings.view['ntfy'] = v ? '1' : '0');
          app.lib.saveSettings();
        },
        title: 'Быстрый канал (ntfy)',
        hint: 'Джем-сессии и уведомления доходят за доли секунды: через бесплатный сервер ntfy.sh идут только короткие сигналы и '
          'действия (почты и идентификаторы треков), тема канала не угадывается без вашей общей папки. Без него всё работает '
          'через Google Диск, но с задержкой в несколько секунд. Применяется после перезапуска.',
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
    // Значок в трее и у окна — сразу в новом цвете
    await app.refreshAppIcon();
    if (mounted) setState(() {});
  }

  Future<void> _custom() async {
    final c = await pickColorDialog(context, C.accent);
    if (c != null) await _pick(c);
  }

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final current = C.accent.value;
    final custom = !accentChoices.any((x) => x.$2.value == current) && current != C.defaultAccent.value;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Flexible(child: Text('Акцентный цвет', style: display(20))),
        const Spacer(),
        if (current != C.defaultAccent.value) TextButton(onPressed: () => _pick(null), child: const Text('Как было')),
      ]),
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
        // Сбоку — любой цвет из палитры
        Tooltip(
          message: 'Свой цвет',
          child: GestureDetector(
            onTap: _custom,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: const SweepGradient(colors: [
                    Color(0xFFFF6B6B),
                    Color(0xFFF2C14E),
                    Color(0xFF8FDB6A),
                    Color(0xFF4FD1C5),
                    Color(0xFF6FA8FF),
                    Color(0xFFB08CFF),
                    Color(0xFFFF7FB2),
                    Color(0xFFFF6B6B),
                  ]),
                  border: Border.all(color: custom ? C.text : C.line, width: custom ? 2.5 : 1),
                ),
                child: Icon(custom ? Icons.check_rounded : Icons.colorize_rounded, size: 18, color: Colors.white),
              ),
            ),
          ),
        ),
      ]),
      const SizedBox(height: 18),
      // Значок программы в цвете акцента: в трее, у окна и у ярлыков он меняется сразу,
      // в самом файле программы (проводник, панель задач у закреплённого) — после перезапуска
      if (app.exeIconPending)
        Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          FilledButton.tonalIcon(
            onPressed: () => app.applyExeIcon(relaunch: true),
            icon: const Icon(Icons.restart_alt_rounded, size: 18),
            label: const Text('Обновить значок программы'),
          ),
          Text(
            'Значок в трее и у окна уже в новом цвете. Значок файла программы (проводник, панель задач) сменится после '
            'этой кнопки: Cavey перезапустится, проводник Windows тоже, панель задач на секунду мигнёт.\n'
            '${app.exeIconFails > 0 ? 'Прошлая попытка не удалась, подробности в файле %TEMP%\\cavey-icon.log. ' : ''}'
            'Если не нажимать, значок обновится сам, когда вы закроете Cavey через меню трея.',
            style: const TextStyle(color: C.faint, fontSize: 12, height: 1.4),
          ),
        ])
      else
        const Text('Значок программы — в трее, на панели задач и в проводнике — тоже в этом цвете.',
            style: TextStyle(color: C.faint, fontSize: 12)),
    ]);
  }
}

/// Выбор любого цвета: оттенок, насыщенность, яркость и код цвета
Future<Color?> pickColorDialog(BuildContext context, Color initial) {
  var hsv = HSVColor.fromColor(initial);
  final hex = TextEditingController(text: C.accentHex(initial));
  return showGlassDialog<Color>(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
      final color = hsv.toColor();
      Widget track(List<Color> colors, double value, ValueChanged<double> on, {double max = 1}) => SizedBox(
            height: 32,
            child: Stack(alignment: Alignment.center, children: [
              Container(
                height: 12,
                margin: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(6), gradient: LinearGradient(colors: colors)),
              ),
              SliderTheme(
                data: SliderTheme.of(ctx).copyWith(
                  activeTrackColor: Colors.transparent,
                  inactiveTrackColor: Colors.transparent,
                  thumbColor: Colors.white,
                  overlayShape: SliderComponentShape.noOverlay,
                ),
                child: Slider(value: value, max: max, onChanged: on),
              ),
            ]),
          );
      void setHsv(HSVColor v) => set(() {
            hsv = v;
            hex.text = C.accentHex(v.toColor());
          });
      return AlertDialog(
        title: Text('Свой цвет', style: display(18)),
        content: SizedBox(
          width: 360,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(width: 56, height: 56, decoration: BoxDecoration(color: color, shape: BoxShape.circle, border: Border.all(color: C.line))),
              const SizedBox(width: 16),
              Expanded(
                child: TextField(
                  controller: hex,
                  decoration: const InputDecoration(labelText: 'Код цвета', hintText: '#F2C14E'),
                  onSubmitted: (v) {
                    final c = C.parseAccent(v.trim().startsWith('#') ? v.trim() : '#${v.trim()}');
                    if (c != null) set(() => hsv = HSVColor.fromColor(c));
                  },
                ),
              ),
            ]),
            const SizedBox(height: 18),
            const Text('Оттенок', style: TextStyle(color: C.muted, fontSize: 13)),
            track([for (var h = 0; h <= 360; h += 60) HSVColor.fromAHSV(1, h.toDouble(), 1, 1).toColor()], hsv.hue,
                (v) => setHsv(hsv.withHue(v)),
                max: 360),
            const Text('Насыщенность', style: TextStyle(color: C.muted, fontSize: 13)),
            track([hsv.withSaturation(0).toColor(), hsv.withSaturation(1).toColor()], hsv.saturation, (v) => setHsv(hsv.withSaturation(v))),
            const Text('Яркость', style: TextStyle(color: C.muted, fontSize: 13)),
            track([hsv.withValue(0.25).toColor(), hsv.withValue(1).toColor()], hsv.value, (v) => setHsv(hsv.withValue(v))),
            const SizedBox(height: 4),
            if (hsv.value < 0.45)
              const Text('Слишком тёмный цвет плохо видно на тёмном стекле.', style: TextStyle(color: C.faint, fontSize: 12)),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена', style: TextStyle(color: C.muted))),
          FilledButton(onPressed: () => Navigator.pop(ctx, hsv.toColor()), child: const Text('Выбрать')),
        ],
      );
    }),
  );
}

/// Какой край у осветления прослушанной части в плеере: прямая линия или бегущая волна
class _SeekEdgeSection extends StatefulWidget {
  const _SeekEdgeSection();
  @override
  State<_SeekEdgeSection> createState() => _SeekEdgeSectionState();
}

class _SeekEdgeSectionState extends State<_SeekEdgeSection> {
  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final wave = app.settings.viewOf('seek.edge', 'straight') == 'wave';
    Widget option(String id, String label, bool isWave) {
      final on = wave == isWave;
      return GestureDetector(
        onTap: () {
          setState(() => app.settings.view['seek.edge'] = id);
          seekEdgeWave.value = isWave;
          app.lib.saveSettings();
        },
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: on ? C.accent : C.line, width: on ? 2 : 1),
            ),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              SeekEdgeSample(wave: isWave),
              const SizedBox(height: 8),
              Text(label, style: TextStyle(color: on ? C.accent : C.muted, fontWeight: FontWeight.w600)),
            ]),
          ),
        ),
      );
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const HintHeading('Край прослушанного', null),
      const SizedBox(height: 14),
      Wrap(spacing: 14, runSpacing: 14, children: [
        option('straight', 'Прямая', false),
        option('wave', 'Волна', true),
      ]),
      const SizedBox(height: 14),
      // Длина волны: короче — частая рябь, длиннее — плавные изгибы. Работает, когда выбрана волна
      Opacity(
        opacity: wave ? 1 : 0.45,
        child: Row(children: [
          const SizedBox(width: 110, child: Text('Длина волны', style: TextStyle(color: C.muted, fontSize: 13))),
          const Text('короче', style: TextStyle(color: C.faint, fontSize: 12)),
          Expanded(
            child: ValueListenableBuilder<double>(
              valueListenable: seekWaveLength,
              builder: (context, len, _) => Slider(
                value: len.clamp(seekWaveMin, seekWaveMax),
                min: seekWaveMin,
                max: seekWaveMax,
                onChanged: wave ? (v) => seekWaveLength.value = v : null,
                onChangeEnd: (v) {
                  app.settings.view['seek.wlen'] = v.round().toString();
                  app.lib.saveSettings();
                },
              ),
            ),
          ),
          const Text('длиннее', style: TextStyle(color: C.faint, fontSize: 12)),
        ]),
      ),
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
        Flexible(child: Text('Фон', style: display(20))),
        const Spacer(),
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
    ]);
  }
}

/// Сворачивание в трей при закрытии окна и медиаклавиши: идут в «Работе приложения»
class _TraySwitches extends StatefulWidget {
  const _TraySwitches();
  @override
  State<_TraySwitches> createState() => _TraySwitchesState();
}

class _TraySwitchesState extends State<_TraySwitches> {
  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      HintSwitch(
        contentPadding: EdgeInsets.zero,
        value: app.settings.trayOnClose,
        title: 'Сворачивать в трей при закрытии окна',
        onChanged: (v) async {
          setState(() {
            app.settings
              ..trayOnClose = v
              ..trayAsked = true;
          });
          await app.lib.saveSettings();
        },
      ),
      HintSwitch(
        contentPadding: EdgeInsets.zero,
        value: app.settings.globalMediaKeys,
        title: 'Медиаклавиши, когда окно не активно',
        hint: '⏮ ⏯ ⏭ на клавиатуре (в том числе Fn+F-клавиши ноутбука) работают, даже если Cavey свёрнут или спрятан в трей.',
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
        HintSwitch(
          contentPadding: EdgeInsets.zero,
          value: app.settings.discord,
          title: 'Показывать в Discord, что я слушаю',
          hint: 'Друзья в Discord увидят название трека и исполнителя, пока музыка играет.',
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



/// Spotify account authorization belongs to Library settings, not the download
/// form. Only the Client ID is configured by the app or supplied by the user;
/// OAuth tokens and the user's password never pass through this UI.
class _SpotifySettingsSection extends StatefulWidget {
  const _SpotifySettingsSection();

  @override
  State<_SpotifySettingsSection> createState() => _SpotifySettingsSectionState();
}

class _SpotifySettingsSectionState extends State<_SpotifySettingsSection> {
  final _clientId = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Services.of(context).downloads.refreshSpotify();
    });
  }

  @override
  void dispose() {
    _clientId.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dl = Services.of(context).downloads;
    return ListenableBuilder(
      listenable: dl,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Spotify', style: display(20)),
          const SizedBox(height: 8),
          Text(
            dl.spotifyConnected
                ? 'Подключён: ${dl.spotifyAccount.isEmpty ? 'Spotify' : dl.spotifyAccount}. '
                  'Можно импортировать свои плейлисты целиком, до 2000 записей.'
                : 'Подключите Spotify, чтобы импортировать свои плейлисты полностью. '
                  'Плейлисты других пользователей могут быть ограничены Spotify API.',
            style: const TextStyle(color: C.muted, fontSize: 13, height: 1.5),
          ),
          if (!dl.spotifyConnected && !dl.spotifyConfigured) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _clientId,
              decoration: const InputDecoration(
                labelText: 'Spotify Client ID',
                hintText: 'Client ID из Spotify Developer Dashboard',
                isDense: true,
              ),
            ),
            const SizedBox(height: 6),
            const SelectableText(
              'Redirect URI: http://127.0.0.1:43811/callback',
              style: TextStyle(color: C.faint, fontSize: 12),
            ),
          ],
          if (!dl.spotifyConnected && dl.spotifyConfigured) ...[
            const SizedBox(height: 6),
            const Text('Client ID уже настроен — вручную вводить не нужно.',
                style: TextStyle(color: C.faint, fontSize: 12)),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (dl.spotifyConnected)
                OutlinedButton.icon(
                  onPressed: dl.busy ? null : dl.logoutSpotify,
                  icon: const Icon(Icons.logout, size: 18),
                  label: const Text('Выйти из Spotify'),
                )
              else
                FilledButton.icon(
                  onPressed: dl.busy ? null : () => dl.loginSpotify(_clientId.text),
                  icon: const Icon(Icons.login_rounded, size: 18),
                  label: const Text('Войти в Spotify'),
                ),
              if (dl.spotifyBusy)
                const SizedBox.square(dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2)),
            ],
          ),
          if (dl.spotifyMessage.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(dl.spotifyMessage,
                style: const TextStyle(color: C.muted, fontSize: 12)),
          ],
          if (dl.spotifyError.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(dl.spotifyError,
                style: const TextStyle(color: C.danger, fontSize: 12)),
          ],
        ],
      ),
    );
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
      await app.downloads.installProvider('sockseek', (line) {
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
      final path = await app.downloads.providerConfig('sockseek');
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
      await app.downloads.installProvider('deezer', (line) {
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
      final path = await app.downloads.providerConfig('deezer');
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
      HintHeading('Загрузчик музыки', 'Deezer загружает через локальную Python-библиотеку. Полный поиск последовательно пробует Deezer → Soulseek → YouTube → Bandcamp для каждого трека. Альбомы обрабатываются параллельно (до 3 треков).'),
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




/// Значок «?» с облачком-описанием по наведению: так же, как в меню настройки звука
class HelpMark extends StatelessWidget {
  final String text;
  const HelpMark(this.text, {super.key});

  @override
  Widget build(BuildContext context) => Tooltip(
        // Ширину облачка ограничиваем сами: у Tooltip в Flutter 3.27 нет параметра constraints
        richMessage: WidgetSpan(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 320),
            child: Text(text, style: const TextStyle(color: C.text, fontSize: 12.5, height: 1.4)),
          ),
        ),
        waitDuration: const Duration(milliseconds: 120),
        showDuration: const Duration(seconds: 30),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        preferBelow: false,
        child: MouseRegion(
          cursor: SystemMouseCursors.help,
          child: Opacity(
            opacity: 0.5,
            child: Container(
              width: 18,
              height: 18,
              alignment: Alignment.center,
              decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: C.muted, width: 1.3)),
              child: const Text('?', style: TextStyle(fontSize: 11, height: 1, fontWeight: FontWeight.w700, color: C.muted)),
            ),
          ),
        ),
      );
}

/// Название настройки со значком «?» справа; описание показывается облачком
class HintTitle extends StatelessWidget {
  final String title;
  final String? hint;
  final double size;
  const HintTitle(this.title, this.hint, {super.key, this.size = 16});

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Flexible(child: Text(title, style: TextStyle(fontSize: size))),
        if (hint != null && hint!.isNotEmpty) ...[const SizedBox(width: 8), HelpMark(hint!)],
      ]);
}

/// Заголовок раздела настроек с описанием в «?»
class HintHeading extends StatelessWidget {
  final String title;
  final String? hint;
  const HintHeading(this.title, this.hint, {super.key});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(children: [
          Flexible(child: Text(title, style: display(20))),
          if (hint != null && hint!.isNotEmpty) ...[const SizedBox(width: 10), HelpMark(hint!)],
        ]),
      );
}

/// Переключатель с подписью и «?» вместо длинного описания под ней
class HintSwitch extends StatelessWidget {
  final bool value;
  final String title;
  final String? hint;
  final ValueChanged<bool>? onChanged;
  final EdgeInsets? contentPadding;
  const HintSwitch({super.key, required this.value, required this.title, this.hint, required this.onChanged, this.contentPadding});

  @override
  Widget build(BuildContext context) {
    final on = onChanged != null;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: on ? () => onChanged!(!value) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [
          Expanded(
            child: Opacity(
              opacity: on ? 1 : 0.5,
              child: Row(children: [
                Flexible(child: Text(title, style: const TextStyle(fontSize: 16))),
                if (hint != null && hint!.isNotEmpty) ...[const SizedBox(width: 8), HelpMark(hint!)],
              ]),
            ),
          ),
          const SizedBox(width: 12),
          Switch(value: value, onChanged: onChanged),
        ]),
      ),
    );
  }
}

/// Выпадающий список в стиле приложения: кнопка со стрелкой и стеклянное меню; после выбора подсветка не остаётся
class GlassSelect<T> extends StatefulWidget {
  final T value;
  final List<(T, String)> options;
  final ValueChanged<T> onChanged;
  final double width;
  const GlassSelect({super.key, required this.value, required this.options, required this.onChanged, this.width = 200});

  @override
  State<GlassSelect<T>> createState() => _GlassSelectState<T>();
}

class _GlassSelectState<T> extends State<GlassSelect<T>> {
  bool _hover = false, _open = false;

  Future<void> _show() async {
    final box = context.findRenderObject() as RenderBox;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final topLeft = box.localToGlobal(Offset(0, box.size.height + 4), ancestor: overlay);
    setState(() => _open = true);
    final v = await showGlassMenu<T>(
      context: context,
      position: RelativeRect.fromLTRB(topLeft.dx, topLeft.dy, overlay.size.width - topLeft.dx - box.size.width, 0),
      items: [
        for (final (id, label) in widget.options)
          PopupMenuItem<T>(
            value: id,
            child: Row(children: [
              Expanded(child: Text(label, style: TextStyle(fontWeight: id == widget.value ? FontWeight.w700 : FontWeight.w400))),
              if (id == widget.value) Icon(Icons.check_rounded, size: 18, color: C.accent),
            ]),
          ),
      ],
    );
    if (!mounted) return;
    setState(() {
      _open = false;
      _hover = false;
    });
    if (v != null) widget.onChanged(v);
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.options.firstWhere((o) => o.$1 == widget.value, orElse: () => widget.options.first).$2;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _show,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: widget.width,
          height: 42,
          padding: const EdgeInsets.fromLTRB(14, 0, 10, 0),
          decoration: BoxDecoration(
            color: _hover || _open ? C.hoverOverlay : C.raised,
            border: Border.all(color: C.line),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(children: [
            Expanded(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis)),
            Icon(_open ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 20, color: C.muted),
          ]),
        ),
      ),
    );
  }
}
