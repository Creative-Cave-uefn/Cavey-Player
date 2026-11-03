import 'dart:async';

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/library.dart';
import '../core/models.dart';
import '../core/notices.dart';
import '../core/social.dart';
import '../core/wave.dart';
import '../core/web_info.dart';
import '../mobile_main.dart';
import '../ui/theme.dart';
import 'mobile_home.dart';

// ───────────────────────────── общее ─────────────────────────────

/// Картинка из интернета (обложка и фото из Deezer)
class NetImage extends StatelessWidget {
  const NetImage({super.key, required this.url, required this.size, this.radius = 10, this.icon = Icons.music_note_rounded});
  final String url;
  final double size;
  final double radius;
  final IconData icon;

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: SizedBox(
          width: size,
          height: size,
          child: url.isEmpty
              ? _hole()
              : Image.network(url, fit: BoxFit.cover, errorBuilder: (_, __, ___) => _hole(), loadingBuilder: (_, child, p) => p == null ? child : _hole()),
        ),
      );

  Widget _hole() => DecoratedBox(
        decoration: const BoxDecoration(color: C.raised),
        child: Center(child: Icon(icon, color: C.faint)),
      );
}

Widget pageHeader(String title, {Widget? trailing}) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 12, 8),
      child: Row(children: [
        Expanded(child: Text(title, style: display(30))),
        if (trailing != null) trailing,
      ]),
    );

/// Страница поверх оболочки: обычный Scaffold с мини-плеером снизу
class SubPage extends StatelessWidget {
  const SubPage({super.key, required this.services, required this.title, required this.child});
  final MobileServices services;
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          title: Text(title, style: display(20)),
        ),
        body: child,
        bottomNavigationBar: AnimatedBuilder(
          animation: services.player,
          builder: (_, __) => services.player.current == null
              ? const SizedBox.shrink()
              : MiniPlayer(services: services, onOpen: () => showPlayer(context, services)),
        ),
      );
}

void toast(BuildContext context, String text) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
}

// ───────────────────────────── Моя волна ─────────────────────────────

class WaveTab extends StatelessWidget {
  const WaveTab({super.key, required this.services});
  final MobileServices services;

