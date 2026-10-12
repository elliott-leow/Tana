"""Optional native transition check. Requires an idle Tana session and TanaFixture.

Runs only float/fill/restore/retile on a verified disposable fixture window.
Samples fresh-process WindowServer bounds; does not claim compositor FPS.
"""
import json
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
WM = ROOT / 'build/tana'


def command(*parts):
    return subprocess.check_output([str(WM), '-m', *map(str, parts)], text=True)


def windows():
    return json.loads(command('query', '--windows'))


def frame(wid):
    value = json.loads(subprocess.check_output(
        [str(ROOT / 'build/window_metrics'), str(wid)], text=True))[0]
    return tuple(value[key] for key in ('x', 'y', 'w', 'h'))


def transition(wid, action):
    focused = next((w for w in windows() if w['has-focus']), None)
    assert focused and focused['id'] == wid and focused['app'] == 'TanaFixture', 'fixture lost focus; stop instead of acting on another app'
    before = frame(wid)
    command('strip', action)
    samples = []
    start = time.monotonic()
    while time.monotonic() - start < .8:
        samples.append(frame(wid))
        time.sleep(.012)
    final = samples[-1]
    assert before != final, (action, 'no movement')
    intermediate = {sample for sample in samples if sample not in (before, final)}
    assert len(intermediate) >= 2, (action, 'transition jumped without intermediate geometry', samples)
    return {'action': action, 'intermediate_frames': len(intermediate), 'before': before, 'after': final}


def main():
    initial = json.loads(command('strip', 'status'))
    assert initial['ready'] and not initial['paused'] and initial['backend']
    original_focus = next((w['id'] for w in windows() if w['has-focus']), None)
    fixture = next(w for w in windows() if w['app'] == 'TanaFixture' and not w['is-floating'])
    wid = fixture['id']
    report = []
    try:
        command('window', wid, '--focus')
        time.sleep(.7)
        report.append(transition(wid, 'float'))
        floating_frame = frame(wid)
        report.append(transition(wid, 'full'))
        report.append(transition(wid, 'full'))
        assert frame(wid) == floating_frame, 'floating fill must restore exact geometry'
        report.append(transition(wid, 'float'))
    finally:
        focused = next((w for w in windows() if w['has-focus']), None)
        # Preserve fresh user input if they started interacting during the check.
        if focused and focused['id'] == wid:
            if original_focus:
                command('window', original_focus, '--focus')
            command('strip', 'scroll', initial['offset'])
    (ROOT / 'build/animation-check.json').write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps(report))


if __name__ == '__main__':
    main()
