#!/usr/bin/env python3
"""Render the same pair with AutoMix and the selected Adaptive plan.

This is an offline plan audition, NOT a recording of the running Windows decks.
The input mapping stays local; reports contain track IDs and content hashes.
"""
from __future__ import annotations
import argparse
import array
import hashlib
import json
import math
from pathlib import Path
import random
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass


@dataclass(frozen=True)
class Plan:
    out_ms: int
    in_ms: int
    length_ms: int
    rate: float
    gain: float
    technique: str
    swap_ms: int | None = None

    @classmethod
    def read(cls, data: dict, *, baseline: bool = False) -> 'Plan':
        plan = cls(int(data['outMs']), int(data['inMs']), int(data['lengthMs']),
                   float(data.get('rate', 1)), float(data.get('inGain', 1)),
                   'autoMix' if baseline else str(data['technique']), data.get('swapMs'))
        if not (plan.out_ms >= 0 and plan.in_ms >= 0 and 200 <= plan.length_ms <= 180000):
            raise ValueError('Invalid cue/length')
        if not (math.isfinite(plan.rate) and 0.5 <= plan.rate <= 2 and math.isfinite(plan.gain) and 0.25 <= plan.gain <= 4):
            raise ValueError('Invalid rate/gain')
        if plan.technique not in {'autoMix', 'beatBlend', 'shortFade', 'cut', 'atmospheric'}:
            raise ValueError('Unknown transition technique')
        if plan.swap_ms is not None and not (0 < plan.swap_ms < plan.length_ms):
            raise ValueError('Invalid bass swap')
        return plan


def read_decisions(path: Path) -> list[dict]:
    decisions = []
    for number, line in enumerate(path.read_text(encoding='utf-8-sig').splitlines(), 1):
        if not line.strip():
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError as exc:
            raise ValueError(f'Invalid JSONL line {number}') from exc
        if not isinstance(row, dict):
            raise ValueError(f'Expected a JSON object on line {number}')
        if row.get('kind') == 'decision' and row.get('outMs') is not None:
            decisions.append(row)
    return decisions


def _number(value: float) -> str:
    if not math.isfinite(value):
        raise ValueError('Non-finite filter parameter')
    return f'{value:.9f}'


def filter_graph(plan: Plan, *, lead: float = 6, tail: float = 6) -> str:
    duration = plan.length_ms / 1000
    start = max(0, plan.out_ms / 1000 - lead)
    delay = plan.out_ms / 1000 - start
    incoming_len = (duration + tail) * plan.rate
    x_out = f'clip((t-{_number(delay)})/{_number(duration)},0,1)'
    x_in = f'clip(t/{_number(duration)},0,1)'
    if plan.technique == 'beatBlend':
        def angle(x: str) -> str:
            return f'if(lt({x},0.2),({x})/0.2*PI/4,if(gt({x},0.8),PI/4+(({x})-0.8)/0.2*PI/4,PI/4))'
        out_gain = f'cos({angle(x_out)})'
        in_gain = f'sin({angle(x_in)})*({_number(plan.gain)}+(1-{_number(plan.gain)})*({x_in}))'
    else:
        # Existing plain AutoMix uses the mpv volume-slider envelope directly.
        out_gain = f'pow(cos(({x_out})*PI/2),3)'
        in_gain = f'pow(sin(({x_in})*PI/2)*({_number(plan.gain)}+(1-{_number(plan.gain)})*({x_in})),3)'
    out_fx = in_fx = ''
    if plan.technique == 'beatBlend' and plan.swap_ms is not None:
        swap = plan.swap_ms / 1000
        out_fx = f",highpass=f=220:enable='gte(t,{_number(delay + swap)})'"
        in_fx = f",highpass=f=220:enable='lt(t,{_number(swap)})'"
    return (
        f'[0:a]atrim=start={_number(start)}:end={_number(plan.out_ms / 1000 + duration)},'
        f'asetpts=PTS-STARTPTS,aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo'
        f"{out_fx},volume='{out_gain}':eval=frame[a];"
        f'[1:a]atrim=start={_number(plan.in_ms / 1000)}:duration={_number(incoming_len)},'
        f'asetpts=PTS-STARTPTS,aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo,'
        f'atempo={_number(plan.rate)}{in_fx},volume=\'{in_gain}\':eval=frame,'
        f'adelay={round(delay * 1000)}|{round(delay * 1000)}[b];'
        '[a][b]amix=inputs=2:duration=longest:normalize=0[out]'
    )


def run(command: list[str], *, binary: bool = False) -> subprocess.CompletedProcess:
    result = subprocess.run(command, capture_output=True, timeout=300)
    if result.returncode:
        raise RuntimeError(result.stderr.decode('utf-8', errors='replace')[-6000:])
    return result


def render(ffmpeg: str, a: Path, b: Path, plan: Plan, target: Path) -> None:
    run([ffmpeg, '-hide_banner', '-nostdin', '-v', 'error', '-y', '-i', str(a), '-i', str(b),
         '-filter_complex', filter_graph(plan), '-map', '[out]', '-c:a', 'pcm_f32le', str(target)])