  @override
  Widget build(BuildContext context) {
    final wave = services.wave;
    final p = services.player;
    return AnimatedBuilder(
      animation: Listenable.merge([wave, p, services.library]),
      builder: (_, __) {
        final active = wave.active && p.current != null;
        final t = p.current;
        final top = wave.topArtists(8);
        return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
            child: Row(children: [
              const SizedBox(width: 42),
              Expanded(child: Center(child: Text('Моя волна', style: display(22, color: C.muted)))),
              Glass(
                radius: 21,
                color: const Color(0x9E1A1A24),
                child: InkWell(
                  onTap: () => _settings(context, wave),
                  child: SizedBox(
                    width: 42,
                    height: 42,
                    child: Stack(alignment: Alignment.center, children: [
                      const Icon(Icons.tune_rounded, size: 22, color: C.text),
                      Positioned(top: 8, right: 8, child: Container(width: 8, height: 8, decoration: BoxDecoration(color: C.accent, shape: BoxShape.circle))),
                    ]),
                  ),
                ),
              ),
            ]),
          ),
          const SizedBox(height: 20),
          Center(
            child: SizedBox(
              width: 248,
              height: 248,
              child: Stack(alignment: Alignment.center, children: [
                Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(colors: [C.accent.withValues(alpha: 0.26), C.accent.withValues(alpha: 0)], stops: const [0, 0.68]),
                  ),
                ),
                Container(
                  width: 196,
                  height: 196,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0x12FFFFFF),
                    border: Border.all(color: const Color(0x38FFFFFF)),
                  ),
                  child: ClipOval(child: CustomPaint(painter: _WavePainter())),
                ),
                GestureDetector(
                  onTap: () async {
                    if (active) {
                      await p.toggle();
                    } else {
                      await wave.start();
                    }
                  },
                  child: Container(
                    width: 84,
                    height: 84,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: C.accent,
                      boxShadow: [BoxShadow(color: C.accent.withValues(alpha: 0.35), blurRadius: 30, offset: const Offset(0, 10))],
                    ),
                    child: Icon(active && p.playing ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 46, color: C.accentInk),
                  ),
                ),
              ]),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(36, 0, 36, 0),
            child: Text('Бесконечный поток из вашей библиотеки: волна подстраивается под то, что вы дослушиваете и пропускаете',
                textAlign: TextAlign.center, style: const TextStyle(color: C.muted, height: 1.4, fontSize: 14)),
          ),
          if (active && t != null) ...[
            const SizedBox(height: 18),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Glass(
                radius: 16,
                color: C.surface,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(children: [
                    TrackCover(services: services, track: t, size: 52),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
                        Text(wave.reasonFor(t.id), maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.muted, fontSize: 12)),
                      ]),
                    ),
                    IconButton(onPressed: wave.dislike, tooltip: 'Не нравится', icon: const Icon(Icons.thumb_down_alt_outlined, color: C.text)),
                    IconButton(
                      onPressed: wave.upvote,
                      tooltip: 'Нравится',
                      icon: Icon(wave.isUpvoted(t.id) ? Icons.thumb_up_alt_rounded : Icons.thumb_up_alt_outlined,
                          color: wave.isUpvoted(t.id) ? C.accent : C.text),
                    ),
                  ]),
                ),
              ),
            ),
          ],
          Padding(padding: const EdgeInsets.fromLTRB(20, 22, 20, 0), child: Text('Под настроение', style: display(21))),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: GridView(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, mainAxisSpacing: 10, crossAxisSpacing: 10, mainAxisExtent: 70),
              children: [
                for (final (i, m) in waveMoods.indexed)
                  InkWell(
                    borderRadius: BorderRadius.circular(18),
                    onTap: () {
                      wave.setMood(wave.mood == m.id ? null : m.id);
                      if (wave.mood != null) wave.start();
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: wave.mood == m.id ? C.accent : const Color(0x2EFFFFFF)),
                        color: const Color(0x12FFFFFF),
                        gradient: RadialGradient(center: Alignment.topLeft, radius: 1.3, colors: [_moodColors[i % _moodColors.length].withValues(alpha: 0.34), Colors.transparent]),
                      ),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                        Icon(_moodIcons[i % _moodIcons.length], size: 20, color: _moodColors[i % _moodColors.length]),
                        Text(m.title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                      ]),
                    ),
                  ),
              ],
            ),
          ),
          if (top.isNotEmpty) ...[
            const SectionTitle('Ваши исполнители'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(spacing: 8, runSpacing: 8, children: [
                for (final a in top)
                  ActionChip(
                    label: Text(a.$1),
                    onPressed: () => wave.startFromArtist(a.$1),
                  ),
              ]),
            ),
          ],
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 22, 20, 0),
            child: Text(
              'Волна подбирает треки из вашей общей библиотеки. Новые треки из интернета на телефоне не скачиваются: это делает Cavey на компьютере.',
              style: const TextStyle(color: C.faint, fontSize: 12, height: 1.4),
            ),
          ),
        ]);
      },
    );
  }
}

const _moodColors = [Color(0xFFFF9A4A), Color(0xFF5FD3B4), Color(0xFF7FA2FF), Color(0xFFFF7FB2), Color(0xFFA08CFF), Color(0xFF8FDB6A)];
const _moodIcons = [Icons.bolt_rounded, Icons.south_rounded, Icons.water_drop_outlined, Icons.favorite_border_rounded, Icons.nightlight_outlined, Icons.gps_fixed_rounded];

