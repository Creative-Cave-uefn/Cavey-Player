import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../app.dart';
import '../core/dj.dart' show Camelot;
import '../core/intel/record.dart';
import '../core/intel/similarity.dart';
import '../core/intel/viz.dart';
import '../core/models.dart';
import 'theme.dart';
import 'widgets.dart' show CoverImage;

// Отладочные экраны анализа звука: карта схожести библиотеки и спектрограмма трека с отметками долей, фраз, энергии и вокала.

Future<void> showSoundMap(BuildContext context) =>
    showDialog<void>(context: context, builder: (_) => Services(app: Services.of(context), child: const _SoundMapDialog()));

Future<void> showTrackSpectrogram(BuildContext context, Track track) => showDialog<void>(
    context: context, builder: (_) => Services(app: Services.of(context), child: _SpectroDialog(track: track)));

String _fmtTime(double sec) {
  final s = sec.round();
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

String _trackName(Track t) => t.displayArtist.isEmpty ? t.title : '${t.displayArtist} — ${t.title}';

// ---------------------------------------------------------------- карта

enum _ColorBy { key, energy, tempo }

class _SoundMapDialog extends StatefulWidget {
  const _SoundMapDialog();
  @override
  State<_SoundMapDialog> createState() => _SoundMapDialogState();
}

class _SoundMapDialogState extends State<_SoundMapDialog> {
  List<MapPoint> _points = const [];
  List<Color> _colors = const [];
  List<String> _hay = const []; // строка для поиска у каждой точки: название, исполнитель, альбом (нижний регистр)
  _ColorBy _by = _ColorBy.key;
  int? _sel;
  List<SimilarityHit> _near = const [];
  bool _ready = false;
  bool _covers = false;
  double _eLo = -30, _eHi = -10;
  final _search = TextEditingController();
  List<int> _found = const [];
  int _focusTick = 0;
  int? _focusIndex;

  AppServices get app => Services.of(context);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_ready) return;
    _ready = true;
    final index = app.intel.index;
    _points = projectMap(index);
    _hay = [
      for (final p in _points)
        () {
          final t = app.lib.data.tracks[p.id];
          return t == null ? '' : '${t.title} ${t.displayArtist} ${t.album}'.toLowerCase();
        }()
    ];
    final e = [for (final p in _points) p.f.rmsDb]..sort();
    if (e.length >= 5) {
      _eLo = e[(e.length * 0.05).floor()];
      _eHi = e[math.min(e.length - 1, (e.length * 0.95).floor())];
      if (_eHi - _eLo < 1) _eHi = _eLo + 1;
    }
    _recolor();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _recolor() {
    _colors = [for (final p in _points) _colorOf(p.f)];
  }

  Color _colorOf(TrackFeatures f) {
    switch (_by) {
      case _ColorBy.key:
        final k = Camelot.parse(f.key);
        if (k == null || !f.keyReliable) return const Color(0x66FFFFFF);
        return HSLColor.fromAHSL(1, ((k.n - 1) * 30.0) % 360, 0.75, k.minor ? 0.52 : 0.68).toColor();
      case _ColorBy.energy:
        final t = ((f.rmsDb - _eLo) / (_eHi - _eLo)).clamp(0.0, 1.0).toDouble();
        return HSLColor.fromAHSL(1, 220 - 220 * t, 0.8, 0.55).toColor();
      case _ColorBy.tempo:
        if (!f.tempoReliable || f.bpm == null) return const Color(0x66FFFFFF);
        final t = ((f.bpm! - 70) / 110).clamp(0.0, 1.0).toDouble();
        return HSLColor.fromAHSL(1, 210 - 210 * t, 0.8, 0.55).toColor();
    }
  }

  /// Поиск по названию, исполнителю и альбому: все слова запроса должны встретиться
  void _onSearch(String q) {
    final words = q.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    setState(() {
      if (words.isEmpty) {
        _found = const [];
        return;
      }
      final out = <int>[];
      for (var i = 0; i < _hay.length; i++) {
        final h = _hay[i];
        if (h.isEmpty) continue;
        var ok = true;
        for (final w in words) {
          if (!h.contains(w)) {
            ok = false;
            break;
          }
        }
        if (ok) out.add(i);
      }
      _found = out;
    });
  }

  /// Выбрать точку; [focus] — ещё и подвести к ней карту
  void _select(int? i, {bool focus = false}) {
    setState(() {
      _sel = i;
      _near = i == null ? const [] : app.intel.index.similar(seeds: [_points[i].id], limit: 12, mode: SimilarityMode.sound);
      if (focus && i != null) {
        _focusIndex = i;
        _focusTick++;
      }
    });
  }

  void _selectId(String id, {bool focus = true}) {
    final i = _indexOfId(id);
    if (i >= 0) _select(i, focus: focus);
  }

  Future<void> _playGroup() async {
    final i = _sel;
    if (i == null) return;
    final tracks = <Track>[];
    final first = app.lib.data.tracks[_points[i].id];
    if (first != null) tracks.add(first);
    for (final h in _near) {
      final t = app.lib.data.tracks[h.id];
      if (t != null) tracks.add(t);
    }
    if (tracks.isEmpty) return;
    await app.player.playTracks(tracks, 0, inOrder: true);
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final sel = _sel;
    final selPoint = sel == null ? null : _points[sel];
    final selTrack = selPoint == null ? null : app.lib.data.tracks[selPoint.id];
    final searching = _search.text.trim().isNotEmpty;
    return Dialog(
      backgroundColor: C.panel,
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: SizedBox(
        width: 1100,
        height: 720,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text('Карта схожести', style: display(20)),
              const SizedBox(width: 12),
              Text('${_points.length} треков', style: const TextStyle(color: C.faint, fontSize: 13)),
              const SizedBox(width: 18),
              Expanded(
                child: SizedBox(
                  height: 38,
                  child: TextField(
                    controller: _search,
                    onChanged: _onSearch,
                    style: const TextStyle(fontSize: 14),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: 'Найти трек: название, исполнитель, альбом',
                      prefixIcon: const Icon(Icons.search_rounded, size: 18),
                      suffixIcon: searching
                          ? IconButton(
                              icon: const Icon(Icons.close_rounded, size: 16),
                              onPressed: () {
                                _search.clear();
                                _onSearch('');
                              },
                            )
                          : null,
                      filled: true,
                      fillColor: C.raised,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close_rounded)),
            ]),
            const SizedBox(height: 6),
            const Text(
              'Каждая точка — трек. Чем ближе точки, тем похожее их звучание (тембр, гармония, энергия, ритм). '
              'Колёсико и перетаскивание — масштаб и сдвиг, клик по точке — соседи справа.',
              style: TextStyle(color: C.muted, fontSize: 13, height: 1.4),
            ),
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
              const Text('Цвет:', style: TextStyle(color: C.faint, fontSize: 13)),
              for (final e in const [(_ColorBy.key, 'Тональность'), (_ColorBy.energy, 'Громкость'), (_ColorBy.tempo, 'Темп')])
                ChoiceChip(
                  label: Text(e.$2),
                  selected: _by == e.$1,
                  onSelected: (_) => setState(() {
                    _by = e.$1;
                    _recolor();
                  }),
                ),
              const SizedBox(width: 6),
              FilterChip(
                avatar: const Icon(Icons.image_rounded, size: 16),
                label: const Text('Обложки вместо точек'),
                selected: _covers,
                onSelected: (v) => setState(() => _covers = v),
              ),
              const SizedBox(width: 6),
              _Legend(by: _by, eLo: _eLo, eHi: _eHi),
            ]),
            if (_covers)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text('Обложки появляются, когда в окне остаётся не больше ~120 треков: приблизьте нужный участок.',
                    style: TextStyle(color: C.faint, fontSize: 12)),
              ),
            const SizedBox(height: 10),
            Expanded(
              child: _points.length < 3
                  ? const Center(
                      child: Text('В индексе пока меньше трёх треков: карту строить не из чего. Дождитесь разбора звука.',
                          style: TextStyle(color: C.muted)))
                  : Row(children: [
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Container(
                            color: const Color(0xFF0A0C18),
                            child: _MapCanvas(
                              points: _points,
                              colors: _colors,
                              selected: sel,
                              near: [for (final h in _near) _indexOfId(h.id)].where((i) => i >= 0).toList(),
                              found: _found.length > 300 ? const [] : _found,
                              accent: accent,
                              covers: _covers,
                              tracks: app.lib.data.tracks,
                              focusIndex: _focusIndex,
                              focusTick: _focusTick,
                              onSelect: _select,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 14),
                      SizedBox(
                        width: 320,
                        child: searching
                            ? _SearchResults(
                                found: _found,
                                points: _points,
                                tracks: app.lib.data.tracks,
                                selected: sel,
                                onPick: (i) => _select(i, focus: true),
                              )
                            : selPoint == null
                                ? const Center(child: Text('Выберите точку или найдите трек', style: TextStyle(color: C.faint)))
                                : _SidePanel(
                                    point: selPoint,
                                    track: selTrack,
                                    near: _near,
                                    tracks: app.lib.data.tracks,
                                    onPick: _selectId,
                                    onPlay: _playGroup,
                                    onSpectro: selTrack == null ? null : () => showTrackSpectrogram(context, selTrack),
                                  ),
                      ),
                    ]),
            ),
          ]),
        ),
      ),
    );
  }

  int _indexOfId(String id) => _points.indexWhereId(id);
}

