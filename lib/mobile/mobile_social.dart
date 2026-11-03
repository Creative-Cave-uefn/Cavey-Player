import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/models.dart';
import '../core/social.dart';
import '../mobile_main.dart';
import '../ui/theme.dart';
import 'mobile_home.dart';
import 'mobile_pages.dart';

String plural(int n, String one, String few, String many) {
  final m10 = n % 10, m100 = n % 100;
  if (m10 == 1 && m100 != 11) return one;
  if (m10 >= 2 && m10 <= 4 && (m100 < 12 || m100 > 14)) return few;
  return many;
}

String countTracks(int n) => '$n ${plural(n, 'трек', 'трека', 'треков')}';

String timeAgo(DateTime t) {
  final d = Member.nowSynced.difference(t.toUtc());
  if (d.inMinutes < 2) return 'только что';
  if (d.inMinutes < 60) return '${d.inMinutes} мин назад';
  if (d.inHours < 24) return '${d.inHours} ч назад';
  if (d.inDays < 7) return '${d.inDays} дн назад';
  return '${t.day.toString().padLeft(2, '0')}.${t.month.toString().padLeft(2, '0')}';
}

// ───────────────────────────── аватарка ─────────────────────────────

/// Аватарка человека: своя картинка из профиля или цветной кружок с буквой, как на ПК
class MobileAvatar extends StatefulWidget {
  const MobileAvatar({super.key, required this.services, required this.email, required this.size});
  final MobileServices services;
  final String email;
  final double size;
  @override
  State<MobileAvatar> createState() => _MobileAvatarState();
}

