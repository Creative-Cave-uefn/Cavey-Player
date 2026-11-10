import 'package:flutter_test/flutter_test.dart';
import 'package:cave_player/core/dj_live_math.dart';

void main() {
  test('equal power at center and correct endpoint isolation', () {
    final left = djCrossfaderGains(0);
    final middle = djCrossfaderGains(0.5);
    final right = djCrossfaderGains(1);
    expect(left.$1, closeTo(1, 0.0001));
    expect(left.$2, closeTo(0, 0.0001));
    expect(right.$1, closeTo(0, 0.0001));
    expect(right.$2, closeTo(1, 0.0001));
    expect(middle.$1 * middle.$1 + middle.$2 * middle.$2,
        closeTo(1, 0.0001));
    expect(djCrossfaderGains(0.5, master: 0.7).$1, lessThan(0.5));
  });

  test('sync accepts close BPM and half-time annotations', () {
    expect(
        djSyncRate(leaderBpm: 128, leaderRate: 1, followerBpm: 125),
        closeTo(1.024, 0.0001));
    expect(
        djSyncRate(leaderBpm: 128, leaderRate: 1, followerBpm: 64),
        closeTo(1, 0.0001));
    expect(
        djSyncRate(leaderBpm: 128, leaderRate: 1, followerBpm: 90),
        isNull);
  });

  test('beat phase nudge chooses the nearest beat', () {
    expect(
        djBeatNudgeMs(
            leaderPositionMs: 1000,
            leaderBeatOriginMs: 0,
            leaderBpm: 120,
            followerPositionMs: 1125,
            followerBeatOriginMs: 0,
            followerBpm: 120),
        closeTo(-125, 0.001));
    expect(
        djBeatNudgeMs(
            leaderPositionMs: 1000,
            leaderBeatOriginMs: 0,
            leaderBpm: 120,
            followerPositionMs: 1400,
            followerBeatOriginMs: 0,
            followerBpm: 120),
        closeTo(100, 0.001));
  });
}
