import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';

import '../app.dart';
import '../core/library.dart';
import '../core/models.dart';
import '../core/social.dart';
import 'ambient.dart';
import 'company_view.dart';
import 'shell.dart';
import 'playlists_view.dart';
import 'profile_edit.dart';
import 'theme.dart';
import 'tracks_view.dart';
import 'web_pages.dart';
import 'web_views.dart';
import 'widgets.dart';
import 'glass_popup.dart';

// Страницы исполнителя и пользователя: общая раскладка — цветной фон, круглое фото,
// имя, кнопки «i», «играть» и ещё одна, сетка «Топ-песни» и ряды плиток.

// ---------- цвет фона по обложке ----------

final Map<String, Color> _tintCache = {};

Future<Color?> _tintOf(Uint8List bytes, String key) async {
  final cached = _tintCache[key];
  if (cached != null) return cached;
  try {
    final codec = await ui.instantiateImageCodec(bytes, targetWidth: 24);
    final frame = await codec.getNextFrame();
    final data = await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
    frame.image.dispose();
    codec.dispose();
    if (data == null) return null;
    var r = 0.0, g = 0.0, b = 0.0, w = 0.0;
    for (var i = 0; i + 3 < data.lengthInBytes; i += 4) {
      final pr = data.getUint8(i), pg = data.getUint8(i + 1), pb = data.getUint8(i + 2), pa = data.getUint8(i + 3);
      if (pa < 128) continue;
      final spread = (math.max(pr, math.max(pg, pb)) - math.min(pr, math.min(pg, pb))) / 255.0;
      final weight = 0.2 + spread; // яркие цвета важнее серых
      r += pr * weight;
      g += pg * weight;
      b += pb * weight;
      w += weight;
    }
    if (w == 0) return null;
    final avg = Color.fromARGB(255, (r / w).round(), (g / w).round(), (b / w).round());
    return _tintCache[key] = _darken(avg);
  } catch (_) {
    return null;
  }
}

Color _darken(Color c) {
  final hsl = HSLColor.fromColor(c);
  return hsl.withLightness(0.32).withSaturation(math.min(hsl.saturation, 0.5)).toColor();
}

/// Цвет обложки, если уже посчитан (без ожидания)
Color? trackTintNow(AppServices app, Track t) => _tintCache[app.covers.keyOf(t)];

Future<Color?> trackTint(AppServices app, Track t) async {
  final key = app.covers.keyOf(t);
  final cached = _tintCache[key];
  if (cached != null) return cached;
  final bytes = await app.covers.forTrack(t, px: 160);
  if (bytes == null) return null;
  return _tintOf(bytes, key);
}

// ---------- общая раскладка ----------

class ProfileLayout extends StatefulWidget {
  final bool compact;
  final Widget avatar;
  final Future<Color?>? tintFuture;
  final Color? tintNow;
  final String name;
  final String? subtitle;
  final VoidCallback? onPlay;
  final VoidCallback? onInfo;
  final Widget? thirdButton;
  final List<Widget> sections;

  /// Свой баннер человека (id картинки на Диске): показывается сверху и плавно уходит в фон
  final String? bannerFileId;

  /// Чем красить фон окна, пока открыт этот профиль (важнее обложки текущего трека)
  final AmbientSource? ambient;
  /// Дополнительные кнопки сбоку от шапки (например, «Слушать вместе»); на узком окне уходят под кнопки
  final Widget? extras;

  const ProfileLayout({
    super.key,
    required this.compact,
    required this.avatar,
    required this.name,
    required this.sections,
    this.tintFuture,
    this.tintNow,
    this.subtitle,
    this.onPlay,
    this.onInfo,
    this.thirdButton,
    this.bannerFileId,
    this.ambient,
    this.extras,
  });

  @override
  State<ProfileLayout> createState() => _ProfileLayoutState();
}

class _ProfileLayoutState extends State<ProfileLayout> {
  final _scroll = ScrollController();