class _MobileAvatarState extends State<MobileAvatar> {
  Uint8List? bytes;
  String? loaded;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    load();
  }

  @override
  void didUpdateWidget(MobileAvatar old) {
    super.didUpdateWidget(old);
    load();
  }

  void load() {
    final id = widget.services.library.profileAvatar(widget.email);
    if (id == null || id.isEmpty) {
      if (bytes != null || loaded != null) {
        bytes = null;
        loaded = null;
      }
      return;
    }
    if (id == loaded) return;
    loaded = id;
    final px = (widget.size * MediaQuery.devicePixelRatioOf(context)).round();
    final c = widget.services.covers;
    bytes = c.peekFile(id, px: px);
    if (bytes == null) {
      c.forFile(id, px: px).then((b) {
        if (mounted && loaded == id && b != null) setState(() => bytes = b);
      }).catchError((_) {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final lib = widget.services.library;
    final name = lib.nameOf(widget.email);
    final b = bytes;
    return ClipOval(
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: b != null
            ? Image.memory(b, fit: BoxFit.cover, gaplessPlayback: true, errorBuilder: (_, __, ___) => _letter(name))
            : _letter(name),
      ),
    );
  }

  Widget _letter(String name) => ColoredBox(
        color: friendColor(widget.email),
        child: Center(
          child: Text(name.isEmpty ? '?' : name.characters.first.toUpperCase(),
              style: TextStyle(color: const Color(0xFF14141B), fontWeight: FontWeight.w700, fontSize: widget.size * 0.42)),
        ),
      );
}

// ───────────────────────────── компания ─────────────────────────────

class CompanyPage extends StatelessWidget {
  const CompanyPage({super.key, required this.services});
  final MobileServices services;

  @override
  Widget build(BuildContext context) => SubPage(services: services, title: 'Компания', child: CompanyView(services: services));
}

/// Содержимое «Компании»: и как отдельная страница, и как вкладка нижней панели (embedded)
class CompanyView extends StatelessWidget {
  const CompanyView({super.key, required this.services, this.embedded = false});
  final MobileServices services;
  final bool embedded;

  void openUser(BuildContext context, String email) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => UserPage(services: services, email: email)));

  @override
  Widget build(BuildContext context) {
    final social = services.social;
    final lib = services.library;
    return AnimatedBuilder(
        animation: Listenable.merge([social, lib]),
        builder: (_, __) {
          final people = [for (final e in lib.people) if (e != lib.me) e]..sort((a, b) => lib.nameOf(a).toLowerCase().compareTo(lib.nameOf(b).toLowerCase()));
          final now = social.listeningNow;
          final chart = social.chart();
          final feed = social.feed.take(40).toList();
          final notices = social.notices.take(20).toList();
          final following = social.following;
          return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
            if (embedded)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Компания', style: display(34)),
                  const SizedBox(height: 6),
                  const Text('Что слушают друзья и что нового в библиотеке', style: TextStyle(fontSize: 14.5, color: C.muted)),
                ]),
              )
            else
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                child: Text('Что слушают друзья, что у вас в чарте и что нового в библиотеке.', style: const TextStyle(color: C.muted, height: 1.4)),
              ),
            if (following != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                child: Glass(
                  radius: 16,
                  color: C.surface,
                  child: ListTile(
                    leading: Icon(Icons.headphones_rounded, color: C.accent),
                    title: Text('Слушаете вместе с ${lib.firstNameOf(following)}'),
                    trailing: TextButton(onPressed: social.stopFollowing, child: Text('Выйти', style: TextStyle(color: C.accent))),
                  ),
                ),
              ),
            const SectionTitle('Участники'),
            if (people.isEmpty)
              const Padding(padding: EdgeInsets.fromLTRB(20, 0, 20, 8), child: Text('Пока никого нет', style: TextStyle(color: C.muted))),
            if (people.isNotEmpty)
              SizedBox(
                height: 104,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  itemCount: people.length,
                  itemBuilder: (_, i) {
                    final e = people[i];
                    final live = social.members[e]?.live ?? false;
                    return InkWell(
                      borderRadius: BorderRadius.circular(14),
                      onTap: () => openUser(context, e),
                      child: SizedBox(
                        width: 82,
                        child: Column(children: [
                          Stack(children: [
                            MobileAvatar(services: services, email: e, size: 64),
                            if (live)
                              Positioned(
                                right: 0,
                                bottom: 0,
                                child: Container(
                                    width: 15, height: 15, decoration: BoxDecoration(color: const Color(0xFF5BD66F), shape: BoxShape.circle, border: Border.all(color: C.bg, width: 2.5))),
                              ),
                          ]),
                          const SizedBox(height: 6),
                          Text(lib.firstNameOf(e), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                        ]),
                      ),
                    );
                  },
                ),
              ),
            const SectionTitle('Сейчас слушают'),
            if (now.isEmpty) const Padding(padding: EdgeInsets.fromLTRB(20, 0, 20, 8), child: Text('Сейчас никто ничего не слушает.', style: TextStyle(color: C.faint))),
            for (final m in now) _ListenerCard(services: services, member: m, onOpen: () => openUser(context, m.email)),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 22, 12, 6),
              child: Row(children: [
                Expanded(child: Text('Чарт недели', style: display(20))),
                if (chart.isNotEmpty)
                  OutlinedButton.icon(
                    onPressed: () => playTracks(context, services, [for (final e in chart) e.track], 0),
                    icon: const Icon(Icons.play_arrow_rounded, size: 18),
                    label: const Text('Слушать'),
                  ),
              ]),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text('Самое прослушиваемое у всех вместе за 7 дней. Считается, если трек играл дольше 30 секунд.', style: TextStyle(color: C.faint, fontSize: 12, height: 1.4)),
            ),
            if (chart.isEmpty) const Padding(padding: EdgeInsets.fromLTRB(20, 4, 20, 8), child: Text('Пока ничего не прослушано.', style: TextStyle(color: C.faint))),
            for (var i = 0; i < chart.length; i++) _ChartRow(services: services, rank: i + 1, entry: chart[i], all: chart),
            if (notices.isNotEmpty) const SectionTitle('Вам'),
            for (final n in notices) NoticeTile(services: services, notice: n, ago: timeAgo(n.at)),
            const SectionTitle('Лента'),
            if (feed.isEmpty) const Padding(padding: EdgeInsets.fromLTRB(20, 0, 20, 8), child: Text('Событий пока нет.', style: TextStyle(color: C.faint))),
            for (final e in feed) _FeedRow(services: services, event: e),
          ]);
        },
    );
  }
}

class _ListenerCard extends StatelessWidget {
  const _ListenerCard({required this.services, required this.member, required this.onOpen});
  final MobileServices services;
  final Member member;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final social = services.social;
    final lib = services.library;
    final n = member.now!;
    final track = lib.data.tracks[n.trackId];
    final following = social.following == member.email;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: Glass(
        radius: 16,
        color: C.surface,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            GestureDetector(onTap: onOpen, child: MobileAvatar(services: services, email: member.email, size: 46)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(lib.firstNameOf(member.email), style: const TextStyle(fontWeight: FontWeight.w700)),
                Text('${n.title} — ${n.artist}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.muted, fontSize: 13)),
              ]),
            ),
            if (track != null)
              IconButton(tooltip: 'Включить у себя', onPressed: () => playTracks(context, services, [track], 0), icon: const Icon(Icons.play_circle_outline_rounded, size: 28, color: C.text)),
            IconButton(
              tooltip: following ? 'Перестать слушать вместе' : 'Слушать вместе',
              onPressed: () => following ? social.stopFollowing() : social.follow(member.email),
              icon: Icon(following ? Icons.headphones_rounded : Icons.headphones_outlined, color: following ? C.accent : C.text),
            ),
          ]),
        ),
      ),
    );
  }
}

