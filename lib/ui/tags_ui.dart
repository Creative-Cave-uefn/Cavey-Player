import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app.dart';
import '../core/models.dart';
import '../core/track_tags.dart';
import 'glass_popup.dart';
import 'shell.dart' show Nav, NavScope;
import 'theme.dart';

/// Ширина столбца «Теги» в таблицах треков
const kTagsColW = 190.0;

/// Тег-«таблетка» с решёткой, как в галерее на телефоне. [state]: 0 — нет, 1 — есть у всех выбранных, 2 — у части
class TagChip extends StatelessWidget {
  final String name;
  final int state;
  final VoidCallback? onTap;
  final bool small;
  const TagChip({super.key, required this.name, this.state = 0, this.onTap, this.small = true});

  @override
  Widget build(BuildContext context) {
    final on = state != 0;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        borderRadius: BorderRadius.circular(99),
        onTap: onTap,
        hoverColor: C.hoverOverlay,
        child: Container(
          height: small ? 24 : 30,
          padding: EdgeInsets.symmetric(horizontal: small ? 8 : 11),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(99),
            color: state == 1 ? C.accent.withValues(alpha: 0.16) : null,
            border: Border.all(color: on ? C.accent.withValues(alpha: state == 1 ? 0.9 : 0.5) : C.line),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.tag_rounded, size: small ? 13 : 15, color: on ? C.accent : C.faint),
            const SizedBox(width: 3),
            Flexible(
              child: Text(name,
                  maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: small ? 12.5 : 14, color: C.text, height: 1.1)),
            ),
            if (state == 2) ...[
              const SizedBox(width: 3),
              Icon(Icons.remove_rounded, size: small ? 12 : 14, color: C.accent),
            ],
          ]),
        ),
      ),
    );
  }
}

final Map<String, double> _chipWidths = {};

/// Ширина маленькой таблетки с этим именем (для расчёта, сколько их влезает в столбец)
double tagChipWidth(String name) {
  if (_chipWidths.length > 3000) _chipWidths.clear();
  return _chipWidths[name] ??= (TextPainter(
            text: TextSpan(text: name, style: const TextStyle(fontSize: 12.5, height: 1.1)),
            textDirection: TextDirection.ltr,
            maxLines: 1,
          )..layout())
              .width +
      8 + 13 + 3 + 8 + 2;
}

/// Столбец «Теги» в строке трека: таблетки в одну строку, не поместившиеся — «+N»; при наведении справа «+»
class TrackTagsCell extends StatefulWidget {
  final Track track;

  /// Для группового выбора: теги получит весь выбор, а не один трек
  final List<Track> Function()? group;
  const TrackTagsCell({super.key, required this.track, this.group});

  @override
  State<TrackTagsCell> createState() => _TrackTagsCellState();
}

class _TrackTagsCellState extends State<TrackTagsCell> {
  bool _hover = false;

  void _edit() => showTagsDialog(context, widget.group?.call() ?? [widget.track]);

