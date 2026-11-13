import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../app.dart';
import '../core/app_icon.dart' show recolorLogoPng;
import '../core/covers.dart';
import '../core/models.dart';
import 'shell.dart';
import 'theme.dart';
import 'glass_popup.dart';
import 'tags_ui.dart' show TagSuggest;

String plural(int n, String one, String few, String many) {
  final m10 = n % 10, m100 = n % 100;
  if (m10 == 1 && m100 != 11) return one;
  if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return few;
  return many;
}

/// Размер в байтах человеческим языком: 1,4 ГБ
String formatBytes(int b) {
  const units = ['Б', 'КБ', 'МБ', 'ГБ', 'ТБ'];
  var v = b.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  final text = i == 0 || v >= 100 ? v.round().toString() : v.toStringAsFixed(1).replaceAll('.', ',');
  return '$text ${units[i]}';
}

String countTracks(int n) => '$n ${plural(n, 'трек', 'трека', 'треков')}';

String formatDuration(Duration d) {
  final s = d.inSeconds;
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
  final ss = sec.toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$ss' : '$m:$ss';
}

/// Значок приложения (тот же, что у окна и установщика). Метка на нём — в цвете акцента
class BrandMark extends StatefulWidget {
  final double size;
  const BrandMark({super.key, this.size = 28});

  @override
  State<BrandMark> createState() => _BrandMarkState();
}

class _BrandMarkState extends State<BrandMark> {
  // Перекрашенные картинки по цвету: считаются один раз и живут до выхода
  static final Map<int, Uint8List> _cache = {};
  static final Set<int> _loading = {};

  void _load(int argb) {
    if (_cache.containsKey(argb) || !_loading.add(argb)) return;
    () async {
      try {
        final png = (await rootBundle.load('assets/logo.png')).buffer.asUint8List();
        final out = await compute(recolorLogoPng, (png, argb));
        _cache[argb] = out;
      } catch (_) {
        // останется обычный значок
      } finally {
        _loading.remove(argb);
        if (mounted) setState(() {});
      }
    }();
  }

  @override
  Widget build(BuildContext context) {
    final argb = C.accent.value;
    final plain = Image.asset('assets/logo.png',
        width: widget.size, height: widget.size, filterQuality: FilterQuality.medium, semanticLabel: 'Cavey');
    if (argb == C.defaultAccent.value) return plain;
    final bytes = _cache[argb];
    if (bytes == null) {
      _load(argb);
      return plain;
    }
    return Image.memory(bytes,
        width: widget.size, height: widget.size, filterQuality: FilterQuality.medium, gaplessPlayback: true, semanticLabel: 'Cavey');
  }
}

/// Значок и название Cavey
class Wordmark extends StatelessWidget {
  final double size;
  const Wordmark({super.key, this.size = 22});

  @override
  Widget build(BuildContext context) {
    // UnconstrainedBox: название всегда рисуется целиком и не режется по ширине родителя
    return UnconstrainedBox(
      alignment: Alignment.centerLeft,
      clipBehavior: Clip.none,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          BrandMark(size: size * 1.5),
          SizedBox(width: size * 0.45),
          Text('Cavey', maxLines: 1, softWrap: false, overflow: TextOverflow.visible, style: brand(size)),
        ],
      ),
    );
  }
}

/// Четыре трека с разными обложками для сетки 2×2 на обложке плейлиста без своей картинки.
/// Берутся первые по порядку треки с разными обложками (своя обложка трека или обложка альбома);
/// если разных обложек меньше четырёх — пусто, и остаётся одна обложка, как раньше
List<Track> gridCoverTracks(Iterable<Track> tracks) {
  final seen = <String>{};
  final out = <Track>[];
  for (final t in tracks) {
    if (!t.hasCover) continue;
    if (!seen.add(t.customCover ?? t.albumKey)) continue;
    out.add(t);
    if (out.length == 4) return out;
  }
  return const [];
}

/// Обложка из четырёх обложек треков, 2×2
class CoverGrid extends StatelessWidget {
  final List<Track> tracks;
  final double size;
  final double radius;
  const CoverGrid({super.key, required this.tracks, required this.size, this.radius = 8});

