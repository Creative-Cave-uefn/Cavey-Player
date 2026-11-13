import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/services.dart';

import '../app.dart';
import '../core/dl/service.dart';
import '../core/log.dart';
import '../core/upload_queue.dart';
import 'accounts_view.dart' show GlassSelect;
import 'device_export_ui.dart' show chooseExportFormat;
import 'shell.dart';
import 'theme.dart';

/// Раздел «Скачать»: ссылка или название → трек на Диске и в библиотеке у всех
class DownloadPage extends StatefulWidget {
  final bool compact;
  const DownloadPage({super.key, required this.compact});
  @override
  State<DownloadPage> createState() => _DownloadPageState();
}

class _DownloadPageState extends State<DownloadPage> {
  final _input = TextEditingController();
  /// Галочка «Сделать плейлист» хранится в настройках, поэтому не сбрасывается при смене вкладки
  bool _makePlaylist = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final dl = Services.of(context).downloads;
      if (dl.toolsVersion.isEmpty) dl.refreshVersion();
    });
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    _makePlaylist = Services.of(context).settings.viewOf('dl.playlist', '1') != '0';
  }

  void _setMakePlaylist(bool v) {
    setState(() => _makePlaylist = v);
    final app = Services.of(context);
    app.settings.view['dl.playlist'] = v ? '1' : '0';
    app.lib.saveSettings();
  }

  void _start() {
    final app = Services.of(context);
    final target = app.settings.hubId ?? app.lib.data.sources.firstOrNull?.id;
    if (target == null || _input.text.trim().isEmpty) return;
    app.downloads.enqueue(_input.text, target, makePlaylist: _makePlaylist);
    _input.clear();
  }

  /// Скачать в папку на компьютере: в библиотеку и на Диск не попадает
  Future<void> _startToDevice() async {
    final app = Services.of(context);
    final text = _input.text.trim();
    if (text.isEmpty) return;
    final format = await chooseExportFormat(context);
    if (format == null || !mounted) return;
    final last = app.settings.viewOf('export.dir', '');
    final dir = await getDirectoryPath(initialDirectory: last.isEmpty ? null : last, confirmButtonText: 'Сохранить сюда');
    if (dir == null || !mounted) return;
    app.settings.view['export.dir'] = dir;
    app.lib.viewChanged();
    final source = app.settings.hubId ?? app.lib.data.sources.firstOrNull?.id ?? '';
    app.downloads.enqueue(text, source, makePlaylist: false, deviceDir: dir, deviceFormat: format);
    _input.clear();
  }

  Widget _inputPanel(BuildContext context, AppServices app, DownloadService dl, String? target) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (app.lib.uploadQueue.count > 0) ...[
        _PendingUploads(queue: app.lib.uploadQueue, onRetry: () => app.lib.retryPendingUploads(manual: true)),
        const SizedBox(height: 16),
      ],
      Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(14), border: Border.all(color: C.line)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextField(
            controller: _input,
            autofocus: true,
            decoration: InputDecoration(
              hintText: app.settings.downloadProvider == 'bandcamp' ? 'Ссылка Bandcamp на трек или альбом' : 'Ссылка или «Исполнитель - Название»',
              prefixIcon: const Icon(Icons.link_rounded, size: 18),
              suffixIcon: IconButton(
                tooltip: 'Вставить из буфера',
                icon: const Icon(Icons.content_paste_rounded, size: 18),
                onPressed: _paste,
              ),
            ),
            onSubmitted: (_) => _start(),
          ),
          const SizedBox(height: 14),
          Wrap(spacing: 12, runSpacing: 10, children: [
            FilledButton.icon(
              onPressed: target == null ? null : _start,
              icon: const Icon(Icons.download_rounded, size: 18),
              label: const Text('Скачать в плеер'),
            ),
            OutlinedButton.icon(
              onPressed: _startToDevice,
              icon: const Icon(Icons.computer_rounded, size: 18),
              label: const Text('Скачать на устройство'),
            ),
          ]),
          const SizedBox(height: 14),
          // Выбор источника — как «Автозапуск» в настройках: подпись слева, стеклянный список справа
          Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            const Expanded(child: Text('Источник музыки', style: TextStyle(fontSize: 16))),
            const SizedBox(width: 16),
            // Пока идёт скачивание, источник не меняем
            IgnorePointer(
              ignoring: dl.busy,
              child: Opacity(
                opacity: dl.busy ? 0.5 : 1,
                child: GlassSelect<String>(
                  value: app.settings.downloadProvider,
                  width: 250,
                  options: const [
                    ('youtube', 'YouTube'),
                    ('deezer', 'Deezer'),
                    ('full', 'Универсальный поиск и ссылки'),
                    ('sockseek', 'Soulseek / Sockseek'),
                    ('bandcamp', 'Bandcamp'),
                  ],
                  onChanged: (value) {
                    setState(() => app.settings.downloadProvider = value);
                    app.lib.saveSettings();
                  },
                ),
              ),
            ),
          ]),
          const SizedBox(height: 10),
          InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: () => _setMakePlaylist(!_makePlaylist),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                SizedBox(
                  width: 24,
                  height: 24,
                  child: Checkbox(
                    value: _makePlaylist,
                    activeColor: C.accent,
                    checkColor: C.accentInk,
                    onChanged: (v) => _setMakePlaylist(v ?? true),
                  ),
                ),
                const SizedBox(width: 8),
                const Flexible(
                  child: Text('Сделать плейлист в Cavey (для ссылок на плейлисты)', style: TextStyle(color: C.muted)),
                ),
              ]),
            ),
          ),
        ]),
      ),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(
          child: Text(
            dl.installing
                ? 'Устанавливаю программы для скачивания…'
                : 'yt-dlp: ${dl.toolsVersion.isEmpty ? '…' : dl.toolsVersion}. Программы ставятся сами при первом скачивании.',
            style: const TextStyle(color: C.faint, fontSize: 13),
          ),
        ),
        TextButton.icon(
          onPressed: dl.busy ? null : dl.updateTools,
          icon: const Icon(Icons.refresh_rounded, size: 16),
          label: const Text('Обновить yt-dlp'),
        ),
      ]),
    ]);
  }

  /// Правая половина: карточки заданий. Первая карточка начинается на одной высоте с панелью ссылки слева
  Widget _jobsPanel(BuildContext context, DownloadService dl) {
    if (dl.jobs.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(14), border: Border.all(color: C.line)),
        child: const Text('Здесь появятся скачивания: вставьте ссылку слева.', style: TextStyle(color: C.faint)),
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final j in dl.jobs) _JobCard(key: ObjectKey(j), job: j),
    ]);
  }

  Widget _jobsHeader(DownloadService dl) => Row(children: [
        Expanded(child: Text('Задания', style: display(20))),
        if (dl.jobs.any((j) => j.state == JobState.done || j.state == JobState.failed || j.state == JobState.cancelled))
          TextButton(onPressed: dl.clearFinished, child: const Text('Убрать завершённые')),
      ]);

  /// Описание выбранного источника — только в ширину левой половины
  Widget _description(AppServices app) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(
        switch (app.settings.downloadProvider) {
          'full' => 'Универсальные ссылки: Spotify, Deezer, Apple Music, Яндекс, YouTube, Bandcamp, SoundCloud, Audiomack, Mixcloud, Internet Archive. Каталоги: Deezer → Soulseek → YouTube → Bandcamp. До трёх треков одновременно.',
          'deezer' => 'Deezer: прямые ссылки на треки, альбомы и плейлисты или «Исполнитель - Название». Нужны локальный ARL и Python.',
          'sockseek' => 'Soulseek (Sockseek): «Исполнитель - Название» или ссылка Spotify, Deezer, Яндекс Музыки. Ищет файлы в P2P сети.',
          'bandcamp' => 'Bandcamp: вставьте прямую ссылку на трек или альбом (artist.bandcamp.com/track/... или /album/...). Скачивается доступный для прослушивания аудиопоток, а не оригинальный FLAC.',
          _ => 'YouTube / YouTube Music: ссылки музыкальных каталогов используются для метаданных; доступное аудио со страниц YouTube, SoundCloud, Bandcamp, Audiomack, Mixcloud и Internet Archive загружается через yt-dlp.',
        },
        style: const TextStyle(color: C.muted, fontSize: 15, height: 1.5),
      ),
      const SizedBox(height: 8),
      Text(
        'Активный источник: ${switch (app.settings.downloadProvider) { 'full' => 'Полный поиск', 'deezer' => 'Deezer', 'bandcamp' => 'Bandcamp', 'sockseek' => 'Soulseek', _ => 'YouTube' }}. Переключить можно здесь или в настройках аккаунта.',
        style: const TextStyle(color: C.faint, fontSize: 13),
      ),
    ]);
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
    if (text != null && text.isNotEmpty) {
      _input.text = text;
      _input.selection = TextSelection.collapsed(offset: text.length);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final pad = widget.compact ? 20.0 : 36.0;
    return ListenableBuilder(
      listenable: Listenable.merge([app.downloads, app.lib, app.lib.uploadQueue]),
      builder: (context, _) {
        try {
          return _content(context, app, pad);
        } catch (e, st) {
          // Ошибка в вёрстке раздела не должна оставлять пустое окно: показываем причину и пишем её в журнал
          AppLog.error('Раздел «Скачать»: не удалось построить', e, st);
          return Padding(padding: EdgeInsets.all(pad), child: Text('Не удалось показать раздел: $e', style: const TextStyle(color: C.danger)));
        }
      },
    );
  }

  Widget _content(BuildContext context, AppServices app, double pad) {
    final dl = app.downloads;
    final sources = app.lib.data.sources;
    // Всё скачивается в одну общую папку библиотеки
    final target = sources.any((s) => s.id == app.settings.hubId) ? app.settings.hubId : sources.firstOrNull?.id;
    return ListView(key: const PageStorageKey('page:download'), padding: EdgeInsets.fromLTRB(pad, 34, pad, 40), children: [
      Text('Скачать', style: display(36, weight: FontWeight.w700)),
      const SizedBox(height: 10),
      // Две половины: слева описание, ссылка и кнопки, справа задания. Верхние края панелей на одной высоте
      LayoutBuilder(builder: (context, box) {
        final wide = box.maxWidth >= 860;
        final description = _description(app);
        final left = _inputPanel(context, app, dl, target);
        final right = _jobsPanel(context, dl);
        if (!wide) {
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            description,
            const SizedBox(height: 18),
            left,
            const SizedBox(height: 26),
            _jobsHeader(dl),
            const SizedBox(height: 10),
            right,
          ]);
        }
        const gap = 28.0;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          // Заголовки внизу своих половин: описание слева и «Задания» справа заканчиваются на одной линии
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Expanded(child: description),
            const SizedBox(width: gap),
            Expanded(child: _jobsHeader(dl)),
          ]),
          const SizedBox(height: 14),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: left),
            const SizedBox(width: gap),
            Expanded(child: right),
          ]),
        ]);
      }),
    ]);
  }
}

