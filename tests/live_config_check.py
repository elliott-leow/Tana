"""Live config and same-boot workflow persistence, using only disposable fixtures."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

ROOT=Path(__file__).resolve().parents[1]
WM=ROOT/'build/tana'
CONFIG=Path.home()/'Library/Application Support/Tana/config.json'

def command(*args): return subprocess.check_output([str(WM),'-m',*map(str,args)],text=True)
def windows(): return json.loads(command('query','--windows'))
def state(): return json.loads(command('strip','status'))
def config(): return json.loads(command('strip','config-status'))
def write(data):
    fd,name=tempfile.mkstemp(dir=CONFIG.parent,prefix='.config-check-')
    with os.fdopen(fd,'wb') as f: f.write(data)
    os.replace(name,CONFIG)
def restart():
    command('strip','quit')
    for _ in range(80):
        if subprocess.run([str(WM),'-m','strip','status'],capture_output=True).returncode: break
        time.sleep(.1)
    else: raise AssertionError('manager did not stop')
    subprocess.run(['open','-g','-n','--stdout',str(ROOT/'build/tana-live.out.log'),'--stderr',str(ROOT/'build/tana-live.err.log'),str(ROOT/'build/Tana.app')],check=True)
    for _ in range(100):
        q=subprocess.run([str(WM),'-m','strip','status'],capture_output=True,text=True)
        if not q.returncode and json.loads(q.stdout).get('ready'): break
        time.sleep(.1)
    else: raise AssertionError('manager did not restart')
    time.sleep(.8)
def focus(wid):
    assert any(w['id']==wid and w['app']=='TanaFixture' for w in windows())
    command('window',wid,'--focus');time.sleep(.5)

def metrics(wid): return json.loads(subprocess.check_output([str(ROOT/'build/window_metrics'),str(wid)],text=True))[0]

initial=state(); original_focus=next((w['id'] for w in windows() if w['has-focus']),None)
assert not any(w['app']=='TanaFixture' for w in windows())
original=CONFIG.read_bytes();report={};spawned=False
try:
    document=json.loads(original)
    document.setdefault('settings',{})['motionStrength']=.5
    document.setdefault('appRules',{})['dev.tana.fixture']={'width':460,'floating':False,'openBesideCurrent':True}
    write(json.dumps(document).encode());command('strip','reload-config')
    assert config()['motionStrength']==.5
    write(b'{invalid');command('strip','reload-config')
    assert config()['motionStrength']==.5 and config()['error']
    write(json.dumps(document).encode());command('strip','reload-config')
    report['reload_and_malformed_retention']=True
    subprocess.run(['open','-n',str(ROOT/'build/TanaFixture.app')],check=True);spawned=True
    time.sleep(1)
    ids={w['id'] for w in windows() if w['app']=='TanaFixture'}
    tiles=[w for w in state()['windows'] if w['id'] in ids]
    assert len(tiles)==3 and all(abs(w['width']-460)<2 for w in tiles),tiles
    a,b,c=[w['id'] for w in tiles]
    report['new_window_app_rules']=True
    focus(a);command('strip','width',512);time.sleep(.5);command('strip','remember-width')
    assert json.loads(CONFIG.read_text())['appRules']['dev.tana.fixture']['width']==512
    report['remember_width']=True
    command('strip','place',b,a,'below');time.sleep(.5);command('strip','tabs');time.sleep(.5)
    focus(c);command('strip','utility-mark');time.sleep(.5)
    restart()
    assert metrics(b)['x']<-2000
    assert next(w for w in windows() if w['id']==c)['is-floating']
    focus(a);focus(c);command('strip','utility');time.sleep(.5)
    assert next(w for w in windows() if w['id']==c)['is-minimized']
    assert next(w for w in windows() if w['id']==a)['has-focus']
    report['same_boot_tab_and_utility_restart']=True
finally:
    write(original);command('strip','reload-config')
    if spawned: subprocess.run([str(ROOT/'build/window_fixture'),'quit'],check=False)
    time.sleep(.5)
    if original_focus and any(w['id']==original_focus for w in windows()): command('window',original_focus,'--focus')
    command('strip','scroll',initial['offset'])
    (ROOT/'build/config-check.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