/// Волнистые линии внутри круга «Моей волны»
class _WavePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final shader = const LinearGradient(colors: [Color(0xFF8AB4FF), Color(0xFFF2C14E), Color(0xFFFF8A80)]).createShader(Offset.zero & size);
    for (var k = 0; k < 4; k++) {
      final path = Path();
      final y0 = h * (0.34 + k * 0.1);
      for (var x = 0.0; x <= w; x += 3) {
        final y = y0 + math.sin(x / w * math.pi * 3 + k * 0.9) * (12 + k * 2);
        if (x == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..shader = shader
            ..color = Colors.white.withValues(alpha: 0.7 - k * 0.1));
    }
  }

  @override
  bool shouldRepaint(_WavePainter old) => false;
}

void _settings(BuildContext context, dynamic wave) {
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: C.panel,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (sheet) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Характер волны', style: display(19)),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final m in WaveMode.values)
              ChoiceChip(
                label: Text(m.title),
                selected: wave.mode == m,
                labelStyle: TextStyle(color: wave.mode == m ? C.accentInk : C.text, fontWeight: FontWeight.w600),
                onSelected: (_) {
                  wave.setMode(m);
                  Navigator.pop(sheet);
                },
              ),
          ]),
          const SizedBox(height: 14),
          TextButton(
            onPressed: () {
              wave.setMood(null);
              Navigator.pop(sheet);
            },
            child: Text('Сбросить настроение', style: TextStyle(color: C.accent)),
          ),
        ]),
      ),
    ),
  );
}

// ───────────────────────────── Поиск в интернете ─────────────────────────────

class WebSearchSection extends StatefulWidget {
  const WebSearchSection({super.key, required this.services, required this.query});
  final MobileServices services;
  final String query;

  @override
  State<WebSearchSection> createState() => _WebSearchSectionState();
}

class _WebSearchSectionState extends State<WebSearchSection> {
  WebSearchResults? results;
  bool loading = false;
  String? error;
  Timer? debounce;
  int gen = 0;

  @override
  void initState() {
    super.initState();
    schedule();
  }

  @override
  void didUpdateWidget(WebSearchSection old) {
    super.didUpdateWidget(old);
    if (old.query != widget.query) schedule();
  }

  @override
  void dispose() {
    debounce?.cancel();
    super.dispose();
  }

  void schedule() {
    debounce?.cancel();
    final q = widget.query.trim();
    if (q.isEmpty) {
      setState(() {
        results = null;
        loading = false;
      });
      return;
    }
    debounce = Timer(const Duration(milliseconds: 450), () => run(q));
  }

  Future<void> run(String q) async {
    final g = ++gen;
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final r = await widget.services.web.search(q, onUpdate: (r) {
        if (mounted && g == gen) setState(() => results = r);
      });
      if (!mounted || g != gen) return;
      setState(() {
        results = r;
        loading = false;
      });
    } catch (e) {
      if (!mounted || g != gen) return;
      setState(() {
        loading = false;
        error = 'Не удалось выполнить поиск. Проверьте интернет.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.services;
    final r = results;
    if (widget.query.trim().isEmpty) {
      return const Center(child: Text('Поиск по Deezer: исполнители, альбомы, треки', style: TextStyle(color: C.muted)));
    }
    if (r == null) {
      return Center(child: error != null ? Text(error!, style: const TextStyle(color: C.danger)) : const CircularProgressIndicator());
    }
    return ListView(children: [
      if (loading) const LinearProgressIndicator(minHeight: 2),
      if (error != null) Padding(padding: const EdgeInsets.all(16), child: Text(error!, style: const TextStyle(color: C.danger))),
      if (r.artists.isNotEmpty) ...[
        const SectionTitle('Исполнители'),
        SizedBox(
          height: 130,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            itemCount: r.artists.length,
            itemBuilder: (_, i) => _ArtistChip(services: s, artist: r.artists[i]),
          ),
        ),
      ],
      if (r.albums.isNotEmpty) ...[
        const SectionTitle('Альбомы'),
        SizedBox(
          height: 204,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            itemCount: r.albums.length,
            itemBuilder: (_, i) => WebAlbumCard(services: s, album: r.albums[i]),
          ),
        ),
      ],
      if (r.tracks.isNotEmpty) ...[
        const SectionTitle('Треки'),
        for (final t in r.tracks) WebTrackTile(services: s, track: t),
      ],
      if (!loading && r.tracks.isEmpty && r.albums.isEmpty && r.artists.isEmpty)
        const Padding(padding: EdgeInsets.all(30), child: Center(child: Text('Ничего не найдено', style: TextStyle(color: C.muted)))),
      const SizedBox(height: 16),
    ]);
  }
}

