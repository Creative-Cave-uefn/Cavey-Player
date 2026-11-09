import 'dart:async';

import 'package:flutter/material.dart';

import '../app.dart';
import '../core/notices.dart';
import '../core/social.dart';
import 'glass_popup.dart';
import 'shell.dart';
import 'profile_view.dart';
import 'tracks_view.dart' show Links, LinkPart, trackLinks, TrackMenu, showTrackMenu;
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
        final notices = social.notices.take(20).toList();
        return ListView(padding: EdgeInsets.fromLTRB(pad, 28, pad, 40), children: [
          Row(children: [
            Expanded(child: Text('Участники', style: display(20))),
            _NoticeBell(notices: notices),
          ]),
          const SizedBox(height: 6),
          const Text('Нажмите на человека, чтобы открыть его страницу.', style: TextStyle(color: C.faint, fontSize: 13)),
          const SizedBox(height: 14),
          _People(),
          const SizedBox(height: 40),
          Text('Сейчас слушают', style: display(20)),
          const SizedBox(height: 6),
          Text(
            social.pollError != null
                ? 'Не получилось обновить статусы: ${social.pollError}'
                : social.lastPoll == null
                    ? 'Загружаю статусы друзей…'
                    : 'Обновляется раз в 15 секунд, последний раз в ${TimeOfDay.fromDateTime(social.lastPoll!).format(context)}. '
                        'Друзей с Cavey: ${social.friends.length}.',
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

/// «Слушать вместе» теперь про джем-сессию: человека зовут в общую очередь, а не заставляют повторять за собой.
/// Подпись и действие зависят от того, где мы оба сейчас
({String label, IconData icon, bool inJam}) jamButton(AppServices app, String email) {
  final jam = app.jam;
  if (jam.active && jam.participants.contains(email)) return (label: 'В джеме · выйти', icon: Icons.headphones_rounded, inJam: true);
  if (jam.active) return (label: 'Позвать в джем', icon: Icons.person_add_alt_1_rounded, inJam: false);
  final m = app.social.members[email];
  if (m?.jamId != null) return (label: 'Попроситься в джем', icon: Icons.login_rounded, inJam: false);
  return (label: 'Слушать вместе', icon: Icons.headphones_rounded, inJam: false);
}

Future<void> jamTogether(AppServices app, String email) async {
  final jam = app.jam;
  final name = app.lib.firstNameOf(email);
  if (jam.active && jam.participants.contains(email)) {
    await jam.leave();
    return;
  }
  final m = app.social.members[email];
  if (!jam.active && m?.jamId != null) {
    await jam.requestJoin(m!);
    app.lib.messages.add('Запрос в джем отправлен: $name');
    return;
  }
  await jam.invite([email]);
  app.lib.messages.add('Приглашение в джем отправлено: $name');
}

class _ListenerCard extends StatelessWidget {
  final Member member;
  const _ListenerCard({required this.member});

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final now = member.now!;
    final track = app.lib.data.tracks[now.trackId];
    final jb = jamButton(app, member.email);
    final following = jb.inJam;
    // Карточка в цвет обложки трека: свечение из угла поверх стекла, имя — на тёмной плашке, чтобы не сливалось
    return FutureBuilder<Color?>(
      future: track == null ? null : trackTint(app, track),
      initialData: track == null ? null : trackTintNow(app, track),
      builder: (context, snap) {
        final tint = snap.data;
        return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      width: 300,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: tint == null ? C.surface : null,
        gradient: tint == null
            ? null
            : LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color.alphaBlend(tint.withValues(alpha: 0.85), C.surface),
                  Color.alphaBlend(tint.withValues(alpha: 0.35), C.surface),
                ],
              ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: following ? C.accent : C.line),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () => NavScope.of(context).go(Nav('user', member.email)),
          child: Container(
            padding: const EdgeInsets.fromLTRB(3, 3, 10, 3),
            decoration: BoxDecoration(color: const Color(0x47000000), borderRadius: BorderRadius.circular(20)),
            child: Row(children: [
              Avatar(email: member.email, name: member.name, size: 26),
              const SizedBox(width: 10),
              Expanded(
                child: Text(member.name.isEmpty ? member.email : member.name,
                    overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
              ),
              Text(member.live ? 'слушает' : 'на паузе',
                  style: TextStyle(color: member.live ? C.accent : C.faint, fontSize: 12, fontWeight: FontWeight.w600)),
            ]),
          ),
        ),
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
          following
              ? TextButton(onPressed: () => jamTogether(app, member.email), child: Text(jb.label))
              : FilledButton(
                  style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10)),
                  onPressed: () => jamTogether(app, member.email),
                  child: Text(jb.label),
                ),
        ]),
      ]),
    );
      },
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
      // Правый клик — то же меню, что под «…»
      onSecondaryTapUp: (d) => showTrackMenu(context, t, null, d.globalPosition),
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
              // Название ведёт в альбом, исполнитель — на его страницу; клик по пустому месту строки включает чарт
              Links(
                parts: [LinkPart(t.title, () => NavScope.of(context).go(Nav('album', t.albumKey)))],
                style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 14),
              ),
              const SizedBox(height: 2),
              Links(parts: trackLinks(context, t), style: const TextStyle(color: C.muted, fontSize: 13)),
            ]),
          ),
          // Кто слушал: маленькие аватарки внахлёст
          Tooltip(
            message: 'Слушали: ${entry.listeners.map(app.lib.firstNameOf).join(', ')}',
            child: SizedBox(
              width: 20 + (entry.listeners.take(4).length - 1).clamp(0, 3) * 12.0,
              height: 22,
              child: Stack(children: [
                for (final (i, e) in entry.listeners.take(4).indexed)
                  Positioned(
                    left: i * 12.0,
                    top: 0,
                    child: Container(
                      padding: const EdgeInsets.all(1),
                      decoration: BoxDecoration(color: C.bg, shape: BoxShape.circle),
                      child: Avatar(email: e, name: app.lib.nameOf(e), size: 20),
                    ),
                  ),
              ]),
            ),
          ),
          const SizedBox(width: 14),
          SizedBox(
            width: 110,
            child: Text('${entry.plays} ${plural(entry.plays, 'прослушивание', 'прослушивания', 'прослушиваний')}',
                textAlign: TextAlign.right, style: const TextStyle(color: C.faint, fontSize: 12)),
          ),
          TrackMenu(track: t),
        ]),
      ),
    );
  }
}

