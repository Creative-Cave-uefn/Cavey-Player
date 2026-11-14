import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../app.dart';
import '../core/automix.dart';
import '../core/dj.dart';
import '../core/mixbook.dart';
import '../core/models.dart';
import 'theme.dart';
import 'widgets.dart';

// Режим «Микс» у списка треков: колонки BPM и тональность, между треками — плашка перехода.
// Нажатие на плашку открывает редактор: можно оставить автоматический переход, настроить вручную или убрать совсем.

/// Цветная метка тональности по кругу Camelot («8A»); без тональности — прочерк
class KeyBadge extends StatelessWidget {
  final String? camelot;
  const KeyBadge(this.camelot, {super.key});

  @override
  Widget build(BuildContext context) {
    final k = Camelot.parse(camelot);
    if (k == null) return const Text('—', style: TextStyle(color: C.faint, fontSize: 13));
    final hue = ((k.n - 1) * 30.0 + 330) % 360;
    final bg = HSLColor.fromAHSL(1, hue, 0.75, k.minor ? 0.62 : 0.78).toColor();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(5)),
      child: Text(k.toString(), style: const TextStyle(color: Color(0xFF15151C), fontSize: 12, fontWeight: FontWeight.w700)),
    );
  }
}

/// Ширины колонок BPM и тональности в режиме «Микс»: шапка и строки совпадают
const kMixBpmW = 64.0;
const kMixKeyW = 64.0;

/// Ячейки BPM и тональности одного трека
class MixCells extends StatelessWidget {
  final Track track;
  const MixCells(this.track, {super.key});

  @override
  Widget build(BuildContext context) {
    final p = Services.of(context).player.mixer?.profileCached(track.id);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      SizedBox(
        width: kMixBpmW,
        child: Text(p?.bpm == null ? '—' : '${p!.bpm!.round()}',
            style: TextStyle(color: p?.bpm == null ? C.faint : C.muted, fontSize: 13, fontFeatures: const [FontFeature.tabularFigures()])),
      ),
      SizedBox(width: kMixKeyW, child: Align(alignment: Alignment.centerLeft, child: KeyBadge(p?.key))),
    ]);
  }
}

