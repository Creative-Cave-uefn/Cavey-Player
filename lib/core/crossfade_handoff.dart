import 'dart:async';

/// Transport evidence required before the silent deck becomes the main deck.
/// Position movement is evidence of playback, not proof of audible PCM output.
class HandoffState {
  final Duration position;
  final Duration duration;
  final bool playing;
  final bool buffering;
  const HandoffState(this.position, this.duration, {required this.playing, required this.buffering});

  bool readyAfter(Duration cue) => playing && !buffering &&
      position > cue + const Duration(milliseconds: 40) &&
      (duration <= Duration.zero || position < duration);
}

/// Recheck ownership after asynchronous waits: pause/seek/next may cancel a mix.
Future<bool> waitForHandoff({
  required HandoffState Function() read,
  required Stream<void> changes,
  required bool Function() isCurrent,
  required Duration cue,
  Duration timeout = const Duration(seconds: 5),
}) async {
  if (!isCurrent()) return false;
  if (read().readyAfter(cue)) return true;
  final result = Completer<bool>();
  void poll() {
    if (result.isCompleted) return;
    if (!isCurrent()) {
      result.complete(false);
    } else if (read().readyAfter(cue)) {
      result.complete(true);
    }
  }
  final subscription = changes.listen((_) => poll(),
      onError: (Object error, StackTrace stack) {
        if (!result.isCompleted) result.complete(false);
      }, onDone: () {
        if (!result.isCompleted) result.complete(false);
      });
  final pollTimer = Timer.periodic(const Duration(milliseconds: 50), (_) => poll());
  final timer = Timer(timeout, () {
    if (!result.isCompleted) result.complete(false);
  });
  try {
    poll();
    final ready = await result.future;
    return ready && isCurrent() && read().readyAfter(cue);
  } finally {
    timer.cancel();
    pollTimer.cancel();
    await subscription.cancel();
  }
}