/// Сколько уведомлений пришло после последнего открытия колокольчика (для красной точки у «Компании»)
int unreadNotices(AppServices app) {
  final seen = DateTime.tryParse(app.settings.bellSeen ?? '');
  if (seen == null) return 0;
  return app.social.notices.where((n) => n.at.isAfter(seen)).length;
}

/// Колокольчик с уведомлениями «Вам»: цвета акцента и красная точка, пока есть непрочитанные; по нажатию раскрывается окошко
class _NoticeBell extends StatefulWidget {
  final List<Notice> notices;
  const _NoticeBell({required this.notices});
  @override
  State<_NoticeBell> createState() => _NoticeBellState();
}

class _NoticeBellState extends State<_NoticeBell> {
  final _menu = MenuController();

  /// Что считать прочитанным: всё, что старше последнего открытия колокольчика
  DateTime? _seen(AppServices app) => DateTime.tryParse(app.settings.bellSeen ?? '');

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final seen = _seen(app);
    final unread = seen == null ? 0 : widget.notices.where((n) => n.at.isAfter(seen)).length;
    final lit = unread > 0;
    return MenuAnchor(
      controller: _menu,
      style: MenuStyle(
        backgroundColor: const WidgetStatePropertyAll(C.panel),
        side: const WidgetStatePropertyAll(BorderSide(color: C.line)),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
        padding: const WidgetStatePropertyAll(EdgeInsets.zero),
      ),
      alignmentOffset: const Offset(-330, 4),
      onOpen: () {
        // Открыли — всё считается прочитанным, колокольчик гаснет
        app.settings.bellSeen = DateTime.now().toUtc().toIso8601String();
        // Сохраняет и обновляет боковую панель: красная точка у «Компании» гаснет
        app.lib.viewChanged();
      },
      onClose: () {
        if (mounted) setState(() {});
      },
      menuChildren: [
        SizedBox(
          width: 380,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 380),
            child: widget.notices.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(20),
                    child: Text('Пока ничего нет. Здесь появятся добавления ваших загрузок в любимое и плейлисты, а также треки, которыми с вами поделились.',
                        style: TextStyle(color: C.faint, fontSize: 13, height: 1.4)),
                  )
                : ListView(
                    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
                    shrinkWrap: true,
                    children: [for (final n in widget.notices) _NoticeRow(notice: n, closeMenu: _menu.close)],
                  ),
          ),
        ),
      ],
      builder: (context, controller, _) => IconButton(
        tooltip: lit ? 'Новых уведомлений: $unread' : 'Уведомления',
        onPressed: () => controller.isOpen ? controller.close() : controller.open(),
        icon: Stack(clipBehavior: Clip.none, children: [
          Icon(lit ? Icons.notifications_active_rounded : Icons.notifications_none_rounded,
              color: lit ? C.accent : C.muted),
          if (lit)
            Positioned(
              right: -2,
              top: -2,
              child: Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(color: const Color(0xFFFF4D4D), shape: BoxShape.circle, border: Border.all(color: C.bg, width: 1.5)),
              ),
            ),
        ]),
      ),
    );
  }
}