class _ChartRow extends StatelessWidget {
  const _ChartRow({required this.services, required this.rank, required this.entry, required this.all});
  final MobileServices services;
  final int rank;
  final ChartEntry entry;
  final List<ChartEntry> all;

  @override
  Widget build(BuildContext context) {
    final t = entry.track;
    final lib = services.library;
    return InkWell(
      onTap: () => playTracks(context, services, [for (final e in all) e.track], rank - 1),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
        child: Row(children: [
          SizedBox(width: 30, child: Text('$rank', style: display(16, color: rank <= 3 ? C.accent : C.faint))),
          TrackCover(services: services, track: t, size: 46),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
              Text(t.displayArtist, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.muted, fontSize: 13)),
            ]),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 22 + (entry.listeners.take(3).length - 1).clamp(0, 2) * 13.0,
            height: 24,
            child: Stack(children: [
              for (final (i, e) in entry.listeners.take(3).indexed)
                Positioned(
                  left: i * 13.0,
                  child: Container(
                    padding: const EdgeInsets.all(1.5),
                    decoration: const BoxDecoration(color: C.bg, shape: BoxShape.circle),
                    child: MobileAvatar(services: services, email: e, size: 19),
                  ),
                ),
            ]),
          ),
          const SizedBox(width: 8),
          Text('${entry.plays}', style: const TextStyle(color: C.faint, fontSize: 12)),
          const SizedBox(width: 2),
          Icon(Icons.headphones_rounded, size: 13, color: C.faint),
          if (lib.isLiked(t.id)) Padding(padding: const EdgeInsets.only(left: 8), child: Icon(Icons.favorite_rounded, size: 15, color: C.accent)),
        ]),
      ),
    );
  }
}

class _FeedRow extends StatelessWidget {
  const _FeedRow({required this.services, required this.event});
  final MobileServices services;
  final FeedEvent event;

  @override
  Widget build(BuildContext context) {
    final lib = services.library;
    final who = lib.firstNameOf(event.email);
    final d = event.data;
    String text;
    VoidCallback? onTap;
    IconData icon;
    switch (event.kind) {
      case 'upload':
        final n = (d['n'] as num?)?.toInt() ?? 0;
        text = '$who добавил(а) ${countTracks(n)} в «${d['folder'] ?? 'Cave Player'}»';
        icon = Icons.library_add_rounded;
      case 'playlist':
        final p = lib.playlist('${d['id']}');
        text = '$who создал(а) плейлист «${p?.name ?? d['name']}»';
        icon = Icons.queue_music_rounded;
        if (p != null) {
          onTap = () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => CollectionPage(services: services, title: p.name, tracks: lib.playlistTracks(p.id))));
        }
      case 'like':
        final t = lib.data.tracks['${d['track']}'];
        if (t == null) return const SizedBox.shrink();
        text = '$who нравится «${t.title}» — ${t.displayArtist}';
        icon = Icons.favorite_rounded;
        onTap = () => playTracks(context, services, [t], 0);
      case 'share':
        final t = lib.data.tracks[lib.data.resolve('${d['track']}')];
        if (t == null) return const SizedBox.shrink();
        final to = [for (final x in (d['to'] as List? ?? const [])) '$x'];
        final whom = to.length == 1 ? lib.firstNameOf(to.first) : 'друзьями (${to.length})';
        text = '$who поделился(ась) «${t.title}» — ${t.displayArtist} с $whom';
        icon = Icons.share_rounded;
        onTap = () => playTracks(context, services, [t], 0);
      case 'addpl':
        final name = d['name'];
        final first = (d['tracks'] as List? ?? const []).isEmpty ? null : lib.data.tracks[lib.data.resolve('${(d['tracks'] as List).first}')];
        if (name is! String || name.isEmpty || first == null) return const SizedBox.shrink();
        final n = (d['tracks'] as List).length;
        text = n == 1 ? '$who добавил(а) «${first.title}» в плейлист «$name»' : '$who добавил(а) в плейлист «$name» треков: $n';
        icon = Icons.playlist_add_rounded;
      default:
        return const SizedBox.shrink();
    }
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 20),
        child: Row(children: [
          Icon(icon, size: 18, color: friendColor(event.email)),
          const SizedBox(width: 14),
          Expanded(child: Text(text, style: const TextStyle(height: 1.3, fontSize: 14))),
          const SizedBox(width: 10),
          Text(timeAgo(event.at), style: const TextStyle(color: C.faint, fontSize: 11)),
        ]),
      ),
    );
  }
}