/// Плашка перехода между двумя подряд идущими треками
class TransitionChip extends StatelessWidget {
  final Track from;
  final Track to;
  const TransitionChip({super.key, required this.from, required this.to});

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    return ListenableBuilder(
      listenable: app.mixBook,
      builder: (context, _) {
        final pref = app.mixBook.get(from.id, to.id);
        final mode = pref?.mode ?? TransitionMode.auto;
        final (icon, label) = switch (mode) {
          TransitionMode.auto => (Icons.auto_awesome_rounded, 'Авто'),
          TransitionMode.manual => (Icons.tune_rounded, 'Вручную'),
          TransitionMode.cut => (Icons.content_cut_rounded, 'Без перехода'),
        };
        final color = mode == TransitionMode.auto ? C.muted : C.accent;
        return Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.only(left: 36),
            child: Tooltip(
              message: 'Настроить переход между треками',
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => showTransitionEditor(context, from, to),
                child: Container(
                  height: 26,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(color: C.raised, borderRadius: BorderRadius.circular(8)),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(icon, size: 14, color: color),
                    const SizedBox(width: 6),
                    Text(label, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600)),
                  ]),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

Future<void> showTransitionEditor(BuildContext context, Track from, Track to) {
  final app = Services.of(context);
  return showDialog<void>(context: context, builder: (_) => _TransitionEditor(app: app, from: from, to: to));
}

class _TransitionEditor extends StatefulWidget {
  final AppServices app;
  final Track from;
  final Track to;
  const _TransitionEditor({required this.app, required this.from, required this.to});

  @override
  State<_TransitionEditor> createState() => _TransitionEditorState();
}

class _TransitionEditorState extends State<_TransitionEditor> {
  static const _barSteps = [1, 2, 4, 8, 16, 32];

  late TransitionPref _pref;
  MixProfile? _a;
  MixProfile? _b;
  MixPlan? _auto;

  AppServices get app => widget.app;

  @override
  void initState() {
    super.initState();
    _pref = app.mixBook.get(widget.from.id, widget.to.id) ?? const TransitionPref();
    app.player.mixer?.pending.addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    app.player.mixer?.pending.removeListener(_reload);
    super.dispose();
  }

  void _reload() {
    final m = app.player.mixer;
    final a = m?.profile(widget.from.id), b = m?.profile(widget.to.id);
    MixPlan? auto;
    if (a != null && b != null) {
      auto = MixPlan.make(a, b, maxSec: app.player.crossfadeSecNow.clamp(1, 12).toInt(), dj: djMixOf(app));
    }
    if (!mounted) return;
    setState(() {
      _a = a;
      _b = b;
      _auto = auto;
    });
  }

  /// Автоматические значения для подсказок: как переход прошёл бы без ручной настройки
  DjMix? djMixOf(AppServices app) => app.player.djStyle ? const DjMix() : null;

  void _set(TransitionPref p) => setState(() => _pref = p);

  int get _outMs => _pref.outMs ?? _auto?.start.inMilliseconds ?? math.max(0, (_a?.endMs ?? 0) - 6000);
  int get _inMs => _pref.inMs ?? _auto?.inStart.inMilliseconds ?? math.min(_b?.introMs ?? 0, 8000);

  String _t(int ms) {
    final s = ms ~/ 1000;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final ready = _a != null && _b != null;
    final manual = _pref.mode == TransitionMode.manual;
    final dj = _pref.style == 'dj';
    final barIdx = _barSteps.indexOf(_pref.bars).clamp(0, _barSteps.length - 1).toInt();
    return Dialog(
      backgroundColor: C.panel,
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(22),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Переход', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            _trackLine(widget.from, _a),
            const Padding(padding: EdgeInsets.only(left: 6), child: Icon(Icons.south_rounded, size: 16, color: C.faint)),
            _trackLine(widget.to, _b),
            const SizedBox(height: 16),
            SegmentedButton<TransitionMode>(
              segments: const [
                ButtonSegment(value: TransitionMode.auto, label: Text('Авто'), icon: Icon(Icons.auto_awesome_rounded, size: 16)),
                ButtonSegment(value: TransitionMode.manual, label: Text('Вручную'), icon: Icon(Icons.tune_rounded, size: 16)),
                ButtonSegment(value: TransitionMode.cut, label: Text('Без перехода'), icon: Icon(Icons.content_cut_rounded, size: 16)),
              ],
              selected: {_pref.mode},
              onSelectionChanged: (v) => _set(_pref.copyWith(mode: v.first)),
            ),
            const SizedBox(height: 8),
            Text(
              switch (_pref.mode) {
                TransitionMode.auto => 'Переход по общим настройкам: плеер сам выберет момент, длину и подгонку темпа.',
                TransitionMode.manual => 'Выберите, где начать переход в первом треке и с какого места вступает второй.',
                TransitionMode.cut => 'Первый трек доиграет до конца, второй начнётся сразу следом.',
              },
              style: const TextStyle(color: C.muted, fontSize: 13, height: 1.4),
            ),
            if (manual) ...[
              const SizedBox(height: 14),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'dj', label: Text('DJ: по долям')),
                  ButtonSegment(value: 'fade', label: Text('Плавный')),
                ],
                selected: {_pref.style},
                onSelectionChanged: (v) => _set(_pref.copyWith(style: v.first)),
              ),
              const SizedBox(height: 12),
              if (!ready)
                _needAnalysis()
              else ...[
                _WaveMarker(
                  title: 'Начало перехода в «${widget.from.title}»',
                  profile: _a!,
                  ms: _outMs,
                  label: _t(_outMs),
                  onChanged: (ms) => _set(_pref.copyWith(outMs: ms)),
                ),
                const SizedBox(height: 10),
                _WaveMarker(
                  title: 'Вступление «${widget.to.title}» с места',
                  profile: _b!,
                  ms: _inMs,
                  label: _t(_inMs),
                  onChanged: (ms) => _set(_pref.copyWith(inMs: ms)),
                ),
              ],
              const SizedBox(height: 8),
              Row(children: [
                SizedBox(width: 150, child: Text(dj ? 'Длина перехода' : 'Длина, секунд')),
                Expanded(
                  child: dj
                      ? Slider(
                          value: barIdx.toDouble(),
                          min: 0,
                          max: (_barSteps.length - 1).toDouble(),
                          divisions: _barSteps.length - 1,
                          label: '${_barSteps[barIdx]} тактов',
                          onChanged: (v) => _set(_pref.copyWith(bars: _barSteps[v.round()])),
                        )
                      : Slider(
                          value: _pref.seconds.toDouble().clamp(1, 16).toDouble(),
                          min: 1,
                          max: 16,
                          divisions: 15,
                          label: '${_pref.seconds} с',
                          onChanged: (v) => _set(_pref.copyWith(seconds: v.round())),
                        ),
                ),
                SizedBox(
                  width: 80,
                  child: Text(dj ? '${_barSteps[barIdx]} тактов' : '${_pref.seconds} с',
                      textAlign: TextAlign.right, style: const TextStyle(color: C.muted)),
                ),
              ]),
              if (dj) ...[
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: _pref.sync,
                  onChanged: (v) => _set(_pref.copyWith(sync: v)),
                  title: const Text('Подгонять темп второго трека'),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: _pref.bass,
                  onChanged: (v) => _set(_pref.copyWith(bass: v)),
                  title: const Text('Обмен басов'),
                ),
                Row(children: [
                  const SizedBox(width: 150, child: Text('Сдвиг долей')),
                  Expanded(
                    child: Slider(
                      value: _pref.offsetMs.toDouble().clamp(-150, 150).toDouble(),
                      min: -150,
                      max: 150,
                      divisions: 60,
                      label: '${_pref.offsetMs} мс',
                      onChanged: (v) => _set(_pref.copyWith(offsetMs: (v / 5).round() * 5)),
                    ),
                  ),
                  SizedBox(width: 80, child: Text('${_pref.offsetMs} мс', textAlign: TextAlign.right, style: const TextStyle(color: C.muted))),
                ]),
                if (ready && (_a!.bpm == null || _b!.bpm == null || (_a!.tailBeatMs == null) || (_b!.headBeatMs == null)))
                  const Padding(
                    padding: EdgeInsets.only(top: 4),
                    child: Text('У этой пары неизвестны темп или доли: переход пройдёт как плавный.',
                        style: TextStyle(color: C.danger, fontSize: 12, height: 1.4)),
                  ),
              ],
            ],
            const SizedBox(height: 18),
            Row(children: [
              OutlinedButton.icon(
                onPressed: !ready
                    ? null
                    : () async {
                        final ok = await app.player.previewTransition(widget.from, widget.to, _pref);
                        if (!ok) app.lib.messages.add('Для предпрослушивания нужно разобрать оба трека');
                      },
                icon: const Icon(Icons.play_arrow_rounded, size: 18),
                label: const Text('Прослушать'),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () {
                  app.mixBook.remove(widget.from.id, widget.to.id);
                  Navigator.of(context).pop();
                },
                child: const Text('Сбросить'),
              ),
              const Spacer(),
              TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Отмена')),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () {
                  app.mixBook.set(widget.from.id, widget.to.id, _pref);
                  Navigator.of(context).pop();
                },
                child: const Text('Готово'),
              ),
            ]),
          ]),
        ),
      ),
    );
  }

  Widget _trackLine(Track t, MixProfile? p) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          CoverImage(track: t, size: 34, radius: 5),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
              Text(t.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.muted, fontSize: 12)),
            ]),
          ),
          Text(p?.bpm == null ? '—' : '${p!.bpm!.round()} BPM', style: const TextStyle(color: C.muted, fontSize: 12)),
          const SizedBox(width: 10),
          KeyBadge(p?.key),
        ]),
      );

  Widget _needAnalysis() => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: C.raised, borderRadius: BorderRadius.circular(10)),
        child: Row(children: [
          const Expanded(
            child: Text('Эти треки ещё не разобраны: без волны и долей начало перехода не выбрать.',
                style: TextStyle(color: C.muted, fontSize: 13, height: 1.4)),
          ),
          const SizedBox(width: 10),
          FilledButton(
            onPressed: () {
              app.player.mixer?.prepareMany([widget.from.id, widget.to.id]);
              app.lib.messages.add('Треки поставлены на разбор, это займёт немного времени');
            },
            child: const Text('Разобрать'),
          ),
        ]),
      );
}