class _NoticeRow extends StatelessWidget {
  final Notice notice;
  /// Закрывает окошко уведомлений (нужно при переходе на другую страницу)
  final VoidCallback closeMenu;
  const _NoticeRow({required this.notice, required this.closeMenu});

  /// Ссылка внутри строки: подчёркивается при наведении и перехватывает нажатие у всей строки
  Widget _link(String text, VoidCallback onTap) => _HoverLink(text: text, onTap: onTap);

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final lib = app.lib;
    final track = lib.data.tracks[lib.data.resolve(notice.trackIds.first)];
    final icon = switch (notice.kind) {
      NoticeKind.like => Icons.favorite_rounded,
      NoticeKind.addToPlaylist => Icons.playlist_add_rounded,
      NoticeKind.share => Icons.share_rounded,
      NoticeKind.jamInvite => Icons.headphones_rounded,
      NoticeKind.jamRequest => Icons.person_add_alt_1_rounded,
    };
    void toUser() {
      closeMenu();
      NavScope.of(context).go(Nav('user', notice.from));
    }

    void toAlbum() {
      if (track == null) return;
      closeMenu();
      NavScope.of(context).go(Nav('album', track.albumKey));
    }

    final who = _link(lib.firstNameOf(notice.from), toUser);
    final title = track == null ? const Text('трек') : _link('«${track.title}»', toAlbum);
    const plain = TextStyle(height: 1.35);
    Widget line(List<Widget> parts) => Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: parts);
    Widget t(String s) => Text(s, style: plain);
    final Widget body = switch (notice.kind) {
      NoticeKind.like => line([who, t(' добавил(а) '), title, t(' в любимое')]),
      NoticeKind.addToPlaylist => notice.trackIds.length == 1
          ? line([who, t(' добавил(а) '), title, t(notice.playlist == null ? ' в плейлист' : ' в плейлист «${notice.playlist}»')])
          : line([who, t(' добавил(а) ваших треков: ${notice.trackIds.length} ${notice.playlist == null ? 'в плейлист' : 'в плейлист «${notice.playlist}»'}')]),
      NoticeKind.share => line([who, t(' поделился(ась): '), title, t(track == null ? '' : ' — ${track.displayArtist}')]),
      NoticeKind.jamInvite => line([who, t(' зовёт в джем')]),
      NoticeKind.jamRequest => line([who, t(' просится в джем')]),
    };
    final isJam = notice.kind == NoticeKind.jamInvite || notice.kind == NoticeKind.jamRequest;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      // Нажатие на строку включает трек; окно уведомлений остаётся открытым
      onTap: isJam || track == null ? null : () => app.player.playTracks([track], 0),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 4),
        child: Row(children: [
          // Значок события и маленький аватар человека в правом нижнем углу
          SizedBox(
            width: 34,
            height: 30,
            child: Stack(clipBehavior: Clip.none, children: [
              Positioned(left: 2, top: 2, child: Icon(icon, size: 22, color: friendColor(notice.from))),
              Positioned(
                right: 0,
                bottom: 0,
                child: Container(
                  padding: const EdgeInsets.all(1.5),
                  decoration: const BoxDecoration(color: C.panel, shape: BoxShape.circle),
                  child: Avatar(email: notice.from, name: lib.firstNameOf(notice.from), size: 15),
                ),
              ),
            ]),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              body,
              if (notice.note != null) Text('«${notice.note}»', style: const TextStyle(color: C.muted, fontSize: 13)),
              if (isJam) _JamNoticeActions(notice: notice),
            ]),
          ),
          const SizedBox(width: 12),
          Text(timeAgo(notice.at), style: const TextStyle(color: C.faint, fontSize: 12)),
        ]),
      ),
    );
  }
}

