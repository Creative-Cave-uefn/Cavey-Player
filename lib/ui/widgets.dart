import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../app.dart';
import '../core/covers.dart';
import '../core/models.dart';
import 'shell.dart';
import 'theme.dart';

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

/// Название с жёлтой полочкой под ним
class Wordmark extends StatelessWidget {
  final double size;
  const Wordmark({super.key, this.size = 22});

  @override
  Widget build(BuildContext context) {
    return IntrinsicWidth(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Cave Player', maxLines: 1, style: brand(size)),
          SizedBox(height: size * 0.18),
          Container(
            height: size * 0.16,
            decoration: BoxDecoration(color: C.accent, borderRadius: BorderRadius.circular(2)),
          ),
        ],
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
  const CoverImage({super.key, required this.track, required this.size, this.height, this.radius = 6, this.fileId, this.label, this.maxPx});

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

  /// Ключ поменялся (другой трек, другой человек) — старую картинку не показываем ни на кадр
  void _ensure() {
    final svc = _svc;
    if (svc == null) return;
    final t = widget.track;
    final id = widget.fileId;
    final key = id != null ? 'cv_$id' : (t == null ? null : svc.keyOf(t));
    final px = _wantPx;
    final bucket = CoverService.bucketFor(px);
    if (key == _key && bucket == _px) return;
    final sameKey = key == _key;
    _key = key;
    _px = bucket;
    _wants = id != null || (t != null && svc.wants(t));
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
    final f = id != null ? svc.forFile(id, px: px) : (t == null ? Future<Uint8List?>.value(null) : svc.forTrack(t, px: px));
    f.then((b) {
      if (!mounted || gen != _gen || key != _key || b == null || identical(b, _bytes)) return;
      setState(() => _bytes = b);
    });
  }

  /// Сервис что-то догрузил или пришло время повторить: если у нас картинки ещё нет, пробуем снова
  void _onReady() {
    if (!mounted || _bytes != null || !_wants || _key == null) return;
    final t = widget.track;
    final id = widget.fileId;
    final svc = _svc!;
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
            : Image.memory(
                bytes,
                fit: BoxFit.cover,
                cacheWidth: (widget.size * dpr).round(),
                errorBuilder: (_, __, ___) => placeholder,
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
              FriendDot(email),
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
  return showDialog<String>(
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
  final r = await showDialog<bool>(
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