  /// На какой высоте прокрутки баннер исчезает совсем
  static const _fadeAt = 360.0;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Баннер (или градиент) уезжает вверх медленнее страницы, растворяется и чуть увеличивается
  Widget _backdrop(Widget child) => Positioned.fill(
        // Увеличенная картинка не должна выезжать за вкладку на левую панель
        child: ClipRect(
         child: AnimatedBuilder(
          animation: _scroll,
          builder: (context, c) {
            final off = _scroll.hasClients ? _scroll.offset.clamp(0.0, 4000.0).toDouble() : 0.0;
            final t = (off / _fadeAt).clamp(0.0, 1.0);
            return Opacity(
              opacity: 1 - t,
              child: Transform.translate(
                offset: Offset(0, -off * 0.5),
                child: Transform.scale(scale: 1 + 0.08 * t, alignment: Alignment.topCenter, child: c),
              ),
            );
          },
          child: child,
         ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final compact = widget.compact;
    final avatar = widget.avatar;
    final name = widget.name;
    final subtitle = widget.subtitle;
    final onPlay = widget.onPlay;
    final onInfo = widget.onInfo;
    final thirdButton = widget.thirdButton;
    final sections = widget.sections;
    final bannerFileId = widget.bannerFileId;
    final tintFuture = widget.tintFuture;
    final tintNow = widget.tintNow;
    final pad = compact ? 20.0 : 40.0;
    final photo = compact ? 160.0 : 220.0;
    Widget page(Color? tint) {
      return Stack(children: [
        if (bannerFileId != null)
          _backdrop(Align(alignment: Alignment.topCenter, child: _Banner(fileId: bannerFileId)))
        else
          // Свечение цветом профиля — на всё окно, плавное, медленно «дышит»
          AmbientGlow(color: tint?.withValues(alpha: 0.4)),
        CustomScrollView(controller: _scroll, slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(pad, 56, pad, 0),
              child: Column(children: [
                SizedBox.square(dimension: photo, child: ClipOval(child: avatar)),
                const SizedBox(height: 26),
                SelectionArea(
                  child: Text(name,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: display(compact ? 28 : 40, weight: FontWeight.w700)),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 10),
                  SelectionArea(
                    child: Text(subtitle!, textAlign: TextAlign.center, style: const TextStyle(color: C.muted, fontSize: 15)),
                  ),
                ],
                const SizedBox(height: 22),
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  _roundButton(Icons.info_outline_rounded, onInfo, tooltip: 'О странице'),
                  const SizedBox(width: 16),
                  _playButton(onPlay),
                  const SizedBox(width: 16),
                  thirdButton ?? const SizedBox.square(dimension: 42),
                ]),
                if (widget.extras != null && compact) ...[const SizedBox(height: 16), widget.extras!],
              ]),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(pad, 40, pad, 48),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: sections),
            ),
          ),
        ]),
        if (widget.extras != null && !compact)
          Positioned(
            right: pad,
            top: 56 + photo / 2 - 40,
            width: 220,
            child: AnimatedBuilder(
              animation: _scroll,
              builder: (context, c) => Transform.translate(offset: Offset(0, -(_scroll.hasClients ? _scroll.offset : 0.0)), child: c),
              child: widget.extras!,
            ),
          ),
      ]);
    }

    final body = tintFuture == null
        ? page(tintNow)
        : FutureBuilder<Color?>(
            future: tintFuture,
            initialData: tintNow,
            builder: (context, snap) => page(snap.data ?? tintNow),
          );
    return AmbientOverride(source: widget.ambient, child: body);
  }
}

/// Баннер профиля вместо градиента: немного затемнён и размыт, чтобы текст поверх читался; низ плавно уходит в фон
class _Banner extends StatelessWidget {
  final String fileId;
  const _Banner({required this.fileId});