class _HoverLink extends StatefulWidget {
  final String text;
  final VoidCallback onTap;
  const _HoverLink({required this.text, required this.onTap});
  @override
  State<_HoverLink> createState() => _HoverLinkState();
}

class _HoverLinkState extends State<_HoverLink> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) => MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: Text(widget.text,
              style: TextStyle(height: 1.35, fontWeight: FontWeight.w600, decoration: _hover ? TextDecoration.underline : TextDecoration.none)),
        ),
      );
}

/// Кнопки «Присоединиться» и «Отклонить» у приглашения в джем и запроса на вход
class _JamNoticeActions extends StatelessWidget {
  final Notice notice;
  const _JamNoticeActions({required this.notice});

  @override
  Widget build(BuildContext context) {
    final jam = Services.of(context).jam;
    final invite = notice.kind == NoticeKind.jamInvite;
    return ListenableBuilder(
      listenable: jam,
      builder: (context, _) {
        final state = jam.noticeState(notice);
        if (state != null) {
          return Padding(padding: const EdgeInsets.only(top: 4), child: Text(state, style: const TextStyle(color: C.faint, fontSize: 12)));
        }
        return Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Row(children: [
            FilledButton(
              style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
              onPressed: () => jam.acceptNotice(notice),
              child: Text(invite ? 'Присоединиться' : 'Принять'),
            ),
            const SizedBox(width: 8),
            TextButton(onPressed: () => jam.declineNotice(notice), child: const Text('Отклонить')),
          ]),
        );
      },
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
      case 'share':
        final t = lib.data.tracks[lib.data.resolve('${d['track']}')];
        if (t == null) return const SizedBox.shrink();
        final to = [for (final x in (d['to'] as List? ?? const [])) '$x'];
        final whom = to.length == 1 ? lib.firstNameOf(to.first) : 'друзьями (${to.length})';
        text = '$who поделился(ась) «${t.title}» — ${t.displayArtist} с $whom';
        icon = Icons.share_rounded;
        onTap = () => app.player.playTracks([t], 0);
      case 'addpl':
        // В ленте только открытые плейлисты: у них в событии есть название
        final name = d['name'];
        final first = (d['tracks'] as List? ?? const []).isEmpty ? null : lib.data.tracks[lib.data.resolve('${(d['tracks'] as List).first}')];
        if (name is! String || name.isEmpty || first == null) return const SizedBox.shrink();
        final n = (d['tracks'] as List).length;
        text = n == 1
            ? '$who добавил(а) «${first.title}» в плейлист «$name»'
            : '$who добавил(а) в плейлист «$name» треков: $n';
        icon = Icons.playlist_add_rounded;
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

/// Блок «Сейчас слушают» внизу боковой панели. Свёрнут: одна строка с аватарками.
/// При наведении раскрывается вверх и показывает всех, кто слушает
class NowListeningSidebar extends StatefulWidget {
  final bool compact;
  const NowListeningSidebar({super.key, required this.compact});

  @override
  State<NowListeningSidebar> createState() => _NowListeningSidebarState();
}

class _NowListeningSidebarState extends State<NowListeningSidebar> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final social = app.social;
    final compact = widget.compact;
    return ListenableBuilder(
      listenable: Listenable.merge([social, app.jam]),
      builder: (context, _) {
        final jam = app.jam;
        // Те, кто в джеме, показываются отдельной карточкой джема, а не в общем списке «слушают»
        final live = social.friends.where((m) => m.live && !m.inJam).toList();
        final jamGroups = otherJams(app);
        if (live.isEmpty && !jam.active && jamGroups.isEmpty) return const SizedBox.shrink();
        return MouseRegion(
          onEnter: (_) => setState(() => _open = true),
          onExit: (_) => setState(() => _open = false),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            // Список над заголовком: при раскрытии заголовок остаётся под курсором
            AnimatedSize(
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOut,
              alignment: Alignment.bottomCenter,
              child: _open && live.isNotEmpty
                  ? ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 300),
                      child: SingleChildScrollView(
                        child: Column(children: [
                          for (final m in live) _ListenerTile(key: ValueKey(m.email), member: m, compact: compact),
                        ]),
                      ),
                    )
                  : const SizedBox(width: double.infinity),
            ),
            if (jam.active) JamStrip(compact: compact),
            for (final g in jamGroups) JamGroupCard(key: ValueKey('jg-${g.id}'), group: g, compact: compact),
            Padding(
              padding: EdgeInsets.fromLTRB(compact ? 0 : 22, 10, compact ? 0 : 16, 10),
              child: Row(mainAxisAlignment: compact ? MainAxisAlignment.center : MainAxisAlignment.start, children: [
                if (!compact) ...[
                  const Expanded(child: Text('Сейчас слушают', style: TextStyle(color: C.muted, fontSize: 13))),
                  SizedBox(
                    height: 20,
                    width: (20 + (live.length.clamp(0, 3) - 1).clamp(0, 2) * 12).toDouble(),
                    child: Stack(children: [
                      for (var i = 0; i < live.length && i < 3; i++)
                        Positioned(left: i * 12.0, child: Avatar(key: ValueKey('hd-${live[i].email}'), email: live[i].email, name: live[i].name, size: 20)),
                    ]),
                  ),
                  const SizedBox(width: 8),
                  Text('${live.length}', style: const TextStyle(color: C.faint, fontSize: 12)),
                ] else
                  const Icon(Icons.headphones_rounded, size: 18, color: C.muted),
              ]),
            ),
          ]),
        );
      },
    );
  }
}

