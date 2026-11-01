import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../core/library.dart';
import '../core/models.dart';
import '../mobile_main.dart';

const accent = Color(0xFF9B85F7);

class CaveyAndroid extends StatelessWidget {
  const CaveyAndroid({super.key, required this.services});
  final MobileServices services;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Cavey Player',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true, brightness: Brightness.dark,
      colorScheme: ColorScheme.fromSeed(seedColor: accent, brightness: Brightness.dark),
      scaffoldBackgroundColor: const Color(0xFF111119),
    ),
    home: AnimatedBuilder(
      animation: Listenable.merge([services.accounts, services.library]),
      builder: (_, __) {
        if (services.accounts.primary == null) return Login(services: services);
        if (!services.library.hasHub) return JoinLibrary(services: services);
        return MobileShell(services: services);
      },
    ),
  );
}

class Login extends StatefulWidget {
  const Login({super.key, required this.services});
  final MobileServices services;
  @override
  State<Login> createState() => _LoginState();
}

class _LoginState extends State<Login> {
  bool busy = false;
  String? error;
  Future<void> login() async {
    setState(() { busy = true; error = null; });
    try {
      await widget.services.accounts.signIn();
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(child: Center(child: Padding(
      padding: const EdgeInsets.all(28),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Image.asset('assets/logo.png', width: 104, height: 104),
        const SizedBox(height: 20),
        const Text('Cavey Player', style: TextStyle(
          fontSize: 30, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        const Text('Музыка с общего Google Диска'),
        const SizedBox(height: 30),
        FilledButton.icon(
          onPressed: busy || !widget.services.accounts.configured ? null : login,
          icon: const Icon(Icons.account_circle_outlined),
          label: Text(busy ? 'Подключаем…' : 'Войти через Google'),
        ),
        if (!widget.services.accounts.configured)
          const Padding(padding: EdgeInsets.all(12),
            child: Text('Для APK не задан GOOGLE_WEB_CLIENT_ID.')),
        if (error != null) Padding(
          padding: const EdgeInsets.all(12),
          child: SelectableText(error!, textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.orangeAccent)),
        ),
      ]),
    ))),
  );
}

class JoinLibrary extends StatefulWidget {
  const JoinLibrary({super.key, required this.services});
  final MobileServices services;
  @override
  State<JoinLibrary> createState() => _JoinLibraryState();
}