// ───────────────────────────── страница человека ─────────────────────────────

List<Track> likedBy(MobileServices s, String email) {
  final lib = s.library;
  final list = [for (final t in lib.allTracks) if (lib.data.likes[t.id]?.contains(email) ?? false) t];
  list.sort((x, y) => s.social.playsOf(y.id, email: email).compareTo(s.social.playsOf(x.id, email: email)));
  return list;
}

List<Track> uploadedBy(MobileServices s, String email) {
  String when(Track t) => t.added.isNotEmpty ? t.added : t.modified;
  final list = [for (final t in s.library.allTracks) if (t.by == email) t];
  list.sort((x, y) => when(y).compareTo(when(x)));
  return list;
}

/// Страница человека: шапка с баннером, статистика прослушивания, любимые треки, загрузки, плейлисты.
/// Для себя — «Моя страница»: можно сменить ник и открыть настройки
class UserPage extends StatelessWidget {
  const UserPage({super.key, required this.services, required this.email, this.onSettings});
  final MobileServices services;
  final String email;
  final VoidCallback? onSettings;

  void openList(BuildContext context, String title, List<Track> tracks) => Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => CollectionPage(services: services, title: title, tracks: tracks)));

  Future<void> editNick(BuildContext context) async {
    final lib = services.library;
    final c = TextEditingController(text: lib.profileNick(email) ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        backgroundColor: C.panel,
        title: const Text('Мой профиль'),
        content: TextField(
          controller: c,
          maxLength: 24,
          decoration: InputDecoration(labelText: 'Ник', hintText: lib.nameOf(email), helperText: 'Его увидят все друзья. Пусто — имя из Google.'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Отмена')),
          TextButton(onPressed: () => Navigator.pop(d, true), child: Text('Сохранить', style: TextStyle(color: C.accent))),
        ],
      ),
    );
    if (ok == true) lib.setProfile(nick: c.text.trim());
    c.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = services;
    final lib = s.library;
    final social = s.social;
    final mine = email == lib.me;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        actions: [
          if (mine) IconButton(tooltip: 'Изменить ник', onPressed: () => editNick(context), icon: const Icon(Icons.edit_rounded)),
          if (mine && onSettings != null) IconButton(tooltip: 'Настройки', onPressed: onSettings, icon: const Icon(Icons.settings_rounded)),
        ],
      ),
      body: AnimatedBuilder(
        animation: Listenable.merge([lib, social, s.player]),
        builder: (context, _) {
          final name = lib.nameOf(email);
          final liked = likedBy(s, email);
          final uploads = uploadedBy(s, email);
          final lists = [for (final p in lib.visiblePlaylists) if (p.by == email) p];
          final m = social.members[email];
          final favs = lib.favoritesOf(email);
          String? subtitle;
          if (m != null && m.live && m.now != null) {
            subtitle = 'Сейчас слушает: ${m.now!.title} — ${m.now!.artist}';
          } else if (mine) {
            subtitle = 'Это ваша страница';
          }
          final hasStats = m != null && (m.timeTotals.isNotEmpty || m.totals.isNotEmpty || m.plays.isNotEmpty);
          final nothing = liked.isEmpty && uploads.isEmpty && lists.isEmpty;
          return ListView(padding: EdgeInsets.zero, children: [
            _Banner(services: s, email: email, name: name, subtitle: subtitle),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
              child: Row(children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: liked.isEmpty && uploads.isEmpty
                        ? null
                        : () {
                            final p = s.player;
                            if (p.shuffle) p.toggleShuffle();
                            playTracks(context, s, liked.isNotEmpty ? liked : uploads, 0);
                          },
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: const Text('Играть'),
                  ),
                ),
                if (!mine && m != null && m.live) ...[
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => social.following == email ? social.stopFollowing() : social.follow(email),
                      icon: Icon(social.following == email ? Icons.headphones_rounded : Icons.headphones_outlined),
                      label: Text(social.following == email ? 'Выйти' : 'Слушать вместе'),
                    ),
                  ),
                ],
              ]),
            ),
            if (hasStats) ListenStats(services: s, email: email),
            if (nothing)
              const Padding(
                padding: EdgeInsets.fromLTRB(24, 30, 24, 10),
                child: Text('Пока ничего: ни любимых треков, ни загрузок, ни плейлистов.', textAlign: TextAlign.center, style: TextStyle(color: C.muted)),
              ),
            if (liked.isNotEmpty) ...[
              SectionTitle('Любимые треки', onMore: () => openList(context, 'Любимые: $name', liked)),
              for (var i = 0; i < math.min(liked.length, 6); i++) TrackTile(services: s, track: liked[i], onTap: () => playTracks(context, s, liked, i)),
            ],
            if (uploads.isNotEmpty) ...[
              SectionTitle('Загрузил(а): ${countTracks(uploads.length)}', onMore: () => openList(context, 'Загрузки: $name', uploads)),
              for (var i = 0; i < math.min(uploads.length, 6); i++) TrackTile(services: s, track: uploads[i], onTap: () => playTracks(context, s, uploads, i)),
            ],
            if (lists.isNotEmpty) ...[
              const SectionTitle('Плейлисты'),
              SizedBox(
                height: 200,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  itemCount: lists.length,
                  itemBuilder: (_, i) {
                    final p = lists[i];
                    final tracks = lib.playlistTracks(p.id);
                    return _Tile(
                      services: s,
                      cover: tracks.isEmpty ? null : tracks.first,
                      title: p.name,
                      subtitle: countTracks(p.items.length),
                      onTap: () => openList(context, p.name, tracks),
                    );
                  },
                ),
              ),
            ],
            if (favs.albums.isNotEmpty || favs.playlists.isNotEmpty || favs.artists.isNotEmpty) ...[
              const SectionTitle('Любимое'),
              SizedBox(
                height: 200,
                child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 14), children: [
                  for (final a in favs.albums)
                    _Tile(services: s, cover: a.coverTrack, title: a.title, subtitle: 'Альбом · ${a.artist}', onTap: () => openList(context, a.title, a.tracks)),
                  for (final p in favs.playlists)
                    () {
                      final tracks = lib.playlistTracks(p.id);
                      return _Tile(
                          services: s,
                          cover: tracks.isEmpty ? null : tracks.first,
                          title: p.name,
                          subtitle: 'Плейлист · ${lib.firstNameOf(p.by)}',
                          onTap: () => openList(context, p.name, tracks));
                    }(),
                  for (final a in favs.artists)
                    _Tile(services: s, cover: a.coverTrack, title: a.name, subtitle: 'Исполнитель', round: true, onTap: () => openList(context, a.name, a.tracks)),
                ]),
              ),
            ],
            const SizedBox(height: 28),
          ]);
        },
      ),
      bottomNavigationBar: AnimatedBuilder(
        animation: services.player,
        builder: (_, __) => services.player.current == null ? const SizedBox.shrink() : MiniPlayer(services: services, onOpen: () => showPlayer(context, services)),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.services, required this.cover, required this.title, required this.subtitle, required this.onTap, this.round = false});
  final MobileServices services;
  final Track? cover;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool round;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: 140,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              cover == null
                  ? Container(
                      width: 130,
                      height: 130,
                      decoration: BoxDecoration(color: C.raised, borderRadius: BorderRadius.circular(round ? 65 : 14)),
                      child: const Icon(Icons.queue_music_rounded, color: C.faint, size: 38))
                  : TrackCover(services: services, track: cover!, size: 130, radius: round ? 65 : 14),
              const SizedBox(height: 8),
              Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
              Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.muted, fontSize: 12)),
            ]),
          ),
        ),
      );
}

