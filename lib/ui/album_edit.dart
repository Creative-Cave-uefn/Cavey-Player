import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/gestures.dart' show PointerScrollEvent;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/services.dart';

import '../app.dart';
import '../core/library.dart';
import '../core/models.dart';
import 'cover_picker.dart';
import 'glass_popup.dart';
import 'theme.dart';
import 'widgets.dart';

/// Большая обложка в шапке альбома или плейлиста: клик — посмотреть на весь экран,
/// при наведении в правом нижнем углу кнопка с карандашом — правка
class HeaderCover extends StatefulWidget {
  final Track? track;
  final String? fileId;
  final String? label;
  final double size;
  final VoidCallback? onEdit;
  final String editTooltip;

  /// Четыре обложки для сетки 2×2 (плейлист без своей картинки)
  final List<Track> grid;
  const HeaderCover({
    super.key,
    required this.track,
    required this.size,
    this.fileId,
    this.label,
    this.onEdit,
    this.editTooltip = 'Изменить',
    this.grid = const [],
  });

  @override
  State<HeaderCover> createState() => _HeaderCoverState();
}

class _HeaderCoverState extends State<HeaderCover> {
  bool _hover = false;

  /// Пока обложка «улетела» на весь экран, на месте её нет: в шапке она появится, когда вернётся
  bool _flying = false;

