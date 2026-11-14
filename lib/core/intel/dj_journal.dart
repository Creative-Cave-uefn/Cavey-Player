import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Local, bounded decision/execution journal. It stores IDs and measurements,
/// never Drive URLs, OAuth headers or decoded audio. All writes are serialized.
class DjJournal {
  final Directory dir;
  final int maxBytes;
  final String session;
  final void Function(Object)? onError;
  Future<void> _pending = Future.value();
  DjJournal(this.dir, {this.maxBytes = 4 * 1024 * 1024, this.onError})
      : session = DateTime.now().microsecondsSinceEpoch.toString();
  File get file => File('${dir.path}${Platform.pathSeparator}transitions.jsonl');
  File get previous => File('${dir.path}${Platform.pathSeparator}transitions.previous.jsonl');

  void append(Map<String, Object?> event) {
    final snapshot = jsonEncode({'journalVersion': 1, 'session': session,
      'atUtc': DateTime.now().toUtc().toIso8601String(), ...event});
    _pending = _pending.then((_) async {
      await dir.create(recursive: true);
      if (await file.exists() && await file.length() >= maxBytes) {
        if (await previous.exists()) await previous.delete();
        await file.rename(previous.path);
      }
      await file.writeAsString('$snapshot\n', mode: FileMode.append, flush: true);
    }).catchError((Object error) { onError?.call(error); });
  }
  Future<void> flush() => _pending;
  Future<void> exportTo(String path) async {
    await flush();
    final lines = StringBuffer();
    if (await previous.exists()) lines.write(await previous.readAsString());
    if (await file.exists()) lines.write(await file.readAsString());
    await File(path).writeAsString(lines.toString(), flush: true);
  }
}

/// Transport telemetry only: cannot establish true peak, audible clicks or PCM
/// beat accuracy. Keep phase error samples bounded for long blends.
class TransitionProbe {
  final String from, to, technique;
  final String? decisionId;
  final String eqMode;
  final int requestedStartMs, actualStartMs, cueInMs, plannedLengthMs, actualLengthMs, prepareMs;
  final double requestedRate, actualRate;
  final List<double> _phase = [];
  int _phaseCount = 0;
  double _phaseSum = 0, _phaseMax = 0;
  int? bassSwapMs;
  final Stopwatch elapsed = Stopwatch()..start();
  TransitionProbe({required this.from, required this.to, required this.technique,
    this.decisionId, this.eqMode = 'none',
    required this.requestedStartMs, required this.actualStartMs, required this.cueInMs,
    required this.plannedLengthMs, required this.actualLengthMs, required this.prepareMs,
    required this.requestedRate, required this.actualRate});

  void phase(double errorMs) {
    if (!errorMs.isFinite) return;
    final value = errorMs.abs();
    _phaseCount++; _phaseSum += value;
    if (value > _phaseMax) _phaseMax = value;
    if (_phase.length < 2048) _phase.add(value);
  }
  Map<String, Object?> finish(String outcome) {
    elapsed.stop();
    final sorted = List<double>.of(_phase)..sort();
    double? percentile(double fraction) => sorted.isEmpty ? null : sorted[((sorted.length - 1) * fraction).round()];
    return {'kind': 'execution', 'from': from, 'to': to, 'technique': technique, 'outcome': outcome,
      if (decisionId != null) 'decisionId': decisionId, 'eqMode': eqMode,
      'requestedStartMs': requestedStartMs, 'actualStartMs': actualStartMs,
      'startErrorMs': actualStartMs - requestedStartMs, 'cueInMs': cueInMs,
      'plannedLengthMs': plannedLengthMs, 'actualLengthMs': actualLengthMs,
      'elapsedMs': elapsed.elapsedMilliseconds, 'prepareMs': prepareMs,
      'requestedRate': requestedRate, 'actualRate': actualRate, 'bassSwapMs': bassSwapMs,
      'phaseSamples': _phaseCount, 'meanAbsPhaseMs': _phaseCount == 0 ? null : _phaseSum / _phaseCount,
      'medianAbsPhaseMs': percentile(0.5), 'p95AbsPhaseMs': percentile(0.95),
      'maxAbsPhaseMs': _phaseCount == 0 ? null : _phaseMax,
      'measurement': 'transport_estimate_not_output_pcm'};
  }
}
