import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../app.dart';
import 'theme.dart';

/// Откуда фон берёт картинку. Профиль (исполнитель, человек) важнее трека:
/// пока он открыт, фон красит его фото; в остальных местах — обложка текущего трека
class AmbientSource {
  final String key;

  /// Картинка-источник: байты (обложка, баннер на Диске) или адрес в интернете (фото исполнителя)
  final Future<Uint8List?> Function()? bytes;
  final Future<String?> Function()? url;

  /// Картинки нет — мягкое свечение этим цветом (например, цвет друга)
  final Color? color;

  /// Если [bytes]/[url] ничего не дали — запасной источник
  final AmbientSource? fallback;

  const AmbientSource(this.key, {this.bytes, this.url, this.color, this.fallback});
}

/// Источник фона, который сейчас задаёт открытая страница (профиль). null — фон от трека
class AmbientScope {
  static final ValueNotifier<AmbientSource?> override = ValueNotifier(null);
  static Object? _owner;

  static void claim(Object owner, AmbientSource? source) {
    _owner = owner;
    if (override.value?.key != source?.key) override.value = source;
  }

  static void release(Object owner) {
    if (!identical(_owner, owner)) return; // фон уже забрала следующая страница
    _owner = null;
    override.value = null;
  }

  /// Цветное свечение, которое просит страница (шапка «Любимого», профиль без баннера).
  /// Рисуется на всём окне, а не внутри страницы — поэтому без обрезанных краёв
  static final ValueNotifier<Color?> glow = ValueNotifier(null);
  static Object? _glowOwner;

  static void claimGlow(Object owner, Color? color) {
    _glowOwner = owner;
    glow.value = color;
  }

  static void releaseGlow(Object owner) {
    if (!identical(_glowOwner, owner)) return;
    _glowOwner = null;
    glow.value = null;
  }
}

/// Ставится на страницу: пока она открыта, по всему окну мягко светится [color]. Сам ничего не рисует
class AmbientGlow extends StatefulWidget {
  final Color? color;
  const AmbientGlow({super.key, required this.color});

  @override
  State<AmbientGlow> createState() => _AmbientGlowState();
}