extension on List<MapPoint> {
  int indexWhereId(String id) {
    for (var i = 0; i < length; i++) {
      if (this[i].id == id) return i;
    }
    return -1;
  }
}

class _Legend extends StatelessWidget {
  final _ColorBy by;
  final double eLo, eHi;
  const _Legend({required this.by, required this.eLo, required this.eHi});

  @override
  Widget build(BuildContext context) {
    switch (by) {
      case _ColorBy.key:
        return Row(mainAxisSize: MainAxisSize.min, children: [
          for (var n = 1; n <= 12; n++)
            Container(
              width: 16,
              height: 10,
              color: HSLColor.fromAHSL(1, ((n - 1) * 30.0) % 360, 0.75, 0.6).toColor(),
            ),
          const SizedBox(width: 6),
          const Text('1 … 12 (по кругу Camelot); тёмнее — минор, светлее — мажор; серый — неясно',
              style: TextStyle(color: C.faint, fontSize: 12)),
        ]);
      case _ColorBy.energy:
        return Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 120,
            height: 10,
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [
                for (var i = 0; i <= 6; i++) HSLColor.fromAHSL(1, 220 - 220 * i / 6, 0.8, 0.55).toColor(),
              ]),
            ),
          ),
          const SizedBox(width: 6),
          Text('${eLo.toStringAsFixed(0)} … ${eHi.toStringAsFixed(0)} дБ', style: const TextStyle(color: C.faint, fontSize: 12)),
        ]);
      case _ColorBy.tempo:
        return Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 120,
            height: 10,
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [
                for (var i = 0; i <= 6; i++) HSLColor.fromAHSL(1, 210 - 210 * i / 6, 0.8, 0.55).toColor(),
              ]),
            ),
          ),
          const SizedBox(width: 6),
          const Text('70 … 180 BPM; серый — темп неясен', style: TextStyle(color: C.faint, fontSize: 12)),
        ]);
    }
  }
}

