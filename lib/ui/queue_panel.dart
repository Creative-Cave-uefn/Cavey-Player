import 'package:flutter/material.dart';

import '../app.dart';
import '../core/models.dart';
import 'shell.dart' show SidePanelSlot;
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
      width: SidePanelSlot.panelWidth,
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
          padding: const EdgeInsets.fromLTRB(12, 16, 0, 6),
          child: Row(children: [
            Expanded(child: Text(text, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700))),
            if (trailing != null) trailing,
          ]),
        );

    // Один общий список: заголовки разделов — неподвижные элементы, строки треков тянутся куда угодно,
    // в том числе из «подобрано плеером» в «добавлено вами» и обратно
    final entries = <_QEntry>[
      const _QEntry.header(true),
      if (user == 0) const _QEntry.empty() else for (var i = 0; i < user; i++) _QEntry.track(firstUp + i),
      if (ctxTotal > 0) ...[
        const _QEntry.header(false),
        for (var i = 0; i < ctxShown; i++) _QEntry.track(ctxStart + i),
      ],
    ];

    void onReorder(int from, int to) {
      if (to > from) to--;
      if (from == to) return;
      final moved = entries[from];
      if (moved.qi == null) return;
      // Список без переносимого элемента: ищем место вставки и раздел, в который трек попал
      final rest = [...entries]..removeAt(from);
      var tracksBefore = 0;
      var userSection = true;
      for (var i = 0; i < to && i < rest.length; i++) {
        final e = rest[i];
        if (e.qi != null) tracksBefore++;
        if (e.isHeader) userSection = e.userHeader;
      }
      p.moveInQueue(moved.qi!, firstUp + tracksBefore, asUser: userSection);
    }

    return ReorderableListView.builder(
      buildDefaultDragHandles: false,
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 24),
      header: Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          title('Сейчас играет'),
          _QueueRow(track: cur, current: true, playing: p.playing),
        ]),
      ),
      footer: ctxTotal > ctxShown
          ? Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
              child: Text('…и ещё ${ctxTotal - ctxShown}', style: const TextStyle(color: C.faint, fontSize: 13)),
            )
          : null,
      itemCount: entries.length,
      onReorder: onReorder,
      proxyDecorator: (child, i, anim) => Material(color: C.panelRaised, elevation: 6, borderRadius: BorderRadius.circular(10), child: child),
      itemBuilder: (context, i) {
        final e = entries[i];
        if (e.isHeader) {
          return Container(
            key: ValueKey('h${e.userHeader}'),
            child: e.userHeader
                ? title('Далее в очереди',
                    trailing: user > 0
                        ? TextButton(
                            onPressed: p.clearUserQueue,
                            style: TextButton.styleFrom(visualDensity: VisualDensity.compact, foregroundColor: C.muted),
                            child: const Text('Очистить очередь', style: TextStyle(fontSize: 13)),
                          )
                        : null)
                : title(p.feeder != null ? 'Далее в волне' : 'Далее подобрано'),
          );
        }
        if (e.qi == null) {
          return Container(
            key: const ValueKey('empty-user'),
            height: 56,
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: const Text('Пусто. Добавьте трек через «…» или перетащите сюда из списка ниже.',
                maxLines: 2, style: TextStyle(color: C.faint, fontSize: 13, height: 1.4)),
          );
        }
        final qi = e.qi!;
        final t = at(qi);
        return ReorderableDragStartListener(
          key: ValueKey('q$qi:${p.queue[qi]}'),
          index: i,
          child: t == null ? const SizedBox(height: 1) : _QueueRow(track: t, onTap: () => p.jumpTo(qi), onRemove: () => p.removeAt(qi)),
        );
      },
    );
  }
}

/// Строка общего списка очереди: заголовок раздела, подсказка «пусто» или трек под номером [qi] в очереди плеера
class _QEntry {
  final int? qi;
  final bool isHeader;
  final bool userHeader;
  const _QEntry.header(this.userHeader)
      : qi = null,
        isHeader = true;
  const _QEntry.empty()
      : qi = null,
        isHeader = false,
        userHeader = false;
  const _QEntry.track(int this.qi)
      : isHeader = false,
        userHeader = false;
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