/// Шапка: баннер человека (или его цвет), поверх — аватарка, имя и подпись
class _Banner extends StatefulWidget {
  const _Banner({required this.services, required this.email, required this.name, this.subtitle});
  final MobileServices services;
  final String email;
  final String name;
  final String? subtitle;
  @override
  State<_Banner> createState() => _BannerState();
}

class _BannerState extends State<_Banner> {
  Uint8List? bytes;
  String? loaded;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    load();
  }

  void load() {
    final id = widget.services.library.profileBanner(widget.email);
    if (id == null || id.isEmpty) {
      bytes = null;
      loaded = null;
      return;
    }
    if (id == loaded) return;
    loaded = id;
    final c = widget.services.covers;
    bytes = c.peekFile(id, px: 640);
    if (bytes == null) {
      c.forFile(id, px: 640).then((b) {
        if (mounted && loaded == id && b != null) setState(() => bytes = b);
      }).catchError((_) {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = friendColor(widget.email);
    final top = MediaQuery.paddingOf(context).top;
    final b = bytes;
    return SizedBox(
      height: 250 + top,
      child: Stack(fit: StackFit.expand, children: [
        if (b != null)
          Image.memory(b, fit: BoxFit.cover, gaplessPlayback: true, errorBuilder: (_, __, ___) => const SizedBox.shrink())
        else
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(center: const Alignment(-0.3, -0.8), radius: 1.4, colors: [color.withValues(alpha: 0.8), color.withValues(alpha: 0.25), Colors.transparent]),
            ),
          ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0x66000000), Color(0x00000000), Color(0xB3000000)], stops: [0, 0.4, 1]),
          ),
        ),
        Positioned(
          left: 20,
          right: 20,
          bottom: 14,
          child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            DecoratedBox(
              decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: const Color(0x66FFFFFF), width: 2), boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 18)]),
              child: MobileAvatar(services: widget.services, email: widget.email, size: 96),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(widget.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: display(28)),
                if (widget.subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(widget.subtitle!, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.muted, fontSize: 13)),
                  ),
              ]),
            ),
          ]),
        ),
      ]),
    );
  }
}