/// Карта с масштабом и сдвигом. Режим обложек: вместо точек обложки треков, но только пока в окне их не больше [_coverCap]
/// (иначе их сотни наложились бы друг на друга и тормозили); выбранный трек и его соседи всегда с обложками
class _MapCanvas extends StatefulWidget {
  final List<MapPoint> points;
  final List<Color> colors;
  final int? selected;
  final List<int> near;
  final List<int> found;
  final Color accent;
  final bool covers;
  final Map<String, Track> tracks;
  final int? focusIndex;
  final int focusTick;
  final ValueChanged<int?> onSelect;
  const _MapCanvas({
    required this.points,
    required this.colors,
    required this.selected,
    required this.near,
    required this.found,
    required this.accent,
    required this.covers,
    required this.tracks,
    required this.focusIndex,
    required this.focusTick,
    required this.onSelect,
  });

  @override
  State<_MapCanvas> createState() => _MapCanvasState();
}

const int _coverCap = 120;

class _MapCanvasState extends State<_MapCanvas> {
  final _ctrl = TransformationController();
  Size _size = Size.zero;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Offset _pos(MapPoint p, Size size) => Offset(
        24 + (p.x + 1) / 2 * (size.width - 48),
        24 + (1 - (p.y + 1) / 2) * (size.height - 48),
      );

