"""Live native-transform and border restoration check. Leave pointer idle."""
import json
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
WM = ROOT / 'build/tana'
METRICS = ROOT / 'build/window_metrics'

def command(*parts):
    return subprocess.check_output([str(WM), '-m', 'strip', *parts], text=True)

def state():
    return json.loads(command('input-status'))

def wait_for(predicate, timeout=8):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if predicate():
            return
        time.sleep(.04)
    raise AssertionError('overview transition timed out')

def metrics(ids):
    return json.loads(subprocess.check_output([str(METRICS), *map(str, ids)], text=True))

def restored(before):
    after = metrics([w['id'] for w in before])
    for a, b in zip(before, after):
        for key in ('x', 'y', 'w', 'h', 'tx', 'ty'):
            assert abs(a[key]-b[key]) <= 1, (key,a,b)
        assert abs(b['a']-1)<.00001 and abs(b['d']-1)<.00001, b

assert not state()['overview'], 'close the overview before running this check'
assert state()['overview_renderer'] == 'native'
status = json.loads(command('status'))
ids = [window['id'] for window in status['windows']]
time.sleep(.5)
before = metrics(ids)
borders = metrics(['--borders'])
report = {'windows': len(ids), 'borders':len(borders), 'checks': []}
try:
    command('overview-progress', '.25')
    time.sleep(.2)
    quarter = metrics(ids)
    assert any(abs(w['a']-1)>.01 for w in quarter), 'native transforms did not change'
    command('overview-progress', '1')
    time.sleep(.2)
    full = metrics(ids)
    assert all(w['a']>1 and w['d']>1 for w in full), 'grid did not shrink actual windows'
    assert any(abs(a['tx']-b['tx'])>2 for a,b in zip(quarter,full)), 'gesture progress did not move windows'
    rects = [(-w['tx']/w['a'],-w['ty']/w['d'],w['w']/w['a'],w['h']/w['d']) for w in full]
    for i,(x,y,w,h) in enumerate(rects):
        for xx,yy,ww,hh in rects[i+1:]:
            assert min(x+w,xx+ww)-max(x,xx)<=1 or min(y+h,yy+hh)-max(y,yy)<=1, 'grid overlap'
    hidden = metrics(['--borders'])
    assert all(w['alpha']==0 for w in hidden), hidden
    report['checks'].append('actual windows move and shrink with progress into a nonoverlapping grid')
    report['checks'].append('all JankyBorders windows have zero opacity during overview')
    command('overview-cancel')
    wait_for(lambda: not state()['overview'])
    time.sleep(.4)
    restored(before)
    after_borders = {w['id']:w for w in metrics(['--borders'])}
    for w in borders:
        if w['id'] in after_borders:
            assert abs(w['alpha']-after_borders[w['id']]['alpha'])<.001
    report['checks'].append('cancel restores native transforms, positions and border opacity')
    command('overview-progress', '.1')
    command('overview-cancel')
    wait_for(lambda: not state()['overview'])
    time.sleep(.4)
    restored(before)
    report['checks'].append('early cancellation restores every window')
    report['timing'] = state()
finally:
    if state()['overview']:
        command('overview-cancel')
report['result'] = 'pass'
(ROOT / 'build/overview-check.json').write_text(json.dumps(report, indent=2)+'\n')
print(json.dumps(report))
