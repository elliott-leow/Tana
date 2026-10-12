"""Optional real WindowServer checks, restricted to disposable fixture windows."""
import json
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WM = ROOT / 'build/tana'
report = {}

def command(*parts):
    return subprocess.check_output([str(WM), '-m', *map(str, parts)], text=True)

def state():
    return json.loads(command('strip', 'status'))

def windows():
    return json.loads(command('query', '--windows'))

def metrics(*ids):
    return json.loads(subprocess.check_output([str(ROOT/'build/window_metrics'), *map(str,ids)], text=True))

def focus(wid):
    assert any(w['id']==wid and w['app']=='TanaFixture' for w in windows())
    command('window',wid,'--focus')
    time.sleep(.5)

def act(wid,name):
    assert any(w['id']==wid and w['app']=='TanaFixture' and w['has-focus'] for w in windows()), 'fixture lost focus'
    command('strip',name)
    time.sleep(.65)

def tile(wid):
    return next(w for w in state()['windows'] if w['id']==wid)

initial=state()
original_focus=next((w['id'] for w in windows() if w['has-focus']),None)
assert initial['version']=='0.2.0' and initial['ready'] and initial['backend']
assert not json.loads(command('strip','input-status'))['suspended']
assert not any(w['app']=='TanaFixture' for w in windows()), 'close earlier disposable fixtures first'
subprocess.run(['open','-n',str(ROOT/'build/TanaFixture.app')],check=True)
try:
    for _ in range(50):
        fixtures=[w for w in windows() if w['app']=='TanaFixture']
        if len(fixtures)>=3: break
        time.sleep(.1)
    assert len(fixtures)==3
    ids={w['id'] for w in fixtures}
    order=[w['id'] for w in state()['windows'] if w['id'] in ids]
    a,b,c=order
    focus(a); before=tile(a)['width']; act(a,'preset-width'); changed=tile(a)['width']
    assert abs(changed-before)>2
    act(a,'undo'); assert abs(tile(a)['width']-before)<2
    report['preset_and_undo']=True
    act(a,'fit-two'); pair=(tile(a)['width'],tile(b)['width'])
    assert all(v>=240 for v in pair)
    frames=metrics(a,b)
    assert abs(frames[1]['x']-(frames[0]['x']+frames[0]['w']+12))<=2
    report['fit_two_widths']=pair
    act(a,'consume'); assert tile(a)['column']==tile(b)['column']
    act(a,'tabs'); parked=metrics(b)[0]; assert parked['x']<-2000
    act(a,'down'); assert metrics(a)[0]['x']<-2000 and metrics(b)[0]['x']>=0
    act(b,'up'); assert metrics(b)[0]['x']<-2000
    act(a,'tabs'); assert metrics(b)[0]['y']>metrics(a)[0]['y']
    report['stack_tabs_and_row_focus']=True
    focus(b); act(b,'expel'); assert tile(a)['column']!=tile(b)['column']
    report['expel']=True
    focus(c); act(c,'utility-mark')
    assert next(w for w in windows() if w['id']==c)['is-floating']
    act(c,'utility'); assert next(w for w in windows() if w['id']==c)['is-minimized']
    assert not next(w for w in windows() if w['id']==c)['has-focus']
    command('strip','utility'); time.sleep(.8)
    assert next(w for w in windows() if w['id']==c)['has-focus']
    act(c,'utility-mark'); act(c,'float')
    report['utility']=True
    focus(a); focus(b); act(b,'previous')
    assert next(w for w in windows() if w['id']==a)['has-focus']
    report['previous']=True
    focus(a); command('strip','width',600); command('strip','center'); time.sleep(.8)
    for edge,delta in [('right',120),('left',-80)]:
        focus(a)
        result=json.loads(subprocess.check_output([str(ROOT/'build/native_edge_probe'),str(a),edge,str(delta)],text=True))
        expected=result['before'][2]+abs(delta)
        assert abs(result['after'][2]-expected)<=4,(edge,result['before'],result['after'])
        widths=[x['w'] for x in result['samples']]
        assert all(y>=x-3 for x,y in zip(widths,widths[1:])), (edge,'width reversed during outward drag')
        report['edge_'+edge]=result
    report['passed']=True
finally:
    (ROOT/'build/workflow-check.json').write_text(json.dumps(report,indent=2)+'\n')
    subprocess.run([str(ROOT/'build/window_fixture'),'quit'],check=False)
    time.sleep(.5)
    if original_focus and any(w['id']==original_focus for w in windows()): command('window',original_focus,'--focus')
    command('strip','scroll',initial['offset'])
    (ROOT/'build/workflow-check.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({k:v for k,v in report.items() if not k.startswith('edge_')},indent=2))
