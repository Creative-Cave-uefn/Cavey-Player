import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app.dart';
import '../core/library.dart';
import '../core/models.dart';
import 'cover_picker.dart';
import 'glass_popup.dart';
import 'theme.dart';
import 'widgets.dart';

/// Большая обложка в шапке альбома или плейлиста: клик — посмотреть на весь экран,
/// при наведении в правом нижнем углу кнопка с карандашом — правка
class HeaderCover extends StatefulWidget {
  final Track? track;
  final String? fileId;
  final String? label;
  final double size;
  final VoidCallback? onEdit;
  final String editTooltip;
  const HeaderCover({
    super.key,
    required this.track,
    required this.size,
    this.fileId,
    this.label,
    this.onEdit,
    this.editTooltip = 'Изменить',
  });

  @override
  State<HeaderCover> createState() => _HeaderCoverState();
}

class _HeaderCoverState extends State<HeaderCover> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final canView = widget.track != null || widget.fileId != null;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: canView ? SystemMouseCursors.click : MouseCursor.defer,
      child: SizedBox.square(
        dimension: widget.size,
        child: Stack(children: [
          Positioned.fill(
            child: GestureDetector(
              onTap: canView ? () => showCoverViewer(context, track: widget.track, fileId: widget.fileId) : null,
              child: CoverImage(track: widget.track, fileId: widget.fileId, label: widget.label, size: widget.size, radius: 12),
            ),
          ),
          if (widget.onEdit != null)
            Positioned(
              right: 8,
              bottom: 8,
              child: AnimatedOpacity(
                opacity: _hover ? 1 : 0,
                duration: const Duration(milliseconds: 140),
                child: IgnorePointer(
                  ignoring: !_hover,
                  child: Tooltip(
                    message: widget.editTooltip,
                    child: Material(
                      color: Colors.black.withValues(alpha: 0.55),
                      shape: const CircleBorder(),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: widget.onEdit,
                        child: const Padding(
                          padding: EdgeInsets.all(8),
                          child: Icon(Icons.edit_rounded, size: 18, color: Colors.white),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}

/// Обложка на весь экран: колесо — масштаб к точке под курсором, зажатая левая кнопка — двигать.
/// Закрывается по Esc, клику по фону или крестиком
Future<void> showCoverViewer(BuildContext context, {Track? track, String? fileId}) {
  final covers = Services.of(context).covers;
  final Future<Uint8List?> bytes = fileId != null
      ? covers.forFile(fileId)
      : (track != null ? covers.forTrack(track) : Future<Uint8List?>.value(null));
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Закрыть',
    barrierColor: Colors.black.withValues(alpha: 0.86),
    transitionDuration: const Duration(milliseconds: 160),
    pageBuilder: (ctx, _, __) => _CoverViewer(bytes: bytes),
    transitionBuilder: (ctx, a, _, child) => FadeTransition(opacity: a, child: child),
  );
}

class _CoverViewer extends StatefulWidget {
  final Future<Uint8List?> bytes;
  const _CoverViewer({required this.bytes});

  @override
  State<_CoverViewer> createState() => _CoverViewerState();
}

class _CoverViewerState extends State<_CoverViewer> {
  final _tc = TransformationController();

  @override
  void dispose() {
    _tc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.of(context).maybePop()},
      child: Focus(
        autofocus: true,
        child: Stack(children: [
          // Клик мимо картинки закрывает просмотр
          Positioned.fill(child: GestureDetector(onTap: () => Navigator.of(context).maybePop())),
          Positioned.fill(
            child: FutureBuilder<Uint8List?>(
              future: widget.bytes,
              builder: (context, snap) {
                final b = snap.data;
                if (snap.connectionState != ConnectionState.done) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (b == null) {
                  return const Center(child: Text('Картинку не получилось загрузить', style: TextStyle(color: Colors.white70)));
                }
                return LayoutBuilder(builder: (context, box) {
                  final side = (box.biggest.shortestSide - 80).clamp(120.0, 4000.0);
                  return InteractiveViewer(
                    transformationController: _tc,
                    minScale: 1,
                    maxScale: 10,
                    clipBehavior: Clip.none,
                    boundaryMargin: EdgeInsets.all(side),
                    child: Center(
                      child: GestureDetector(
                        onTap: () {}, // клик по самой картинке не закрывает
                        onDoubleTap: () => _tc.value = Matrix4.identity(),
                        child: SizedBox.square(
                          dimension: side,
                          child: Image.memory(b, fit: BoxFit.contain, filterQuality: FilterQuality.high, gaplessPlayback: true),
                        ),
                      ),
                    ),
                  );
                });
              },
            ),
          ),
          Positioned(
            top: 44,
            right: 20,
            child: IconButton.filledTonal(
              tooltip: 'Закрыть (Esc)',
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(Icons.close_rounded),
            ),
          ),
        ]),
      ),
    );
  }
}

/// Окно «Альбом»: название, обложка, год, исполнитель альбома. Применяется ко всем трекам альбома
Future<void> editAlbumDialog(BuildContext context, Album a) async {
  final lib = Services.of(context).lib;
  String common(String Function(Track) f) {
    final first = f(a.tracks.first);
    return a.tracks.every((t) => f(t) == first) ? first : '';
  }

  final initTitle = a.title;
  final initYear = a.year;
  final initArtist = common((t) => t.albumArtist).isNotEmpty
      ? common((t) => t.albumArtist)
      : (a.artist == 'Разные исполнители' ? '' : a.artist);
  final title = TextEditingController(text: initTitle);
  final year = TextEditingController(text: initYear);
  final artist = TextEditingController(text: initArtist);
  final choice = CoverChoice();
  final ok = await showGlassDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Альбом', style: display(18)),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            CoverEditorView(
              choice: choice,
              current: CoverImage(track: a.coverTrack, size: 120, radius: 0),
              canReset: lib.albumCover(a.key) != null,
            ),
            const SizedBox(height: 18),
            const Text('Название', style: TextStyle(color: C.muted, fontSize: 13)),
            const SizedBox(height: 6),
            TextField(controller: title, autofocus: true),
            const SizedBox(height: 14),
            const Text('Исполнитель альбома', style: TextStyle(color: C.muted, fontSize: 13)),
            const SizedBox(height: 6),
            TextField(controller: artist, decoration: const InputDecoration(hintText: 'Например, ATLUS Sound Team')),
            const SizedBox(height: 14),
            const Text('Год', style: TextStyle(color: C.muted, fontSize: 13)),
            const SizedBox(height: 6),
            SizedBox(
              width: 120,
              child: TextField(
                controller: year,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(4)],
              ),
            ),
            const SizedBox(height: 14),
            Text(
              'Изменится у всех ${countTracks(a.tracks.length)} альбома, и это увидят все друзья. '
              'Исполнители отдельных треков не меняются. Сами файлы на Диске остаются как были.',
              style: const TextStyle(color: C.faint, fontSize: 12, height: 1.4),
            ),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена', style: TextStyle(color: C.muted))),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Сохранить')),
      ],
    ),
  );
  if (ok != true) return;
  final t = title.text.trim();
  if (t.isEmpty) {
    lib.messages.add('Название альбома не может быть пустым');
    return;
  }
  final cover = context.mounted ? await choice.commit(context) : null;
  final y = year.text.trim();
  final ar = artist.text.trim();
  lib.editAlbum(
    a,
    title: t != initTitle ? t : null,
    year: y != initYear ? y : null,
    albumArtist: ar != initArtist ? ar : null,
    cover: cover,
  );
  lib.messages.add('Альбом «$t» обновлён');
}

/// Окно «Плейлист»: название и обложка
Future<void> editPlaylistDialog(BuildContext context, Playlist p, {Track? coverTrack}) async {
  final lib = Services.of(context).lib;
  final own = lib.playlistCover(p.id);
  final name = TextEditingController(text: p.name);
  final choice = CoverChoice();
  final ok = await showGlassDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Плейлист', style: display(18)),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            CoverEditorView(
              choice: choice,
              current: CoverImage(track: coverTrack, fileId: own, label: p.name, size: 120, radius: 0),
              canReset: own != null,
              note: 'Обложку и название увидят все, кому виден плейлист.',
            ),
            const SizedBox(height: 18),
            const Text('Название', style: TextStyle(color: C.muted, fontSize: 13)),
            const SizedBox(height: 6),
            TextField(controller: name, autofocus: true),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена', style: TextStyle(color: C.muted))),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Сохранить')),
      ],
    ),
  );
  if (ok != true) return;
  final n = name.text.trim();
  if (n.isNotEmpty && n != p.name) lib.renamePlaylist(p.id, n);
  final cover = context.mounted ? await choice.commit(context) : null;
  if (cover != null) lib.setPlaylistCover(p.id, cover);
}