  @override
  Widget build(BuildContext context) {
    final covers = Services.of(context).covers;
    return LayoutBuilder(builder: (context, box) {
      // Карточка со скруглёнными углами и отступом от краёв: раньше баннер упирался в панель и шапку окна
      const margin = 12.0;
      final w = box.maxWidth - margin * 2;
      final h = (w / 3).clamp(300.0, 620.0).toDouble();
      // Края растворяются в фон окна по плавной кривой — без резкой границы и без «лесенки»
      List<Color> fade(int n, {bool reverse = false}) => [
            for (var i = 0; i <= n; i++)
              () {
                final t = i / n;
                final e = t * t * (3 - 2 * t);
                return Colors.white.withValues(alpha: reverse ? 1 - e : e);
              }(),
          ];
      final steps = [for (var i = 0; i <= 12; i++) i / 12];
      return Padding(
        padding: const EdgeInsets.fromLTRB(margin, 4, margin, 0),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(28),
          child: ShaderMask(
            // снизу: плавно в прозрачность с середины
            blendMode: BlendMode.dstIn,
            shaderCallback: (r) => LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.white, Colors.white, ...fade(12, reverse: true)],
              stops: [0.0, 0.45, for (final s in steps) 0.45 + s * 0.55],
            ).createShader(r),
            child: ShaderMask(
              // по бокам: мягко растворяется у левого и правого края
              blendMode: BlendMode.dstIn,
              shaderCallback: (r) => LinearGradient(
                colors: [...fade(12), ...fade(12, reverse: true)],
                stops: [for (final s in steps) s * 0.12, for (final s in steps) 0.88 + s * 0.12],
              ).createShader(r),
              child: SizedBox(
                width: w,
                height: h,
                child: Stack(fit: StackFit.expand, children: [
                  ImageFiltered(
                    // mirror, а не clamp: у краёв clamp тянет крайний ряд пикселей в полосы — тот самый «шов»
                    imageFilter: ui.ImageFilter.blur(sigmaX: 6, sigmaY: 6, tileMode: TileMode.mirror),
                    // Баннер размыт, поэтому хватает копии в 640 px: она читается с диска мгновенно
                    child: CoverImage(track: null, fileId: fileId, label: '', size: w, height: h, radius: 0, maxPx: 640),
                  ),
                  ColoredBox(color: Colors.black.withValues(alpha: 0.4)),
                ]),
              ),
            ),
          ),
        ),
      );
    });
  }
}

Widget _roundButton(IconData icon, VoidCallback? onTap, {String tooltip = '', Color? color}) => Tooltip(
      message: tooltip,
      child: Material(
        color: const Color(0x33FFFFFF),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox.square(dimension: 42, child: Icon(icon, size: 20, color: color ?? Colors.white)),
        ),
      ),
    );

Widget _playButton(VoidCallback? onTap) => Tooltip(
      message: 'Слушать',
      child: Material(
        color: Colors.white,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: const SizedBox.square(dimension: 66, child: Icon(Icons.play_arrow_rounded, size: 38, color: Colors.black)),
        ),
      ),
    );

/// Заголовок раздела; со стрелкой «›», если раздел открывается целиком
class SectionTitle extends StatelessWidget {
  final String text;
  final VoidCallback? onTap;
  final Widget? trailing;
  const SectionTitle(this.text, {super.key, this.onTap, this.trailing});

  @override
  Widget build(BuildContext context) {
    final title = Row(mainAxisSize: MainAxisSize.min, children: [
      Text(text, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
      if (onTap != null) const Icon(Icons.chevron_right_rounded, size: 22, color: C.muted),
    ]);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(children: [
        onTap == null ? title : InkWell(borderRadius: BorderRadius.circular(6), onTap: onTap, child: title),
        const Spacer(),
        if (trailing != null) trailing!,
      ]),
    );
  }
}

// ---------- сетка «Топ-песни» ----------

/// Треки столбцами по три: слева направо, сверху вниз, как в Apple Music
class TrackGrid extends StatelessWidget {
  final List<Track> tracks;
  const TrackGrid({super.key, required this.tracks});

  static const _rows = 3;
  static const _cell = 70.0;

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    return LayoutBuilder(builder: (context, box) {
      final cols = box.maxWidth >= 1150 ? 4 : (box.maxWidth >= 850 ? 3 : (box.maxWidth >= 560 ? 2 : 1));
      final shown = tracks.take(cols * _rows).toList();
      return ListenableBuilder(
        listenable: app.player,
        builder: (context, _) {
          final currentId = app.player.current?.id;
          return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (var c = 0; c < cols; c++) ...[
              if (c > 0) const SizedBox(width: 24),
              Expanded(
                child: Column(children: [
                  for (var r = 0; r < _rows; r++)
                    c * _rows + r < shown.length
                        ? _cellFor(context, app, shown, c * _rows + r, currentId)
                        : const SizedBox(height: _cell),
                ]),
              ),
            ],
          ]);
        },
      );
    });
  }

  Widget _cellFor(BuildContext context, AppServices app, List<Track> shown, int i, String? currentId) {
    final t = shown[i];
    final current = t.id == currentId;
    return SizedBox(
      height: _cell,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () {
          if (current) {
            app.player.toggle();
          } else {
            app.player.playTracks(shown, i);
          }
        },
        onSecondaryTapUp: (d) => showTrackMenu(context, t, null, d.globalPosition),
        child: Container(
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: C.divider))),
          padding: const EdgeInsets.only(left: 4),
          child: Row(children: [
            CoverImage(track: t, size: 46, radius: 4),
            const SizedBox(width: 14),
            Expanded(
              child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(t.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w500, color: current ? C.accent : C.text)),
                const SizedBox(height: 3),
                // Название альбома — ссылка на альбом
                Links(
                  parts: [
                    LinkPart(t.displayAlbum, () => NavScope.of(context).go(Nav('album', t.albumKey))),
                    if (t.year.isNotEmpty) LinkPart(' · ${t.year}'),
                  ],
                  style: const TextStyle(color: C.muted, fontSize: 12.5),
                ),
              ]),
            ),
            TrackMenu(track: t),
          ]),
        ),
      ),
    );
  }
}