  @override
  Widget build(BuildContext context) {
    final book = Services.of(context).lib.myTags;
    final ids = book.tagsOf(widget.track.id);
    const plusW = 30.0;
    const gap = 6.0;
    const moreW = 38.0;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: SizedBox(
        width: kTagsColW,
        height: double.infinity,
        child: LayoutBuilder(builder: (context, box) {
          final room = box.maxWidth - plusW;
          final shown = <String>[];
          var used = 0.0;
          for (var i = 0; i < ids.length; i++) {
            final name = book.nameOf(ids[i]) ?? '';
            final w = tagChipWidth(name) + (shown.isEmpty ? 0 : gap);
            final tail = i < ids.length - 1 ? gap + moreW : 0;
            if (shown.isNotEmpty && used + w + tail > room) break;
            shown.add(ids[i]);
            used += w;
            if (shown.length == 1 && used + tail > room) break; // одна длинная таблетка: обрежется многоточием
          }
          final hidden = ids.length - shown.length;
          final first = shown.isEmpty ? null : shown.first;
          return Align(
            alignment: Alignment.centerLeft,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              for (var i = 0; i < shown.length; i++) ...[
                if (i > 0) const SizedBox(width: gap),
                if (shown[i] == first && shown.length == 1)
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: (room - (hidden > 0 ? gap + moreW : 0)).clamp(40.0, 400.0)),
                    child: TagChip(name: book.nameOf(shown[i]) ?? '', onTap: () => _open(shown[i])),
                  )
                else
                  TagChip(name: book.nameOf(shown[i]) ?? '', onTap: () => _open(shown[i])),
              ],
              if (hidden > 0) ...[
                const SizedBox(width: gap),
                Tooltip(
                  message: [for (final id in ids.skip(shown.length)) '#${book.nameOf(id)}'].join('  '),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(99),
                    onTap: _edit,
                    child: Container(
                      height: 24,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(borderRadius: BorderRadius.circular(99), border: Border.all(color: C.line)),
                      child: Text('+$hidden', style: const TextStyle(fontSize: 12, color: C.muted)),
                    ),
                  ),
                ),
              ],
              const SizedBox(width: 6),
              // Место под «+» занято всегда, поэтому таблетки не прыгают, когда он появляется
              SizedBox(
                width: 24,
                height: 24,
                child: IgnorePointer(
                  ignoring: !_hover,
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 110),
                    opacity: _hover ? 1 : 0,
                    child: Tooltip(
                      message: 'Добавить тег',
                      child: InkWell(
                        borderRadius: BorderRadius.circular(99),
                        onTap: _edit,
                        child: Container(
                          decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: C.line)),
                          child: const Icon(Icons.add_rounded, size: 15, color: C.muted),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ]),
          );
        }),
      ),
    );
  }

  void _open(String tagId) => NavScope.of(context).go(Nav('tag', tagId));
}

/// Окно «Теги»: поле для новых и таблетки всех моих тегов. Нажатие вешает тег на все [tracks] или снимает с них.
/// «Есть у части» — тег с минусом: нажатие вешает его на все
Future<void> showTagsDialog(BuildContext context, List<Track> tracks) {
  if (tracks.isEmpty) return Future.value();
  return showGlassDialog<void>(context: context, builder: (_) => _TagsDialog(tracks: tracks));
}

class _TagsDialog extends StatefulWidget {
  final List<Track> tracks;
  const _TagsDialog({required this.tracks});
  @override
  State<_TagsDialog> createState() => _TagsDialogState();
}

class _TagsDialogState extends State<_TagsDialog> {
  final _input = TextEditingController();
  final _focus = FocusNode();
  static final _sepChar = RegExp(r'[\s,#|]');

  List<String> get _ids => [for (final t in widget.tracks) t.id];

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Создаёт теги с этими именами (если их ещё нет) и вешает на все выбранные треки
  void _apply(Iterable<String> names) {
    final lib = Services.of(context).lib;
    final ids = lib.ensureTags(names);
    if (ids.isEmpty) return;
    lib.setTagsOn(_ids, {for (final id in ids) id: true});
  }

  void _changed(String v) {
    if (!v.contains(_sepChar)) {
      setState(() {});
      return;
    }
    // Пробел, запятая и «#» заканчивают тег: всё, кроме последнего недописанного слова, уже готово
    final parts = v.split(RegExp(r'[\s,#|]+'));
    final ends = _sepChar.hasMatch(v[v.length - 1]);
    final done = ends ? parts : parts.sublist(0, parts.length - 1);
    final rest = ends ? '' : parts.last;
    _apply(done);
    _input.value = TextEditingValue(text: rest, selection: TextSelection.collapsed(offset: rest.length));
    setState(() {});
  }

  void _submit(String v) {
    _apply(splitTagNames(v));
    _input.clear();
    setState(() {});
    _focus.requestFocus();
  }

