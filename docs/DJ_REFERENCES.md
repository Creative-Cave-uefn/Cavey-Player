# DJ transition references and implementation

Reviewed references:

- https://github.com/byronxu99/AutoDJ — Mixxx controller, GPLv3-or-later. Tempo/key matching, half/double-time sync, cue handoff and bass EQ.
- https://github.com/rdircio/autodj — extended version of that controller. Its current defaults differ from README: EQ is disabled, randomized transitions enabled. Resetting pitch abruptly after a transition and random effects are not adopted.
- https://github.com/yask123/ai-dj — MIT. Its conductor restricts available moves by phrase position, recent moves and a decision deadline; the audio engine owns execution. The current Python set targets short performance mixes rather than uninterrupted whole-song listening.
- https://github.com/beneaze/ClubCraft — MIT OR Apache-2.0. Joint mix points, phrase-aligned automatic cues and a shared tempo timeline are useful references. Stem separation and its complete Rust engine are separate systems, not part of this change.

No source from these projects is copied into the transition implementation.
The Dart planner and equal-tempered pitch/tempo calculations are implemented for
Cavey's existing two-deck playback path. No cloud model or new account is required.

## Current behavior

Adaptive beat blends glide both decks toward the incoming track's native tempo,
finishing the glide at 75% of the transition. Their relative speed stays fixed;
envelopes, bass handoff and completion follow outgoing source position so the
planned phrase windows remain valid. The ordinary DJ/manual path stays separate.

`Подстраивать тональность` is optional and defaults off. With reliable keys,
the adaptive planner considers only -1, 0 and +1 semitone, preferring the original
when it already fits. After the transition the original pitch returns with a
1.2-second smooth Rubber Band ramp; planning waits for restoration and lookahead
assumes the native key for later tracks. A new file cancels any pending recovery.
Unsupported filter setup aborts preparation and uses an ordinary crossfade.

Phase alignment uses mpv `audio-pts`, which accounts for output delay, rather than
the coarse UI position stream. Exact seeks while the incoming deck is muted are
checked up to three times with measured seek latency. A residual above 45 ms
rejects beat sync with an explicit error; phase control samples audio PTS during
the blend. Two native test transports exercise initial misalignment and a tempo
glide in `tools/verify-dj-phase.py`. This is transport verification, not a PCM
capture of two music tracks or a guarantee about beat-analysis correctness.

The standard progress line matches main again; the experimental waveform bars
are removed. Full-track tempo/key changes are not retained after a transition.

The stock media_kit Windows audio and video distributions omit needed FFmpeg
filters. A vendored MIT plugin wrapper instead downloads a full pinned libmpv,
checks SHA-256 and bundles upstream licensing notices. Other platforms still use
the existing packages. The installer is larger as a result.

`tools/verify-dj-native.py` renders a synthetic tone through the exact bundled
DLL with no speaker output. It checks EQ command support, semitone frequencies
and durations at 0.92/1.08 playback speed. Unit tests cover harmonic shifts,
phrase endpoints, rate ratios, source consumption and default-off behavior.
These measurements do not replace listening to real transitions.

## Effect programs

Measured peak rejection now attempts one bounded correction before abandoning
the plan: attenuate both decks by at most 6 dB toward -1.5 dBTP, then render and
measure again. Only an accepted repeat render enables the corrected plan.
The effect, rate and pitch remain unchanged. The volume recovers over one second
after completion. Preflight, headroom adjustment, fallback reasons and execution
errors are included in the ordinary app log; execution records carry the actual
effect and headroom gain. A replay test reproduced the reported real pair:
+2.8 dBTP rejected, -4.3 dB correction, -1.5 dBTP accepted with echoOut retained.

Adaptive plans carry `echoOut`, `filterOut`, `rhythmicGate` or `none` separately
from volume/tempo envelopes. Reliable rhythmic blends select a bounded echo send
for vocal-risk windows, a half-beat gate for dense percussion, or a rising
high-pass sweep for bright sparse material. Unknown rhythm uses no effect.
Programs run over the final four beats in source time; the echo has two bounded
dotted-eighth taps. Filters are owned by the outgoing deck and removed when the
transition completes or is cancelled. The same graph builder is used by mpv and
offline peak preflight. This implements a subset of the reference performance
systems: stem separation, scratching and sample-loop engines are not included.

Export exact graphs with `dart tools/export-dj-effects.dart native-effects.json`.
Pass that JSON as the optional third argument of `tools/verify-dj-native.py`.
The native probe checks processed PCM: filter-out attenuation, rhythmic-gate
energy and audible echo contribution, alongside pitch/tempo checks.

Offline preflight includes both actual pitch shifts and the original source
windows. It is a source-time level check, not a capture of the live variable-tempo
mpv output, and does not certify perceptual quality or exact live true peaks.