class _JoinLibraryState extends State<JoinLibrary> {
  final link = TextEditingController();
  bool busy = false;
  String? error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => autoJoin());
  }
  @override
  void dispose() {
    link.dispose();
    super.dispose();
  }
  Future<void> run(Future<void> Function() task) async {
    if (busy) return;
    setState(() { busy = true; error = null; });
    try {
      await task();
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }
  Future<void> autoJoin() => run(() async {
    if (!await widget.services.library.autoJoin(manual: true) && mounted) {
      setState(() => error = 'Библиотека не найдена. Вставьте ссылку на общую папку.');
    }
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Общая библиотека')),
    body: ListView(padding: const EdgeInsets.all(24), children: [
      const Icon(Icons.library_music_outlined, color: accent, size: 80),
      const SizedBox(height: 18),
      const Text('Подключи музыку с ПК', style: TextStyle(
        fontSize: 24, fontWeight: FontWeight.bold)),
      const SizedBox(height: 12),
      const Text('Cavey ищет папку Cave Player на твоём Google Диске. '
        'Можно вставить ссылку на общую папку вручную.'),
      const SizedBox(height: 24),
      TextField(controller: link,
        decoration: const InputDecoration(
          labelText: 'Ссылка на папку Google Drive',
          border: OutlineInputBorder())),
      const SizedBox(height: 12),
      FilledButton(onPressed: busy ? null : () => run(() async {
        await widget.services.library.joinHub(link.text.trim());
      }), child: const Text('Подключить')),
      OutlinedButton(onPressed: busy ? null : autoJoin,
        child: const Text('Найти автоматически')),
      if (busy) const Padding(padding: EdgeInsets.all(20),
        child: Center(child: CircularProgressIndicator())),
      if (error != null) Padding(padding: const EdgeInsets.all(14),
        child: SelectableText(error!,
          style: const TextStyle(color: Colors.orangeAccent))),
    ]),
  );
}

class MobileShell extends StatefulWidget {
  const MobileShell({super.key, required this.services});
  final MobileServices services;
  @override
  State<MobileShell> createState() => _MobileShellState();
}

class _MobileShellState extends State<MobileShell> {
  int tab = 0;
  int section = 0;
  String query = '';
  MobileServices get s => widget.services;

  Future<void> refresh() async {
    try {
      await s.library.reload();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> play(List<Track> tracks, int index) async {
    try {
      await s.player.playTracks(tracks, index);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка воспроизведения: $e')));
    }
  }

  void openPlayer() => showPlayer(context, s);
  void openTracks(String title, List<Track> tracks) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => TrackPage(services: s, title: title, tracks: tracks)));
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([s.library, s.player]),
    builder: (_, __) => Scaffold(
      appBar: AppBar(
        title: Text(['Cavey', 'Поиск', 'Медиатека'][tab],
          style: const TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          IconButton(onPressed: refresh, tooltip: 'Обновить',
            icon: const Icon(Icons.refresh)),
          PopupMenuButton<String>(
            onSelected: (value) async {
              if (value == 'logout') {
                final email = s.accounts.primary?.email;
                if (email != null) await s.accounts.remove(email);
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem<String>(enabled: false, value: 'email',
                child: Text(s.accounts.primary?.email ?? '')),
              const PopupMenuItem<String>(value: 'logout',
                child: Text('Выйти из Google')),
            ],
          ),
        ],
      ),
      body: IndexedStack(index: tab, children: [home(), search(), library()]),
      bottomNavigationBar: Column(mainAxisSize: MainAxisSize.min, children: [
        if (s.player.current != null)
          MiniPlayer(services: s, onOpen: openPlayer),
        NavigationBar(
          selectedIndex: tab,
          onDestinationSelected: (i) => setState(() => tab = i),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.home_outlined), label: 'Главная'),
            NavigationDestination(icon: Icon(Icons.search), label: 'Поиск'),
            NavigationDestination(icon: Icon(Icons.library_music_outlined),
              label: 'Медиатека'),
          ],
        ),
      ]),
    ),
  );

  Widget home() {
    final recent = s.library.recent.take(30).toList();
    final albums = s.library.albums.take(20).toList();
    return RefreshIndicator(onRefresh: refresh, child: ListView(children: [
      const SectionTitle('Альбомы'),
      SizedBox(height: 174, child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        itemCount: albums.length,
        itemBuilder: (_, i) {
          final a = albums[i];
          return InkWell(
            onTap: () => openTracks(a.title, a.tracks),
            child: SizedBox(width: 130, child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 5),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TrackCover(services: s, track: a.coverTrack, size: 118),
                  const SizedBox(height: 6),
                  Text(a.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text(a.artist, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white60, fontSize: 12)),
                ]),
            )),
          );
        },
      )),
      const SectionTitle('Недавно добавленные'),
      for (var i = 0; i < recent.length; i++)
        TrackTile(services: s, track: recent[i],
          onTap: () => play(recent, i)),
      if (recent.isEmpty) const Padding(
        padding: EdgeInsets.all(24), child: Text('Пока нет треков')),
    ]));
  }

  Widget search() {
    final q = query.trim().toLowerCase();
    final list = q.isEmpty ? <Track>[] : s.library.allTracks.where((t) =>
      t.title.toLowerCase().contains(q) ||
      t.artist.toLowerCase().contains(q) ||
      t.displayAlbum.toLowerCase().contains(q)).toList();
    return Column(children: [
      Padding(padding: const EdgeInsets.all(14),
        child: TextField(
          onChanged: (v) => setState(() => query = v),
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search),
            hintText: 'Трек, альбом или исполнитель',
            border: OutlineInputBorder(),
          ))),
      Expanded(child: q.isEmpty
        ? const Center(child: Text('Поиск по общей библиотеке'))
        : TrackList(services: s, tracks: list, onPlay: play)),
    ]);
  }

  Widget library() {
    const labels = ['Все', 'Любимые', 'Альбомы', 'Плейлисты'];
    return Column(children: [
      SizedBox(height: 58, child: ListView(scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        children: [
          for (var i = 0; i < labels.length; i++)
            Padding(padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(label: Text(labels[i]),
                selected: section == i,
                onSelected: (_) => setState(() => section = i))),
        ])),
      Expanded(child: switch (section) {
        0 => TrackList(services: s, tracks: s.library.allTracks, onPlay: play),
        1 => TrackList(services: s, tracks: s.library.liked, onPlay: play),
        2 => ListView.builder(itemCount: s.library.albums.length,
          itemBuilder: (_, i) {
            final a = s.library.albums[i];
            return ListTile(
              leading: TrackCover(services: s, track: a.coverTrack, size: 50),
              title: Text(a.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(a.artist),
              onTap: () => openTracks(a.title, a.tracks),
            );
          }),
        _ => ListView.builder(itemCount: s.library.data.playlists.length,
          itemBuilder: (_, i) {
            final p = s.library.data.playlists[i];
            final tracks = p.items.map((id) => s.library.data.tracks[id])
              .whereType<Track>().toList();
            return ListTile(
              leading: const Icon(Icons.queue_music),
              title: Text(p.name),
              subtitle: Text(tracks.length.toString() + ' треков'),
              onTap: () => openTracks(p.name, tracks),
            );
          }),
      }),
    ]);
  }
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.title, {super.key});
  final String title;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(18, 20, 18, 12),
    child: Text(title, style: const TextStyle(
      fontSize: 20, fontWeight: FontWeight.bold)));
}