// ---------- ряд плиток с прокруткой ----------

class TileRow extends StatefulWidget {
  final String title;
  final List<Widget> tiles;
  final double tileWidth;
  final double height;

  /// «›» у заголовка — открыть раздел целиком
  final VoidCallback? onMore;
  const TileRow({super.key, required this.title, required this.tiles, this.tileWidth = 220, this.height = 270, this.onMore});

  @override
  State<TileRow> createState() => _TileRowState();
}

class _TileRowState extends State<TileRow> {
  final _ctl = ScrollController();

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _scroll(int dir) {
    if (!_ctl.hasClients) return;
    final to = (_ctl.offset + dir * (widget.tileWidth + 20) * 2).clamp(0.0, _ctl.position.maxScrollExtent).toDouble();
    _ctl.animateTo(to, duration: const Duration(milliseconds: 260), curve: Curves.easeOut);
  }

  @override
  Widget build(BuildContext context) {
    final many = widget.tiles.length * (widget.tileWidth + 20) > 600;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionTitle(
        widget.title,
        onTap: widget.onMore,
        trailing: many
            ? Row(mainAxisSize: MainAxisSize.min, children: [
                IconButton(onPressed: () => _scroll(-1), icon: const Icon(Icons.chevron_left_rounded), tooltip: 'Назад'),
                IconButton(onPressed: () => _scroll(1), icon: const Icon(Icons.chevron_right_rounded), tooltip: 'Вперёд'),
              ])
            : null,
      ),
      SizedBox(
        height: widget.height,
        child: ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(dragDevices: {PointerDeviceKind.touch, PointerDeviceKind.mouse}),
          child: ListView.separated(
            controller: _ctl,
            scrollDirection: Axis.horizontal,
            itemCount: widget.tiles.length,
            separatorBuilder: (_, __) => const SizedBox(width: 20),
            itemBuilder: (_, i) => SizedBox(width: widget.tileWidth, child: widget.tiles[i]),
          ),
        ),
      ),
    ]);
  }
}

/// Плитка: квадратная обложка, название и подпись
Widget _tile(BuildContext context, {required Widget cover, required String title, required String subtitle, required VoidCallback onTap}) {
  return InkWell(
    borderRadius: BorderRadius.circular(10),
    onTap: onTap,
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      AspectRatio(aspectRatio: 1, child: cover),
      const SizedBox(height: 10),
      Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
      const SizedBox(height: 3),
      Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.muted, fontSize: 13)),
    ]),
  );
}

Widget _albumTile(BuildContext context, Album a) => _tile(
      context,
      cover: LayoutBuilder(builder: (context, box) => CoverImage(track: a.coverTrack, size: box.maxWidth, radius: 10)),
      title: a.title,
      subtitle: a.year.isEmpty ? countTracks(a.tracks.length) : '${a.year} · ${countTracks(a.tracks.length)}',
      onTap: () => NavScope.of(context).go(Nav('album', a.key)),
    );

// ---------- страница исполнителя ----------

/// Страница исполнителя — одна и для библиотеки, и для поиска: шапка профиля,
/// дальше полная дискография из интернета, а в ней раздел «Скачанное» — что есть у вас
class ArtistProfilePage extends StatelessWidget {
  final String artistKey;
  final bool compact;

  /// id исполнителя на Deezer, если уже известен (пришли из поиска)
  final int? webId;
  const ArtistProfilePage({super.key, required this.artistKey, required this.compact, this.webId});

  static String _when(Track t) => t.added.isNotEmpty ? t.added : t.modified;

