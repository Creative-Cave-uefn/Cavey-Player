"""Render synthetic audio with the bundled Windows libmpv, without speakers.

Usage: python tools/verify-dj-native.py <libmpv-2.dll> <output-directory>
No music, credentials or connected accounts are used.
"""
import array
import ctypes as c
import json
import hashlib
import math
from pathlib import Path
import sys
import struct
import time
import wave

dll, dest = Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve()
dest.mkdir(parents=True, exist_ok=True)
source = dest / 'tone.wav'
with wave.open(str(source), 'wb') as f:
    f.setparams((1, 2, 48000, 0, 'NONE', 'not compressed'))
    f.writeframes(array.array('h', (int(5000 * math.sin(2 * math.pi * 440 * i / 48000))
                                  for i in range(48000 * 4))).tobytes())

mpv = c.CDLL(str(dll))
mpv.mpv_create.restype = c.c_void_p
mpv.mpv_set_option_string.argtypes = [c.c_void_p, c.c_char_p, c.c_char_p]
mpv.mpv_initialize.argtypes = [c.c_void_p]
mpv.mpv_command.argtypes = [c.c_void_p, c.POINTER(c.c_char_p)]
mpv.mpv_terminate_destroy.argtypes = [c.c_void_p]
class Event(c.Structure):
    _fields_ = [('id', c.c_int), ('error', c.c_int), ('reply', c.c_uint64), ('data', c.c_void_p)]
mpv.mpv_wait_event.argtypes = [c.c_void_p, c.c_double]
mpv.mpv_wait_event.restype = c.POINTER(Event)

results = []
for shift, rate in [(0, 1.0), (1, 1.0), (-1, 0.92), (1, 1.08)]:
    output = dest / f'pitch-{shift}-rate-{rate}.wav'
    handle = mpv.mpv_create()
    try:
        options = {'ao': 'pcm', 'ao-pcm-file': str(output), 'audio-format': 's16',
                   'audio-channels': 'mono', 'audio-samplerate': '48000',
                   'video': 'no', 'terminal': 'no', 'idle': 'yes', 'speed': str(rate),
                   'log-file': str(dest / f'mpv-{shift}-{rate}.log')}
        if shift:
            shifted_rate = round(48000 * 2**(shift/12))
            options['af'] = f'@cave-dj-pitch:lavfi=[aresample=sample_rate=48000,asetrate=sample_rate={shifted_rate},aresample=sample_rate=48000,atempo=tempo={48000/shifted_rate}]'
        else:
            options['af'] = '@cave-dj-eq:lavfi=[bass@low=f=180:g=0,equalizer@mid=f=1400:t=o:w=2:g=0,treble@high=f=6000:g=0,arealtime]'
        for key, value in options.items():
            assert mpv.mpv_set_option_string(handle, key.encode(), value.encode()) >= 0, key
        assert mpv.mpv_initialize(handle) >= 0
        args = (c.c_char_p * 3)(b'loadfile', str(source).encode(), None)
        assert mpv.mpv_command(handle, args) >= 0
        deadline = time.monotonic() + 20
        loaded = False
        eq_checked = shift != 0
        while time.monotonic() < deadline:
            event = mpv.mpv_wait_event(handle, 0.1).contents
            if event.id == 8:
                loaded = True
            if event.id == 21 and shift == 0:
                command = (c.c_char_p * 6)(b'af-command', b'cave-dj-eq', b'g', b'-12', b'bass@low', None)
                assert mpv.mpv_command(handle, command) >= 0, 'Live EQ command failed'
                eq_checked = True
            if event.id == 7:
                assert loaded, 'Failed to load synthetic tone'
                break
        else:
            raise AssertionError('Native render timed out')
        assert eq_checked, 'Live EQ command was not exercised'
    finally:
        mpv.mpv_terminate_destroy(handle)
    # mpv writes WAVE_FORMAT_EXTENSIBLE, unsupported by Python 3.11's wave reader.
    raw, offset, pcm, fmt = output.read_bytes(), 12, None, None
    assert raw[:4] == b'RIFF' and raw[8:12] == b'WAVE'
    while offset + 8 <= len(raw):
        tag, size = struct.unpack_from('<4sI', raw, offset)
        chunk = raw[offset + 8:offset + 8 + size]
        if tag == b'fmt ': fmt = chunk
        if tag == b'data': pcm = chunk
        offset += 8 + size + size % 2
    assert fmt is not None and pcm is not None
    code, channels, hz, _, _, bits = struct.unpack_from('<HHIIHH', fmt)
    assert channels == 1 and bits == 16
    assert code == 1 or (code == 65534 and struct.unpack_from('<I', fmt, 24)[0] == 1)
    samples = array.array('h', pcm)
    # Ignore filter startup/tail latency; count positive crossings in the middle.
    middle = samples[hz:2*hz]
    frequency = sum(a <= 0 < b for a, b in zip(middle, middle[1:]))
    expected = 440 * 2**(shift/12)
    seconds = len(samples) / hz
    assert abs(frequency - expected) < 2, (frequency, expected)
    assert abs(seconds - 4/rate) < 0.15, (seconds, rate)
    results.append(dict(semitones=shift, rate=rate, measuredHz=frequency,
                        expectedHz=expected, durationSec=seconds))
report = dict(library=str(dll), librarySha256=hashlib.sha256(dll.read_bytes()).hexdigest(),
              eqCommandVerified=True, checks=results, listening='not_run')
(dest / 'report.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
print(json.dumps(report, indent=2))
