import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:cave_player/core/intel/dj_journal.dart';
import 'package:cave_player/core/intel/sync.dart';
import 'intel_test.dart' show fakeRecord;

void main() {
  test('journal serializes writes and exports parseable ordered events', () async {
    final dir = await Directory.systemTemp.createTemp('dj-journal-');
    try {
      final journal = DjJournal(dir);
      for (var i = 0; i < 20; i++) { journal.append({'kind': 'decision', 'ordinal': i}); }
      final target = '${dir.path}/export.jsonl';
      await journal.exportTo(target);
      final records = (await File(target).readAsLines()).map((l) => jsonDecode(l) as Map).toList();
      expect(records.map((r) => r['ordinal']), List.generate(20, (i) => i));
      expect(records.every((r) => r['journalVersion'] == 1), isTrue);
    } finally { await dir.delete(recursive: true); }
  });
  test('rotation keeps bounded current and previous files without truncating events', () async {
    final dir = await Directory.systemTemp.createTemp('dj-rotate-');
    try {
      final journal = DjJournal(dir, maxBytes: 250);
      for (var i = 0; i < 20; i++) { journal.append({'ordinal': i}); }
      await journal.flush();
      expect(await journal.previous.exists(), isTrue);
      final records = (await journal.file.readAsLines()).map((l) => jsonDecode(l) as Map).toList();
      expect(records.last['ordinal'], 19);
      expect(await journal.file.length(), lessThan(500));
    } finally { await dir.delete(recursive: true); }
  });
  test('transport diagnostics distinguish timing from actual output PCM', () {
    final probe = TransitionProbe(from: 'a', to: 'b', technique: 'beatBlend',
        requestedStartMs: 1000, actualStartMs: 1040, cueInMs: 2000,
        plannedLengthMs: 16000, actualLengthMs: 15000, prepareMs: 300,
        requestedRate: 1.01, actualRate: 1.01);
    for (final e in [-10.0, 20.0, -30.0, double.nan]) { probe.phase(e); }
    probe.bassSwapMs = 8000;
    final result = probe.finish('completed');
    expect(result['startErrorMs'], 40);
    expect(result['meanAbsPhaseMs'], 20);
    expect(result['phaseSamples'], 3);
    expect(result['maxAbsPhaseMs'], 30);
    expect(result['measurement'], 'transport_estimate_not_output_pcm');
    expect(result['outcome'], 'completed');
  });
  test('richer records are split by byte budget, not just record count', () {
    final records = List.generate(5, (i) => fakeRecord('a$i', 0, i));
    final oneSize = utf8.encode(jsonEncode(records.first.toJson())).length;
    final batch = boundedIntelBatch(records, maxBytes: oneSize + 256 + 10);
    expect(batch.length, 1);
    expect(batch.first.trackId, 'a0');
    expect(boundedIntelBatch([], maxBytes: 1), isEmpty);
  });
}