class _ArtistChip extends StatelessWidget {
  const _ArtistChip({required this.services, required this.artist});
  final MobileServices services;
  final WebArtist artist;
  @override
  Widget build(BuildContext context) => InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => WebArtistPage(services: services, artistId: artist.id, name: artist.name))),
        child: SizedBox(
          width: 96,
          child: Column(children: [
            NetImage(url: artist.picture, size: 80, radius: 40, icon: Icons.person_rounded),
            const SizedBox(height: 6),
            Text(artist.name, maxLines: 2, textAlign: TextAlign.center, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
          ]),
        ),
      );
}

class WebAlbumCard extends StatelessWidget {
  const WebAlbumCard({super.key, required this.services, required this.album, this.width = 140});
  final MobileServices services;
  final WebAlbum album;
  final double width;
  @override
  Widget build(BuildContext context) => SizedBox(
        width: width,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => WebAlbumPage(services: services, albumId: album.id, title: album.title))),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              NetImage(url: album.cover, size: width - 10, radius: 14),
              const SizedBox(height: 8),
              Text(album.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
              Text('${album.artist}${album.year.isEmpty ? '' : ' · ${album.year}'}',
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.muted, fontSize: 12)),
            ]),
          ),
        ),
      );
}

/// Трек из интернета: отрывок 30 секунд; если такой трек уже есть в библиотеке — нажатие включает его целиком
class WebTrackTile extends StatelessWidget {
  const WebTrackTile({super.key, required this.services, required this.track, this.showCover = true});
  final MobileServices services;
  final WebTrack track;
  final bool showCover;

  Track? inLibrary() {
    final key = LibraryController.dupKey(track.artist, track.title);
    for (final t in services.library.allTracks) {
      if (LibraryController.dupKey(t.displayArtist, t.title) == key || LibraryController.dupKey(t.artist, t.title) == key) return t;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final mine = inLibrary();
    return AnimatedBuilder(
      animation: services.preview,
      builder: (_, __) {
        final on = services.preview.current == track.id;
        return ListTile(
          contentPadding: const EdgeInsets.only(left: 16, right: 8),
          leading: showCover ? NetImage(url: track.cover, size: 50) : null,
          title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: FontWeight.w600, color: on ? C.accent : C.text)),
          subtitle: Row(children: [
            if (mine != null) Padding(padding: const EdgeInsets.only(right: 5), child: Icon(Icons.check_circle_rounded, size: 14, color: C.accent)),
            Expanded(child: Text(track.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.muted, fontSize: 13))),
          ]),
          onTap: mine != null
              ? () => playTracks(context, services, [mine], 0)
              : (track.preview.isEmpty ? null : () => services.preview.toggle(track)),
          trailing: track.preview.isEmpty
              ? null
              : IconButton(
                  tooltip: 'Отрывок 30 секунд',
                  onPressed: () => services.preview.toggle(track),
                  icon: on
                      ? SizedBox.square(
                          dimension: 28,
                          child: CircularProgressIndicator(strokeWidth: 3, value: services.preview.progress.clamp(0.0, 1.0), color: C.accent))
                      : const Icon(Icons.play_circle_outline_rounded, size: 30, color: C.text),
                ),
        );
      },
    );
  }
}

