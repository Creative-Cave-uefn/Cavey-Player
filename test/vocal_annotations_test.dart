import 'package:flutter_test/flutter_test.dart';
import 'package:cave_player/core/intel/sections.dart';
import 'package:cave_player/core/intel/vocal_annotations.dart';
import 'sections_test.dart' show region;

void main() {
  test('reviewed evidence overlays only sufficiently covered windows', () {
    final source = SectionIndex([region(0), region(4000)]);
    final result = applyVocalAnnotations(source, [const VocalObservation(0, 4000, 0.9, 0.95)], 'annotation');
    expect(result.at(0, 4000)!.vocalProbability, closeTo(0.9, 1e-9));
    expect(result.at(4000, 4000)!.vocalProbability, isNull);
    expect(source.regions.first.vocalProbability, isNull);
  });
  test('partial or low-confidence annotations do not turn unknown into absence', () {
    final source = SectionIndex([region(0)]);
    final partial = applyVocalAnnotations(source, [const VocalObservation(0, 1000, 0, 1)], 'annotation');
    final weak = applyVocalAnnotations(source, [const VocalObservation(0, 4000, 0, 0.2)], 'model:test');
    expect(partial.at(0, 4000)!.vocalProbability, isNull);
    expect(weak.at(0, 4000)!.vocalProbability, isNull);
  });
  test('overlap, invalid provenance and out-of-range probabilities are rejected', () {
    final source = SectionIndex([region(0)]);
    expect(() => applyVocalAnnotations(source, [const VocalObservation(0, 3000, 1, 1),
      const VocalObservation(2000, 4000, 0, 1)], 'annotation'), throwsFormatException);
    expect(() => applyVocalAnnotations(source, [], 'heuristic'), throwsFormatException);
    expect(() => VocalObservation.parse({'startMs': 0, 'endMs': 4000, 'probability': 2, 'confidence': 1}), throwsFormatException);
  });
}
