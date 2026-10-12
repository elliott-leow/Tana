"""Live strip regression: viewport snaps and fixture-only position drift."""
import getpass
import json
from pathlib import Path
import socket
import struct
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
WM = ROOT / "build/tana"


def command(*args):
    return subprocess.check_output([str(WM), "-m", *map(str, args)], text=True)


def status():
    return json.loads(command("strip", "status"))


def metrics(ids):
    return json.loads(subprocess.check_output(
        [str(ROOT / "build/window_metrics"), *map(str, ids)], text=True))


initial = status()
assert initial["ready"] and not initial["paused"] and initial["windows"]
assert not json.loads(command("strip", "input-status"))["suspended"]
left = float(command("config", "left_padding"))
samples = []
try:
    # Repeatedly bring neighboring columns into view, including full-width ones.
    for tile in initial["windows"][:6]:
        command("strip", "scroll", tile["x"])
        time.sleep(.6)
        state = status()
        actual = metrics(w["id"] for w in state["windows"])
        errors = []
        for w in state["windows"]:
            measured = next(a for a in actual if a["id"] == w["id"])
            expected = round(left + w["x"] - state["offset"])
            if abs(measured["x"] - expected) > 1:
                errors.append({"id": w["id"], "expected": expected, "actual": measured["x"]})
        overlaps = []
        for i, a in enumerate(actual):
            for b in actual[i + 1:]:
                dx = min(a["x"] + a["w"], b["x"] + b["w"]) - max(a["x"], b["x"])
                dy = min(a["y"] + a["h"], b["y"] + b["h"]) - max(a["y"], b["y"])
                if dx > 1 and dy > 1:
                    overlaps.append([a["id"], b["id"], dx, dy])
        samples.append({"offset": state["offset"], "errors": errors, "overlaps": overlaps})
        assert not errors and not overlaps, samples[-1]

    # Fault injection is restricted to an existing disposable fixture window.
    state = status()
    ids = {w["id"] for w in state["windows"]}
    fixture = next(w for w in json.loads(command("query", "--windows"))
                   if w["app"] == "TanaFixture" and w["id"] in ids)
    wid = fixture["id"]
    before = metrics([wid])[0]
    payload = struct.pack("=BIii", 6, wid, int(before["x"] + 44), int(before["y"]))
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(1)
        connection.connect(f"/tmp/yabai-sa_{getpass.getuser()}.socket")
        connection.sendall(struct.pack("=h", len(payload)) + payload)
        connection.recv(1)
    start = time.monotonic()
    corrected = False
    while time.monotonic() - start < 1:
        actual = metrics([wid])[0]
        state = status()
        tile = next(w for w in state["windows"] if w["id"] == wid)
        if abs(actual["x"] - round(left + tile["x"] - state["offset"])) <= 1:
            corrected = True
            break
        time.sleep(.03)
    assert corrected, "fixture position did not recover"
    report = {"snaps": samples, "drift_corrected": corrected,
              "drift_recovery_seconds": time.monotonic() - start}
    (ROOT / "build/position-check.json").write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))
finally:
    command("strip", "scroll", initial["offset"])
