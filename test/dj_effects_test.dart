import 'package:flutter_test/flutter_test.dart';
import 'package:cave_player/core/dj_effects.dart';
void main() {
  test('uncertain rhythm never requests a quantized effect', () {
    expect(chooseDjEffect(vocalRisk:1,onsets:4,brightness:4000,reliableBeat:false),DjEffect.none);
    expect(chooseDjEffect(vocalRisk:1,onsets:4,brightness:4000,reliableBeat:true),DjEffect.echoOut);
    expect(chooseDjEffect(vocalRisk:0,onsets:4,brightness:4000,reliableBeat:true),DjEffect.rhythmicGate);
    expect(chooseDjEffect(vocalRisk:0,onsets:1,brightness:4000,reliableBeat:true),DjEffect.filterOut);
  });
  test('echo delay follows tempo and is bounded', () {
    final a=djEffectGraph(DjEffect.echoOut,input:'[in]',output:'[out]',start:20,length:8,beat:0.5);
    final b=djEffectGraph(DjEffect.echoOut,input:'[in]',output:'[out]',start:20,length:8,beat:1);
    expect(a,contains('375|750'));expect(b,contains('750|1500'));
    expect(a,contains('gte(t,26.0)'));
  });
}