  @override
  Widget build(BuildContext context) {
    final half = size / 2;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox.square(
        dimension: size,
        child: Column(children: [
          for (var r = 0; r < 2; r++)
            Row(children: [
              for (var c = 0; c < 2; c++) CoverImage(track: tracks[r * 2 + c], size: half, radius: 0),
            ]),
        ]),
      ),
    );
  }
}

/// Обложка трека или альбома. Пока грузится — цветная плашка с буквой альбома.
class CoverImage extends StatefulWidget {
  final Track? track;
  final double size;

  /// Высота, если картинка не квадратная (баннер)
  final double? height;
  final double radius;

  /// Картинка из папки covers на Диске (обложка плейлиста или выбранная вручную) — важнее обложки трека
  final String? fileId;

  /// Подпись на плашке, пока нет картинки (по умолчанию — альбом трека)
  final String? label;

  /// Не просить копию крупнее этого размера в пикселях (для размытых баннеров хватает 640)
  final int? maxPx;

  /// Закрашивать всю площадь: под обложкой кладётся её же размытая копия, чтобы прозрачные поля
  /// и неквадратные картинки не оставляли пустых полос (плеер)
  final bool fill;

  /// Обложка на весь экран (кинотеатр): грузится вне очереди за списками, оригинал запоминается,
  /// при уменьшении используется качественная фильтрация
  final bool fullscreen;
  const CoverImage(
      {super.key, required this.track, required this.size, this.height, this.radius = 6, this.fileId, this.label, this.maxPx, this.fill = false, this.fullscreen = false});

  @override
  State<CoverImage> createState() => _CoverImageState();
}

class _CoverImageState extends State<CoverImage> {
  Uint8List? _bytes;
  String? _key;
  int _px = 0;
  int _gen = 0;
  bool _wants = false;
  CoverService? _svc;
  String? _brokenKey;

