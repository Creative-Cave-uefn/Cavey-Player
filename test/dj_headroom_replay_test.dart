import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:cave_player/core/automix.dart';
import 'package:cave_player/core/intel/transition_verifier.dart';

void main() {
  final path = Platform.environment['CAVEY_DJ_REPLAY'];
  test('replay a rejected real transition with verified headroom correction', () async {
    final f = jsonDecode(File(path!).readAsStringSync()) as Map;
    final p = MixPlan(Duration(milliseconds:f['outMs']),Duration(milliseconds:f['lengthMs']),
        Duration(milliseconds:f['inMs']), (f['inGain'] as num).toDouble(),
        dj:true, rate:(f['rate'] as num).toDouble(), transpose:f['transpose'],effect:f['effect']);
    final verifier = TransitionVerifier(f['ffmpeg']);
    final a=File(f['a']),b=File(f['b']);
    final first=await verifier.verify(a,b,p);
    expect(first.reason,'true_peak_headroom');
    final gain=headroomCorrection(first);
    expect(gain,isNotNull);
    final fixed=p.withHeadroom(gain!);
    final retry=await verifier.verify(a,b,fixed);
    expect(retry.verdict,TransitionVerdict.accepted,reason:retry.reason);
    expect(fixed.effect,p.effect); expect(fixed.rate,p.rate); expect(fixed.transpose,p.transpose);
    print(jsonEncode({'before':first.toJson(),'after':retry.toJson(),'gain':gain,'effect':fixed.effect}));
  },skip:path==null?'Set CAVEY_DJ_REPLAY to a local replay fixture':false);
}