class _JobCard extends StatefulWidget {
  final DownloadJob job;
  const _JobCard({super.key, required this.job});
  @override
  State<_JobCard> createState() => _JobCardState();
}

class _JobCardState extends State<_JobCard> {
  late bool _open = widget.job.state == JobState.running;

  @override
  Widget build(BuildContext context) {
    try {
      return _card(context);
    } catch (e, st) {
      AppLog.error('Карточка задания: не удалось построить', e, st);
      return Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(14), border: Border.all(color: C.line)),
        child: Text('${widget.job.title}: не удалось показать задание ($e)', style: const TextStyle(color: C.danger, fontSize: 13)),
      );
    }
  }

  Widget _card(BuildContext context) {
    final job = widget.job;
    final dl = Services.of(context).downloads;
    final (label, color) = switch (job.state) {
      JobState.queued => ('В очереди', C.faint),
      JobState.running => (job.cancelRequested ? 'Останавливаю загрузку…' :
          (job.total > 1 ? 'Скачиваю ${job.done + job.failed} из ${job.total}' : 'Скачиваю…'), C.accent),
      JobState.done => (
          switch ((job.failed > 0, job.deferred > 0)) {
            (false, false) => 'Готово',
            (true, false) => 'Готово, не скачалось: ${job.failed}',
            (false, true) => 'Скачано ${job.done}, загружено ${job.done - job.deferred}, ждут загрузки: ${job.deferred}',
            (true, true) => 'Скачано ${job.done}, загружено ${job.done - job.deferred}, ждут загрузки: ${job.deferred}, не скачалось: ${job.failed}',
          },
          const Color(0xFF7CD3B8)),
      JobState.failed => ('Не получилось', C.danger),
      JobState.cancelled => ('Отменено: скачано ${job.done}, уже было ${job.skipped}', C.faint),
    };
    final canStop = (job.state == JobState.queued || job.state == JobState.running) && !job.cancelRequested;
    // «Перезапустить» докачивает только недоделанное: у зависшего задания, у упавшего и у отменённого
    final canRestart = job.restartable &&
        !job.cancelRequested &&
        (job.state == JobState.running ||
            job.state == JobState.failed ||
            job.state == JobState.cancelled ||
            (job.state == JobState.done && job.failed > 0));
    // Кнопки справа в одну линию по высоте всей карточки, вместе со стрелкой раскрытия
    Widget action(String tooltip, IconData icon, Color c, VoidCallback onTap) => IconButton(
          tooltip: tooltip,
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints.tightFor(width: 36, height: 36),
          padding: EdgeInsets.zero,
          icon: Icon(icon, color: c, size: 20),
          onPressed: onTap,
        );
    // Своё раскрытие вместо ExpansionTile: тот хранит состояние в PageStorage страницы (одно на все карточки)
    // и ломал вёрстку при смене состояния задания
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(14), border: Border.all(color: C.line)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
            child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(job.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                  const SizedBox(height: 4),
                  Text(
                    job.deviceDir != null ? '$label, на устройство: ${job.deviceDir}' : (job.folderName.isEmpty ? label : '$label, в «${job.folderName}»'),
                    style: TextStyle(color: color, fontSize: 13),
                  ),
                  if (job.state == JobState.running) ...[
                    const SizedBox(height: 6),
                    // Полоса не во всю ширину карточки, а компактно под подписью
                    ConstrainedBox(constraints: const BoxConstraints(maxWidth: 280), child: JobProgressBar(job: job)),
                  ],
                  if (job.playlistId != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: TextButton.icon(
                        style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(0, 30)),
                        onPressed: () => NavScope.of(context).go(Nav('playlist', job.playlistId!)),
                        icon: const Icon(Icons.queue_music_rounded, size: 16),
                        label: Text('Открыть плейлист «${job.playlistName}»'),
                      ),
                    ),
                ]),
              ),
              if (canRestart)
                action('Перезапустить: докачать только недоделанные треки', Icons.refresh_rounded, C.accent, () => dl.restart(job)),
              if (canStop)
                action(job.state == JobState.queued ? 'Отменить задание в очереди' : 'Остановить загрузку',
                    Icons.cancel_outlined, C.danger, () => dl.cancel(job)),
              SizedBox.square(
                dimension: 36,
                child: Center(
                  child: AnimatedRotation(
                    turns: _open ? 0.5 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: const Icon(Icons.expand_more_rounded, color: C.muted),
                  ),
                ),
              ),
            ]),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          alignment: Alignment.topCenter,
          child: !_open
              ? const SizedBox(width: double.infinity)
              : Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Container(
                      constraints: const BoxConstraints(maxHeight: 260),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(color: const Color(0x40000000), borderRadius: BorderRadius.circular(8)),
                      child: SingleChildScrollView(
                        reverse: true,
                        child: SelectableText(
                          job.log.isEmpty ? 'Пока пусто' : job.log.join('\n'),
                          style: const TextStyle(fontFamily: 'Consolas', fontSize: 12, color: C.muted, height: 1.4),
                        ),
                      ),
                    ),
                    if (job.input != job.title)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(job.input, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.faint, fontSize: 12)),
                      ),
                  ]),
                ),
        ),
      ]),
    );
  }
}