  Future<void> _view() async {
    final box = context.findRenderObject() as RenderBox?;
    final from = box != null && box.hasSize ? box.localToGlobal(Offset.zero) & box.size : null;
    setState(() => _flying = true);
    try {
      await showCoverViewer(context, track: widget.track, fileId: widget.fileId, from: from, fromRadius: 12);
    } finally {
      if (mounted) setState(() => _flying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canView = widget.track != null || widget.fileId != null;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: canView ? SystemMouseCursors.click : MouseCursor.defer,
      child: SizedBox.square(
        dimension: widget.size,
        child: Stack(children: [
          Positioned.fill(
            child: GestureDetector(
              onTap: canView ? _view : null,
              child: Opacity(
                opacity: _flying ? 0 : 1,
                child: widget.grid.length == 4 && widget.fileId == null
                    ? CoverGrid(tracks: widget.grid, size: widget.size, radius: 12)
                    : CoverImage(track: widget.track, fileId: widget.fileId, label: widget.label, size: widget.size, radius: 12),
              ),
            ),
          ),
          if (widget.onEdit != null)
            Positioned(
              right: 8,
              bottom: 8,
              child: AnimatedOpacity(
                opacity: _hover ? 1 : 0,
                duration: const Duration(milliseconds: 140),
                child: IgnorePointer(
                  ignoring: !_hover,
                  child: Tooltip(
                    message: widget.editTooltip,
                    child: Material(
                      color: Colors.black.withValues(alpha: 0.55),
                      shape: const CircleBorder(),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: widget.onEdit,
                        child: const Padding(
                          padding: EdgeInsets.all(8),
                          child: Icon(Icons.edit_rounded, size: 18, color: Colors.white),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}

/// Обложка на весь экран: колесо или ползунок под ней — масштаб, зажатая левая кнопка — двигать.
/// Пока картинка не приближена, она слегка наклоняется в сторону курсора. Закрывается по Esc или клику по пустому месту
Future<void> showCoverViewer(BuildContext context, {Track? track, String? fileId, Rect? from, double fromRadius = 0}) {
  final covers = Services.of(context).covers;
  final Future<Uint8List?> bytes = (fileId != null
          ? covers.forFile(fileId)
          : (track != null ? covers.forTrack(track) : Future<Uint8List?>.value(null)))
      // Если картинка так и не пришла, окно не должно висеть с крутилкой вечно
      .timeout(const Duration(seconds: 25), onTimeout: () => null)
      .catchError((Object _) => null);
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Закрыть',
    barrierColor: Colors.black.withValues(alpha: 0.86),
    // Обложка вылетает из шапки в центр и так же возвращается; фон темнеет вместе с ней
    transitionDuration: const Duration(milliseconds: 340),
    pageBuilder: (ctx, anim, __) =>
        _CoverViewer(bytes: bytes, fallback: _fallbackCover(context, track, fileId), anim: anim, from: from, fromRadius: fromRadius),
    transitionBuilder: (ctx, a, _, child) => child,
  );
}

/// Пока крупная картинка грузится (или не загрузилась), показываем ту, что уже есть на экране
Widget? _fallbackCover(BuildContext context, Track? track, String? fileId) {
  if (track == null && fileId == null) return null;
  return CoverImage(track: track, fileId: fileId, size: 480, radius: 0);
}

class _CoverViewer extends StatefulWidget {
  final Future<Uint8List?> bytes;
  final Widget? fallback;

  /// Ход открытия 0…1 (при закрытии идёт обратно), откуда вылетает обложка (на экране) и её скругление там
  final Animation<double> anim;
  final Rect? from;
  final double fromRadius;
  const _CoverViewer({required this.bytes, this.fallback, required this.anim, this.from, this.fromRadius = 0});

  @override
  State<_CoverViewer> createState() => _CoverViewerState();
}

class _CoverViewerState extends State<_CoverViewer> with SingleTickerProviderStateMixin {
  static const _maxScale = 12.0;

  /// Наибольший наклон, градусы: «лёгкая» панорама, а не переворот картинки
  static const _maxTiltDeg = 7.0;

  double _scale = 1;
  Offset _pan = Offset.zero;

  /// Куда смотрит курсор: от -1 до 1 по каждой оси относительно центра окна — и как далеко наклон дошёл сейчас
  Offset _tiltTarget = Offset.zero;
  Offset _tilt = Offset.zero;
  late final Ticker _ticker = createTicker(_onTick);

  DateTime _lastTap = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _onTick(Duration _) {
    // Приближенная картинка не наклоняется: наклон плавно возвращается в ноль
    final target = _scale > 1.001 ? Offset.zero : _tiltTarget;
    final next = _tilt + (target - _tilt) * 0.16;
    final done = (next - target).distance < 0.002;
    setState(() => _tilt = done ? target : next);
    if (done) _ticker.stop();
  }

  void _aim(Offset t) {
    _tiltTarget = t;
    if (!_ticker.isActive) _ticker.start();
  }

  /// Колесо: масштаб относительно точки под курсором, чтобы она оставалась на месте
  void _zoom(Offset fromCenter, double factor) {
    final s = (_scale * factor).clamp(1.0, _maxScale).toDouble();
    if (s == _scale) return;
    setState(() {
      _pan = s <= 1.0001 ? Offset.zero : fromCenter - (fromCenter - _pan) * (s / _scale);
      _scale = s;
    });
    if (!_ticker.isActive) _ticker.start();
  }

  void _reset() {
    setState(() {
      _scale = 1;
      _pan = Offset.zero;
    });
    if (!_ticker.isActive) _ticker.start();
  }

  Curve get _curve => Curves.easeInOutCubic;

  /// Вылет из шапки в центр и обратно: обложка плавно растёт от размера и места в шапке до полного.
  /// Без известного места (нет исходного прямоугольника) — просто плавное появление
  Widget _fly(Offset center, double side, Widget child) {
    final from = widget.from;
    return AnimatedBuilder(
      animation: widget.anim,
      child: child,
      builder: (context, c) {
        final t = _curve.transform(widget.anim.value.clamp(0.0, 1.0));
        if (from == null || from.width <= 0) {
          return Opacity(opacity: t, child: Transform.scale(scale: 0.94 + 0.06 * t, child: c));
        }
        final k = from.width / side;
        return Transform.translate(
          offset: (from.center - center) * (1 - t),
          child: Transform.scale(scale: k + (1 - k) * t, child: c),
        );
      },
    );
  }

  /// Скругление у обложки в шапке плавно уходит, пока она растёт на весь экран
  Widget _clipped(double side, Widget picture) {
    final from = widget.from;
    final box = SizedBox.square(dimension: side, child: picture);
    if (from == null || from.width <= 0 || widget.fromRadius <= 0) return box;
    final k = from.width / side;
    return AnimatedBuilder(
      animation: widget.anim,
      child: box,
      builder: (context, c) {
        final t = _curve.transform(widget.anim.value.clamp(0.0, 1.0));
        return ClipRRect(borderRadius: BorderRadius.circular(widget.fromRadius / k * (1 - t)), child: c);
      },
    );
  }

  Widget _controls() {
    // Ползунок логарифмический: каждый шаг даёт одинаковое «во сколько раз» ближе
    final t = math.log(_scale) / math.log(_maxScale);
    return FadeTransition(
      opacity: CurvedAnimation(parent: widget.anim, curve: const Interval(0.5, 1)),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
      Row(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.search_rounded, size: 20, color: Colors.white70),
        SizedBox(
          width: 260,
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(trackHeight: 3, overlayShape: const RoundSliderOverlayShape(overlayRadius: 14)),
            child: Slider(
              value: t.clamp(0.0, 1.0).toDouble(),
              onChanged: (v) => _zoom(Offset.zero, math.pow(_maxScale, v).toDouble() / _scale),
            ),
          ),
        ),
      ]),
      const Text('Щелкните по пустому месту на экране для выхода', style: TextStyle(color: Colors.white38, fontSize: 12.5)),
    ]));
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.of(context).maybePop()},
      child: Focus(
        autofocus: true,
        child: Material(
          type: MaterialType.transparency,
          child: Stack(children: [
            Positioned.fill(
              child: FutureBuilder<Uint8List?>(
                future: widget.bytes,
                builder: (context, snap) {
                  final b = snap.data;
                  return LayoutBuilder(builder: (context, box) {
                    final side = (box.biggest.shortestSide - 190).clamp(120.0, 4000.0).toDouble();
                    final center = box.biggest.center(Offset.zero);
                    final Widget picture;
                    if (b != null) {
                      picture = Image.memory(b, fit: BoxFit.contain, filterQuality: FilterQuality.high, gaplessPlayback: true);
                    } else if (snap.connectionState != ConnectionState.done && widget.fallback != null) {
                      // Пока грузится крупная — видна обычная, без колеса загрузки: оригинал подменит её сам, как придёт
                      picture = widget.fallback!;
                    } else if (snap.connectionState != ConnectionState.done) {
                      picture = const Center(child: SizedBox.square(dimension: 28, child: CircularProgressIndicator(strokeWidth: 2.5)));
                    } else {
                      picture = widget.fallback ??
                          const Center(child: Text('Картинку не получилось загрузить', style: TextStyle(color: Colors.white70)));
                    }
                    final ax = _tilt.dx * _maxTiltDeg * math.pi / 180;
                    final ay = _tilt.dy * _maxTiltDeg * math.pi / 180;
                    return Listener(
                      onPointerSignal: (e) {
                        if (e is PointerScrollEvent && e.scrollDelta.dy != 0) {
                          _zoom(e.localPosition - center, e.scrollDelta.dy < 0 ? 1.18 : 1 / 1.18);
                        }
                      },
                      child: MouseRegion(
                        cursor: _scale > 1 ? SystemMouseCursors.grab : SystemMouseCursors.basic,
                        onHover: (e) {
                          final half = box.biggest / 2;
                          final d = e.localPosition - center;
                          _aim(Offset((d.dx / half.width).clamp(-1.0, 1.0).toDouble(), (d.dy / half.height).clamp(-1.0, 1.0).toDouble()));
                        },
                        onExit: (_) => _aim(Offset.zero),
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          // Клик мимо картинки закрывает просмотр сразу: без onDoubleTap, который заставлял ждать
                          // его срок (около трети секунды) перед тем, как одиночный клик сработает
                          onTapUp: (d) {
                            final r = Rect.fromCenter(center: center + _pan, width: side * _scale, height: side * _scale);
                            if (!r.contains(d.localPosition)) {
                              Navigator.of(context).maybePop();
                              return;
                            }
                            final now = DateTime.now();
                            if (now.difference(_lastTap) < const Duration(milliseconds: 320)) {
                              _lastTap = DateTime.fromMillisecondsSinceEpoch(0);
                              _reset();
                            } else {
                              _lastTap = now;
                            }
                          },
                          onPanUpdate: (d) {
                            if (_scale > 1) setState(() => _pan += d.delta);
                          },
                          child: SizedBox.expand(
                            child: Center(
                              child: _fly(
                                center,
                                side,
                                Transform(
                                alignment: Alignment.center,
                                transform: Matrix4.identity()
                                  ..setEntry(3, 2, 0.0011)
                                  // Обложка прогибается под курсором: край, к которому он подведён, уходит вглубь
                                  ..rotateX(ay)
                                  ..rotateY(-ax)
                                  ..translate(_pan.dx, _pan.dy)
                                  ..scale(_scale),
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black.withValues(alpha: 0.35),
                                        blurRadius: 40,
                                        offset: Offset(_tilt.dx * 14, 14 + _tilt.dy * 10),
                                      ),
                                    ],
                                  ),
                                  child: _clipped(side, picture),
                                ),
                              ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  });
                },
              ),
            ),
            Positioned(left: 0, right: 0, bottom: 16, child: Center(child: _controls())),
          ]),
        ),
      ),
    );
  }
}

/// Окно «Альбом»: название, обложка, год, исполнитель альбома. Применяется ко всем трекам альбома
Future<void> editAlbumDialog(BuildContext context, Album a) async {
  final lib = Services.of(context).lib;
  String common(String Function(Track) f) {
    final first = f(a.tracks.first);
    return a.tracks.every((t) => f(t) == first) ? first : '';
  }

  final initTitle = a.title;
  final initYear = a.year;
  final initArtist = common((t) => t.albumArtist).isNotEmpty
      ? common((t) => t.albumArtist)
      : (a.artist == 'Разные исполнители' ? '' : a.artist);
  final title = TextEditingController(text: initTitle);
  final year = TextEditingController(text: initYear);
  final artist = TextEditingController(text: initArtist);
  final choice = CoverChoice();
  final ok = await showGlassDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Альбом', style: display(18)),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            CoverEditorView(
              choice: choice,
              current: CoverImage(track: a.coverTrack, size: 120, radius: 0),
              canReset: lib.albumCover(a.key) != null,
            ),
            const SizedBox(height: 18),
            const Text('Название', style: TextStyle(color: C.muted, fontSize: 13)),
            const SizedBox(height: 6),
            TextField(controller: title, autofocus: true),
            const SizedBox(height: 14),
            const Text('Исполнитель альбома', style: TextStyle(color: C.muted, fontSize: 13)),
            const SizedBox(height: 6),
            TextField(controller: artist, decoration: const InputDecoration(hintText: 'Например, ATLUS Sound Team')),
            const SizedBox(height: 14),
            const Text('Год', style: TextStyle(color: C.muted, fontSize: 13)),
            const SizedBox(height: 6),
            SizedBox(
              width: 120,
              child: TextField(
                controller: year,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(4)],
              ),
            ),
            const SizedBox(height: 14),
            Text(
              'Изменится у всех ${countTracks(a.tracks.length)} альбома, и это увидят все друзья. '
              'Исполнители отдельных треков не меняются. Сами файлы на Диске остаются как были.',
              style: const TextStyle(color: C.faint, fontSize: 12, height: 1.4),
            ),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена', style: TextStyle(color: C.muted))),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Сохранить')),
      ],
    ),
  );
  if (ok != true) return;
  final t = title.text.trim();
  if (t.isEmpty) {
    lib.messages.add('Название альбома не может быть пустым');
    return;
  }
  final cover = context.mounted ? await choice.commit(context) : null;
  final y = year.text.trim();
  final ar = artist.text.trim();
  lib.editAlbum(
    a,
    title: t != initTitle ? t : null,
    year: y != initYear ? y : null,
    albumArtist: ar != initArtist ? ar : null,
    cover: cover,
  );
  lib.messages.add('Альбом «$t» обновлён');
}

/// Окно «Плейлист»: название и обложка
Future<void> editPlaylistDialog(BuildContext context, Playlist p, {Track? coverTrack}) async {
  final lib = Services.of(context).lib;
  final own = lib.playlistCover(p.id);
  final name = TextEditingController(text: p.name);
  final choice = CoverChoice();
  final ok = await showGlassDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Плейлист', style: display(18)),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            CoverEditorView(
              choice: choice,
              current: CoverImage(track: coverTrack, fileId: own, label: p.name, size: 120, radius: 0),
              canReset: own != null,
              note: 'Обложку и название увидят все, кому виден плейлист.',
            ),
            const SizedBox(height: 18),
            const Text('Название', style: TextStyle(color: C.muted, fontSize: 13)),
            const SizedBox(height: 6),
            TextField(controller: name, autofocus: true),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена', style: TextStyle(color: C.muted))),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Сохранить')),
      ],
    ),
  );
  if (ok != true) return;
  final n = name.text.trim();
  if (n.isNotEmpty && n != p.name) lib.renamePlaylist(p.id, n);
  final cover = context.mounted ? await choice.commit(context) : null;
  if (cover != null) lib.setPlaylistCover(p.id, cover);
}
