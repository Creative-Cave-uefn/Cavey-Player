import 'dart:math' as math;

enum SetIntent { balanced, rise, relax, explore }

class DjHistoryEntry {
  final String id, artist, genre, technique;
  final double energyDb;
  const DjHistoryEntry(this.id, {this.artist = '', this.genre = '', this.technique = '', required this.energyDb});
}

class DjSetContext {
  final SetIntent intent;
  final List<DjHistoryEntry> history;
  const DjSetContext({this.intent = SetIntent.balanced, this.history = const []});

  /// Physical loudness trajectory, not a claim about perceived mood/valence.
  double score(DjHistoryEntry next, {double timbreFit = 0.5}) {
    final recent = history.reversed.take(8).toList();
    var score = 0.0;
    for (var i = 0; i < recent.length; i++) {
      final weight = 1 / (i + 1);
      if (recent[i].id == next.id) score -= 0.3 * weight;
      if (next.artist.isNotEmpty && recent[i].artist == next.artist) score -= 0.1 * weight;
    }
    if (recent.isEmpty) return score;
    final last = recent.first;
    if (next.technique.isNotEmpty && last.technique == next.technique) score -= 0.025;
    if (recent.length >= 2 && recent[0].technique == next.technique && recent[1].technique == next.technique) score -= 0.04;
    final target = switch (intent) {
      SetIntent.rise => math.min(-10.0, last.energyDb + 1.5),
      SetIntent.relax => math.max(-30.0, last.energyDb - 1.5),
      _ => last.energyDb,
    };
    score += 0.12 * math.exp(-(next.energyDb - target).abs() / 8);
    if (intent == SetIntent.explore) {
      score += 0.1 * (1 - timbreFit.clamp(0.0, 1.0));
      if (next.genre.isNotEmpty && !recent.take(3).any((h) => h.genre == next.genre)) score += 0.04;
    }
    if (next.genre.isNotEmpty && recent.length >= 3 && recent.take(3).every((h) => h.genre == next.genre)) score -= 0.035;
    return score;
  }

  DjSetContext append(DjHistoryEntry entry) => DjSetContext(intent: intent, history: [...history, entry].reversed.take(8).toList().reversed.toList());
}