/// Значение полосы прогресса: сколько треков готово плюс небольшая «доля текущего». Загрузчик присылает
/// только целые числа готовых треков, поэтому внутри трека полоса понемногу ползёт вперёд (не дальше 85 % шага),
/// а когда трек готов — доезжает до следующего шага
double jobProgressTarget(int finished, int total, Duration sinceChange) {
  if (total <= 0) return 0;
  final inside = 0.85 * (1 - math.exp(-sinceChange.inMilliseconds / 20000));
  return ((finished + (finished < total ? inside : 0)) / total).clamp(0.0, 1.0);
}

/// Полоса прогресса задания, которая заполняется плавно, а не рывками при каждом готовом треке
class JobProgressBar extends StatefulWidget {
  final DownloadJob job;
  const JobProgressBar({super.key, required this.job});
  @override
  State<JobProgressBar> createState() => _JobProgressBarState();
}

class _JobProgressBarState extends State<JobProgressBar> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  double _shown = 0;
  int _finished = -1;
  DateTime _changed = DateTime.now();
  Duration _last = Duration.zero;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_tick)..start();
  }

  void _tick(Duration t) {
    final job = widget.job;
    final finished = job.done + job.failed;
    if (finished != _finished) {
      _finished = finished;
      _changed = DateTime.now();
    }
    final target = jobProgressTarget(finished, job.total, DateTime.now().difference(_changed));
    final dt = ((t - _last).inMicroseconds / 1e6).clamp(0.0, 0.1);
    _last = t;
    // Движемся к цели с плавным замедлением и никогда не пятимся
    final next = target > _shown ? _shown + (target - _shown) * (1 - math.exp(-dt * 4)) : _shown;
    if ((next - _shown).abs() > 0.0005) setState(() => _shown = next);
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final job = widget.job;
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: LinearProgressIndicator(value: job.total > 1 ? _shown : null, minHeight: 5),
    );
  }
}