  /// Картинку не удалось разобрать: показываем плашку, сбрасываем её кэш и грузим заново
  /// (один раз на картинку, см. CoverService.discard)
  Widget _onBroken(Widget placeholder) {
    final key = _key;
    if (key != null && _brokenKey != key) {
      _brokenKey = key;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || key != _key) return;
        _svc?.discard(key);
        setState(() => _bytes = null);
        if (_wants) _request();
      });
    }
    return placeholder;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final svc = Services.of(context).covers;
    if (!identical(svc, _svc)) {
      _svc?.removeListener(_onReady);
      _svc = svc..addListener(_onReady);
      _key = null;
    }
    _ensure();
  }

  @override
  void didUpdateWidget(CoverImage old) {
    super.didUpdateWidget(old);
    _ensure();
  }

  @override
  void dispose() {
    _svc?.removeListener(_onReady);
    super.dispose();
  }

  int get _wantPx {
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
    final px = (math.max(widget.size, widget.height ?? 0) * dpr).round();
    final cap = widget.maxPx;
    return cap != null && px > cap ? cap : px;
  }

  /// Ширина, в которую декодируется картинка. Округляется вверх до 32 пикселей: пока плитка чуть меняет размер
  /// (разворачивается боковая панель), картинка не декодируется заново на каждом кадре и не мерцает
  int _cacheWidth(double dpr) => ((widget.size * dpr / 32).ceil() * 32).clamp(32, 4096).toInt();

  /// Ключ поменялся (другой трек, другой человек) — старую картинку не показываем ни на кадр
  void _ensure() {
    final svc = _svc;
    if (svc == null) return;
    final t = widget.track;
    final id = widget.fileId;
    final key = id != null ? 'cv_$id' : (t == null ? null : svc.keyOf(t));
    final px = _wantPx;
    final bucket = CoverService.bucketFor(px);
    final wantsNow = id != null || (t != null && svc.wants(t));
    if (key == _key && bucket == _px) {
      // Тот же трек, но у него появилась обложка (досканировали, нашли cover.jpg) — сразу просим её,
      // а не ждём, пока виджет пересоздадут сменой вкладки
      final became = wantsNow && !_wants;
      _wants = wantsNow;
      if (became && _bytes == null) _request();
      return;
    }
    final sameKey = key == _key;
    _key = key;
    _px = bucket;
    _wants = wantsNow;
    final peek = id != null ? svc.peekFile(id, px: px) : (t == null ? null : svc.peek(t, px: px));
    if (!sameKey || peek != null) _bytes = peek;
    if (peek == null && _wants) _request();
  }

  void _request() {
    final svc = _svc;
    if (svc == null) return;
    final t = widget.track;
    final id = widget.fileId;
    final key = _key;
    final gen = ++_gen;
    final px = _wantPx;
    final fs = widget.fullscreen;
    final f = id != null
        ? svc.forFile(id, px: px, fullscreen: fs)
        : (t == null ? Future<Uint8List?>.value(null) : svc.forTrack(t, px: px, fullscreen: fs));
    f.then((b) {
      if (!mounted || gen != _gen || key != _key || b == null || identical(b, _bytes)) return;
      setState(() => _bytes = b);
    });
  }

  /// Сервис что-то догрузил или пришло время повторить: если у нас картинки ещё нет, пробуем снова
  void _onReady() {
    if (!mounted || _bytes != null || _key == null) return;
    final t = widget.track;
    final id = widget.fileId;
    final svc = _svc!;
    _wants = id != null || (t != null && svc.wants(t));
    if (!_wants) return;
    final px = _wantPx;
    final peek = id != null ? svc.peekFile(id, px: px) : (t == null ? null : svc.peek(t, px: px));
    if (peek != null) {
      setState(() => _bytes = peek);
    } else {
      _request();
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.track;
    final placeholder = _Placeholder(label: widget.label ?? t?.displayAlbum ?? '', size: widget.size);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final bytes = _bytes;
    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.radius),
      child: SizedBox(
        width: widget.size,
        height: widget.height ?? widget.size,
        child: bytes == null
            ? placeholder
            : widget.fill
                ? Stack(fit: StackFit.expand, children: [
                    ImageFiltered(
                      imageFilter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14, tileMode: ui.TileMode.clamp),
                      child: Transform.scale(
                        scale: 1.3,
                        child: Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true, cacheWidth: 64, errorBuilder: (_, __, ___) => const SizedBox.shrink()),
                      ),
                    ),
                    Image.memory(
                      bytes,
                      fit: BoxFit.cover,
                      alignment: Alignment.center,
                      filterQuality: FilterQuality.medium,
                      gaplessPlayback: true,
                      cacheWidth: _cacheWidth(dpr),
                      errorBuilder: (_, __, ___) => _onBroken(placeholder),
                    ),
                  ])
                : Image.memory(
                    bytes,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    // На весь экран картинку уменьшают, и качественная фильтрация держит резкость
                    filterQuality: widget.fullscreen ? FilterQuality.high : FilterQuality.low,
                    cacheWidth: _cacheWidth(dpr),
                    errorBuilder: (_, __, ___) => _onBroken(placeholder),
                  ),
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  final String label;
  final double size;
  const _Placeholder({required this.label, required this.size});

  @override
  Widget build(BuildContext context) {
    final color = friendColor(label);
    final letter = label.trim().isEmpty ? '♪' : label.trim().characters.first.toUpperCase();
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [color.withValues(alpha: 0.35), C.raised],
        ),
      ),
      alignment: Alignment.center,
      child: Text(letter, style: display(size * 0.38, weight: FontWeight.w700, color: color.withValues(alpha: 0.9))),
    );
  }
}

class FriendDot extends StatelessWidget {
  final String email;
  final double size;
  const FriendDot(this.email, {super.key, this.size = 8});

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(color: friendColor(email), shape: BoxShape.circle),
      );
}

/// «Кто принёс»: цветная точка и имя друга
class FriendTag extends StatelessWidget {
  final String email;
  const FriendTag(this.email, {super.key});