  @override
  void didUpdateWidget(_MapCanvas old) {
    super.didUpdateWidget(old);
    final i = widget.focusIndex;
    if (i != null && widget.focusTick != old.focusTick && _size != Size.zero) _centerOn(i);
  }

  /// Подвести карту к точке: масштаб не меньше 5, точка в центре окна
  void _centerOn(int i) {
    final c = _pos(widget.points[i], _size);
    final s = math.max(5.0, _ctrl.value.getMaxScaleOnAxis());
    final tx = _size.width / 2 - c.dx * s;
    final ty = _size.height / 2 - c.dy * s;
    _ctrl.value = Matrix4(s, 0, 0, 0, 0, s, 0, 0, 0, 0, 1, 0, tx, ty, 0, 1);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final size = Size(box.maxWidth, box.maxHeight);
      _size = size;
      return InteractiveViewer(
        transformationController: _ctrl,
        minScale: 0.8,
        maxScale: 40,
        boundaryMargin: const EdgeInsets.all(400),
        child: AnimatedBuilder(
          animation: _ctrl,
          builder: (context, _) {
            final m = _ctrl.value;
            final scale = m.getMaxScaleOnAxis();
            // Окно в координатах карты
            final view = MatrixUtils.transformRect(Matrix4.inverted(m), Offset.zero & size).inflate(20 / scale);
            final inView = <int>[];
            if (widget.covers) {
              for (var i = 0; i < widget.points.length; i++) {
                if (view.contains(_pos(widget.points[i], size))) {
                  inView.add(i);
                  if (inView.length > _coverCap) break;
                }
              }
            }
            final showCovers = widget.covers && inView.length <= _coverCap;
            final withCover = <int>{
              if (showCovers) ...inView,
              if (widget.covers && widget.selected != null) widget.selected!,
              if (widget.covers) ...widget.near,
            };
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (d) {
                // Зона попадания — 14 пикселей на экране: в координатах карты она сжимается с масштабом
                final r = (withCover.isEmpty ? 14.0 : 20.0) / scale;
                var best = -1;
                var bestD = r * r;
                for (var i = 0; i < widget.points.length; i++) {
                  final o = _pos(widget.points[i], size) - d.localPosition;
                  final dd = o.dx * o.dx + o.dy * o.dy;
                  if (dd < bestD) {
                    bestD = dd;
                    best = i;
                  }
                }
                widget.onSelect(best < 0 ? null : best);
              },
              child: SizedBox(
                width: size.width,
                height: size.height,
                child: Stack(clipBehavior: Clip.none, children: [
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _MapPainter(
                        points: widget.points,
                        colors: widget.colors,
                        selected: widget.selected,
                        near: widget.near,
                        found: widget.found,
                        accent: widget.accent,
                        scale: scale,
                        hideDots: withCover,
                        pos: (p) => _pos(p, size),
                      ),
                    ),
                  ),
                  for (final i in withCover)
                    () {
                      final isSel = i == widget.selected;
                      // Размер на экране: 40 пикселей, у выбранного 56; в координатах карты делим на масштаб
                      final px = (isSel ? 56.0 : 40.0) / scale;
                      final c = _pos(widget.points[i], size);
                      return Positioned(
                        key: ValueKey('cv_${widget.points[i].id}'),
                        left: c.dx - px / 2,
                        top: c.dy - px / 2,
                        width: px,
                        height: px,
                        child: IgnorePointer(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(math.max(1.0, 5.0 / scale)),
                              border: Border.all(color: isSel ? widget.accent : widget.colors[i], width: (isSel ? 2.5 : 1.5) / scale),
                            ),
                            child: CoverImage(track: widget.tracks[widget.points[i].id], size: px, radius: math.max(1.0, 4.0 / scale)),
                          ),
                        ),
                      );
                    }(),
                ]),
              ),
            );
          },
        ),
      );
    });
  }
}

