import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/library.dart' show LibraryController;
import '../core/models.dart';
import '../core/suggest.dart';
import 'theme.dart';
import 'widgets.dart';

/// Поле ввода с выпадающим под ним списком подсказок (3–4 строки, дальше прокрутка).
/// Список раскладывается в самой форме, а не поверх неё, поэтому работает внутри диалогов с прокруткой.
/// Первая строка — «Создать «…»», если такого значения ещё нет; клавиши: ↑ ↓ — выбор, Enter — подставить, Esc — закрыть
class SuggestField extends StatefulWidget {
  final TextEditingController controller;
  final List<Suggestion> Function() source;

  /// Через запятую можно перечислить нескольких исполнителей: подсказки для последнего
  final bool multi;
  final ValueChanged<String>? onChanged;
  final InputDecoration? decoration;
  final bool autofocus;
  const SuggestField({
    super.key,
    required this.controller,
    required this.source,
    this.multi = false,
    this.onChanged,
    this.decoration,
    this.autofocus = false,
  });

  @override
  State<SuggestField> createState() => _SuggestFieldState();
}

class _Row {
  final String text;
  final Suggestion? s;
  final bool create;
  const _Row(this.text, this.s, this.create);
}

class _SuggestFieldState extends State<SuggestField> {
  static const _rowHeight = 46.0;
  final _focus = FocusNode();
  final _scroll = ScrollController();
  List<Suggestion>? _all;
  bool _open = false;
  int _hot = -1;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_focusChanged);
  }

  @override
  void dispose() {
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _focusChanged() {
    if (!mounted) return;
    setState(() {
      _open = _focus.hasFocus;
      _hot = -1;
    });
    if (_open) _reveal();
  }

  /// Чтобы список был виден целиком внутри прокручиваемого диалога
  void _reveal() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_open) return;
      Scrollable.maybeOf(context)?.position.ensureVisible(
            context.findRenderObject()!,
            alignment: 0.2,
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOutCubic,
          );
    });
  }

  String get _query => widget.multi ? splitLastArtist(widget.controller.text).tail : widget.controller.text;

  List<_Row> _rows() {
    final all = _all ??= widget.source();
    final q = _query.trim();
    final found = rankSuggestions(all, q);
    return [
      if (q.isNotEmpty && !hasExactSuggestion(all, q)) _Row('Создать «$q»', null, true),
      for (final s in found) _Row(s.text, s, false),
    ];
  }

  void _pick(_Row r) {
    final value = r.create ? _query.trim() : r.text;
    final head = widget.multi ? splitLastArtist(widget.controller.text).head : '';
    final text = head.isEmpty ? value : '$head $value';
    widget.controller.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
    widget.onChanged?.call(text);
    setState(() {
      _open = false;
      _hot = -1;
    });
  }

  KeyEventResult _key(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final key = e.logicalKey;
    if (key == LogicalKeyboardKey.escape && _open) {
      setState(() => _open = false);
      return KeyEventResult.handled;
    }
    final rows = _rows();
    if (key == LogicalKeyboardKey.arrowDown || key == LogicalKeyboardKey.arrowUp) {
      if (rows.isEmpty) return KeyEventResult.ignored;
      setState(() {
        _open = true;
        final d = key == LogicalKeyboardKey.arrowDown ? 1 : -1;
        _hot = (_hot + d).clamp(0, rows.length - 1);
      });
      _scrollToHot();
      return KeyEventResult.handled;
    }
    if ((key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) && _open && _hot >= 0 && _hot < rows.length) {
      _pick(rows[_hot]);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _scrollToHot() {
    if (!_scroll.hasClients || _hot < 0) return;
    final top = _hot * _rowHeight;
    final view = _scroll.position.viewportDimension;
    if (top < _scroll.offset) {
      _scroll.jumpTo(top);
    } else if (top + _rowHeight > _scroll.offset + view) {
      _scroll.jumpTo(top + _rowHeight - view);
    }
  }

  Widget _leading(_Row r) {
    if (r.create) return Icon(Icons.add_circle_outline_rounded, size: 20, color: C.accent);
    final ref = r.s?.ref;
    if (ref is Track) return CoverImage(track: ref, size: 30, radius: 4);
    return const Icon(Icons.person_outline_rounded, size: 20, color: C.muted);
  }

  @override
  Widget build(BuildContext context) {
    final rows = _open ? _rows() : const <_Row>[];
    final shown = rows.length.clamp(0, 4);
    return Focus(
      onKeyEvent: _key,
      skipTraversal: true,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        TextField(
          controller: widget.controller,
          focusNode: _focus,
          autofocus: widget.autofocus,
          decoration: widget.decoration,
          onTap: () {
            if (!_open) setState(() => _open = true);
          },
          onChanged: (v) {
            widget.onChanged?.call(v);
            setState(() {
              _open = true;
              _hot = -1;
            });
            if (_scroll.hasClients) _scroll.jumpTo(0);
          },
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: shown == 0
              ? const SizedBox(width: double.infinity)
              : TextFieldTapRegion(
                  child: Container(
                    margin: const EdgeInsets.only(top: 4),
                    height: shown * _rowHeight,
                    decoration: BoxDecoration(
                      color: C.panelRaised,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: C.line),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Scrollbar(
                      controller: _scroll,
                      thumbVisibility: rows.length > 4,
                      child: ListView.builder(
                        controller: _scroll,
                        padding: EdgeInsets.zero,
                        itemExtent: _rowHeight,
                        itemCount: rows.length,
                        itemBuilder: (_, i) {
                          final r = rows[i];
                          return InkWell(
                            canRequestFocus: false,
                            onTap: () => _pick(r),
                            child: Container(
                              color: i == _hot ? C.hover : null,
                              padding: const EdgeInsets.symmetric(horizontal: 10),
                              child: Row(children: [
                                SizedBox(width: 30, child: Center(child: _leading(r))),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                                    Text(r.text,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(fontSize: 14, color: r.create ? C.accent : C.text)),
                                    if (!r.create && (r.s?.sub ?? '').isNotEmpty)
                                      Text(r.s!.sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: C.faint)),
                                  ]),
                                ),
                              ]),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
        ),
      ]),
    );
  }
}

/// Подсказки исполнителей и альбомов из библиотеки
List<Suggestion> libraryArtistSuggestions(LibraryController lib) =>
    [for (final a in lib.artists) Suggestion(a.name, sub: countTracks(a.tracks.length), weight: a.tracks.length)];

List<Suggestion> libraryAlbumSuggestions(LibraryController lib) =>
    [for (final a in lib.albums) Suggestion(a.title, sub: a.artist, ref: a.coverTrack, weight: a.tracks.length)];
