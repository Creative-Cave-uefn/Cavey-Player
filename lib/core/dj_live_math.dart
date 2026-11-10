import 'dart:math' as math;

/// Equal-power curve with a conservative master trim to leave headroom.
/// Left at 0, right at 1. At the midpoint both channels are -3 dB.
(double, double) djCrossfaderGains(double position, {double master = 1}) {
  final x = position.clamp(0.0, 1.0).toDouble();
  final gain = master.clamp(0.0, 1.0).toDouble();
  return (math.cos(x * math.pi / 2) * gain,
      math.sin(x * math.pi / 2) * gain);
}

/// Match a follower deck to the tempo of the leader.
/// Half-time and double-time BPM estimates are treated as the same beat grid.
double? djSyncRate({
  required double leaderBpm,
  required double leaderRate,
  required double followerBpm,
  double maxStretch = 0.16,
}) {
  if (leaderBpm <= 0 || followerBpm <= 0 || leaderRate <= 0) return null;
  double? best;
  for (final factor in const [0.5, 1.0, 2.0]) {
    final rate = leaderBpm * leaderRate * factor / followerBpm;
    if (best == null || (rate - 1).abs() < (best - 1).abs()) best = rate;
  }
  if (best == null || (best - 1).abs() > maxStretch) return null;
  return best;
}

/// Seek correction in *follower media milliseconds* to line up beat phases.
/// Correct by at most half a beat, choosing the shortest possible nudge.
double djBeatNudgeMs({
  required double leaderPositionMs,
  required double leaderBeatOriginMs,
  required double leaderBpm,
  required double followerPositionMs,
  required double followerBeatOriginMs,
  required double followerBpm,
}) {
  if (leaderBpm <= 0 || followerBpm <= 0) return 0;
  final leaderBeat = 60000 / leaderBpm;
  final followerBeat = 60000 / followerBpm;
  final leaderPhase = (leaderPositionMs - leaderBeatOriginMs) / leaderBeat;
  final followerPhase = (followerPositionMs - followerBeatOriginMs) / followerBeat;
  var delta = (leaderPhase - followerPhase) % 1;
  if (delta > 0.5) delta -= 1;
  return delta * followerBeat;
}
