"""Local YAMNet audio-event voice-risk baseline, not calibrated singing absence.
Inference never downloads weights or uploads audio. Setup owns network access.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

MODEL_SHA256 = '4d8b4a53282dc83ef04e3e7dbc4fbc98082e34e44ed798e16c3a0cdd4c584faf'
MODEL_URL = 'https://storage.googleapis.com/mediapipe-models/audio_classifier/yamnet/float32/1/yamnet.tflite'
VOICE_LABELS = {'Speech','Singing','Choir','Yodeling','Chant','Mantra','Child singing','Synthetic singing','Rapping','Humming','Vocal music','A capella'}
RATE, FRAME, HOP = 16000, 15600, 7680

def verify_model(path):
    if hashlib.sha256(Path(path).read_bytes()).hexdigest() != MODEL_SHA256:
        raise ValueError('model_hash_mismatch')

def analyze(source, model, ffmpeg):
    verify_model(model)
    import numpy as np
    decoded = subprocess.run([str(ffmpeg),'-nostdin','-v','error','-i',str(source),'-t','900','-vn',
                              '-ac','1','-ar',str(RATE),'-f','f32le','pipe:1'],capture_output=True,timeout=90,check=True)
    wave = np.frombuffer(decoded.stdout,dtype='<f4').copy()
    if not len(wave) or not np.isfinite(wave).all():
        raise ValueError('invalid_pcm')
    return analyze_wave(np.clip(wave,-1,1),model)

def analyze_wave(wave,model):
    verify_model(model)
    import numpy as np
    from mediapipe.tasks import python
    from mediapipe.tasks.python import audio
    from mediapipe.tasks.python.components import containers
    options = audio.AudioClassifierOptions(base_options=python.BaseOptions(model_asset_path=str(model)),
        running_mode=audio.RunningMode.AUDIO_CLIPS,category_allowlist=sorted(VOICE_LABELS),max_results=-1,score_threshold=0.0)
    scores = []
    with audio.AudioClassifier.create_from_options(options) as classifier:
        for start in range(0,len(wave),HOP):
            chunk = wave[start:start+FRAME]
            if len(chunk)<FRAME: chunk=np.pad(chunk,(0,FRAME-len(chunk)))
            results=classifier.classify(containers.AudioData.create_from_array(chunk,RATE))
            score=max((c.score for r in results for h in r.classifications for c in h.categories if c.category_name in VOICE_LABELS),default=0.0)
            scores.append(round(float(score),4))
    return {'v':1,'source':'model:yamnet/float32/1','modelSha256':MODEL_SHA256,'runtime':'mediapipe:0.10.21',
            'hopMs':480,'windowMs':975,'durationMs':round(len(wave)*1000/RATE),'calibratedAbsence':False,'scores':scores}

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--input',type=Path);p.add_argument('--self-test',action='store_true')
    p.add_argument('--model',required=True,type=Path);p.add_argument('--output',required=True,type=Path)
    p.add_argument('--ffmpeg',default='ffmpeg');args=p.parse_args()
    try:
        if args.self_test:
            import numpy as np
            result=analyze_wave(np.zeros(RATE,dtype=np.float32),args.model)
        elif args.input is not None: result=analyze(args.input,args.model,args.ffmpeg)
        else: p.error('--input or --self-test is required')
        temp=args.output.with_suffix('.part')
        temp.write_text(json.dumps(result,allow_nan=False,separators=(',',':')),encoding='utf-8')
        os.replace(temp,args.output);return 0
    except Exception as e:
        print(json.dumps({'error':type(e).__name__}),file=sys.stderr);return 1
if __name__=='__main__': raise SystemExit(main())