  void _toggle(String tagId, int state) {
    Services.of(context).lib.setTagsOn(_ids, {tagId: state != 1});
  }

  @override
  Widget build(BuildContext context) {
    final app = Services.of(context);
    final many = widget.tracks.length > 1;
    return ListenableBuilder(
      listenable: app.lib,
      builder: (context, _) {
        final book = app.lib.myTags;
        final typed = cleanTagName(_input.text);
        final all = book.all;
        final shown = [for (final t in all) if (typed.isEmpty || t.name.contains(typed)) t];
        int stateOf(String id) {
          final n = widget.tracks.where((t) => book.has(t.id, id)).length;
          return n == 0 ? 0 : (n == widget.tracks.length ? 1 : 2);
        }

        return AlertDialog(
          title: Text('Теги', style: display(20)),
          content: SizedBox(
            width: 460,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(
                many ? 'Выбрано треков: ${widget.tracks.length}' : '${widget.tracks.first.title} — ${widget.tracks.first.displayArtist}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _input,
                focusNode: _focus,
                autofocus: true,
                maxLength: 64,
                inputFormatters: [FilteringTextInputFormatter.deny(RegExp(r'[|]'))],
                onChanged: _changed,
                onSubmitted: _submit,
                decoration: const InputDecoration(
                  hintText: 'Новый тег. Пробел или Enter — добавить',
                  counterText: '',
                  prefixIcon: Icon(Icons.tag_rounded, size: 18),
                ),
              ),
              const SizedBox(height: 14),
              if (all.isEmpty)
                const Text('Тегов пока нет. Напишите название выше: например, «вечер» или «тренировка».',
                    style: TextStyle(color: C.faint, fontSize: 13, height: 1.4))
              else if (shown.isEmpty)
                Text('Такого тега нет. Нажмите Enter, чтобы создать #$typed и повесить на ${many ? 'выбранные треки' : 'трек'}.',
                    style: const TextStyle(color: C.faint, fontSize: 13, height: 1.4))
              else
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 260),
                  child: SingleChildScrollView(
                    child: Wrap(spacing: 8, runSpacing: 8, children: [
                      for (final t in shown)
                        TagChip(name: t.name, small: false, state: stateOf(t.id), onTap: () => _toggle(t.id, stateOf(t.id))),
                    ]),
                  ),
                ),
              if (many && all.isNotEmpty) ...[
                const SizedBox(height: 10),
                const Text('Тег с минусом есть только у части выбранных: нажатие повесит его на все, второе нажатие снимет.',
                    style: TextStyle(color: C.faint, fontSize: 12, height: 1.35)),
              ],
            ]),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Готово'))],
        );
      },
    );
  }
}

// ---------- подсказки тегов под полем поиска ----------

class _Hint {
  final String name;
  final int count;
  const _Hint(this.name, this.count);
}

typedef _Tok = ({int start, int end, String frag, bool minus});

/// Оборачивает поле поиска: когда курсор в слове, начинающемся с «#» (или «-#»), под полем появляется список
/// моих тегов. ↑ ↓ — выбор, Enter или Tab — дописать тег, Esc — закрыть. Над списком переключатель «И» / «ИЛИ»
/// для запросов с несколькими тегами
class TagSuggest extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;

  /// Само поле ввода (с этими же controller и focusNode)
  final Widget child;
  const TagSuggest({super.key, required this.controller, required this.focusNode, required this.onChanged, required this.child});

  @override
  State<TagSuggest> createState() => _TagSuggestState();
}