/// Чужой джем, который виден в «Сейчас слушают»
class JamGroup {
  final String id;
  final List<Member> members; // те, у кого свежий статус с этим джемом
  final List<String> people; // все участники по их спискам, без меня
  JamGroup(this.id, this.members, this.people);
}

/// Джемы, в которых я не участвую: по свежим статусам людей, сгруппированные по номеру джема
List<JamGroup> otherJams(AppServices app) {
  final mine = app.jam.jamId;
  final byId = <String, List<Member>>{};
  for (final m in app.social.friends) {
    final id = m.jamId;
    if (id == null || id == mine || !m.inJam) continue;
    byId.putIfAbsent(id, () => []).add(m);
  }
  final me = app.lib.me;
  return [
    for (final e in byId.entries)
      JamGroup(e.key, e.value, {
        for (final m in e.value) ...[m.email, ...m.jamMembers],
      }.where((x) => x.isNotEmpty && x != me).toList()),
  ];
}

/// Карточка чужого джема: аватарки участников и кнопка «Присоединиться к джему». Если я уже в своём джеме, кнопка —
/// «Пригласить к своему джему» со списком: все участники этого джема или кто-то один
class JamGroupCard extends StatelessWidget {
  final JamGroup group;
  final bool compact;
  const JamGroupCard({super.key, required this.group, required this.compact});

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final jam = app.jam;
    final people = group.people;
    if (compact) {
      return Tooltip(
        message: 'Джем · ${people.length}: ${jam.active ? 'пригласить к своему' : 'присоединиться'}',
        child: IconButton(
          onPressed: jam.active ? null : () => _join(context),
          icon: Icon(Icons.headphones_rounded, color: C.accent),
        ),
      );
    }
    final names = [for (final e in people) app.lib.firstNameOf(e)].join(', ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: C.accent.withValues(alpha: 0.10),
          border: Border.all(color: C.accent.withValues(alpha: 0.35)),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(Icons.headphones_rounded, size: 16, color: C.accent),
              const SizedBox(width: 8),
              Expanded(child: Text('Джем · ${people.length}', style: TextStyle(color: C.accent, fontSize: 13, fontWeight: FontWeight.w600))),
            ]),
            const SizedBox(height: 10),
            SizedBox(
              height: 28,
              width: double.infinity,
              child: Stack(children: [
                for (var i = 0; i < people.length && i < 6; i++)
                  Positioned(
                    left: i * 20.0,
                    child: DecoratedBox(
                      decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: C.panel, width: 2)),
                      child: Avatar(key: ValueKey('jg-${group.id}-${people[i]}'), email: people[i], name: app.lib.firstNameOf(people[i]), size: 28),
                    ),
                  ),
                if (people.length > 6)
                  Positioned(left: 6 * 20.0 + 6, top: 6, child: Text('+${people.length - 6}', style: const TextStyle(color: C.muted, fontSize: 12))),
              ]),
            ),
            const SizedBox(height: 8),
            Text(names, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.muted, fontSize: 12, height: 1.3)),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              child: jam.active
                  ? Builder(
                      builder: (btn) => OutlinedButton.icon(
                        onPressed: () => _inviteMenu(btn),
                        icon: const Icon(Icons.person_add_alt_1_rounded, size: 16),
                        label: const Text('Пригласить к своему джему', overflow: TextOverflow.ellipsis),
                      ),
                    )
                  : FilledButton(onPressed: () => _join(context), child: const Text('Присоединиться к джему')),
            ),
          ]),
        ),
      ),
    );
  }

  Future<void> _join(BuildContext context) async {
    final app = Services.of(context);
    await app.jam.requestJoin(group.members.first);
    app.lib.messages.add('Запрос в джем отправлен');
  }

  Future<void> _inviteMenu(BuildContext btn) async {
    final app = Services.of(btn);
    final already = app.jam.participants.toSet();
    final candidates = [for (final e in group.people) if (!already.contains(e)) e];
    if (candidates.isEmpty) {
      app.lib.messages.add('Все из этого джема уже в вашем');
      return;
    }
    final box = btn.findRenderObject() as RenderBox;
    final overlay = Navigator.of(btn).overlay!.context.findRenderObject() as RenderBox;
    final rect = Rect.fromPoints(
      box.localToGlobal(box.size.bottomLeft(Offset.zero), ancestor: overlay),
      box.localToGlobal(box.size.bottomRight(Offset.zero), ancestor: overlay),
    );
    final v = await showGlassMenu<String>(
      context: btn,
      position: RelativeRect.fromRect(rect, Offset.zero & overlay.size),
      items: [
        if (candidates.length > 1)
          PopupMenuItem(
            value: '*',
            child: Row(children: [
              const Icon(Icons.groups_rounded, size: 18),
              const SizedBox(width: 10),
              Text('Всех участников (${candidates.length})'),
            ]),
          ),
        for (final e in candidates)
          PopupMenuItem(
            value: e,
            child: Row(children: [
              Avatar(email: e, name: app.lib.firstNameOf(e), size: 22),
              const SizedBox(width: 10),
              Flexible(child: Text(app.lib.firstNameOf(e), overflow: TextOverflow.ellipsis)),
            ]),
          ),
      ],
    );
    if (v == null) return;
    final list = v == '*' ? candidates : [v];
    await app.jam.invite(list);
    app.lib.messages.add(list.length == 1 ? 'Приглашение в джем отправлено: ${app.lib.firstNameOf(list.first)}' : 'Приглашения в джем отправлены: ${list.length}');
  }
}