class WebAlbumPage extends StatefulWidget {
  const WebAlbumPage({super.key, required this.services, required this.albumId, required this.title});
  final MobileServices services;
  final int albumId;
  final String title;
  @override
  State<WebAlbumPage> createState() => _WebAlbumPageState();
}

class _WebAlbumPageState extends State<WebAlbumPage> {
  late final Future<(WebAlbum, List<WebTrack>)> future = widget.services.web.albumById(widget.albumId);

  @override
  void dispose() {
    widget.services.preview.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SubPage(
        services: widget.services,
        title: widget.title,
        child: FutureBuilder<(WebAlbum, List<WebTrack>)>(
          future: future,
          builder: (_, snap) {
            if (snap.hasError) return const Center(child: Text('Не удалось загрузить альбом', style: TextStyle(color: C.danger)));
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            final (album, tracks) = snap.data!;
            return ListView(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 6, 24, 8),
                child: Column(children: [
                  NetImage(url: album.cover, size: 240, radius: 18),
                  const SizedBox(height: 14),
                  Text(album.title, textAlign: TextAlign.center, style: display(22)),
                  const SizedBox(height: 4),
                  Text('${album.artist} · ${album.typeLabel}${album.year.isEmpty ? '' : ' · ${album.year}'}', style: const TextStyle(color: C.muted)),
                ]),
              ),
              for (final t in tracks) WebTrackTile(services: widget.services, track: t, showCover: false),
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 14, 20, 20),
                child: Text('Здесь доступны отрывки по 30 секунд. Треки, которые уже есть в библиотеке, отмечены галочкой и играют целиком.',
                    style: TextStyle(color: C.faint, fontSize: 12, height: 1.4)),
              ),
            ]);
          },
        ),
      );
}

class WebArtistPage extends StatefulWidget {
  const WebArtistPage({super.key, required this.services, required this.artistId, required this.name});
  final MobileServices services;
  final int artistId;
  final String name;
  @override
  State<WebArtistPage> createState() => _WebArtistPageState();
}

class _WebArtistPageState extends State<WebArtistPage> {
  late final Future<(WebArtist, List<WebTrack>, List<WebAlbum>)> future = load();

  Future<(WebArtist, List<WebTrack>, List<WebAlbum>)> load() async {
    final w = widget.services.web;
    final a = await w.artistById(widget.artistId);
    final top = await w.top(widget.artistId);
    List<WebAlbum> albums = const [];
    try {
      albums = await w.albumsOf(widget.artistId, a.name);
    } catch (_) {}
    return (a, top, albums);
  }

  @override
  void dispose() {
    widget.services.preview.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SubPage(
        services: widget.services,
        title: widget.name,
        child: FutureBuilder<(WebArtist, List<WebTrack>, List<WebAlbum>)>(
          future: future,
          builder: (_, snap) {
            if (snap.hasError) return const Center(child: Text('Не удалось загрузить исполнителя', style: TextStyle(color: C.danger)));
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            final (artist, top, albums) = snap.data!;
            return ListView(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 6, 24, 8),
                child: Column(children: [
                  NetImage(url: artist.picture, size: 160, radius: 80, icon: Icons.person_rounded),
                  const SizedBox(height: 12),
                  Text(artist.name, textAlign: TextAlign.center, style: display(24)),
                  if (artist.fans > 0) Text('${artist.fans} слушателей', style: const TextStyle(color: C.muted)),
                ]),
              ),
              if (top.isNotEmpty) const SectionTitle('Популярное'),
              for (final t in top.take(10)) WebTrackTile(services: widget.services, track: t),
              if (albums.isNotEmpty) ...[
                const SectionTitle('Альбомы'),
                SizedBox(
                  height: 204,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    itemCount: albums.length,
                    itemBuilder: (_, i) => WebAlbumCard(services: widget.services, album: albums[i]),
                  ),
                ),
              ],
              const SizedBox(height: 16),
            ]);
          },
        ),
      );
}