class _AmbientGlowState extends State<AmbientGlow> {
  void _claim() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) AmbientScope.claimGlow(this, widget.color);
      });

  @override
  void initState() {
    super.initState();
    _claim();
  }

  @override
  void didUpdateWidget(covariant AmbientGlow old) {
    super.didUpdateWidget(old);
    if (old.color != widget.color) _claim();
  }

  @override
  void dispose() {
    final me = this;
    WidgetsBinding.instance.addPostFrameCallback((_) => AmbientScope.releaseGlow(me));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// Оборачивает страницу профиля: пока она на экране, фон окна красит её [source]
class AmbientOverride extends StatefulWidget {
  final AmbientSource? source;
  final Widget child;
  const AmbientOverride({super.key, required this.source, required this.child});

  @override
  State<AmbientOverride> createState() => _AmbientOverrideState();
}

class _AmbientOverrideState extends State<AmbientOverride> {
  // Менять фон прямо во время построения нельзя — делаем это сразу после кадра
  void _claim() => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) AmbientScope.claim(this, widget.source);
      });

  @override
  void initState() {
    super.initState();
    _claim();
  }

  @override
  void didUpdateWidget(covariant AmbientOverride old) {
    super.didUpdateWidget(old);
    if (old.source?.key != widget.source?.key) _claim();
  }

  @override
  void dispose() {
    final me = this;
    WidgetsBinding.instance.addPostFrameCallback((_) => AmbientScope.release(me));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Фон всего окна: размытая картинка (обложка трека или фото профиля), плавно сменяется.
/// Картинка размывается один раз в маленькую (160×160) и дальше просто растягивается:
/// на каждом кадре ничего не размываем, поэтому прокрутка и анимации не тормозят.
class AmbientBackground extends StatefulWidget {
  const AmbientBackground({super.key});

  @override
  State<AmbientBackground> createState() => _AmbientBackgroundState();
}

class _AmbientBackgroundState extends State<AmbientBackground> {
  static final Map<String, ui.Image> _cache = {};
  static final List<String> _order = [];

  String? _key;
  ui.Image? _image;
  Color? _color;
  final Map<String, DateTime> _retried = {};
  Timer? _tick;
  int _seq = 0;
  VoidCallback? _unlisten;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_unlisten != null) return;
    final player = Services.of(context).player;
    final covers = Services.of(context).covers;
    void changed() => _sync();
    // Обложка догрузилась позже, чем трек включился: фон без картинки пробует ещё раз
    void coversReady() {
      final k = _key;
      if (_image != null || _color != null || k == null) return;
      // Сигналы от обложек частые (прокрутка списков) — повторяем не чаще раза в 8 секунд
      final last = _retried[k];
      if (last != null && DateTime.now().difference(last) < const Duration(seconds: 8)) return;
      _retried[k] = DateTime.now();
      _key = null;
      _sync();
    }

    player.addListener(changed);
    covers.addListener(coversReady);
    // Подстраховка: раз в 2 секунды сверяемся с текущим треком. Если ничего не поменялось — сразу выходим
    _tick = Timer.periodic(const Duration(seconds: 2), (_) => _sync());
    AmbientScope.override.addListener(changed);
    _unlisten = () {
      _tick?.cancel();
      player.removeListener(changed);
      covers.removeListener(coversReady);
      AmbientScope.override.removeListener(changed);
    };
    _sync();
  }

  @override
  void dispose() {
    _unlisten?.call();
    super.dispose();
  }

  AmbientSource? _trackSource() {
    final app = Services.of(context);
    final t = app.player.current;
    if (t == null) return null;
    return AmbientSource(app.covers.keyOf(t), bytes: () => app.covers.forTrack(t));
  }

  Future<void> _sync() async {
    final src = AmbientScope.override.value ?? _trackSource();
    if (src?.key == _key) return;
    _key = src?.key;
    final seq = ++_seq;
    var s = src;
    while (s != null) {
      final hit = _cache[s.key];
      if (hit != null) {
        setState(() {
          _image = hit;
          _color = null;
        });
        return;
      }
      ui.Image? img;
      try {
        final b = s.bytes;
        final u = s.url;
        if (b != null) {
          final bytes = await b();
          if (bytes != null) img = await _blurred(await _decode(bytes));
        } else if (u != null) {
          final link = await u();
          if (link != null && link.isNotEmpty) img = await _blurred(await _fromUrl(link));
        }
      } catch (_) {}
      if (!mounted || seq != _seq) return;
      if (img != null) {
        _cache[s.key] = img;
        _order.add(s.key);
        // Держим несколько последних: назад-вперёд без пересчёта
        if (_order.length > 12) _cache.remove(_order.removeAt(0));
        setState(() {
          _image = img;
          _color = null;
        });
        return;
      }
      if (s.color != null) {
        setState(() {
          _image = null;
          _color = s!.color;
        });
        return;
      }
      s = s.fallback;
    }
    if (!mounted || seq != _seq) return;
    setState(() {
      _image = null;
      _color = null;
    });
  }

  static Future<ui.Image?> _decode(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes, targetWidth: 64);
    final frame = await codec.getNextFrame();
    codec.dispose();
    return frame.image;
  }

  /// Фото по адресу: маленькой копией, через обычный кеш картинок Flutter
  static Future<ui.Image?> _fromUrl(String url) {
    final done = Completer<ui.Image?>();
    final stream = ResizeImage(NetworkImage(url), width: 64).resolve(ImageConfiguration.empty);
    late final ImageStreamListener listener;
    listener = ImageStreamListener((info, _) {
      if (!done.isCompleted) done.complete(info.image.clone());
      info.dispose();
      stream.removeListener(listener);
    }, onError: (_, __) {
      if (!done.isCompleted) done.complete(null);
      stream.removeListener(listener);
    });
    stream.addListener(listener);
    return done.future.timeout(const Duration(seconds: 15), onTimeout: () => null);
  }

  static Future<ui.Image?> _blurred(ui.Image? src) async {
    if (src == null) return null;
    try {
      const size = 288.0; // крупнее — меньше ступенек при растягивании на всё окно
      final rec = ui.PictureRecorder();
      final canvas = Canvas(rec);
      final paint = Paint()
        ..filterQuality = FilterQuality.medium
        ..imageFilter = ui.ImageFilter.blur(sigmaX: 30, sigmaY: 30, tileMode: TileMode.clamp);
      // Чуть шире холста, чтобы края размытия не темнели
      canvas.drawImageRect(src, Rect.fromLTWH(0, 0, src.width.toDouble(), src.height.toDouble()),
          const Rect.fromLTWH(-44, -44, size + 88, size + 88), paint);
      return await rec.endRecording().toImage(size.toInt(), size.toInt());
    } catch (_) {
      return null;
    } finally {
      src.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    final img = _image;
    return RepaintBoundary(
      child: Stack(fit: StackFit.expand, children: [
        const ColoredBox(color: C.bg),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 1200),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          layoutBuilder: (current, previous) => Stack(fit: StackFit.expand, children: [...previous, if (current != null) current]),
          child: img == null
              ? (_color != null ? _ColorGlow(key: ValueKey(_color), color: _color!) : const _BrandGlow(key: ValueKey('brand')))
              : RawImage(
                  key: ValueKey(img),
                  image: img,
                  fit: BoxFit.cover,
                  // Плавное (бикубическое) растягивание: без «квадратиков» при увеличении
                  filterQuality: FilterQuality.high,
                  opacity: const AlwaysStoppedAnimation(0.8),
                ),
        ),
        // Затемнение: снизу темнее — там плеер. Переход по плавной кривой, без ступенек
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                for (var i = 0; i <= 16; i++)
                  Color.lerp(const Color(0x80000000), const Color(0xA8000000), () {
                    final t = i / 16;
                    return t * t * (3 - 2 * t);
                  }())!,
              ],
              stops: smoothFadeStops(),
            ),
          ),
        ),
        // Свечение страницы — на всё окно, плавно появляется и исчезает
        ValueListenableBuilder<Color?>(
          valueListenable: AmbientScope.glow,
          builder: (context, c, _) => AnimatedSwitcher(
            duration: const Duration(milliseconds: 700),
            child: c == null ? const SizedBox.expand(key: ValueKey('no-glow')) : SmoothGlow(key: ValueKey(c), color: c),
          ),
        ),
      ]),
    );
  }
}

