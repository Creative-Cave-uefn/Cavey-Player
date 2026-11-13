import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:cave_player/core/crossfade_handoff.dart';

void main() {
  const cue = Duration(seconds: 2);
  const moving = Duration(seconds: 3);
  const duration = Duration(minutes: 3);
  const ready = HandoffState(moving, duration, playing: true, buffering: false);

  test('prepared deck is accepted from its snapshot without another position event', () async {
    expect(await waitForHandoff(read: () => ready, changes: const Stream<void>.empty(),
        isCurrent: () => true, cue: cue), isTrue);
  });

  test('moving deck without duration cannot take over; timeout cancels subscription', () async {
    var cancelled = false;
    final events = StreamController<void>(onCancel: () { cancelled = true; });
    const unknown = HandoffState(moving, Duration.zero, playing: true, buffering: false);
    expect(await waitForHandoff(read: () => unknown, changes: events.stream,
        isCurrent: () => true, cue: cue, timeout: const Duration(milliseconds: 10)), isFalse);
    expect(cancelled, isTrue);
    await events.close();
  });

  test('handoff waits for progress, duration and unbuffered playback together', () async {
    final events = StreamController<void>();
    var state = const HandoffState(cue, duration, playing: true, buffering: true);
    final waiting = waitForHandoff(read: () => state, changes: events.stream,
        isCurrent: () => true, cue: cue);
    state = ready;
    events.add(null);
    expect(await waiting, isTrue);
    await events.close();
  });

  test('pause or seek during preparation invalidates a late ready event', () async {
    final events = StreamController<void>();
    var current = true;
    var state = const HandoffState(cue, duration, playing: true, buffering: true);
    final waiting = waitForHandoff(read: () => state, changes: events.stream,
        isCurrent: () => current, cue: cue);
    current = false;
    state = ready;
    events.add(null);
    expect(await waiting, isFalse);
    await events.close();
  });

  test('a paused or completed deck cannot be promoted despite a nonzero position', () async {
    for (final state in [
      const HandoffState(moving, duration, playing: false, buffering: false),
      const HandoffState(duration, duration, playing: true, buffering: false),
    ]) {
      expect(await waitForHandoff(read: () => state, changes: const Stream<void>.empty(),
          isCurrent: () => true, cue: cue), isFalse);
    }
  });

  test('stream error leaves ownership with the outgoing deck', () async {
    const stalled = HandoffState(cue, duration, playing: true, buffering: true);
    expect(await waitForHandoff(read: () => stalled,
        changes: Stream<void>.error(StateError('decoder failed')),
        isCurrent: () => true, cue: cue), isFalse);
  });
}
