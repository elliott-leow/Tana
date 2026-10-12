import importlib.util
import json
import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "scripts" / "session.py"
SPEC = importlib.util.spec_from_file_location("tana_session", MODULE_PATH)
assert SPEC and SPEC.loader
session = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = session
SPEC.loader.exec_module(session)


class FakeRunner(session.Runner):
    def __init__(self, responder):
        self.responder = responder
        self.calls = []

    def permission_check(self, executable, app, *, timeout=5.0):
        del app, timeout
        return self.run([str(executable), "--check-permissions"])

    def run(self, args, *, timeout=10.0):
        del timeout
        args = [str(value) for value in args]
        self.calls.append(args)
        return self.responder(args)


class SessionTests(unittest.TestCase):
    def test_rename_preserves_existing_state_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            paths = session.SessionPaths(home / 'project', home)
            base = home / 'Library' / 'Application Support'
            self.assertEqual(paths.state_dir, base / 'Tana')
            legacy = base / 'HorizontalWM'
            legacy.mkdir(parents=True)
            (legacy / 'layout.json').write_text('{"order":[123]}')
            self.assertEqual(paths.state_dir, legacy)
            self.assertEqual(paths.recovery_path, legacy / 'recovery.json')
            (base / 'Tana').mkdir()
            self.assertEqual(paths.state_dir, base / 'Tana')
            self.assertEqual((legacy / 'layout.json').read_text(), '{"order":[123]}')

    def test_rename_can_stop_a_legacy_recovery_session(self):
        paths = self.make_paths()
        runner = FakeRunner(lambda args: session.CommandResult(args, 0, '', ''))
        controller = session.Controller(paths, runner)
        stopped = []
        controller.wait_until_tana_stops = lambda executable: stopped.append(executable) or True
        legacy = '/test/HorizontalWM.app/Contents/MacOS/horizontalwm'
        controller.stop_tana({'horizontalwm': {'executable': legacy, 'pids': []}})
        self.assertEqual(stopped, [str(paths.app_executable), legacy])
        self.assertIn([str(paths.app_executable), '-m', 'strip', 'quit'], runner.calls)
        self.assertIn([legacy, '-m', 'strip', 'quit'], runner.calls)

    def make_paths(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name) / "project"
        home = Path(temporary.name) / "home"
        executable = root / "build" / "Tana.app" / "Contents" / "MacOS" / "tana"
        executable.parent.mkdir(parents=True)
        executable.write_text("placeholder", encoding="utf-8")
        executable.chmod(0o755)
        # Controller paths are normally fixed; make original-yabai presence
        # testable without relying on a Homebrew installation.
        class TestPaths(session.SessionPaths):
            @property
            def original_yabai(self):
                return root / "original-yabai"

            @property
            def original_skhd(self):
                return root / "original-skhd"

            @property
            def sa_socket_path(self):
                return root / "sa.socket"

            @property
            def yabai_lock_path(self):
                return root / "yabai.lock"

        paths = TestPaths(root, home)
        paths.original_yabai.write_text("placeholder", encoding="utf-8")
        paths.original_skhd.write_text("placeholder", encoding="utf-8")
        paths.sa_socket_path.write_text("socket", encoding="utf-8")
        return paths

    def test_atomic_record_is_private_and_complete(self):
        paths = self.make_paths()
        payload = {"format": 1, "phase": "snapshotted", "value": [1, 2, 3]}
        session.atomic_write_json(paths.recovery_path, payload)
        self.assertEqual(session.load_json(paths.recovery_path), payload)
        self.assertEqual(stat.S_IMODE(paths.recovery_path.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(paths.state_dir.stat().st_mode), 0o700)
        self.assertFalse(list(paths.state_dir.glob(".recovery.json.*")))

    def test_snapshot_filters_unknown_window_fields(self):
        windows = [{"id": 1, "pid": 99, "space": 3, "is-floating": True, "has-focus": True,
                    "frame": {"x": 1, "y": 2, "w": 3, "h": 4},
                    "layer": "above", "sub-layer": "normal", "secret": "omit"},
                   {"id": "not-an-id"}]
        self.assertEqual(session.snapshot_windows(windows), [{"id": 1, "pid": 99, "space": 3, "is-floating": True, "has-focus": True,
                                                              "frame": {"x": 1, "y": 2, "w": 3, "h": 4},
                                                              "layer": "above", "sub-layer": "normal"}])

    def test_active_recovery_is_not_overwritten(self):
        paths = self.make_paths()
        session.atomic_write_json(paths.recovery_path, {"format": 1, "phase": "active"})
        controller = session.Controller(paths, FakeRunner(lambda args: session.CommandResult(args, 0, "", "")))
        with self.assertRaises(session.SessionError):
            controller.start()

    def test_restore_skips_reused_ids_and_honors_sublayer_focus(self):
        paths = self.make_paths()
        current = [
            {"id": 1, "pid": 100, "space": 3, "is-floating": True, "frame": {}, "layer": "normal", "sub-layer": "normal"},
            {"id": 2, "pid": 222, "space": 4, "is-floating": False, "frame": {}, "layer": "normal", "sub-layer": "normal"},
        ]

        def respond(args):
            if "query" in args:
                return session.CommandResult(args, 0, json.dumps(current), "")
            return session.CommandResult(args, 0, "", "")

        runner = FakeRunner(respond)
        controller = session.Controller(paths, runner)
        record = {"yabai": {"focused_space": 3, "focused_window": {"id": 1, "pid": 100}, "windows": [
            {"id": 1, "pid": 100, "space": 3, "is-floating": True, "frame": {"x": 1, "y": 2, "w": 30, "h": 40}, "layer": "normal", "sub-layer": "above"},
            {"id": 2, "pid": 999, "space": 4, "is-floating": False, "frame": {}, "layer": "normal", "sub-layer": "normal"},
        ]}}
        errors = controller.restore_windows(record)
        calls = [" ".join(call) for call in runner.calls]
        self.assertTrue(any("window 1 --sub-layer above" in call for call in calls))
        self.assertFalse(any("window 2 --space" in call for call in calls))
        self.assertTrue(any("space --focus 3" in call for call in calls))
        self.assertTrue(any("window 1 --focus" in call for call in calls))
        self.assertIn("window 2 belongs to a different process; skipped", errors)

    def test_preflight_fails_before_any_service_mutation(self):
        paths = self.make_paths()

        def respond(args):
            if args[-1] == "--check-permissions":
                return session.CommandResult(args, 1, json.dumps({"accessibility": False}), "no access")
            return session.CommandResult(args, 0, "", "")

        runner = FakeRunner(respond)
        controller = session.Controller(paths, runner, timeout=0.1)
        with self.assertRaises(session.SessionError):
            controller.start()
        self.assertFalse(any("--stop-service" in call for call in runner.calls))
        self.assertFalse(paths.recovery_path.exists())

    def test_locked_session_fails_before_any_service_mutation(self):
        paths = self.make_paths()
        runner = FakeRunner(lambda args: session.CommandResult(
            args, 0, json.dumps({"accessibility": True, "session_unlocked": False}), ""))
        controller = session.Controller(paths, runner, timeout=0.1)
        with self.assertRaisesRegex(session.SessionError, "Unlock the Mac"):
            controller.start()
        self.assertEqual(len(runner.calls), 1)
        self.assertEqual(runner.calls[0][-1], "--check-permissions")
        self.assertFalse(paths.recovery_path.exists())

    def test_restore_does_not_refocus_an_already_focused_space(self):
        paths = self.make_paths()

        def respond(args):
            if args[-1] == "--spaces":
                return session.CommandResult(args, 0, '[{"index":3,"has-focus":true}]', "")
            if args[-1] == "--windows":
                return session.CommandResult(args, 0, "[]", "")
            return session.CommandResult(args, 1, "", "cannot focus an already focused space")

        runner = FakeRunner(respond)
        controller = session.Controller(paths, runner)
        self.assertEqual(controller.restore_windows({"yabai": {"focused_space": 3, "windows": []}}), [])
        self.assertFalse(any("--focus" in call for call in runner.calls))

    def test_failed_launch_rolls_back_service_and_writes_evidence(self):
        paths = self.make_paths()

        def respond(args):
            if args[-1] == "--check-permissions":
                return session.CommandResult(args, 0, json.dumps({"accessibility": True}), "")
            if args[-1] == "--check-backend":
                return session.CommandResult(args, 0, json.dumps({"backend": True}), "")
            if args[:2] == ["/bin/launchctl", "print"]:
                return session.CommandResult(args, 0 if args[-1].endswith("com.koekeishiya.yabai") else 1, "", "")
            if args[:2] == ["/usr/bin/pgrep", "-x"]:
                return session.CommandResult(args, 1, "", "")
            if "-m" in args and "query" in args:
                subject = args[-1]
                if subject == "--windows":
                    return session.CommandResult(args, 0, json.dumps([{"id": 44, "space": 2, "is-floating": False,
                                                                         "frame": {"x": 0, "y": 0, "w": 100, "h": 100},
                                                                         "layer": "normal", "sub-layer": "normal"}]), "")
                return session.CommandResult(args, 0, "[]", "")
            if args[-3:] == ["-m", "strip", "status"]:
                return session.CommandResult(args, 1, "", "not running")
            return session.CommandResult(args, 0, "", "")

        runner = FakeRunner(respond)
        controller = session.Controller(paths, runner, timeout=0.01)
        with self.assertRaises(session.SessionError):
            controller.start()
        calls = [" ".join(call) for call in runner.calls]
        self.assertTrue(any("--stop-service" in call for call in calls))
        self.assertTrue(any("--start-service" in call for call in calls))
        self.assertTrue(any("-m strip quit" in call for call in calls))
        saved = session.load_json(paths.recovery_path)
        self.assertEqual(saved["phase"], "failed")
        self.assertEqual(saved["evidence"][0]["event"], "start_failed")

    def test_session_lock_rejects_a_second_operation(self):
        paths = self.make_paths()
        with session.SessionLock(paths.session_lock_path):
            with self.assertRaises(session.SessionError):
                with session.SessionLock(paths.session_lock_path):
                    pass

    def test_launch_waits_for_strip_initialization(self):
        paths = self.make_paths()
        polls = 0

        def respond(args):
            nonlocal polls
            if args[-3:] == ["-m", "strip", "status"]:
                polls += 1
                return session.CommandResult(args, 0, json.dumps({"ready": polls >= 2, "backend": True}), "")
            if args[0] == "/usr/bin/pgrep":
                return session.CommandResult(args, 1, "", "")
            return session.CommandResult(args, 0, "", "")

        controller = session.Controller(paths, FakeRunner(respond), timeout=1)
        record = {"tana": {}}
        controller.launch_app(record)
        self.assertEqual(polls, 2)
        self.assertTrue(record["tana"]["status"]["ready"])


if __name__ == "__main__":
    unittest.main()