class _MapPainter extends CustomPainter {
  final List<MapPoint> points;
  final List<Color> colors;
  final int? selected;
  final List<int> near;
  final List<int> found;
  final Color accent;
  final double scale;
  final Set<int> hideDots;
  final Offset Function(MapPoint) pos;
  _MapPainter({
    required this.points,
    required this.colors,
    required this.selected,
    required this.near,
    required this.found,
    required this.accent,
    required this.scale,
    required this.hideDots,
    required this.pos,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Сетка из тонких линий: ориентир при сдвиге и масштабе
    final grid = Paint()
      ..color = const Color(0x10FFFFFF)
      ..strokeWidth = 1 / scale;
    for (var i = 1; i < 8; i++) {
      canvas.drawLine(Offset(size.width * i / 8, 0), Offset(size.width * i / 8, size.height), grid);
      canvas.drawLine(Offset(0, size.height * i / 8), Offset(size.width, size.height * i / 8), grid);
    }
    // Размеры рисуем в экранных пикселях: делим на масштаб, чтобы точки не раздувались при приближении
    final k = 1 / scale;
    final dim = selected != null;
    final dot = Paint();
    for (var i = 0; i < points.length; i++) {
      if (hideDots.contains(i)) continue;
      dot.color = colors[i].withValues(alpha: dim ? 0.45 : 0.85);
      canvas.drawCircle(pos(points[i]), 2.6 * math.min(1.0, k * 2.0 + 0.4), dot);
    }
    // Найденные поиском: кольцо
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6 * k
      ..color = accent;
    for (final i in found) {
      canvas.drawCircle(pos(points[i]), 7 * k, ring);
    }
    final sel = selected;
    if (sel != null) {
      final c = pos(points[sel]);
      final line = Paint()
        ..color = accent.withValues(alpha: 0.35)
        ..strokeWidth = 1 * k;
      for (final i in near) {
        canvas.drawLine(c, pos(points[i]), line);
      }
      for (final i in near) {
        if (hideDots.contains(i)) continue;
        dot.color = colors[i];
        canvas.drawCircle(pos(points[i]), 4.2 * k, dot);
        canvas.drawCircle(
            pos(points[i]),
            5.6 * k,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.2 * k
              ..color = Colors.white70);
      }
      if (!hideDots.contains(sel)) {
        canvas.drawCircle(c, 9 * k, Paint()..color = accent.withValues(alpha: 0.25));
        canvas.drawCircle(c, 5.5 * k, Paint()..color = colors[sel]);
        canvas.drawCircle(
            c,
            7 * k,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2 * k
              ..color = accent);
      }
    }
  }

  @override
  bool shouldRepaint(_MapPainter old) =>
      old.selected != selected ||
      old.colors != colors ||
      old.near != near ||
      old.found != found ||
      old.points != points ||
      old.accent != accent ||
      old.scale != scale ||
      old.hideDots != hideDots;
}

/// Результаты поиска справа от карты: обложка, название, исполнитель; клик подводит карту к точке
class _SearchResults extends StatelessWidget {
  final List<int> found;
  final List<MapPoint> points;
  final Map<String, Track> tracks;
  final int? selected;
  final ValueChanged<int> onPick;
  const _SearchResults({required this.found, required this.points, required this.tracks, required this.selected, required this.onPick});

  @override
  Widget build(BuildContext context) {
    if (found.isEmpty) {
      return const Center(child: Text('Ничего не найдено среди разобранных треков', style: TextStyle(color: C.faint)));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Найдено: ${found.length}${found.length > 60 ? ' (показаны первые 60)' : ''}', style: const TextStyle(color: C.faint, fontSize: 12)),
      const SizedBox(height: 6),
      Expanded(
        child: ListView.builder(
          itemCount: math.min(60, found.length),
          itemBuilder: (context, n) {
            final i = found[n];
            final t = tracks[points[i].id];
            return InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => onPick(i),
              child: Container(
                decoration: BoxDecoration(
                  color: i == selected ? C.raised : null,
                  borderRadius: BorderRadius.circular(8),
                ),
                padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 4),
                child: Row(children: [
                  CoverImage(track: t, size: 38, radius: 5),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(t?.title ?? points[i].id, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, height: 1.25)),
                      if (t != null && t.displayArtist.isNotEmpty)
                        Text(t.displayArtist, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.muted, fontSize: 12)),
                    ]),
                  ),
                ]),
              ),
            );
          },
        ),
      ),
    ]);
  }
}

