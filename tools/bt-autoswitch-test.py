#!/usr/bin/env python3
"""Checks the stock WirePlumber automatic headset profile switching: records from the default microphone
(like any application), checks that the card went to the voice profile and the microphone delivers non-silent
audio, then checks that it returns to the music profile. Also counts KDE volume OSD calls.
usage: bt-autoswitch-test.py [rounds] [pause between rounds, s]"""
import subprocess, sys, time, os, select, struct, threading
ROUNDS = int(sys.argv[1]) if len(sys.argv) > 1 else 5
GAP = float(sys.argv[2]) if len(sys.argv) > 2 else 5
def sh(*a): return subprocess.run(a, capture_output=True, text=True).stdout
def profile():
    cur = False
    for l in sh('pactl', 'list', 'cards').splitlines():
        if l.strip().startswith('Name:'): cur = 'bluez_card' in l
        elif cur and 'Active Profile:' in l: return l.split(':', 1)[1].strip()
osd = []
try: mon = subprocess.Popen(['dbus-monitor', '--session', "path='/org/kde/osdService',type='method_call'"], stdout=subprocess.PIPE, text=True)
except OSError: mon = subprocess.Popen(['sleep', 'infinity'], stdout=subprocess.PIPE, text=True)
def watch():
    for l in mon.stdout:
        if 'member=' in l: osd.append(l.split('member=')[1].strip())
threading.Thread(target=watch, daemon=True).start()
good = 0
for r in range(1, ROUNDS + 1):
    n0 = len(osd); t0 = time.time()
    p = subprocess.Popen(['parecord', '--client-name=autoswitch-test', '--raw', '--format=s16le', '--rate=16000', '--channels=1', '--latency-msec=20'], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    buf = b''; first = None; end = t0 + 4
    while time.time() < end:
        if select.select([p.stdout], [], [], 0.1)[0]:
            d = os.read(p.stdout.fileno(), 4096)
            if not d: break
            if first is None and any(d): first = time.time() - t0
            buf += d
    prof_rec = profile(); p.kill()
    s = struct.unpack('<%dh' % (len(buf) // 2), buf[:len(buf) // 2 * 2]); tail = s[-16000:]
    nz = sum(1 for x in tail if x) / len(tail) if tail else 0
    time.sleep(GAP); prof_after = profile()
    ok = nz > 0.4 and str(prof_rec).startswith('headset') and str(prof_after).startswith('a2dp')
    good += ok
    print('round %d: %s | recording: %s, last second %d%% non-zero, first sound after %s s | %.0f s later: %s | OSD: %s' % (
        r, 'OK' if ok else 'FAILED', prof_rec, nz * 100, '%.1f' % first if first else '-', GAP, prof_after, ','.join(osd[n0:]) or 'none'), flush=True)
print('%d/%d' % (good, ROUNDS)); mon.kill()