def measure(ffmpeg: str, path: Path) -> dict:
    raw = run([ffmpeg, '-hide_banner', '-nostdin', '-v', 'error', '-i', str(path),
               '-f', 'f32le', '-ar', '48000', '-ac', '2', 'pipe:1'], binary=True).stdout
    samples = array.array('f')
    samples.frombytes(raw)
    if sys.byteorder != 'little':
        samples.byteswap()
    peak, discontinuity, nonfinite, overs = 0.0, 0.0, 0, 0
    previous = [0.0, 0.0]
    for i, sample in enumerate(samples):
        if not math.isfinite(sample):
            nonfinite += 1
            continue
        peak = max(peak, abs(sample))
        overs += abs(sample) > 1
        channel = i % 2
        discontinuity = max(discontinuity, abs(sample - previous[channel]))
        previous[channel] = sample
    log = run([ffmpeg, '-hide_banner', '-nostdin', '-i', str(path), '-af', 'ebur128=peak=true',
               '-f', 'null', '-']).stderr.decode('utf-8', errors='replace')
    loudness = re.findall(r'\bI:\s*(-?\d+(?:\.\d+)?)\s*LUFS', log)
    true_peak = re.findall(r'\bPeak:\s*(-?\d+(?:\.\d+)?)\s*dBFS', log)
    tp = float(true_peak[-1]) if true_peak else None
    return {'samplePeakDbfs': 20 * math.log10(peak) if peak > 0 else None,
            'truePeakDbtp': tp, 'integratedLufs': float(loudness[-1]) if loudness else None,
            'nonfiniteSamples': nonfinite, 'samplesOverFullScale': overs, 'silent': peak <= 1e-6,
            'largestAdjacentSampleDelta': discontinuity,  # not itself a click detector
            'durationSec': len(samples) / 2 / 48000,
            'targetMinus1Dbtp': None if tp is None else tp <= -1,
            'pcmIntegrity': nonfinite == 0 and overs == 0}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--journal', required=True, type=Path)
    parser.add_argument('--files', type=Path, help='JSON object: track ID -> local audio path')
    parser.add_argument('--decision', type=int, default=-1, help='Default: latest decision')
    parser.add_argument('--list', action='store_true')
    parser.add_argument('--template', type=Path, help='Write a file-mapping template, then exit')
    parser.add_argument('--out', type=Path, default=Path('dj-benchmark'))
    parser.add_argument('--ffmpeg', default='ffmpeg')
    parser.add_argument('--blind-seed', type=int, default=17)
    args = parser.parse_args(argv)
    rows = read_decisions(args.journal)
    if not rows:
        raise ValueError('No renderable decision in the journal')
    if args.list:
        for i, row in enumerate(rows):
            print(i, row['from'], '->', row['to'], row['technique'], row['outMs'], row['inMs'])
        return 0
    if args.template:
        mapping = {track: 'REPLACE_WITH_LOCAL_AUDIO_PATH' for row in rows for track in [row['from'], row['to']]}
        args.template.write_text(json.dumps(mapping, ensure_ascii=False, indent=2), encoding='utf-8')
        return 0
    if not args.files:
        parser.error('--files is required for rendering')
    ffmpeg = shutil.which(args.ffmpeg)
    if not ffmpeg:
        raise ValueError('FFmpeg not found; pass --ffmpeg with its executable path')
    mapping = json.loads(args.files.read_text(encoding='utf-8-sig'))
    decision = rows[args.decision]
    a, b = Path(mapping[decision['from']]), Path(mapping[decision['to']])
    if not a.is_file() or not b.is_file():
        raise ValueError('Both track IDs must map to existing local audio files')
    plans = [('AutoMix', Plan.read(decision['baseline'], baseline=True)), ('Adaptive', Plan.read(decision))]
    random.Random(args.blind_seed).shuffle(plans)
    args.out.mkdir(parents=True, exist_ok=True)
    key, report = {}, {'kind': 'offline_plan_audition_not_runtime_capture', 'decision': decision,
                       'sourceSha256': {'from': sha256(a), 'to': sha256(b)}, 'renders': {}}
    for label, (system, plan) in zip(['A', 'B'], plans):
        target = args.out / f'{label}.wav'
        render(ffmpeg, a, b, plan, target)
        report['renders'][label] = {'sha256': sha256(target), **measure(ffmpeg, target)}
        key[label] = system
    (args.out / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    (args.out / 'blind-key.json').write_text(json.dumps(key, indent=2), encoding='utf-8')
    (args.out / 'ratings.csv').write_text('label,timing,smoothness,vocal_conflict,fit,notes\nA,,,,,\nB,,,,,\n', encoding='utf-8')
    print(f'Created A.wav, B.wav, report.json and ratings.csv in {args.out}')
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (ValueError, TypeError, KeyError, IndexError, RuntimeError, OSError, subprocess.TimeoutExpired) as exc:
        print(f'Benchmark failed: {exc}', file=sys.stderr)
        raise SystemExit(1)