  /// Главный ли исполнитель трека (первый в списке, у альбома — исполнитель альбома)
  static bool _primary(Track t, String key) {
    final names = t.albumArtist.isNotEmpty ? splitArtists(t.albumArtist) : t.artists;
    return names.isNotEmpty && names.first.toLowerCase() == key;
  }

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([app.lib, app.social]),
      builder: (context, _) {
        final lib = app.lib;
        final a = lib.artist(artistKey);
        if (a == null) {
          return const EmptyState(icon: Icons.mic_none_rounded, title: 'Исполнитель пропал', text: 'Его треки удалили из библиотеки.');
        }
        // Топ: чаще слушали, потом чаще лайкали, потом новее
        final ranked = List<Track>.of(a.tracks)
          ..sort((x, y) {
            final p = app.social.playsOf(y.id).compareTo(app.social.playsOf(x.id));
            if (p != 0) return p;
            final l = (lib.data.likes[y.id]?.length ?? 0).compareTo(lib.data.likes[x.id]?.length ?? 0);
            if (l != 0) return l;
            return _when(y).compareTo(_when(x));
          });

        final own = <Album>[];
        final guest = <Album>[];
        for (final al in lib.albums) {
          if (!al.tracks.any((t) => t.artists.any((n) => n.toLowerCase() == a.key))) continue;
          (al.tracks.any((t) => _primary(t, a.key)) ? own : guest).add(al);
        }
        int byYear(Album x, Album y) {
          final r = y.year.compareTo(x.year);
          return r != 0 ? r : x.title.toLowerCase().compareTo(y.title.toLowerCase());
        }

        own.sort(byYear);
        guest.sort(byYear);

        final fav = lib.isFavArtist(a.key);
        final albumsN = a.albums;
        return ProfileLayout(
          compact: compact,
          // Фото из интернета; пока его нет — обложка одного из треков
          avatar: ArtistPhoto(name: a.name, size: 220, fallback: CoverImage(track: a.coverTrack, size: 220, radius: 0)),
          // Фон окна — по фото исполнителя; нет фото — по обложке одного из его треков
          ambient: AmbientSource(
            'artist:${a.key}',
            url: () async => (app.web.artistCached(a.name) ?? await app.web.artist(a.name))?.picture,
            fallback: AmbientSource(app.covers.keyOf(a.coverTrack), bytes: () => app.covers.forTrack(a.coverTrack)),
          ),
          tintFuture: trackTint(app, a.coverTrack),
          tintNow: _tintCache[app.covers.keyOf(a.coverTrack)],
          name: a.name,
          subtitle: '${countTracks(a.tracks.length)}, $albumsN ${plural(albumsN, 'альбом', 'альбома', 'альбомов')} на Диске',
          onPlay: () {
            if (app.player.shuffle) app.player.toggleShuffle();
            app.player.playTracks(ranked, 0);
          },
          onInfo: () => _showInfo(context, app, a, ranked),
          thirdButton: Row(mainAxisSize: MainAxisSize.min, children: [
            _roundButton(
              fav ? Icons.favorite_rounded : Icons.favorite_border_rounded,
              () => lib.toggleFavArtist(a.key),
              tooltip: fav ? 'Убрать из любимых исполнителей' : 'В любимые исполнители',
              color: fav ? C.accent : null,
            ),
            const SizedBox(width: 10),
            _roundButton(Icons.waves_rounded, () {
              app.wave.startFromArtist(a.name);
              NavScope.of(context).go(const Nav('wave'));
            }, tooltip: 'Моя волна по исполнителю'),
          ]),
          sections: [
            WebArtistSections(
              key: ValueKey('web:${a.key}'),
              artistId: webId,
              name: a.name,
              compact: compact,
              // «Скачанное» — сразу после «Топ-песен» из интернета: это играет целиком
              library: [
                SectionTitle('Скачанное', onTap: () => NavScope.of(context).go(Nav('artistTracks', a.key))),
                TrackGrid(tracks: ranked),
                if (own.isNotEmpty) ...[
                  const SizedBox(height: 36),
                  TileRow(
                    title: 'Скачанные альбомы',
                    tileWidth: compact ? 180 : 240,
                    height: compact ? 252 : 312,
                    tiles: [for (final al in own) _albumTile(context, al)],
                  ),
                ],
              ],
              guest: [
                if (guest.isNotEmpty) ...[
                  const SizedBox(height: 36),
                  TileRow(
                    title: 'Участвует в',
                    tileWidth: compact ? 180 : 240,
                    height: compact ? 252 : 312,
                    tiles: [for (final al in guest) _albumTile(context, al)],
                  ),
                ],
              ],
            ),
          ],
        );
      },
    );
  }

  void _showInfo(BuildContext context, AppServices app, Artist a, List<Track> tracks) {
    final lib = app.lib;
    final byWho = <String, int>{};
    var ms = 0;
    var known = 0;
    var plays = 0;
    for (final t in tracks) {
      byWho[t.by] = (byWho[t.by] ?? 0) + 1;
      if ((t.durationMs ?? 0) > 0) {
        ms += t.durationMs!;
        known++;
      }
      plays += app.social.playsOf(t.id);
    }
    final who = byWho.entries.toList()..sort((x, y) => y.value.compareTo(x.value));
    showGlassDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(a.name, style: display(18)),
        content: SizedBox(
          width: 380,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            _infoRow('Треков на Диске', '${tracks.length}'),
            _infoRow('Альбомов', '${a.albums}'),
            if (known > 0) _infoRow('Общая длительность', _humanDuration(Duration(milliseconds: ms)) + (known < tracks.length ? ' (по $known трекам)' : '')),
            _infoRow('Прослушано за две недели', '$plays'),
            const SizedBox(height: 10),
            const Text('Загрузили', style: TextStyle(color: C.muted, fontSize: 13)),
            const SizedBox(height: 6),
            for (final e in who.take(8)) _infoRow(e.key.isEmpty ? 'Неизвестно' : lib.nameOf(e.key), '${e.value}'),
          ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Закрыть'))],
      ),
    );
  }
}