  @override
  Widget build(BuildContext context) {
    if (email.isEmpty) return const SizedBox.shrink();
    final lib = Services.of(context).lib;
    return Tooltip(
      message: 'Загрузил(а) ${lib.nameOf(email)}',
      // Клик открывает страницу этого человека
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => NavScope.of(context).go(Nav('user', email)),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Avatar(email: email, name: lib.nameOf(email), size: 20),
              const SizedBox(width: 8),
              Flexible(
                child: Text(lib.firstNameOf(email),
                    overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.muted, fontSize: 13)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Аватарка человека: своя картинка из профиля, а если её нет — цветной кружок с буквой
class Avatar extends StatelessWidget {
  final String email;
  final String name;
  final double size;
  const Avatar({super.key, required this.email, required this.name, this.size = 36});

  @override
  Widget build(BuildContext context) {
    final lib = Services.of(context).lib;
    final custom = lib.profileAvatar(email);
    final shown = lib.profileNick(email) ?? name;
    final letter = (shown.trim().isEmpty ? email : shown).trim().characters.first.toUpperCase();
    if (custom != null) {
      return ClipOval(child: CoverImage(track: null, fileId: custom, label: letter, size: size, radius: 0));
    }
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: friendColor(email), shape: BoxShape.circle),
      child: Text(letter, style: display(size * 0.42, weight: FontWeight.w700, color: C.accentInk)),
    );
  }
}

/// Имя человека, которое открывает его страницу; при наведении подчёркивается
class UserLink extends StatefulWidget {
  final String email;
  final TextStyle style;
  const UserLink(this.email, {super.key, this.style = const TextStyle(color: C.muted, fontSize: 15)});

  @override
  State<UserLink> createState() => _UserLinkState();
}

class _UserLinkState extends State<UserLink> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final lib = Services.of(context).lib;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: () => NavScope.of(context).go(Nav('user', widget.email)),
        child: Text(
          lib.firstNameOf(widget.email),
          style: widget.style.copyWith(
            color: _hover ? C.text : widget.style.color,
            decoration: _hover ? TextDecoration.underline : TextDecoration.none,
            decorationColor: C.text,
          ),
        ),
      ),
    );
  }
}

/// Большая жёлтая круглая кнопка воспроизведения
class PlayCircle extends StatelessWidget {
  final bool playing;
  final VoidCallback? onPressed;
  final double size;
  final String tooltip;
  const PlayCircle({super.key, required this.playing, required this.onPressed, this.size = 44, this.tooltip = ''});

  @override
  Widget build(BuildContext context) {
    final btn = Material(
      color: C.accent,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: SizedBox.square(
          dimension: size,
          child: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded, color: C.accentInk, size: size * 0.6),
        ),
      ),
    );
    return tooltip.isEmpty ? btn : Tooltip(message: tooltip, child: btn);
  }
}

class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String text;
  final Widget? action;
  const EmptyState({super.key, required this.icon, required this.title, required this.text, this.action});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 40, color: C.faint),
              const SizedBox(height: 16),
              Text(title, textAlign: TextAlign.center, style: display(18)),
              const SizedBox(height: 8),
              Text(text, textAlign: TextAlign.center, style: const TextStyle(color: C.muted, height: 1.45)),
              if (action != null) ...[const SizedBox(height: 20), action!],
            ],
          ),
        ),
      ),
    );
  }
}

Future<String?> askText(BuildContext context,
    {required String title, required String action, String initial = '', String hint = ''}) {
  final ctrl = TextEditingController(text: initial);
  return showGlassDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title, style: display(18)),
      content: SizedBox(
        width: 360,
        child: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: InputDecoration(hintText: hint),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена', style: TextStyle(color: C.muted))),
        FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: Text(action)),
      ],
    ),
  );
}

Future<bool> confirm(BuildContext context, {required String title, required String text, required String action}) async {
  final r = await showGlassDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title, style: display(18)),
      content: SizedBox(width: 380, child: Text(text, style: const TextStyle(color: C.muted, height: 1.45))),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена', style: TextStyle(color: C.muted))),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: C.danger),
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(action),
        ),
      ],
    ),
  );
  return r ?? false;
}


