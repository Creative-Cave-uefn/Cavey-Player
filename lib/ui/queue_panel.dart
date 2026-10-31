import 'package:flutter/material.dart';

import '../app.dart';
import '../core/models.dart';
import 'theme.dart';
import 'widgets.dart';

/// Панель очереди справа, как панель с текстом песни: сначала то, что человек добавил сам
/// («Добавить в очередь»), потом то, что подобрал плеер
class QueuePanel extends StatelessWidget {
  const QueuePanel({super.key});

  /// Сколько подобранных плеером треков показываем сразу: длинный список на весь альбом не нужен
  static const _shown = 100;

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    return Container(
      width: 360,
      margin: const EdgeInsets.fromLTRB(0, 12, 12, 12),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(color: C.surface, borderRadius: BorderRadius.circular(24), border: Border.all(color: C.line)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 18, 8, 8),
          child: Row(children: [
            Expanded(child: Text('Очередь', style: display(16))),
            IconButton(
              tooltip: 'Закрыть',
              onPressed: () => app.player.queueOpen.value = false,
              icon: const Icon(Icons.close_rounded, size: 18),
            ),
          ]),
        ),
        Expanded(
          child: ListenableBuilder(
            listenable: Listenable.merge([app.player, app.lib]),
            builder: (context, _) => _body(context, app),
          ),
        ),
      ]),
    );
  }

  Widget _body(BuildContext context, AppServices app) {
    final p = app.player;
    final cur = p.current;
    if (cur == null) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(22, 8, 22, 0),
        child: Text('Включите трек, и здесь появится очередь.', style: TextStyle(color: C.faint, height: 1.5)),
      );
    }
    final firstUp = p.index + 1;
    final user = p.userAhead.clamp(0, p.queue.length - firstUp < 0 ? 0 : p.queue.length - firstUp);
    final ctxStart = firstUp + user;
    final ctxTotal = (p.queue.length - ctxStart).clamp(0, 1 << 30);
    final ctxShown = ctxTotal < _shown ? ctxTotal : _shown;

    Track? at(int qi) => qi >= 0 && qi < p.queue.length ? app.lib.data.tracks[p.queue[qi]] : null;

    Widget title(String text, {Widget? trailing}) => Padding(
          padding: const EdgeInsets.fromLTRB(22, 16, 10, 6),
          child: Row(children: [
            Expanded(child: Text(text, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700))),
            if (trailing != null) trailing,
          ]),
        );

    Widget list(int base, int count) => ReorderableListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          itemCount: count,
          onReorder: (from, to) {
            if (to > from) to--;
            if (from == to) return;
            p.moveInQueue(base + from, base + to);
          },
          proxyDecorator: (child, i, anim) => Material(color: C.panelRaised, elevation: 6, borderRadius: BorderRadius.circular(10), child: child),
          itemBuilder: (context, i) {
            final qi = base + i;
            final t = at(qi);
            return ReorderableDragStartListener(
              key: ValueKey('q$qi:${p.queue[qi]}'),
              index: i,
              child: t == null
                  ? const SizedBox(height: 1)
                  : _QueueRow(track: t, onTap: () => p.jumpTo(qi), onRemove: () => p.removeAt(qi)),
            );
          },
        );

    return ListView(padding: const EdgeInsets.only(bottom: 24), children: [
      title('Сейчас играет'),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 10), child: _QueueRow(track: cur, current: true, playing: p.playing)),
      if (user > 0) ...[
        title('Далее в очереди',
            trailing: TextButton(
              onPressed: p.clearUserQueue,
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact, foregroundColor: C.muted),
              child: const Text('Очистить очередь', style: TextStyle(fontSize: 13)),
            )),
        list(firstUp, user),
      ],
      if (ctxTotal > 0) ...[
        title(p.feeder != null ? 'Далее в волне' : 'Далее подобрано'),
        list(ctxStart, ctxShown),
        if (ctxTotal > ctxShown)
          Padding(
            padding: const EdgeInsets.fromLTRB(22, 10, 22, 0),
            child: Text('…и ещё ${ctxTotal - ctxShown}', style: const TextStyle(color: C.faint, fontSize: 13)),
          ),
      ] else if (user == 0)
        const Padding(
          padding: EdgeInsets.fromLTRB(22, 16, 22, 0),
          child: Text('Дальше ничего нет. Добавьте треки через меню «…» у песни: «Добавить в очередь».',
              style: TextStyle(color: C.faint, height: 1.5, fontSize: 13)),
        ),
    ]);
  }
}

class _QueueRow extends StatefulWidget {
  final Track track;
  final bool current;
  final bool playing;
  final VoidCallback? onTap;
  final VoidCallback? onRemove;
  const _QueueRow({required this.track, this.current = false, this.playing = false, this.onTap, this.onRemove});

  @override
  State<_QueueRow> createState() => _QueueRowState();
}

class _QueueRowState extends State<_QueueRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = widget.track;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: widget.onTap,
        child: Container(
          height: 56,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(color: _hover ? C.hoverOverlay : null, borderRadius: BorderRadius.circular(10)),
          child: Row(children: [
            CoverImage(track: t, size: 40, radius: 6),
            const SizedBox(width: 12),
            Expanded(
              child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(t.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: widget.current ? C.accent : C.text)),
                const SizedBox(height: 2),
                Text(t.displayArtist, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: C.muted, fontSize: 13)),
              ]),
            ),
            if (widget.onRemove != null && _hover)
              IconButton(
                tooltip: 'Убрать из очереди',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close_rounded, size: 18, color: C.faint),
                onPressed: widget.onRemove,
              ),
          ]),
        ),
      ),
    );
  }
}