Widget _infoRow(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Expanded(child: Text(label, style: const TextStyle(color: C.muted))),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
      ]),
    );

String _humanDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes % 60;
  if (h > 0) return '$h ч $m мин';
  return '${d.inMinutes} мин';
}

// ---------- страница пользователя ----------

class UserProfilePage extends StatelessWidget {
  final String email;
  final bool compact;
  const UserProfilePage({super.key, required this.email, required this.compact});

  static String _when(Track t) => t.added.isNotEmpty ? t.added : t.modified;

  /// Любимые треки человека: чаще слушаемые им — выше
  static List<Track> likedBy(AppServices app, String email) {
    final lib = app.lib;
    final list = [for (final t in lib.allTracks) if (lib.data.likes[t.id]?.contains(email) ?? false) t];
    list.sort((x, y) {
      final p = app.social.playsOf(y.id, email: email).compareTo(app.social.playsOf(x.id, email: email));
      return p != 0 ? p : _when(y).compareTo(_when(x));
    });
    return list;
  }

  static List<Track> uploadedBy(AppServices app, String email) {
    final list = [for (final t in app.lib.allTracks) if (t.by == email) t];
    list.sort((x, y) => _when(y).compareTo(_when(x)));
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([app.lib, app.social]),
      builder: (context, _) {
        final lib = app.lib;
        final name = lib.nameOf(email);
        final liked = likedBy(app, email);
        final uploads = uploadedBy(app, email);
        final lists = [for (final p in lib.visiblePlaylists) if (p.by == email) p];
        final m = app.social.members[email];
        String? subtitle;
        if (m != null && m.live && m.now != null) {
          subtitle = 'Сейчас слушает: ${m.now!.title} — ${m.now!.artist}';
        } else if (email == lib.me) {
          subtitle = 'Это ваша страница';
        }
        final favs = lib.favoritesOf(email);
        final nothing = liked.isEmpty && uploads.isEmpty && lists.isEmpty;
        return ProfileLayout(
          compact: compact,
          avatar: Avatar(email: email, name: name, size: 220),
          bannerFileId: lib.profileBanner(email),
          // Фон — по баннеру человека, иначе по аватару, иначе его цветом
          ambient: AmbientSource(
            'user:$email:${lib.profileBanner(email)}:${lib.profileAvatar(email)}',
            bytes: () async {
              final id = lib.profileBanner(email) ?? lib.profileAvatar(email);
              return id == null ? null : app.covers.forFile(id);
            },
            color: friendColor(email),
          ),
          extras: email == lib.me ? null : ListenActions(email: email),
          thirdButton: email == lib.me
              ? _roundButton(Icons.edit_rounded, () => editProfileDialog(context), tooltip: 'Изменить профиль')
              : null,
          tintNow: _darken(friendColor(email)),
          name: name,
          subtitle: subtitle,
          onPlay: (liked.isEmpty && uploads.isEmpty)
              ? null
              : () {
                  if (app.player.shuffle) app.player.toggleShuffle();
                  app.player.playTracks(liked.isNotEmpty ? liked : uploads, 0);
                },
          onInfo: () => _showInfo(context, app, name, liked.length, uploads.length, lists.length),
          sections: [
            if (m != null && (m.totals.isNotEmpty || m.plays.isNotEmpty)) ...[
              ListenStats(email: email),
              const SizedBox(height: 36),
            ],
            if (nothing)
              const Padding(
                padding: EdgeInsets.only(top: 20),
                child: Text('Пока ничего: ни любимых треков, ни загрузок, ни плейлистов.',
                    textAlign: TextAlign.center, style: TextStyle(color: C.muted)),
              ),
            if (liked.isNotEmpty) ...[
              SectionTitle('Любимые треки', onTap: () => NavScope.of(context).go(Nav('userLikes', email))),
              TrackGrid(tracks: liked),
            ],
            if (uploads.isNotEmpty) ...[
              SizedBox(height: liked.isEmpty ? 0 : 36),
              SectionTitle('Загрузил(а): ${countTracks(uploads.length)}',
                  onTap: () => NavScope.of(context).go(Nav('userUploads', email))),
              TrackGrid(tracks: uploads),
            ],
            if (lists.isNotEmpty) ...[
              const SizedBox(height: 36),
              TileRow(
                title: 'Плейлисты',
                tileWidth: compact ? 180 : 220,
                height: compact ? 252 : 292,
                tiles: [
                  for (final p in lists)
                    _tile(
                      context,
                      cover: LayoutBuilder(builder: (context, box) {
                        final tracks = lib.playlistTracks(p.id);
                        Track? first;
                        for (final t in tracks) {
                          if (t.hasCover) {
                            first = t;
                            break;
                          }
                        }
                        first ??= tracks.isEmpty ? null : tracks.first;
                        return CoverImage(track: first, fileId: lib.playlistCover(p.id), label: p.name, size: box.maxWidth, radius: 10);
                      }),
                      title: p.name,
                      subtitle: countTracks(p.items.length),
                      onTap: () => NavScope.of(context).go(Nav('playlist', p.id)),
                    ),
                ],
              ),
            ],
            // Что человек отметил сердечком: плейлисты друзей, альбомы и исполнители
            if (favs.playlists.isNotEmpty || favs.albums.isNotEmpty || favs.artists.isNotEmpty) ...[
              const SizedBox(height: 36),
              TileRow(
                title: 'Любимое',
                tileWidth: compact ? 160 : 190,
                height: compact ? 232 : 262,
                tiles: [
                  for (final a in favs.albums)
                    _tile(
                      context,
                      cover: LayoutBuilder(builder: (context, box) => CoverImage(track: a.coverTrack, size: box.maxWidth, radius: 10)),
                      title: a.title,
                      subtitle: 'Альбом · ${a.artist}',
                      onTap: () => NavScope.of(context).go(Nav('album', a.key)),
                    ),
                  for (final p in favs.playlists)
                    _tile(
                      context,
                      cover: LayoutBuilder(builder: (context, box) => PlaylistCover(playlist: p, size: box.maxWidth, radius: 10)),
                      title: p.name,
                      subtitle: 'Плейлист · ${lib.firstNameOf(p.by)}',
                      onTap: () => NavScope.of(context).go(Nav('playlist', p.id)),
                    ),
                  for (final a in favs.artists)
                    _tile(
                      context,
                      cover: LayoutBuilder(
                        builder: (context, box) => ClipOval(
                          child: ArtistPhoto(
                            name: a.name,
                            size: box.maxWidth,
                            fallback: CoverImage(track: a.coverTrack, size: box.maxWidth, radius: 0),
                          ),
                        ),
                      ),
                      title: a.name,
                      subtitle: 'Исполнитель',
                      onTap: () => NavScope.of(context).go(Nav('artist', a.key)),
                    ),
                ],
              ),
            ],
          ],
        );
      },
    );
  }

  void _showInfo(BuildContext context, AppServices app, String name, int likes, int uploads, int lists) {
    var week = 0;
    final m = app.social.members[email];
    if (m != null) {
      final since = DateTime.now().subtract(const Duration(days: 6));
      final key = '${since.year.toString().padLeft(4, '0')}-${since.month.toString().padLeft(2, '0')}-${since.day.toString().padLeft(2, '0')}';
      m.plays.forEach((day, tracks) {
        if (day.compareTo(key) >= 0) week += tracks.values.fold(0, (a, b) => a + b);
      });
    }
    showGlassDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(name, style: display(18)),
        content: SizedBox(
          width: 360,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            _infoRow('Загружено треков', '$uploads'),
            _infoRow('Любимых треков', '$likes'),
            _infoRow('Плейлистов', '$lists'),
            _infoRow('Прослушано за неделю', '$week'),
          ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Закрыть'))],
      ),
    );
  }
}