class _SidePanel extends StatelessWidget {
  final MapPoint point;
  final Track? track;
  final List<SimilarityHit> near;
  final Map<String, Track> tracks;
  final ValueChanged<String> onPick;
  final VoidCallback onPlay;
  final VoidCallback? onSpectro;
  const _SidePanel({
    required this.point,
    required this.track,
    required this.near,
    required this.tracks,
    required this.onPick,
    required this.onPlay,
    required this.onSpectro,
  });

  @override
  Widget build(BuildContext context) {
    final f = point.f;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        CoverImage(track: track, size: 64, radius: 8),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(track == null ? point.id : track!.title,
                maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, height: 1.25)),
            if (track != null && track!.displayArtist.isNotEmpty)
              Text(track!.displayArtist, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.muted, fontSize: 13)),
          ]),
        ),
      ]),
      const SizedBox(height: 8),
      _FeatureChips(f: f),
      const SizedBox(height: 10),
      Row(children: [
        Expanded(
          child: FilledButton.icon(
            onPressed: onPlay,
            icon: const Icon(Icons.play_arrow_rounded, size: 18),
            label: const Text('Играть с похожими'),
          ),
        ),
        const SizedBox(width: 8),
        IconButton.outlined(
          tooltip: 'Спектрограмма трека',
          onPressed: onSpectro,
          icon: const Icon(Icons.graphic_eq_rounded, size: 18),
        ),
      ]),
      const SizedBox(height: 12),
      const Text('Ближайшие по звуку', style: TextStyle(color: C.faint, fontSize: 12)),
      const SizedBox(height: 4),
      Expanded(
        child: ListView.builder(
          itemCount: near.length,
          itemBuilder: (context, i) {
            final h = near[i];
            final t = tracks[h.id];
            return InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => onPick(h.id),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 4),
                child: Row(children: [
                  CoverImage(track: t, size: 34, radius: 5),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 36,
                    child: Text('${(h.score.clamp(0.0, 1.0) * 100).round()}%',
                        style: const TextStyle(color: C.muted, fontSize: 13, fontWeight: FontWeight.w600)),
                  ),
                  Expanded(
                    child: Text(t == null ? h.id : _trackName(t), maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, height: 1.25)),
                  ),
                ]),
              ),
            );
          },
        ),
      ),
    ]);
  }
}

class _FeatureChips extends StatelessWidget {
  final TrackFeatures f;
  const _FeatureChips({required this.f});

  @override
  Widget build(BuildContext context) {
    Widget chip(String s) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(color: C.raised, borderRadius: BorderRadius.circular(999)),
          child: Text(s, style: const TextStyle(fontSize: 12, color: C.muted)),
        );
    return Wrap(spacing: 6, runSpacing: 6, children: [
      chip(f.tempoReliable && f.bpm != null ? '${f.bpm!.round()} BPM' : 'темп неясен'),
      chip(f.key == null ? 'тональность ?' : '${f.key}${f.keyReliable ? '' : '?'}'),
      if (f.lufs != null) chip('${f.lufs!.toStringAsFixed(1)} LUFS'),
      chip(_fmtTime(f.durationSec)),
      if (f.mode != 'full') chip('отрывки'),
    ]);
  }
}

// ---------------------------------------------------------------- спектрограмма

class _SpectroDialog extends StatefulWidget {
  final Track track;
  const _SpectroDialog({required this.track});
  @override
  State<_SpectroDialog> createState() => _SpectroDialogState();
}

