"""Live close regression. Creates/closes only a TanaFixture window."""
import json
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
WM = ROOT / 'build/tana'
FIXTURE = ROOT / 'build/TanaFixture.app/Contents/MacOS/fixture'

def command(*args):
    return subprocess.check_output([str(WM), '-m', *map(str, args)], text=True)

def windows():
    return json.loads(command('query', '--windows'))

def wait_until(check, timeout=3):
    deadline=time.monotonic()+timeout
    while time.monotonic()<deadline:
        value=check()
        if value: return value
        time.sleep(.08)
    raise AssertionError('live condition timed out')

def metrics(ids):
    return {w['id']:w for w in json.loads(subprocess.check_output([str(ROOT/'build/window_metrics'),*map(str,ids)],text=True))}

before_ids={w['id'] for w in windows()}
existing=[w for w in windows() if w['app']=='TanaFixture' and w['is-visible']]
assert existing, 'launch the disposable fixture first'
target=existing[0]['id']
subprocess.run([str(FIXTURE),'new'],check=True)
source=wait_until(lambda: next((w['id'] for w in windows() if w['app']=='TanaFixture' and w['id'] not in before_ids and w['is-visible']),None))
command('window',source,'--focus')
wait_until(lambda:any(w['id']==source and w['has-focus'] for w in windows()))
command('strip','width',500)
command('strip','place',source,target,'left')
command('window',source,'--focus')
time.sleep(.8)
status=json.loads(command('strip','status'))
layout={w['id']:w for w in status['windows']}
assert source in layout and target in layout
s=layout[source]
expected=min((w for w in status['windows'] if w['id']!=source),key=lambda w:abs(w['x']-s['x'])+abs(w['y']-s['y'])*.1)['id']
assert any(w['id']==source and w['has-focus'] for w in windows()), 'focus changed during setup'
before=metrics([expected,target,source])
command('window',source,'--close')
wait_until(lambda:source not in [w['id'] for w in json.loads(command('strip','status'))['windows']])
time.sleep(.7)
after=metrics([expected,target])
focused=[w['id'] for w in windows() if w['has-focus']]
report={'source':source,'expected_neighbor':expected,'before':before,'after':after,'focused':focused,'removed_from_strip':True,'neighbor_screen_x_delta':after[expected]['x']-before[expected]['x']}
(ROOT/'build/close-focus-check.json').write_text(json.dumps(report,indent=2))
print(json.dumps(report,indent=2))
assert focused==[expected]
assert abs(report['neighbor_screen_x_delta'])<=1