class TrackList extends StatelessWidget {
  const TrackList({super.key, required this.services,
    required this.tracks, required this.onPlay});
  final MobileServices services;
  final List<Track> tracks;
  final Future<void> Function(List<Track>, int) onPlay;
  @override
  Widget build(BuildContext context) => ListView.builder(
    itemCount: tracks.length,
    itemBuilder: (_, i) => TrackTile(
      services: services, track: tracks[i],
      onTap: () => onPlay(tracks, i)),
  );
}

class TrackTile extends StatelessWidget {
  const TrackTile({super.key, required this.services,
    required this.track, required this.onTap});
  final MobileServices services;
  final Track track;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final liked = services.library.isLiked(track.id);
    return ListTile(
      leading: TrackCover(services: services, track: track, size: 52),
      title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(track.displayArtist, maxLines: 1,
        overflow: TextOverflow.ellipsis),
      onTap: onTap,
      trailing: IconButton(
        onPressed: () => services.library.toggleLike(track.id),
        icon: Icon(liked ? Icons.favorite : Icons.favorite_border,
          color: liked ? accent : Colors.white54),
      ),
    );
  }
}

class TrackCover extends StatefulWidget {
  const TrackCover({super.key, required this.services,
    required this.track, required this.size});
  final MobileServices services;
  final Track track;
  final double size;
  @override
  State<TrackCover> createState() => _TrackCoverState();
}
class _TrackCoverState extends State<TrackCover> {
  late Future<Uint8List?> cover;
  @override
  void initState() {
    super.initState();
    load();
  }
  @override
  void didUpdateWidget(TrackCover old) {
    super.didUpdateWidget(old);
    if (old.track.id != widget.track.id || old.size != widget.size) load();
  }
  void load() {
    cover = widget.services.covers.forTrack(
      widget.track, px: (widget.size * 2).round());
  }
  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(9),
    child: SizedBox(width: widget.size, height: widget.size,
      child: FutureBuilder<Uint8List?>(
        future: cover,
        builder: (_, state) => state.hasData
          ? Image.memory(state.data!, fit: BoxFit.cover)
          : const ColoredBox(color: Color(0xFF353247),
            child: Icon(Icons.music_note, color: Colors.white54)),
      )),
  );
}