class _SpectroDialogState extends State<_SpectroDialog> {
  SpectroData? _data;
  ui.Image? _image;
  String _status = 'Подготовка…';
  String? _error;
  bool _started = false;
  bool _grid = true, _phrases = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    unawaited(_load());
  }

  Future<void> _load() async {
    final intel = Services.of(context).intel;
    try {
      final d = await intel.spectrogramFor(widget.track, onStatus: (s) {
        if (mounted) setState(() => _status = s);
      });
      final px = spectroPixels(d);
      final c = Completer<ui.Image>();
      ui.decodeImageFromPixels(px, d.frames, d.bands, ui.PixelFormat.rgba8888, c.complete);
      final img = await c.future;
      if (!mounted) {
        img.dispose();
        return;
      }
      setState(() {
        _data = d;
        _image = img;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final f = app.intel.store.get(widget.track.id);
    final accent = Theme.of(context).colorScheme.primary;
    return Dialog(
      backgroundColor: C.panel,
      insetPadding: const EdgeInsets.all(24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: SizedBox(
        width: 1100,
        height: 640,
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(_trackName(widget.track), maxLines: 1, overflow: TextOverflow.ellipsis, style: display(20))),
              IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close_rounded)),
            ]),
            if (f != null) ...[
              const SizedBox(height: 6),
              _FeatureChips(f: f),
            ],
            const SizedBox(height: 10),
            Expanded(
              child: _error != null
                  ? Center(child: Text('Не получилось: $_error', style: const TextStyle(color: C.danger)))
                  : _image == null || _data == null
                      ? Center(
                          child: Column(mainAxisSize: MainAxisSize.min, children: [
                            const CircularProgressIndicator(),
                            const SizedBox(height: 14),
                            Text(_status, style: const TextStyle(color: C.muted)),
                          ]),
                        )
                      : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                            FilterChip(
                              label: const Text('Доли и такты'),
                              selected: _grid,
                              onSelected: f?.dj == null ? null : (v) => setState(() => _grid = v),
                            ),
                            FilterChip(
                              label: const Text('Границы фраз'),
                              selected: _phrases,
                              onSelected: f?.dj == null ? null : (v) => setState(() => _phrases = v),
                            ),
                            if (f?.dj == null)
                              const Text('Для долей, фраз, энергии и вокала нужен разбор «Весь трек».',
                                  style: TextStyle(color: C.faint, fontSize: 12)),
                          ]),
                          const SizedBox(height: 8),
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(12),
                              child: Container(
                                color: const Color(0xFF05060C),
                                child: InteractiveViewer(
                                  minScale: 1,
                                  maxScale: 24,
                                  child: LayoutBuilder(
                                    builder: (context, box) => CustomPaint(
                                      size: Size(box.maxWidth, box.maxHeight),
                                      painter: _SpectroPainter(
                                        image: _image!,
                                        data: _data!,
                                        dj: f?.dj,
                                        showGrid: _grid,
                                        showPhrases: _phrases,
                                        accent: accent,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'Сверху вниз: спектрограмма (частоты от 40 Гц до 10 кГц, ярче — громче), громкость по секундам, присутствие вокала (эвристика по средним частотам). '
                            'Колёсико — масштаб по времени.',
                            style: TextStyle(color: C.faint, fontSize: 12, height: 1.4),
                          ),
                        ]),
            ),
          ]),
        ),
      ),
    );
  }
}