class _TagSuggestState extends State<TagSuggest> {
  final _portal = OverlayPortalController();
  final _link = LayerLink();
  bool _open = false;
  bool _dismissed = false;
  int _hot = 0;
  String _lastFrag = '';

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_sync);
    widget.controller.addListener(_sync);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_portal.isShowing) _portal.show();
    });
  }

  @override
  void didUpdateWidget(TagSuggest old) {
    super.didUpdateWidget(old);
    if (old.focusNode != widget.focusNode) {
      old.focusNode.removeListener(_sync);
      widget.focusNode.addListener(_sync);
    }
    if (old.controller != widget.controller) {
      old.controller.removeListener(_sync);
      widget.controller.addListener(_sync);
    }
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_sync);
    widget.controller.removeListener(_sync);
    super.dispose();
  }

  void _sync() {
    if (!mounted) return;
    final tok = _token();
    final frag = tok == null ? '' : '${tok.minus ? '-' : ''}#${tok.frag}';
    setState(() {
      _open = widget.focusNode.hasFocus;
      if (frag != _lastFrag) {
        _lastFrag = frag;
        _hot = 0;
        _dismissed = false;
      }
    });
  }

  static bool _ws(String c) => c.trim().isEmpty;

  /// Слово с тегом, в котором стоит курсор
  _Tok? _token() {
    final t = widget.controller.text;
    var c = widget.controller.selection.baseOffset;
    if (c < 0 || c > t.length) c = t.length;
    var s = c;
    while (s > 0 && !_ws(t[s - 1])) {
      s--;
    }
    var e = c;
    while (e < t.length && !_ws(t[e])) {
      e++;
    }
    final tok = t.substring(s, e);
    if (tok.contains('|')) return null;
    if (tok.startsWith('-#')) return (start: s, end: e, frag: tok.substring(2), minus: true);
    if (tok.startsWith('#')) return (start: s, end: e, frag: tok.substring(1), minus: false);
    return null;
  }

  ({List<_Hint> rows, bool noTags, bool pair, bool any, _Tok tok})? _state() {
    if (!_open || _dismissed) return null;
    final tok = _token();
    if (tok == null) return null;
    final lib = Services.of(context).lib;
    final book = lib.myTags;
    final text = widget.controller.text;
    final others = parseTagQuery(text.replaceRange(tok.start, tok.end, ''));
    final used = {...others.include, ...others.exclude};
    final f = cleanTagName(tok.frag);
    final me = lib.me ?? '';
    final rows = [
      for (final t in book.all)
        if (!used.contains(t.name) && (f.isEmpty || t.name.contains(f))) _Hint(t.name, lib.tagCount(me, t.id)),
    ]..sort((a, b) {
        final pa = a.name.startsWith(f) ? 0 : 1, pb = b.name.startsWith(f) ? 0 : 1;
        if (pa != pb) return pa - pb;
        return f.isEmpty ? b.count - a.count : a.name.compareTo(b.name);
      });
    final any = parseTagQuery(text).any;
    return (rows: rows.take(8).toList(), noTags: book.isEmpty, pair: others.include.isNotEmpty && !tok.minus, any: any, tok: tok);
  }

  void _setText(String text, int cursor) {
    widget.controller.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: cursor));
    widget.onChanged(text);
  }

  void _pick(_Hint h, _Tok tok) {
    final t = widget.controller.text;
    final ins = '${tok.minus ? '-' : ''}#${h.name} ';
    final tail = t.substring(tok.end).trimLeft();
    _setText(t.substring(0, tok.start) + ins + tail, tok.start + ins.length);
  }

  /// «ИЛИ»: перед набираемым тегом ставится «|»; «И»: все «|» убираются
  void _connector(bool any, _Tok tok) {
    final t = widget.controller.text;
    if (any) {
      if (parseTagQuery(t).any) return;
      _setText('${t.substring(0, tok.start)}| ${t.substring(tok.start)}', tok.end + 2);
    } else {
      final next = t.replaceAll(RegExp(r'\s*\|\s*'), ' ');
      _setText(next, next.length);
    }
  }

  KeyEventResult _key(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final st = _state();
    if (st == null) return KeyEventResult.ignored;
    final key = e.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      setState(() => _dismissed = true);
      return KeyEventResult.handled;
    }
    if (st.rows.isEmpty) return KeyEventResult.ignored;
    final n = st.rows.length;
    if (key == LogicalKeyboardKey.arrowDown) {
      setState(() => _hot = (_hot + 1) % n);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      setState(() => _hot = (_hot - 1 + n) % n);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter || key == LogicalKeyboardKey.tab) {
      _pick(st.rows[_hot.clamp(0, n - 1)], st.tok);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Widget _popup(BuildContext overlayContext) {
    final st = _state();
    if (st == null) return const SizedBox.shrink();
    if (st.rows.isEmpty && !st.noTags) return const SizedBox.shrink();
    var width = 280.0;
    final box = context.findRenderObject();
    if (box is RenderBox && box.attached && box.hasSize && box.size.width > width) width = box.size.width;
    final hot = _hot.clamp(0, st.rows.isEmpty ? 0 : st.rows.length - 1);

    Widget mode(String label, bool on, VoidCallback tap) => InkWell(
          canRequestFocus: false,
          borderRadius: BorderRadius.circular(99),
          onTap: tap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(99),
              color: on ? C.accent.withValues(alpha: 0.18) : null,
              border: Border.all(color: on ? C.accent : C.line),
            ),
            child: Text(label, style: TextStyle(fontSize: 12.5, color: on ? C.accent : C.muted, fontWeight: FontWeight.w600)),
          ),
        );

    return Align(
      alignment: Alignment.topLeft,
      child: CompositedTransformFollower(
        link: _link,
        targetAnchor: Alignment.bottomLeft,
        followerAnchor: Alignment.topLeft,
        offset: const Offset(0, 6),
        child: TextFieldTapRegion(
          child: SizedBox(
            width: width,
            child: GlassPanel(
              radius: 14,
              tint: C.glassLight,
              blur: 32,
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Material(
                type: MaterialType.transparency,
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  if (st.pair)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                      child: Row(children: [
                        const Text('Искать треки с', style: TextStyle(fontSize: 12, color: C.faint)),
                        const SizedBox(width: 8),
                        mode('всеми (И)', !st.any, () => _connector(false, st.tok)),
                        const SizedBox(width: 6),
                        mode('любым (ИЛИ)', st.any, () => _connector(true, st.tok)),
                      ]),
                    ),
                  if (st.rows.isEmpty)
                    const Padding(
                      padding: EdgeInsets.fromLTRB(14, 8, 14, 8),
                      child: Text('Тегов пока нет. Добавьте их по правому клику на треке: «Теги…».',
                          style: TextStyle(fontSize: 12.5, color: C.faint, height: 1.4)),
                    ),
                  for (var i = 0; i < st.rows.length; i++)
                    InkWell(
                      canRequestFocus: false,
                      onTap: () => _pick(st.rows[i], st.tok),
                      child: Container(
                        height: 36,
                        color: i == hot ? C.hover : null,
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        child: Row(children: [
                          Icon(Icons.tag_rounded, size: 16, color: i == hot ? C.accent : C.faint),
                          const SizedBox(width: 8),
                          Expanded(child: Text(st.rows[i].name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14))),
                          Text('${st.rows[i].count}', style: const TextStyle(fontSize: 12, color: C.faint)),
                        ]),
                      ),
                    ),
                  if (st.rows.isNotEmpty)
                    const Padding(
                      padding: EdgeInsets.fromLTRB(14, 6, 14, 2),
                      child: Text('↑ ↓ и Enter — выбрать · «-#тег» — исключить · «|» — ИЛИ',
                          style: TextStyle(fontSize: 11, color: C.faint)),
                    ),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      onKeyEvent: _key,
      skipTraversal: true,
      canRequestFocus: false,
      child: OverlayPortal(
        controller: _portal,
        overlayChildBuilder: _popup,
        child: CompositedTransformTarget(link: _link, child: widget.child),
      ),
    );
  }
}