/// Волна трека с перетаскиваемой отметкой: нажмите или потяните, чтобы выбрать место
class _WaveMarker extends StatelessWidget {
  final String title;
  final MixProfile profile;
  final int ms;
  final String label;
  final ValueChanged<int> onChanged;

  const _WaveMarker({required this.title, required this.profile, required this.ms, required this.label, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final dur = math.max(1, profile.durationMs);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Expanded(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.muted, fontSize: 12))),
        Text(label, style: TextStyle(color: C.accent, fontSize: 12, fontWeight: FontWeight.w600)),
      ]),
      const SizedBox(height: 4),
      LayoutBuilder(builder: (context, box) {
        int at(double dx) => (dx / math.max(1, box.maxWidth) * dur).round().clamp(0, dur).toInt();
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => onChanged(at(d.localPosition.dx)),
          onHorizontalDragUpdate: (d) => onChanged(at(d.localPosition.dx)),
          child: SizedBox(
            height: 52,
            width: double.infinity,
            child: CustomPaint(painter: _MarkerPainter(profile.wave, ms / dur, profile.introMs / dur, profile.endMs / dur)),
          ),
        );
      }),
    ]);
  }
}

class _MarkerPainter extends CustomPainter {
  final List<int> wave;
  final double marker; // 0…1
  final double intro;
  final double end;
  _MarkerPainter(this.wave, this.marker, this.intro, this.end);

  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()..color = const Color(0x14FFFFFF);
    canvas.drawRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(8)), bg);
    final base = Paint()..color = const Color(0x66FFFFFF);
    final past = Paint()..color = C.accent.withValues(alpha: 0.85);
    final n = wave.isEmpty ? 120 : wave.length;
    final w = size.width / n;
    for (var i = 0; i < n; i++) {
      final v = wave.isEmpty ? 0.12 : math.max(0.06, wave[i] / 255.0);
      final h = v * (size.height - 8);
      final x = i * w;
      final after = (i + 0.5) / n >= marker;
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(x + 0.5, (size.height - h) / 2, math.max(1.0, w - 1), h), const Radius.circular(1)),
        after ? past : base,
      );
    }
    final line = Paint()
      ..color = Colors.white
      ..strokeWidth = 2;
    final mx = marker.clamp(0.0, 1.0).toDouble() * size.width;
    canvas.drawLine(Offset(mx, 0), Offset(mx, size.height), line);
  }

  @override
  bool shouldRepaint(_MarkerPainter old) => old.wave != wave || old.marker != marker;
}
