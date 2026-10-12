"""Inject native vertical gesture phases; verify cleanup and subsequent panning.

Run with Tana active and the pointer idle. Restores the original viewport.
"""
import json
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
WM = ROOT / 'build/tana'
PROBE = ROOT / 'build/gesture_probe'
METRICS = ROOT / 'build/window_metrics'


def command(*parts):
    return subprocess.check_output([str(WM), '-m', 'strip', *map(str, parts)], text=True)


def state():
    return json.loads(command('input-status'))


def gesture(part, amount):
    subprocess.run([str(PROBE), part, str(amount)], check=True)


def wait_for(predicate, timeout=3):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(.04)
    raise AssertionError(('gesture transition timed out', state()))


def metrics(ids):
    return json.loads(subprocess.check_output([str(METRICS), *map(str, ids)], text=True))


initial = json.loads(command('status'))
assert initial['ready'] and not initial['paused'] and initial['backend']
assert not state()['overview'] and not state()['mission_control']
ids = [w['id'] for w in initial['windows']]
assert ids
before = metrics(ids)
report = {'checks': []}


def closed():
    wait_for(lambda: not state()['overview'])
    s = state()
    assert s['tap_enabled'] and not s['overview_gesture_active'] and not s['mission_control'], s
    for a, b in zip(before, metrics(ids)):
        for key in ('x', 'y', 'w', 'h', 'a', 'b', 'c', 'd', 'tx', 'ty'):
            assert abs(a[key]-b[key]) < 1, (key, a, b)


try:
    # Regression: a begin during close used to clear animating permanently.
    command('overview-progress', 1)
    command('overview-cancel')
    gesture('vertical-begin', 0)
    closed()
    gesture('vertical-end', .5)
    time.sleep(.1)
    assert not state()['overview'], 'late terminal event reopened the overview'
    report['checks'].append('new begin during close cannot strand transforms or input')

    for _ in range(5):
        gesture('vertical', .5)
        wait_for(lambda: state()['overview'] and not state()['overview_animating'])
        gesture('vertical', -.5)
        closed()
    report['checks'].append('five up/down cycles restore windows and release input')

    # Reverse before the opening settle finishes.
    gesture('vertical', .15)
    gesture('vertical', -.5)
    closed()
    report['checks'].append('quick reversal during opening settles cleanly')

    for opening in (True, False):
        if not opening:
            command('overview-progress', 1)
        gesture('vertical-begin', 0)
        gesture('vertical-change', .08)
        wait_for(lambda: state()['overview_gesture_active'])
        closed()
    report['checks'].append('missing terminal events recover while opening and closing')

    gesture('vertical-begin', 0)
    gesture('vertical-change', .2)
    gesture('vertical-cancel', .2)
    closed()
    command('overview-progress', 1)
    gesture('vertical-begin', 0)
    gesture('vertical-change', -.2)
    gesture('vertical-cancel', -.2)
    wait_for(lambda: state()['overview'] and not state()['overview_animating'])
    command('overview-cancel')
    closed()
    report['checks'].append('cancelled opening restores strip; cancelled closing restores overview')

    # The event tap, renderer, and real windows must respond after cleanup.
    frame_count = json.loads(command('status'))['frames']
    gesture('swipe', .08 if initial['offset'] < 100 else -.08)
    time.sleep(.6)
    after = json.loads(command('status'))
    moved = metrics(ids)
    assert after['frames'] > frame_count
    assert abs(after['offset']-initial['offset']) > 10
    assert any(abs(a['x']-b['x']) > 10 for a, b in zip(before, moved))
    report['checks'].append('subsequent horizontal gesture moves actual windows')
    report['result'] = 'pass'
finally:
    if state()['overview']:
        command('overview-cancel')
        time.sleep(.4)
        if state()['overview']:
            command('pause')
            command('pause')
    command('scroll', initial['offset'])
    (ROOT / 'build/overview-gesture-check.json').write_text(json.dumps(report, indent=2)+'\n')
print(json.dumps(report, indent=2))