/// Строка человека в «Сейчас слушают»: при наведении подсвечивается и показывает кнопки
/// «Слушать вместе» и «Включить у себя»; если задержать курсор — подсказка «Перейти в профиль»
class _ListenerTile extends StatefulWidget {
  final Member member;
  final bool compact;
  const _ListenerTile({super.key, required this.member, required this.compact});

  @override
  State<_ListenerTile> createState() => _ListenerTileState();
}

class _ListenerTileState extends State<_ListenerTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final m = widget.member;
    final compact = widget.compact;
    final together = app.jam.active && app.jam.participants.contains(m.email);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Tooltip(
        message: 'Перейти в профиль',
        waitDuration: const Duration(milliseconds: 600),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 10),
          child: Material(
            color: _hover ? C.hoverOverlay : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => NavScope.of(context).go(Nav('user', m.email)),
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: compact ? 0 : 12, vertical: 5),
                child: Row(
                  mainAxisAlignment: compact ? MainAxisAlignment.center : MainAxisAlignment.start,
                  children: [
                    Avatar(key: ValueKey('av-${m.email}'), email: m.email, name: m.name, size: 22),
                    if (!compact) ...[
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(app.lib.firstNameOf(m.email), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13)),
                          Text(m.now!.title,
                              maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.faint, fontSize: 12)),
                        ]),
                      ),
                      if (_hover)
                        ListenActions(email: m.email, dense: true)
                      else if (together)
                        Icon(Icons.headphones_rounded, size: 14, color: C.accent),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// «Слушать вместе» и «Включить у себя» для человека, который сейчас слушает музыку.
