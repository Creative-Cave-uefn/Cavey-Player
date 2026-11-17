import 'dart:async';

/// Independent attenuation-only frequency handover; never stem separation.
class DjEq {
  final double low, mid, high;
  const DjEq(this.low, this.mid, this.high);
  static const flat = DjEq(0, 0, 0);
  List<double> get bands => [low, mid, high];
}

double _ramp(double x, double a, double b) {
  final t = ((x - a) / (b - a)).clamp(0.0, 1.0);
  return t * t * (3 - 2 * t);
}

(DjEq, DjEq) djEqAt(double progress, double bassSwapFraction) {
  final x = progress.clamp(0.0, 1.0),
      s = bassSwapFraction.clamp(0.25, 0.75),
      bass = _ramp(x, s - 0.1, s + 0.1);
  return (
    DjEq(-18 * bass, -12 * _ramp(x, 0.35, 0.75), -6 * _ramp(x, 0.75, 1)),
    DjEq(-18 * (1 - bass), -12 * (1 - _ramp(x, 0.25, 0.65)),
        -6 * (1 - _ramp(x, 0, 0.2)))
  );
}

typedef DjCommand = Future<void> Function(List<String> command);

/// One owned filter. Commands serialize/coalesce; close drains before removal.
class DjEqDriver {
  final String label;
  final DjCommand command;
  final void Function() onFailure;
  bool _closed = false, _failed = false;
  DjEq? _pending;
  DjEq _last = DjEq.flat;
  Future<void>? _work;
  DjEqDriver(this.label, this.command, this.onFailure);
  bool get active => !_closed && !_failed;
  static double _q(double v) => (v.clamp(-18.0, 0.0) * 2).round() / 2;
  Future<bool> install(DjEq initial) async {
    _last = initial;
    try {
      await command([
        'af',
        'add',
        '@$label:lavfi=[bass@low=f=180:g=${_q(initial.low)},equalizer@mid=f=1400:t=o:w=2:g=${_q(initial.mid)},treble@high=f=6000:g=${_q(initial.high)}]'
      ]);
      return true;
    } catch (_) {
      fail();
      return false;
    }
  }

  void fail() {
    if (!_failed) {
      _failed = true;
      _pending = null;
      onFailure();
    }
  }

  void update(DjEq value) {
    if (_closed || _failed) return;
    _pending = value;
    _work ??= _flush().whenComplete(() {
      _work = null;
    });
  }

  Future<void> _flush() async {
    try {
      while (!_closed && !_failed && _pending != null) {
        final next = _pending!;
        _pending = null;
        for (var i = 0; i < 3; i++) {
          if (_closed || _failed) break;
          if (_q(next.bands[i]) == _q(_last.bands[i])) continue;
          await command([
            'af-command',
            label,
            'g',
            '${_q(next.bands[i])}',
            ['bass@low', 'equalizer@mid', 'treble@high'][i]
          ]);
        }
        _last = next;
      }
    } catch (_) {
      fail();
    }
  }

  Future<void> close() async {
    _closed = true;
    _pending = null;
    await _work;
    try {
      await command(['af', 'remove', '@$label']);
    } catch (_) {}
  }
}