/// Плитка-ссылка (альбом, плейлист, исполнитель): подсветка при наведении с отступом вокруг обложки и текста,
/// справа внизу обложки по наведению появляется кнопка «Играть». Обложка — квадрат на всю ширину плитки сверху
class TileInk extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;
  final GestureTapUpCallback? onSecondaryTapUp;

  /// Если задано — по наведению появляется кнопка воспроизведения
  final VoidCallback? onPlay;
  final double radius;

  /// «В любимое»: сердечко в углу обложки появляется по наведению; у отмеченного остаётся всегда.
  /// [favorite] — отмечено ли сейчас, [onFavorite] — переключить. [favoriteOnCircle] — фото круглое: сердечко ближе к центру
  final bool favorite;
  final VoidCallback? onFavorite;
  final bool favoriteOnCircle;
  const TileInk({
    super.key,
    required this.child,
    required this.onTap,
    this.onSecondaryTapUp,
    this.onPlay,
    this.radius = 12,
    this.favorite = false,
    this.onFavorite,
    this.favoriteOnCircle = false,
  });

  /// Отступ подсветки от обложки и текста
  static const pad = 8.0;

  @override
  State<TileInk> createState() => _TileInkState();
}

class _TileInkState extends State<TileInk> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final side = box.maxWidth.isFinite ? box.maxWidth - TileInk.pad * 2 : 0.0;
      const button = 40.0;
      final show = _hover && widget.onPlay != null;
      return MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: Stack(fit: StackFit.passthrough, children: [
          InkWell(
            borderRadius: BorderRadius.circular(widget.radius),
            onTap: widget.onTap,
            onSecondaryTapUp: widget.onSecondaryTapUp,
            child: Padding(padding: const EdgeInsets.all(TileInk.pad), child: widget.child),
          ),
          if (widget.onFavorite != null && side > 80)
            Positioned(
              // у круглого фото угол квадрата пустой: сердечко ставим на дугу круга
              right: TileInk.pad + (widget.favoriteOnCircle ? side * 0.1 : 8),
              top: TileInk.pad + (widget.favoriteOnCircle ? side * 0.1 : 8),
              child: IgnorePointer(
                ignoring: !(_hover || widget.favorite),
                child: AnimatedOpacity(
                  opacity: (_hover || widget.favorite) ? 1 : 0,
                  duration: const Duration(milliseconds: 140),
                  child: Tooltip(
                    message: widget.favorite ? 'Убрать из любимого' : 'В любимое',
                    child: GestureDetector(
                      onTap: widget.onFavorite,
                      child: Container(
                        width: 34,
                        height: 34,
                        decoration: const BoxDecoration(color: Color(0x88000000), shape: BoxShape.circle),
                        child: Icon(
                          widget.favorite ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                          size: 20,
                          color: widget.favorite ? C.accent : Colors.white,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          if (widget.onPlay != null && side > button * 2)
            Positioned(
              right: TileInk.pad + 8,
              top: TileInk.pad + side - 8 - button,
              child: IgnorePointer(
                ignoring: !show,
                child: AnimatedOpacity(
                  opacity: show ? 1 : 0,
                  duration: const Duration(milliseconds: 140),
                  child: AnimatedSlide(
                    offset: show ? Offset.zero : const Offset(0, 0.18),
                    duration: const Duration(milliseconds: 160),
                    curve: Curves.easeOutCubic,
                    child: Tooltip(
                      message: 'Играть',
                      child: GestureDetector(
                        onTap: widget.onPlay,
                        child: Container(
                          width: button,
                          height: button,
                          decoration: BoxDecoration(
                            color: C.accent,
                            shape: BoxShape.circle,
                            boxShadow: const [BoxShadow(color: Color(0x55000000), blurRadius: 10, offset: Offset(0, 3))],
                          ),
                          child: Icon(Icons.play_arrow_rounded, color: C.accentInk, size: 26),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ]),
      );
    });
  }
}


/// Выбор уровня ровной громкости: три кнопки одной ширины и одинаковых отступов, чтобы разметка не прыгала при переключении.
/// [appear]: при появлении кнопки по очереди плавно выезжают и проявляются
class NormLevelPicker extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;
  final bool appear;
  const NormLevelPicker({super.key, required this.value, required this.onChanged, this.appear = false});

  static const _levels = [('quiet', 'Тише'), ('normal', 'Обычно'), ('loud', 'Громче')];

  @override
  Widget build(BuildContext context) {
    Widget button(int i, String id, String label) {
      final on = id == value;
      final core = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onChanged(id),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            width: 88,
            height: 36,
            alignment: Alignment.center,
            color: on ? C.accent : Colors.transparent,
            child: AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 180),
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: on ? C.accentInk : C.text),
              child: Text(label),
            ),
          ),
        ),
      );
      if (!appear) return core;
      return TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: Duration(milliseconds: 240 + i * 90),
        curve: Curves.easeOutCubic,
        builder: (context, t, child) => Opacity(
          opacity: t,
          child: Transform.translate(offset: Offset(0, (1 - t) * 8), child: child),
        ),
        child: core,
      );
    }

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(border: Border.all(color: C.line), borderRadius: BorderRadius.circular(999)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        for (var i = 0; i < _levels.length; i++) button(i, _levels[i].$1, _levels[i].$2),
      ]),
    );
  }
}