/// Включить у себя — тот же трек с начала, без синхронизации. Нет трека в библиотеке — кнопок нет.
class ListenActions extends StatelessWidget {
  final String email;

  /// Маленькие значки без подписей (боковая панель) или кнопки с подписями (профиль)
  final bool dense;
  const ListenActions({super.key, required this.email, this.dense = false});

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    return ListenableBuilder(
      listenable: app.social,
      builder: (context, _) {
        final m = app.social.members[email];
        final now = m?.now;
        if (m == null || now == null || !m.live) return const SizedBox.shrink();
        final track = app.lib.data.tracks[now.trackId];
        final jb = jamButton(app, email);
        void toggleTogether() => unawaited(jamTogether(app, email));
        void playOwn() {
          if (track == null) return;
          app.player.playTracks([track], 0);
        }

        if (dense) {
          Widget icon(IconData i, String tip, VoidCallback? onTap, {bool on = false}) => Tooltip(
                message: tip,
                child: InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: onTap,
                  child: SizedBox.square(dimension: 26, child: Icon(i, size: 16, color: on ? C.accent : C.muted)),
                ),
              );
          return Row(mainAxisSize: MainAxisSize.min, children: [
            icon(jb.icon, jb.label, toggleTogether, on: jb.inJam),
            icon(Icons.play_arrow_rounded, 'Включить у себя', track == null ? null : playOwn),
          ]);
        }
        return Wrap(spacing: 10, runSpacing: 10, alignment: WrapAlignment.center, children: [
          jb.inJam
              ? OutlinedButton.icon(onPressed: toggleTogether, icon: Icon(jb.icon, size: 18), label: Text(jb.label))
              : FilledButton.icon(onPressed: toggleTogether, icon: Icon(jb.icon, size: 18), label: Text(jb.label)),
          OutlinedButton.icon(
            onPressed: track == null ? null : playOwn,
            icon: const Icon(Icons.play_arrow_rounded, size: 18),
            label: const Text('Включить у себя'),
          ),
        ]);
      },
    );
  }
}