class TrackPage extends StatelessWidget {
  const TrackPage({super.key, required this.services,
    required this.title, required this.tracks});
  final MobileServices services;
  final String title;
  final List<Track> tracks;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(title)),
    body: TrackList(services: services, tracks: tracks, onPlay: (list, i) async {
      try { await services.player.playTracks(list, i); }
      catch (e) {
        if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString())));
      }
    }),
    bottomNavigationBar: AnimatedBuilder(
      animation: services.player,
      builder: (_, __) => services.player.current == null
        ? const SizedBox.shrink()
        : MiniPlayer(services: services, onOpen: () => showPlayer(context, services)),
    ),
  );
}

void showPlayer(BuildContext context, MobileServices services) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: const Color(0xFF181724),
    builder: (_) => FractionallySizedBox(
      heightFactor: 0.92, child: FullPlayer(services: services)),
  );
}

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key, required this.services, required this.onOpen});
  final MobileServices services;
  final VoidCallback onOpen;
  @override
  Widget build(BuildContext context) {
    final p = services.player;
    final t = p.current;
    if (t == null) return const SizedBox.shrink();
    return Material(color: const Color(0xFF252236),
      child: InkWell(onTap: onOpen,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ValueListenableBuilder<Duration>(valueListenable: p.position,
            builder: (_, pos, __) => LinearProgressIndicator(
              value: p.duration.inMilliseconds <= 0 ? 0
                : (pos.inMilliseconds / p.duration.inMilliseconds).clamp(0.0, 1.0),
              minHeight: 2)),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Row(children: [
              TrackCover(services: services, track: t, size: 44),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                  Text(t.displayArtist, maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: Colors.white60)),
                ])),
              IconButton(onPressed: p.toggle,
                icon: Icon(p.playing ? Icons.pause : Icons.play_arrow)),
              IconButton(onPressed: p.next, icon: const Icon(Icons.skip_next)),
            ])),
        ])),
    );
  }
}

class FullPlayer extends StatelessWidget {
  const FullPlayer({super.key, required this.services});
  final MobileServices services;

  static String time(Duration d) {
    final seconds = d.inSeconds.clamp(0, 999999);
    return (seconds ~/ 60).toString() + ':' +
      (seconds % 60).toString().padLeft(2, '0');
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([services.player, services.library]),
    builder: (_, __) {
      final p = services.player;
      final t = p.current;
      if (t == null) return const Center(child: Text('Ничего не играет'));
      return SafeArea(child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 25),
        child: Column(children: [
          Align(alignment: Alignment.centerLeft,
            child: IconButton(onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.keyboard_arrow_down, size: 32))),
          const Spacer(),
          LayoutBuilder(builder: (context, constraints) => Center(
            child: TrackCover(services: services, track: t,
              size: constraints.maxWidth.clamp(0.0, 340.0)))),
          const Spacer(),
          Row(children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t.title, maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 23, fontWeight: FontWeight.bold)),
                Text(t.displayArtist, style: const TextStyle(color: Colors.white60)),
              ])),
            IconButton(
              onPressed: () => services.library.toggleLike(t.id),
              icon: Icon(services.library.isLiked(t.id)
                ? Icons.favorite : Icons.favorite_border, color: accent)),
          ]),
          const SizedBox(height: 16),
          ValueListenableBuilder<Duration>(
            valueListenable: p.position,
            builder: (_, position, __) {
              final max = p.duration.inMilliseconds.toDouble();
              final value = max <= 0 ? 0.0
                : position.inMilliseconds.toDouble().clamp(0.0, max);
              return Column(children: [
                Slider(value: value, max: max <= 0 ? 1 : max,
                  onChanged: max <= 0 ? null : (v) =>
                    p.seek(Duration(milliseconds: v.round()))),
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [Text(time(position)), Text(time(p.duration))]),
              ]);
            }),
          const SizedBox(height: 10),
          Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
            IconButton(onPressed: p.previous,
              icon: const Icon(Icons.skip_previous, size: 38)),
            IconButton.filled(onPressed: p.toggle,
              icon: Icon(p.playing ? Icons.pause : Icons.play_arrow, size: 43)),
            IconButton(onPressed: p.next,
              icon: const Icon(Icons.skip_next, size: 38)),
          ]),
          const Spacer(),
        ]),
      ));
    },
  );
}