/// Высота поля поиска и кнопок в одной строке: у всех одинаковая, поэтому центры совпадают
const double kRowControlHeight = 44;

/// Оборачивает ряд из поля поиска и кнопок: кнопки получают высоту [kRowControlHeight] без лишних отступов под палец
Widget uniformControls(BuildContext context, Widget child) {
  final theme = Theme.of(context);
  final extra = ButtonStyle(
    fixedSize: const WidgetStatePropertyAll(Size.fromHeight(kRowControlHeight)),
    minimumSize: const WidgetStatePropertyAll(Size(0, kRowControlHeight)),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  );
  return Theme(
    data: theme.copyWith(
      filledButtonTheme: FilledButtonThemeData(style: theme.filledButtonTheme.style?.merge(extra) ?? extra),
      outlinedButtonTheme: OutlinedButtonThemeData(style: theme.outlinedButtonTheme.style?.merge(extra) ?? extra),
    ),
    child: child,
  );
}

/// Поле поиска той же высоты, что и кнопки рядом
class RowSearchField extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode? focusNode;
  final String hint;
  final double width;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;

  /// «#» в поле включает поиск по тегам: под полем появляется список моих тегов
  final bool tagSuggest;
  const RowSearchField({
    super.key,
    required this.controller,
    this.focusNode,
    required this.hint,
    required this.onChanged,
    required this.onClear,
    this.width = 340,
    this.tagSuggest = false,
  });

  @override
  State<RowSearchField> createState() => _RowSearchFieldState();
}

class _RowSearchFieldState extends State<RowSearchField> {
  FocusNode? _own;
  FocusNode get _focus => widget.focusNode ?? (_own ??= FocusNode());

  @override
  void dispose() {
    _own?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final field = TextField(
      controller: widget.controller,
      focusNode: _focus,
      onChanged: widget.onChanged,
      maxLines: 1,
      textAlignVertical: TextAlignVertical.center,
      decoration: InputDecoration(
        constraints: const BoxConstraints.tightFor(height: kRowControlHeight),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
        hintText: widget.hint,
        hintMaxLines: 1,
        prefixIcon: const Icon(Icons.search_rounded, size: 18),
        suffixIcon: widget.controller.text.isEmpty
            ? null
            : IconButton(icon: const Icon(Icons.close_rounded, size: 16), onPressed: widget.onClear),
      ),
    );
    return SizedBox(
      width: widget.width,
      height: kRowControlHeight,
      child: widget.tagSuggest
          ? TagSuggest(controller: widget.controller, focusNode: _focus, onChanged: widget.onChanged, child: field)
          : field,
    );
  }
}