class _SpectroPainter extends CustomPainter {
  final ui.Image image;
  final SpectroData data;
  final DjData? dj;
  final bool showGrid, showPhrases;
  final Color accent;
  _SpectroPainter({
    required this.image,
    required this.data,
    required this.dj,
    required this.showGrid,
    required this.showPhrases,
    required this.accent,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const axis = 18.0;
    final curvesH = dj == null ? 0.0 : math.min(110.0, size.height * 0.28);
    final specH = size.height - axis - curvesH;
    final dur = data.durationSec;
    if (dur <= 0 || specH <= 10) return;
    double xOf(double sec) => sec / dur * size.width;

    // Спектрограмма
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromLTWH(0, 0, size.width, specH),
      Paint()..filterQuality = FilterQuality.medium,
    );

    final d = dj;
    if (d != null) {
      // Доли и такты: только пока они различимы (не чаще чем раз в 5 пикселей)
      final bpm = d.gridBpm, first = d.firstBeatMs;
      if (showGrid && bpm != null && bpm > 0 && first != null) {
        final beat = 60.0 / bpm;
        final anchor = (d.barAnchorMs ?? first) / 1000.0;
        final beatPx = xOf(beat);
        final thin = Paint()
          ..color = const Color(0x33FFFFFF)
          ..strokeWidth = 0.6;
        final bar = Paint()
          ..color = const Color(0x77FFFFFF)
          ..strokeWidth = 0.9;
        var k = ((0 - anchor) / beat).floor();
        for (;; k++) {
          final t = anchor + k * beat;
          if (t > dur) break;
          if (t < 0) continue;
          final isBar = ((k % 4) + 4) % 4 == 0;
          if (!isBar && beatPx < 5) continue;
          if (isBar && beatPx * 4 < 5) continue;
          canvas.drawLine(Offset(xOf(t), 0), Offset(xOf(t), specH), isBar ? bar : thin);
        }
      }
      if (showPhrases) {
        final p = Paint()
          ..color = accent
          ..strokeWidth = 1.4;
        for (final ms in d.phrasesMs) {
          final t = ms / 1000.0;
          if (t < 0 || t > dur) continue;
          canvas.drawLine(Offset(xOf(t), 0), Offset(xOf(t), specH + curvesH), p);
        }
      }
      // Кривые: громкость и вокал по секундам
      final h = curvesH / 2;
      _curve(canvas, size, d.energyCurve.length, (i) => ((d.energyCurve[i] - 100.0 + 60.0) / 60.0).clamp(0.0, 1.0).toDouble(),
          top: specH + 2, height: h - 4, color: const Color(0xFF5BC0EB), dur: dur);
      _curve(canvas, size, d.vocalCurve.length, (i) => (d.vocalCurve[i] / 100.0).clamp(0.0, 1.0).toDouble(),
          top: specH + h + 2, height: h - 4, color: const Color(0xFFF2A65A), dur: dur);
    }

    // Ось времени
    final step = _niceStep(dur, size.width);
    final tp = TextPainter(textDirection: TextDirection.ltr);
    for (var t = 0.0; t <= dur; t += step) {
      final x = xOf(t);
      canvas.drawLine(Offset(x, specH + curvesH), Offset(x, specH + curvesH + 4), Paint()..color = const Color(0x88FFFFFF));
      tp.text = TextSpan(text: _fmtTime(t), style: const TextStyle(color: Color(0xAAFFFFFF), fontSize: 10));
      tp.layout();
      tp.paint(canvas, Offset(math.min(size.width - tp.width, x + 2), specH + curvesH + 3));
    }
  }

  void _curve(Canvas canvas, Size size, int n, double Function(int) v,
      {required double top, required double height, required Color color, required double dur}) {
    if (n < 2) return;
    final path = Path();
    final fill = Path()..moveTo(0, top + height);
    for (var i = 0; i < n; i++) {
      final x = (i + 0.5) / dur * size.width;
      final y = top + height * (1 - v(i));
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
      fill.lineTo(x, y);
    }
    fill.lineTo(math.min(size.width, n / dur * size.width), top + height);
    fill.close();
    canvas.drawRect(Rect.fromLTWH(0, top, size.width, height), Paint()..color = const Color(0x0DFFFFFF));
    canvas.drawPath(fill, Paint()..color = color.withValues(alpha: 0.22));
    canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = color);
  }

  /// Шаг подписей: не чаще чем раз в ~70 пикселей, из «круглых» значений
  double _niceStep(double dur, double width) {
    const steps = [5.0, 10.0, 15.0, 30.0, 60.0, 120.0, 300.0];
    final want = dur / math.max(1.0, width / 70.0);
    for (final s in steps) {
      if (s >= want) return s;
    }
    return 600.0;
  }

  @override
  bool shouldRepaint(_SpectroPainter old) =>
      old.image != image || old.showGrid != showGrid || old.showPhrases != showPhrases || old.dj != dj || old.accent != accent;
}
