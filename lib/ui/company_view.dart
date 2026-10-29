import 'package:flutter/material.dart';

import '../app.dart';
import '../core/social.dart';
import 'shell.dart';
import 'theme.dart';
import 'widgets.dart';

String timeAgo(DateTime t) {
  final d = DateTime.now().toUtc().difference(t.toUtc());
  if (d.inMinutes < 1) return 'только что';
  if (d.inMinutes < 60) return '${d.inMinutes} мин назад';
  if (d.inHours < 24) return '${d.inHours} ч назад';
  if (d.inDays == 1) return 'вчера';
  if (d.inDays < 7) return '${d.inDays} ${plural(d.inDays, 'день', 'дня', 'дней')} назад';
  final l = t.toLocal();
  return '${l.day.toString().padLeft(2, '0')}.${l.month.toString().padLeft(2, '0')}';
}

/// Раздел «Компания»: кто что слушает, чарт недели, лента событий
class CompanyPage extends StatelessWidget {
  final bool compact;
  const CompanyPage({super.key, required this.compact});

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final social = app.social;
    final pad = compact ? 20.0 : 36.0;
    return ListenableBuilder(
      listenable: Listenable.merge([social, app.lib]),
      builder: (context, _) {
        final now = social.listeningNow;
        final chart = social.chart();
        final feed = social.feed;
        return ListView(padding: EdgeInsets.fromLTRB(pad, 34, pad, 40), children: [
          Text('Компания', style: display(36, weight: FontWeight.w700)),
          const SizedBox(height: 10),
          const Text('Что слушают друзья, что у вас в чарте и что нового в библиотеке.',
              style: TextStyle(color: C.muted, fontSize: 15)),
          const SizedBox(height: 32),
          Text('Сейчас слушают', style: display(20)),
          const SizedBox(height: 6),
          Text(
            social.pollError != null
                ? 'Не получилось обновить статусы: ${social.pollError}'
                : social.lastPoll == null
                    ? 'Загружаю статусы друзей…'
                    : 'Обновляется раз в 15 секунд, последний раз в ${TimeOfDay.fromDateTime(social.lastPoll!).format(context)}. '
                        'Друзей с Cave Player: ${social.friends.length}.',
            style: TextStyle(color: social.pollError != null ? C.danger : C.faint, fontSize: 13),
          ),
          const SizedBox(height: 14),
          if (now.isEmpty)
            const Text('Сейчас никто ничего не слушает.', style: TextStyle(color: C.faint))
          else
            Wrap(spacing: 14, runSpacing: 14, children: [for (final m in now) _ListenerCard(member: m)]),
          const SizedBox(height: 40),
          Row(children: [
            Expanded(child: Text('Чарт недели', style: display(20))),
            if (chart.isNotEmpty)
              OutlinedButton.icon(
                onPressed: () => app.player.playTracks([for (final e in chart) e.track], 0),
                icon: const Icon(Icons.play_arrow_rounded, size: 18),
                label: const Text('Слушать чарт'),
              ),
          ]),
          const SizedBox(height: 6),
          const Text('Самое прослушиваемое у всех вместе за 7 дней. Считается, если трек играл дольше 30 секунд.',
              style: TextStyle(color: C.faint, fontSize: 13)),
          const SizedBox(height: 12),
          if (chart.isEmpty) const Text('Пока ничего не прослушано.', style: TextStyle(color: C.faint)),
          for (var i = 0; i < chart.length; i++) _ChartRow(rank: i + 1, entry: chart[i], all: chart),
          const SizedBox(height: 40),
          Text('Лента', style: display(20)),
          const SizedBox(height: 12),
          if (feed.isEmpty) const Text('Событий пока нет.', style: TextStyle(color: C.faint)),
          for (final e in feed) _FeedRow(event: e),
        ]);
      },
    );
  }
}

class _ListenerCard extends StatelessWidget {
  final Member member;
  const _ListenerCard({required this.member});

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final now = member.now!;
    final track = app.lib.data.tracks[now.trackId];
    final following = app.social.following == member.email;
    return Container(
      width: 300,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: C.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: following ? C.accent : C.line),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Avatar(email: member.email, name: member.name, size: 26),
          const SizedBox(width: 10),
          Expanded(child: Text(member.name.isEmpty ? member.email : member.name, overflow: TextOverflow.ellipsis)),
          Text(member.live ? 'слушает' : 'на паузе', style: TextStyle(color: member.live ? C.accent : C.faint, fontSize: 12)),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          CoverImage(track: track, size: 52, radius: 6),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(now.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 3),
              Text(now.artist, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.muted, fontSize: 13)),
            ]),
          ),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          if (track != null)
            TextButton(onPressed: () => app.player.playTracks([track], 0), child: const Text('Включить у себя')),
          const Spacer(),
          if (track != null)
            following
                ? TextButton(onPressed: app.social.stopFollowing, child: const Text('Перестать'))
                : FilledButton(
                    style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10)),
                    onPressed: () => app.social.follow(member.email),
                    child: const Text('Слушать вместе'),
                  ),
        ]),
      ]),
    );
  }
}

