import 'dart:async';

import 'package:flutter/material.dart';

import '../core/deezer_art.dart';
import '../core/models.dart';
import 'cover_picker.dart';
import 'theme.dart';

/// Unsaved Deezer results. They remain separate for each track; nothing is
/// written to the shared Google Drive library until the dialog is saved.
class BatchDeezerDraft {
  final Map<String, Map<String, String>> metadata = {};
  final Map<String, PickedCover> covers = {};
  final ValueNotifier<bool> busy = ValueNotifier(false);
}

class BatchDeezerActions extends StatefulWidget {
  final List<Track> tracks;
  final BatchDeezerDraft draft;

  const BatchDeezerActions({super.key, required this.tracks, required this.draft});

  @override
  State<BatchDeezerActions> createState() => _BatchDeezerActionsState();
}

class _BatchDeezerActionsState extends State<BatchDeezerActions> {
  bool _working = false;
  bool _artwork = false;
  int _finished = 0;
  int _found = 0;
  String _message = '';

  Future<void> _fetch({required bool artwork}) async {
    if (_working) return;
    setState(() {
      _working = true;
      _artwork = artwork;
      _finished = 0;
      _found = 0;
      _message = artwork ? 'Ищу обложки в Deezer…' : 'Ищу названия и теги в Deezer…';
    });
    widget.draft.busy.value = true;
    var index = 0;
    try {
      Future<void> worker() async {
        while (mounted && index < widget.tracks.length) {
          final track = widget.tracks[index++];
          var success = false;
          try {
            if (track.artist.trim().isNotEmpty && track.title.trim().isNotEmpty) {
              if (artwork) {
                final result = await DeezerArt.find(
                  artist: track.artist,
                  title: track.title,
                  album: track.album,
                ).timeout(const Duration(seconds: 20));
                if (mounted && result != null) {
                  widget.draft.covers[track.id] = PickedCover(result.bytes, 'jpg');
                  success = true;
                }
              } else {
                final result = await DeezerArt.findMetadata(
                  artist: track.artist,
                  title: track.title,
                  album: track.album,
                ).timeout(const Duration(seconds: 12));
                if (mounted && result != null) {
                  widget.draft.metadata[track.id] = {
                    if (result.title.trim().isNotEmpty) 't': result.title.trim(),
                    if (result.artist.trim().isNotEmpty) 'a': result.artist.trim(),
                    if (result.album.trim().isNotEmpty) 'al': result.album.trim(),
                  };
                  success = widget.draft.metadata[track.id]!.isNotEmpty;
                }
              }
            }
          } catch (_) {
            // One unavailable song or Deezer timeout must never abort a batch.
          }
          if (!mounted) return;
          setState(() {
            _finished++;
            if (success) _found++;
            _message = '${artwork ? "Обложки" : "Названия"}: найдено $_found из $_finished; '
                'проверено $_finished из ${widget.tracks.length}.';
          });
        }
      }

      await Future.wait([
        for (var i = 0; i < 3 && i < widget.tracks.length; i++) worker(),
      ]);
      if (mounted) {
        setState(() => _message =
            '${artwork ? "Обложки" : "Названия"}: найдено $_found из ${widget.tracks.length}. '
            'Изменения применятся после «Сохранить».');
      }
    } finally {
      if (mounted) setState(() => _working = false);
      widget.draft.busy.value = false;
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 12, bottom: 4),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: 8, runSpacing: 8, children: [
        OutlinedButton.icon(
          onPressed: _working ? null : () => _fetch(artwork: true),
          icon: _working && _artwork
              ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.image_search_rounded, size: 18),
          label: const Text('Найти обложки в Deezer'),
        ),
        OutlinedButton.icon(
          onPressed: _working ? null : () => _fetch(artwork: false),
          icon: _working && !_artwork
              ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.auto_fix_high_rounded, size: 18),
          label: const Text('Найти названия в Deezer'),
        ),
      ]),
      if (_message.isNotEmpty) ...[
        const SizedBox(height: 8),
        Text(_message, style: const TextStyle(color: C.muted, fontSize: 12)),
      ],
      if (_working) ...[
        const SizedBox(height: 6),
        LinearProgressIndicator(value: widget.tracks.isEmpty ? null : _finished / widget.tracks.length),
      ],
      if (widget.draft.metadata.isNotEmpty || widget.draft.covers.isNotEmpty) ...[
        const SizedBox(height: 5),
        Text('Подготовлено: ${widget.draft.metadata.length} названий, '
             '${widget.draft.covers.length} обложек.',
             style: const TextStyle(color: C.faint, fontSize: 12)),
      ],
    ]),
  );
}