/// Статистика прослушивания: плашки и столбики по дням за 30 дней
class ListenStats extends StatelessWidget {
  const ListenStats({super.key, required this.services, required this.email});
  final MobileServices services;
  final String email;

  @override
  Widget build(BuildContext context) {
    final s = services.social;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final total = s.listened(email);
    final week = s.listened(email, since: today.subtract(const Duration(days: 6)));
    final month = s.listened(email, since: today.subtract(const Duration(days: 29)));
    final days = s.listenedByDay(email);
    final top = s.topArtist(email);
    final peak = days.fold<int>(0, (a, d) => math.max(a, d.$2.inMinutes));

    Widget tile(String label, String value) => Glass(
          radius: 14,
          color: C.surface,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: display(20)),
              const SizedBox(height: 2),
              Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.muted, fontSize: 12)),
            ]),
          ),
        );

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SectionTitle('Статистика'),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(children: [
          Row(children: [
            Expanded(child: tile('наслушано всего', formatListened(total))),
            const SizedBox(width: 10),
            Expanded(child: tile('за неделю', formatListened(week))),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: tile('за месяц', formatListened(month))),
            const SizedBox(width: 10),
            Expanded(child: tile('любимый исполнитель месяца', top ?? '—')),
          ]),
          const SizedBox(height: 14),
          SizedBox(
            height: 96,
            child: LayoutBuilder(builder: (context, box) {
              final room = math.max(0.0, box.maxHeight - 3);
              return Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                for (final (day, d) in days)
                  Expanded(
                    child: GestureDetector(
                      onTap: () {
                        HapticFeedback.selectionClick();
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                            duration: const Duration(seconds: 1),
                            content: Text('${day.day.toString().padLeft(2, '0')}.${day.month.toString().padLeft(2, '0')}: ${formatListened(d)}')));
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 1.2),
                        child: Container(
                          height: peak == 0 ? 3 : (3 + room * d.inMinutes / peak),
                          decoration: BoxDecoration(color: d.inMinutes == 0 ? C.line : C.accent.withValues(alpha: 0.85), borderRadius: BorderRadius.circular(3)),
                        ),
                      ),
                    ),
                  ),
              ]);
            }),
          ),
          const SizedBox(height: 6),
          const Row(children: [
            Text('30 дней назад', style: TextStyle(color: C.faint, fontSize: 11)),
            Spacer(),
            Text('сегодня', style: TextStyle(color: C.faint, fontSize: 11)),
          ]),
        ]),
      ),
    ]);
  }
}

/// Нужен там, где человека показываем кружком и именем в одну строку
Widget personChip(MobileServices s, String email) => Row(mainAxisSize: MainAxisSize.min, children: [
      MobileAvatar(services: s, email: email, size: 22),
      const SizedBox(width: 8),
      Text(s.library.firstNameOf(email)),
    ]);