/// Профиль без картинки: мягкое свечение его цветом
class _ColorGlow extends StatelessWidget {
  final Color color;
  const _ColorGlow({super.key, required this.color});

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: const Alignment(-0.2, -0.7),
            radius: 1.3,
            colors: [color.withValues(alpha: 0.75), color.withValues(alpha: 0.25), C.bg],
            stops: const [0.0, 0.55, 1.0],
          ),
        ),
      );
}

/// Пока ничего не играет: мягкое свечение фирменных цветов
class _BrandGlow extends StatelessWidget {
  const _BrandGlow({super.key});

  @override
  Widget build(BuildContext context) => const DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(-0.3, -0.6),
            radius: 1.3,
            colors: [Color(0xFF2A3266), Color(0xFF151A36), C.bg],
            stops: [0.0, 0.5, 1.0],
          ),
        ),
      );
}

/// Стеклянная панель: полупрозрачная, со светлой обводкой
class Glass extends StatelessWidget {
  final Widget child;
  final double radius;
  final EdgeInsetsGeometry? padding;
  final Color color;
  const Glass({super.key, required this.child, this.radius = 24, this.padding, this.color = C.surface});

  @override
  Widget build(BuildContext context) => Container(
        padding: padding,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: C.line),
        ),
        child: child,
      );
}

/// Плавный градиент без «лесенки»: прозрачность меняется не по прямой, а по S-кривой
/// и разбита на много шагов — нет резких переломов, которые глаз ловит как полосы
List<Color> smoothFadeColors(Color c, {int steps = 16}) => [
      for (var i = 0; i <= steps; i++)
        () {
          final t = i / steps;
          final e = 1 - t * t * (3 - 2 * t); // smoothstep: мягкий вход и мягкий выход
          return c.withValues(alpha: c.a * e);
        }(),
    ];

List<double> smoothFadeStops({int steps = 16}) => [for (var i = 0; i <= steps; i++) i / steps];

/// Цветное свечение сверху страницы (шапка «Любимого», профили): плавно уходит в прозрачность
/// и медленно «дышит» — центр света неспешно смещается влево-вправо
class SmoothGlow extends StatefulWidget {
  final Color color;
  const SmoothGlow({super.key, required this.color});

  @override
  State<SmoothGlow> createState() => _SmoothGlowState();
}

class _SmoothGlowState extends State<SmoothGlow> with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(vsync: this, duration: const Duration(seconds: 16))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = smoothFadeColors(widget.color);
    final stops = smoothFadeStops();
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _anim,
        builder: (context, _) {
          final v = Curves.easeInOutSine.transform(_anim.value);
          return DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment(-0.5 + v, -1.1),
                radius: 1.6,
                colors: colors,
                stops: stops,
              ),
            ),
          );
        },
      ),
    );
  }
}
