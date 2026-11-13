import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';

import '../app.dart';
import '../core/intel/service.dart';
import 'accounts_view.dart' show HintHeading, HintSwitch;
import 'theme.dart';

/// Настройки анализа звука: статус, прогресс, пауза и возобновление, лимит процессора, повторный разбор, общий индекс на Диске
class IntelPanel extends StatelessWidget {
  const IntelPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final intel = Services.of(context).intel;
    return ListenableBuilder(listenable: intel, builder: (context, _) => _IntelBody(intel: intel));
  }
}

class _IntelBody extends StatefulWidget {
  final IntelService intel;
  const _IntelBody({required this.intel});

  @override
  State<_IntelBody> createState() => _IntelBodyState();
}

class _IntelBodyState extends State<_IntelBody> {
  double? _cpuDrag;

  IntelService get intel => widget.intel;

  Future<void> _confirmReanalyze() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Пересчитать всю библиотеку?'),
        content: const Text(
            'Звук всех треков будет разобран заново. Это долго (около нескольких секунд на трек) и грузит процессор в фоне; '
            'музыка при этом играет как обычно. Старые результаты заменятся по мере разбора.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Пересчитать')),
        ],
      ),
    );
    if (ok == true) intel.reanalyzeAll();
  }

  Future<void> _importVocals() async {
    final app = Services.of(context);
    final file = await openFile(acceptedTypeGroups: [const XTypeGroup(label: 'JSON', extensions: ['json'])]);
    if (file == null) return;
    try {
      if (await file.length() > 4 * 1024 * 1024) throw const FormatException('Файл больше 4 МБ');
      final n = intel.importVocalEvidence(await file.readAsString());
      app.player.refreshMixSettings();
      app.lib.messages.add('Вокальные метки импортированы: $n треков');
    } catch (e) { app.lib.messages.add('Импорт вокальных меток: $e'); }
  }

  Future<void> _exportDj() async {
    final app = Services.of(context);
    final location = await getSaveLocation(suggestedName: 'cavey-dj-transitions.jsonl');
    if (location == null) return;
    try {
      await app.djJournal.exportTo(location.path);
      app.lib.messages.add('DJ-диагностика сохранена');
    } catch (e) {
      app.lib.messages.add('Не удалось сохранить DJ-диагностику: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final canHere = IntelService.canAnalyzeHere;
    final total = intel.total;
    final done = intel.done;
    final cpu = (_cpuDrag ?? intel.cpuPercent.toDouble()).clamp(10, 100).toDouble();
    final busy = intel.running || intel.pending > 0;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const HintHeading(
        'Анализ звука',
        'Для каждого трека считаются темп, тональность, тембр и энергия. По ним «Моя волна» подбирает похожее по звучанию, '
            'а АвтоDJ получает данные для сведения. Нейросети и сервер не нужны: сравниваются готовые числа.',
      ),
      const Text(
        'Разбор идёт в фоне на компьютере с Windows, результаты хранятся в общей папке на Диске, и другие устройства (в том числе Android) '
        'просто берут готовое. Изменённые файлы пересчитываются, остальные нет.',
        style: TextStyle(color: C.muted, fontSize: 13, height: 1.5),
      ),
      const SizedBox(height: 10),
      if (canHere)
        HintSwitch(
          contentPadding: EdgeInsets.zero,
          value: intel.enabled,
          onChanged: intel.setEnabled,
          title: 'Разбирать звук треков',
          hint: 'Новые треки разбираются сами, когда Cavey запущен на этом компьютере.',
        ),
      if (total > 0) ...[
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(value: (done / total).clamp(0.0, 1.0).toDouble(), minHeight: 6),
        ),
        const SizedBox(height: 6),
        Text('Разобрано $done из $total', style: const TextStyle(color: C.muted, fontSize: 13)),
      ],
      const SizedBox(height: 4),
      Text(intel.statusLine, style: const TextStyle(color: C.faint, fontSize: 12)),
      const SizedBox(height: 6),
      Text(intel.vocalModelAvailable ? 'Модель голоса установлена. Низкая оценка не доказывает отсутствие вокала.'
          : 'Модель голоса не установлена: вокальный риск оценивается осторожно.',
          style: const TextStyle(color: C.faint, fontSize: 12)),
      if (canHere && intel.vocalModelAvailable) SwitchListTile.adaptive(
        contentPadding: EdgeInsets.zero, title: const Text('Анализ вокала на этом компьютере'),
        value: intel.vocalModelEnabled, onChanged: intel.setVocalModelEnabled,
        subtitle: const Text('При полном анализе трека. Аудио никуда не отправляется.'),
      ),
      if (intel.lastError.isNotEmpty && intel.failed > 0)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text('Не удалось разобрать: ${intel.failed}. Последняя ошибка: ${intel.lastError}',
              style: const TextStyle(color: C.faint, fontSize: 12)),
        ),
      const SizedBox(height: 10),
      Wrap(spacing: 10, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        if (canHere && intel.enabled && (busy || intel.paused))
          FilledButton.tonalIcon(
            onPressed: intel.paused ? intel.resume : intel.pause,
            icon: Icon(intel.paused ? Icons.play_arrow_rounded : Icons.pause_rounded, size: 18),
            label: Text(intel.paused ? 'Продолжить' : 'Пауза'),
          ),
        if (canHere && intel.enabled)
          OutlinedButton.icon(
            onPressed: _confirmReanalyze,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('Пересчитать всё'),
          ),
        OutlinedButton.icon(
          onPressed: _importVocals,
          icon: const Icon(Icons.record_voice_over_rounded, size: 18),
          label: const Text('Импорт вокальных меток'),
        ),
        OutlinedButton.icon(
          onPressed: _exportDj,
          icon: const Icon(Icons.save_alt_rounded, size: 18),
          label: const Text('Экспорт DJ-диагностики'),
        ),
        if (canHere && intel.enabled) OutlinedButton.icon(
          onPressed: () {
            final p = Services.of(context).player;
            final ids = [if (p.current != null) p.current!.id, ...p.queue.skip(p.index + 1).take(5)];
            intel.setMode('full');
            intel.reanalyze(ids);
          },
          icon: const Icon(Icons.queue_music_rounded, size: 18),
          label: const Text('Полный анализ очереди'),
        ),
        OutlinedButton.icon(
          onPressed: intel.syncEnabled ? () => intel.syncNow() : null,
          icon: const Icon(Icons.cloud_sync_rounded, size: 18),
          label: const Text('Обновить индекс'),
        ),
      ]),
      if (canHere) ...[
        const SizedBox(height: 10),
        Row(children: [
          const SizedBox(width: 170, child: Text('Нагрузка на процессор')),
          Expanded(
            child: Slider(
              value: cpu,
              min: 10,
              max: 100,
              divisions: 9,
              label: '${cpu.round()} %',
              onChanged: (v) => setState(() => _cpuDrag = v),
              onChangeEnd: (v) {
                setState(() => _cpuDrag = null);
                intel.setCpuPercent(v.round());
              },
            ),
          ),
          SizedBox(width: 80, child: Text('${cpu.round()} %', textAlign: TextAlign.right, style: const TextStyle(color: C.muted))),
        ]),
        Row(children: [
          const SizedBox(width: 170, child: Text('Как разбирать')),
          Wrap(spacing: 8, children: [
            ChoiceChip(label: const Text('Весь трек'), selected: intel.mode == 'full', onSelected: (_) => intel.setMode('full')),
            ChoiceChip(label: const Text('Быстро, отрывки'), selected: intel.mode == 'fast', onSelected: (_) => intel.setMode('fast')),
          ]),
        ]),
        const Padding(
          padding: EdgeInsets.only(top: 4, bottom: 4),
          child: Text(
            'Весь трек — сетка долей и локальные участки с тембром, хромой, басом и энергией. Старый индекс обновляется в фоне. '
            'Отрывки (четыре по 16 секунд) считаются в разы быстрее, но темп и тональность менее надёжны.',
            style: TextStyle(color: C.faint, fontSize: 12, height: 1.4),
          ),
        ),
      ],
      HintSwitch(
        contentPadding: EdgeInsets.zero,
        value: intel.planEnabled,
        onChanged: intel.setPlanEnabled,
        title: 'Умные DJ-переходы',
        hint: 'В DJ-стиле переход привязывается к границе фразы, учитывает вокал и выравнивает громкость по LUFS. '
            'Нужен разбор «Весь трек» у обоих треков; без него переход как раньше.',
      ),
      HintSwitch(
        contentPadding: EdgeInsets.zero,
        value: intel.cutEnabled,
        onChanged: intel.planEnabled ? intel.setCutEnabled : null,
        title: 'Резкие стыки',
        hint: 'Когда оба трека на полной энергии или вокал мешал бы наложению, смена идёт за полдоли на границе фразы, без плавного наложения.',
      ),
      HintSwitch(
        contentPadding: EdgeInsets.zero,
        value: intel.syncEnabled,
        onChanged: intel.setSyncEnabled,
        title: 'Общий индекс на Диске',
        hint: 'Результаты разбора кладутся в папку cave-data/audio-intel и читаются другими устройствами. '
            'Без этого индекс остаётся только на этом устройстве.',
      ),
      if (intel.syncStatus.isNotEmpty) Text(intel.syncStatus, style: const TextStyle(color: C.faint, fontSize: 12)),
      Text('В индексе: ${intel.indexed}. Секции: ${intel.sectioned}. Локальный ритм: ${intel.rhythmic}. '
          'Модель голоса: ${intel.vocalModelCount}.', style: const TextStyle(color: C.faint, fontSize: 12)),
    ]);
  }
}
