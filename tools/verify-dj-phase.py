"""Exercise two real libmpv transports without speaker output."""
import ctypes as c
import json
import math
from pathlib import Path
import sys
import time

mpv=c.CDLL(str(Path(sys.argv[1]).resolve()))
mpv.mpv_create.restype=c.c_void_p
mpv.mpv_initialize.argtypes=[c.c_void_p]
mpv.mpv_set_option_string.argtypes=[c.c_void_p,c.c_char_p,c.c_char_p]
mpv.mpv_command.argtypes=[c.c_void_p,c.POINTER(c.c_char_p)]
mpv.mpv_get_property_string.argtypes=[c.c_void_p,c.c_char_p]
mpv.mpv_get_property_string.restype=c.c_void_p
mpv.mpv_free.argtypes=[c.c_void_p]
mpv.mpv_terminate_destroy.argtypes=[c.c_void_p]
def command(p,*args):
    assert mpv.mpv_command(p,(c.c_char_p*(len(args)+1))(*[str(a).encode() for a in args],None))>=0,args
def get(p,name):
    value=mpv.mpv_get_property_string(p,name.encode())
    if not value: return None
    try: return float(c.string_at(value))
    finally: mpv.mpv_free(value)
def create(rate):
    p=mpv.mpv_create()
    for k,v in dict(ao='null',video='no',terminal='no',config='no',idle='yes',speed=str(rate)).items():
        assert mpv.mpv_set_option_string(p,k.encode(),v.encode())>=0
    assert mpv.mpv_initialize(p)>=0
    command(p,'loadfile',str(Path(sys.argv[2]).resolve()))
    return p
ratio=1.03
a,b=create(1),create(ratio)
try:
    time.sleep(0.3)
    command(b,'seek',(get(a,'time-pos')+0.167)*ratio,'absolute+exact')
    time.sleep(0.08)
    def phase():
        x,y=get(a,'audio-pts')*1000,get(b,'audio-pts')*1000
        error=(y/ratio-x)%500
        if error>250: error-=500
        return x,y,error
    before=phase()[2]
    assert abs(before)>80,before
    latency=0
    for attempt in range(3):
        x,y,error=phase()
        if abs(error)<=30: break
        started=time.monotonic()
        target=max(0,y-error*ratio+latency*ratio)
        command(b,'seek',target/1000,'absolute+exact')
        time.sleep(0.04)
        latency=(time.monotonic()-started)*1000
    aligned=phase()[2]
    assert abs(aligned)<=45,aligned
    errors=[]
    for i in range(21):
        t=min(1,(i/20)/0.75); smooth=t*t*(3-2*t)
        out=1+(1/ratio-1)*smooth
        error=phase()[2]; errors.append(abs(error))
        correction=1 if abs(error)<10 else 1+max(-0.02,min(0.02,-error/1500))
        command(a,'set','speed',out)
        command(b,'set','speed',out*ratio*correction)
        time.sleep(0.2)
    command(b,'set','speed',1)
    assert max(errors)<45,errors
    assert abs(get(b,'speed')-1)<1e-6
    report=dict(beforeMs=before,alignedMs=aligned,maxDuringRampMs=max(errors),
                incomingFinalRate=get(b,'speed'),measurement='native_transport_not_output_PCM')
    Path(sys.argv[3]).write_text(json.dumps(report,indent=2))
    print(json.dumps(report,indent=2))
finally:
    mpv.mpv_terminate_destroy(a);mpv.mpv_terminate_destroy(b)