/// Полный список: любимое или загрузки человека
class UserTracksPage extends StatelessWidget {
  final String email;
  final bool uploads;
  final bool compact;
  const UserTracksPage({super.key, required this.email, required this.uploads, required this.compact});

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([app.lib, app.social]),
      builder: (context, _) {
        final tracks = uploads ? UserProfilePage.uploadedBy(app, email) : UserProfilePage.likedBy(app, email);
        final name = app.lib.nameOf(email);
        return TracksPage(
          title: uploads ? 'Загрузил(а) $name' : 'Любимое: $name',
          subtitle: countTracks(tracks.length),
          tracks: tracks,
          compact: compact,
          empty: const EmptyState(icon: Icons.music_off_rounded, title: 'Пока ничего', text: 'Здесь появятся треки.'),
        );
      },
    );
  }
}

/// «Статистика» в профиле: сколько наслушано всего, за неделю и месяц, график за 30 дней и любимый исполнитель.
/// Время примерное: прослушивания × длительность трека
class ListenStats extends StatelessWidget {
  final String email;
  const ListenStats({super.key, required this.email});

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final s = app.social;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final total = s.listened(email);
    final week = s.listened(email, since: today.subtract(const Duration(days: 6)));
    final month = s.listened(email, since: today.subtract(const Duration(days: 29)));
    final days = s.listenedByDay(email);
    final top = s.topArtist(email);
    final peak = days.fold<int>(0, (a, d) => math.max(a, d.$2.inMinutes));
    Widget tile(String label, String value) => Container(
          constraints: const BoxConstraints(minWidth: 150),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          decoration: BoxDecoration(color: C.surface, border: Border.all(color: C.line), borderRadius: BorderRadius.circular(14)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(value, style: display(22, weight: FontWeight.w700)),
            const SizedBox(height: 2),
            Text(label, style: const TextStyle(color: C.muted, fontSize: 13)),
          ]),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SectionTitle('Статистика'),
      Wrap(spacing: 12, runSpacing: 12, children: [
        tile('наслушано всего', formatListened(total)),
        tile('за неделю', formatListened(week)),
        tile('за месяц', formatListened(month)),
        if (top != null)
          InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => NavScope.of(context).go(Nav('artist', top.toLowerCase())),
            child: tile('любимый исполнитель месяца', top),
          ),
      ]),
      const SizedBox(height: 18),
      // По дням за 30 дней: высота столбика — сколько минут слушали
      SizedBox(
        height: 90,
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          for (final (day, d) in days)
            Expanded(
              child: Tooltip(
                message: '${day.day.toString().padLeft(2, '0')}.${day.month.toString().padLeft(2, '0')}: ${formatListened(d)}',
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 1.5),
                  child: Container(
                    height: peak == 0 ? 3 : (3 + 84 * d.inMinutes / peak),
                    decoration: BoxDecoration(
                      color: d.inMinutes == 0 ? C.line : C.accent.withValues(alpha: 0.85),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
              ),
            ),
        ]),
      ),
      const SizedBox(height: 6),
      const Row(children: [
        Text('30 дней назад', style: TextStyle(color: C.faint, fontSize: 11)),
        Spacer(),
        Text('сегодня', style: TextStyle(color: C.faint, fontSize: 11)),
      ]),
      const SizedBox(height: 6),
      const Text('Время примерное: прослушивания × длительность трека.', style: TextStyle(color: C.faint, fontSize: 11)),
    ]);
  }
}