// ───────────────────────────── Новинки ─────────────────────────────

class NewReleasesPage extends StatefulWidget {
  const NewReleasesPage({super.key, required this.services});
  final MobileServices services;
  @override
  State<NewReleasesPage> createState() => _NewReleasesPageState();
}

class _NewReleasesPageState extends State<NewReleasesPage> {
  @override
  void initState() {
    super.initState();
    unawaited(widget.services.web.loadReleases());
  }

  @override
  Widget build(BuildContext context) {
    final web = widget.services.web;
    return SubPage(
      services: widget.services,
      title: 'Новинки',
      child: AnimatedBuilder(
        animation: web,
        builder: (_, __) {
          final list = web.releases;
          return RefreshIndicator(
            color: C.accent,
            onRefresh: () => web.loadReleases(force: true),
            child: ListView(children: [
              if (web.loadingReleases)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    LinearProgressIndicator(
                      minHeight: 3,
                      color: C.accent,
                      value: web.releasesTotal > 0 ? web.releasesDone / web.releasesTotal : null,
                    ),
                    const SizedBox(height: 6),
                    Text('Проверяем исполнителей вашей библиотеки: ${web.releasesDone} из ${web.releasesTotal}',
                        style: const TextStyle(color: C.muted, fontSize: 12)),
                  ]),
                ),
              if (web.releasesError != null)
                Padding(padding: const EdgeInsets.all(20), child: Text(web.releasesError!, style: const TextStyle(color: C.danger))),
              if (list.isEmpty && !web.loadingReleases && web.releasesError == null)
                const Padding(padding: EdgeInsets.all(30), child: Center(child: Text('Новых релизов пока нет', style: TextStyle(color: C.muted)))),
              for (final r in list)
                ListTile(
                  leading: NetImage(url: r.album.cover, size: 56, radius: 10),
                  title: Text(r.album.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text('${r.album.artist} · ${r.album.typeLabel} · ${r.album.date}',
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.muted, fontSize: 13)),
                  onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(builder: (_) => WebAlbumPage(services: widget.services, albumId: r.album.id, title: r.album.title))),
                ),
              const SizedBox(height: 16),
            ]),
          );
        },
      ),
    );
  }
}

// ───────────────────────────── уведомления ─────────────────────────────

class NoticeTile extends StatelessWidget {
  const NoticeTile({required this.services, required this.notice, required this.ago});
  final MobileServices services;
  final Notice notice;
  final String ago;

  @override
  Widget build(BuildContext context) {
    final social = services.social;
    final m = social.members[notice.from];
    final who = m == null || m.name.isEmpty ? notice.from : m.name;
    final tracks = [for (final id in notice.trackIds) services.library.data.tracks[id]].whereType<Track>().toList();
    final what = tracks.isEmpty ? '' : (tracks.length == 1 ? '«${tracks.first.title}»' : '${tracks.length} треков');
    final text = switch (notice.kind) {
      NoticeKind.like => '$who оценил(а) $what',
      NoticeKind.addToPlaylist => '$who добавил(а) $what${notice.playlist == null ? '' : ' в «${notice.playlist}»'}',
      NoticeKind.share => '$who поделился(лась): $what${notice.note == null || notice.note!.isEmpty ? '' : ' — ${notice.note}'}',
    };
    return ListTile(
      leading: Icon(switch (notice.kind) {
        NoticeKind.like => Icons.favorite_rounded,
        NoticeKind.addToPlaylist => Icons.playlist_add_rounded,
        NoticeKind.share => Icons.share_rounded,
      }, color: C.accent),
      title: Text(text, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14)),
      subtitle: Text(ago, style: const TextStyle(color: C.faint, fontSize: 12)),
      onTap: tracks.isEmpty ? null : () => playTracks(context, services, tracks, 0),
    );
  }
}