class _ChartRow extends StatelessWidget {
  final int rank;
  final ChartEntry entry;
  final List<ChartEntry> all;
  const _ChartRow({required this.rank, required this.entry, required this.all});

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final t = entry.track;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => app.player.playTracks([for (final e in all) e.track], rank - 1),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 4),
        child: Row(children: [
          SizedBox(
            width: 34,
            child: Text('$rank', style: display(16, color: rank <= 3 ? C.accent : C.faint)),
          ),
          CoverImage(track: t, size: 40, radius: 5),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w500)),
              const SizedBox(height: 2),
              Text(t.displayArtist, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.muted, fontSize: 13)),
            ]),
          ),
          Tooltip(
            message: 'Слушали: ${entry.listeners.map(app.lib.firstNameOf).join(', ')}',
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              for (final e in entry.listeners.take(4))
                Padding(padding: const EdgeInsets.only(left: 3), child: FriendDot(e)),
            ]),
          ),
          const SizedBox(width: 14),
          SizedBox(
            width: 110,
            child: Text('${entry.plays} ${plural(entry.plays, 'прослушивание', 'прослушивания', 'прослушиваний')}',
                textAlign: TextAlign.right, style: const TextStyle(color: C.faint, fontSize: 12)),
          ),
        ]),
      ),
    );
  }
}

class _FeedRow extends StatelessWidget {
  final FeedEvent event;
  const _FeedRow({required this.event});

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final lib = app.lib;
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
        onTap = () => NavScope.of(context).go(const Nav('recent'));
      case 'playlist':
        final p = lib.playlist('${d['id']}');
        text = '$who создал(а) плейлист «${p?.name ?? d['name']}»';
        icon = Icons.queue_music_rounded;
        if (p != null) onTap = () => NavScope.of(context).go(Nav('playlist', p.id));
      case 'like':
        final t = lib.data.tracks['${d['track']}'];
        if (t == null) return const SizedBox.shrink();
        text = '$who нравится «${t.title}» — ${t.displayArtist}';
        icon = Icons.favorite_rounded;
        onTap = () => app.player.playTracks([t], 0);
      default:
        return const SizedBox.shrink();
    }
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 4),
        child: Row(children: [
          Icon(icon, size: 18, color: friendColor(event.email)),
          const SizedBox(width: 14),
          Expanded(child: Text(text, style: const TextStyle(height: 1.35))),
          const SizedBox(width: 12),
          Text(timeAgo(event.at), style: const TextStyle(color: C.faint, fontSize: 12)),
        ]),
      ),
    );
  }
}

/// Блок «Сейчас слушают» в боковой панели
class NowListeningSidebar extends StatelessWidget {
  final bool compact;
  const NowListeningSidebar({super.key, required this.compact});

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final social = app.social;
    return ListenableBuilder(
      listenable: social,
      builder: (context, _) {
        final live = social.friends.where((m) => m.live).toList();
        final followed = social.following;
        if (live.isEmpty && followed == null) return const SizedBox.shrink();
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (!compact)
            const Padding(
              padding: EdgeInsets.fromLTRB(22, 14, 16, 6),
              child: Text('Сейчас слушают', style: TextStyle(color: C.muted, fontSize: 13)),
            ),
          if (followed != null && !compact)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 10, 4),
              child: Row(children: [
                const Icon(Icons.headphones_rounded, size: 16, color: C.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Вместе с ${app.lib.firstNameOf(followed)}',
                      overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.accent, fontSize: 13)),
                ),
                TextButton(onPressed: social.stopFollowing, child: const Text('Выйти')),
              ]),
            ),
          for (final m in live.take(5))
            Tooltip(
              message: '${m.now!.title} — ${m.now!.artist}',
              child: InkWell(
                onTap: () => NavScope.of(context).go(const Nav('company')),
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: compact ? 0 : 22, vertical: 5),
                  child: Row(
                    mainAxisAlignment: compact ? MainAxisAlignment.center : MainAxisAlignment.start,
                    children: [
                      Avatar(email: m.email, name: m.name, size: 22),
                      if (!compact) ...[
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(app.lib.firstNameOf(m.email), style: const TextStyle(fontSize: 13)),
                            Text(m.now!.title,
                                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.faint, fontSize: 12)),
                          ]),
                        ),
                        if (social.following == m.email) const Icon(Icons.headphones_rounded, size: 14, color: C.accent),
                      ],
                    ],
                  ),
                ),
              ),
            ),
        ]);
      },
    );
  }
}