/// Плашка джема над «Сейчас слушают»: кто в джеме, «Пригласить» и «Выйти»
class JamStrip extends StatelessWidget {
  final bool compact;
  const JamStrip({super.key, required this.compact});

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final jam = app.jam;
    final people = jam.participants;
    if (compact) {
      return Tooltip(
        message: 'Джем: ${people.length} · выйти',
        child: IconButton(onPressed: jam.leave, icon: Icon(Icons.headphones_rounded, color: C.accent)),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 10, 4),
      child: Row(children: [
        Icon(Icons.headphones_rounded, size: 16, color: C.accent),
        const SizedBox(width: 8),
        SizedBox(
          height: 20,
          width: (20 + (people.length.clamp(1, 4) - 1) * 12).toDouble(),
          child: Stack(children: [
            for (var i = 0; i < people.length && i < 4; i++)
              Positioned(left: i * 12.0, child: Avatar(key: ValueKey('jam-${people[i]}'), email: people[i], name: app.lib.firstNameOf(people[i]), size: 20)),
          ]),
        ),
        const SizedBox(width: 8),
        Expanded(child: Text('Джем · ${people.length}', overflow: TextOverflow.ellipsis, style: TextStyle(color: C.accent, fontSize: 13))),
        IconButton(
          tooltip: 'Пригласить в джем',
          visualDensity: VisualDensity.compact,
          icon: Icon(Icons.person_add_alt_1_rounded, size: 18, color: C.accent),
          onPressed: () => _invite(context),
        ),
        TextButton(onPressed: jam.leave, child: const Text('Выйти')),
      ]),
    );
  }

  Future<void> _invite(BuildContext context) async {
    final app = Services.of(context);
    final inJam = app.jam.participants.toSet();
    final candidates = [for (final m in app.social.friends) if (!inJam.contains(m.email)) m];
    if (candidates.isEmpty) {
      app.lib.messages.add('Позвать некого: все из компании уже в джеме');
      return;
    }
    final picked = <String>{};
    final result = await showDialog<List<String>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('Позвать в джем'),
          content: SizedBox(
            width: 340,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                for (final m in candidates)
                  CheckboxListTile(
                    value: picked.contains(m.email),
                    onChanged: (v) => setS(() => v == true ? picked.add(m.email) : picked.remove(m.email)),
                    secondary: Avatar(email: m.email, name: m.name, size: 28),
                    title: Text(app.lib.firstNameOf(m.email)),
                    subtitle: m.live ? const Text('слушает сейчас') : null,
                  ),
              ]),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
            FilledButton(onPressed: picked.isEmpty ? null : () => Navigator.pop(ctx, picked.toList()), child: const Text('Позвать')),
          ],
        ),
      ),
    );
    if (result != null && result.isNotEmpty) {
      await app.jam.invite(result);
      app.lib.messages.add('Приглашение в джем отправлено');
    }
  }
}

/// Все, кто есть в компании: карточки со ссылкой на страницу человека
class _People extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final lib = app.lib;
    final emails = {...lib.people, ...app.social.members.keys}..removeWhere((e) => e.isEmpty);
    final uploads = <String, int>{};
    for (final t in lib.data.tracks.values) {
      if (t.by.isNotEmpty && !lib.data.hidden.contains(t.id)) uploads[t.by] = (uploads[t.by] ?? 0) + 1;
    }
    final list = emails.toList()
      ..sort((a, b) {
        if (a == lib.me) return -1;
        if (b == lib.me) return 1;
        final la = app.social.members[a]?.live ?? false;
        final lb = app.social.members[b]?.live ?? false;
        if (la != lb) return la ? -1 : 1;
        return lib.nameOf(a).toLowerCase().compareTo(lib.nameOf(b).toLowerCase());
      });
    return Wrap(spacing: 12, runSpacing: 12, children: [
      for (final e in list) _PersonCard(email: e, uploads: uploads[e] ?? 0),
    ]);
  }
}

class _PersonCard extends StatelessWidget {
  final String email;
  final int uploads;
  const _PersonCard({required this.email, required this.uploads});

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final lib = app.lib;
    final m = app.social.members[email];
    final name = lib.nameOf(email);
    final String status;
    if (m != null && m.live && m.now != null) {
      status = 'слушает: ${m.now!.title}';
    } else if (m != null && m.recent) {
      status = 'на паузе';
    } else if (m != null) {
      status = 'был(а) ${timeAgo(m.updated)}';
    } else {
      status = uploads == 0 ? 'ещё не заходил(а)' : '';
    }
    final live = m?.live ?? false;
    return SizedBox(
      width: 250,
      child: Material(
        color: C.surface,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => NavScope.of(context).go(Nav('user', email)),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), border: Border.all(color: live ? C.accent : C.line)),
            child: Row(children: [
              Avatar(email: email, name: name, size: 46),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(email == lib.me ? '$name (вы)' : name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                  if (status.isNotEmpty)
                    Text(status, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: live ? C.accent : C.faint, fontSize: 12)),
                  Text(uploads == 0 ? 'без загрузок' : 'загрузил(а) ${countTracks(uploads)}',
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.muted, fontSize: 12)),
                  if (m != null && m.timeTotals.isNotEmpty)
                    Text('Наслушал(а): ${formatListened(app.social.listened(email))}',
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.faint, fontSize: 11)),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