/// Плашка «перетащите сюда» для экрана всех треков
class DropHint extends StatelessWidget {
  const DropHint({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: C.line, width: 1.5),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.file_upload_outlined, size: 18, color: C.faint),
        const SizedBox(width: 10),
        Flexible(
          child: Text(
            'Перетащите сюда файлы или папки с музыкой — они загрузятся на Диск. '
            'Ссылки и названия — в разделе «Скачать».',
            style: const TextStyle(color: C.faint, fontSize: 13),
          ),
        ),
      ]),
    );
  }
}

/// Очередь «Ожидают загрузки»: скачанные файлы, которые ещё не ушли на Диск
class _PendingUploads extends StatelessWidget {
  final UploadQueue queue;
  final VoidCallback onRetry;
  const _PendingUploads({required this.queue, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final items = List.of(queue.items);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: C.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: C.accent.withValues(alpha: 0.5)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(Icons.cloud_upload_outlined, size: 20, color: C.accent),
          const SizedBox(width: 10),
          Expanded(
            child: Text('Ожидают загрузки: ${items.length}',
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          ),
          TextButton(
            onPressed: queue.retrying ? null : onRetry,
            child: Text(queue.retrying ? 'Загружаю…' : 'Повторить сейчас'),
          ),
        ]),
        const SizedBox(height: 4),
        const Text('Файлы скачаны и лежат на этом компьютере. Они уйдут в общую библиотеку сами, как только сервис загрузки станет доступен.',
            style: TextStyle(color: C.muted, fontSize: 13, height: 1.4)),
        const SizedBox(height: 8),
        for (final p in items.take(8))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
                  if (p.lastError.isNotEmpty)
                    Text(p.lastError, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.faint, fontSize: 12)),
                ]),
              ),
              IconButton(
                tooltip: 'Убрать из очереди и удалить файл',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close_rounded, size: 18),
                onPressed: () => queue.remove(p),
              ),
            ]),
          ),
        if (items.length > 8)
          Text('…и ещё ${items.length - 8}', style: const TextStyle(color: C.faint, fontSize: 12)),
      ]),
    );
  }
}
