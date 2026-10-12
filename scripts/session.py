#!/usr/bin/env python3
"""Explicit, reversible handoff between an existing yabai session and Tana.

This tool never installs a service, changes configuration, loads the scripting
addition, or grants macOS permissions.  It records the state it can query
before changing anything, and keeps that record after restore as an audit log.
"""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import signal
import stat
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable, Optional

APP_NAME = "Tana"
SERVICE_LABELS = ("com.asmvik.yabai", "com.koekeishiya.yabai", "homebrew.mxcl.yabai")


class SessionError(RuntimeError):
    pass


@dataclass
class CommandResult:
    args: list[str]
    returncode: int
    stdout: str = ""
    stderr: str = ""


class Runner:
    """Small subprocess seam used by both the CLI and unit tests."""

    def run(self, args: Iterable[str], *, timeout: float = 10.0) -> CommandResult:
        argv = [str(part) for part in args]
        try:
            completed = subprocess.run(argv, text=True, capture_output=True, timeout=timeout, check=False)
        except (OSError, subprocess.TimeoutExpired) as exc:
            return CommandResult(argv, 127, "", str(exc))
        return CommandResult(argv, completed.returncode, completed.stdout, completed.stderr)


    def permission_check(self, executable: Path, app: Path, *, timeout: float = 5.0) -> CommandResult:
        """Probe the standalone app's TCC identity, not inherited terminal access."""
        with tempfile.TemporaryDirectory(prefix="tana-permission-") as directory:
            output = Path(directory) / "stdout"
            error = Path(directory) / "stderr"
            args = ["/usr/bin/open", "-n", "--stdout", str(output), "--stderr", str(error), str(app), "--args", "--check-permissions"]
            launched = self.run(args, timeout=timeout)
            if launched.returncode != 0:
                return launched
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                try:
                    text = output.read_text()
                    value = json.loads(text)
                    if isinstance(value, dict):
                        return CommandResult([str(executable), "--check-permissions"], 0, text, "")
                except (OSError, json.JSONDecodeError):
                    pass
                time.sleep(0.05)
            detail = error.read_text() if error.exists() else "permission probe did not finish"
            return CommandResult(args, 1, "", detail)


@dataclass
class SessionPaths:
    root: Path
    home: Path

    @property
    def app(self) -> Path:
        override = os.environ.get("TANA_APP") or os.environ.get("HORIZONTALWM_APP")
        return Path(override).expanduser() if override else self.root / "build" / "Tana.app"

    @property
    def app_executable(self) -> Path:
        return self.app / "Contents" / "MacOS" / "tana"

    @property
    def original_yabai(self) -> Path:
        return Path("/opt/homebrew/bin/yabai")

    @property
    def original_skhd(self) -> Path:
        return Path("/opt/homebrew/bin/skhd")

    @property
    def state_dir(self) -> Path:
        base = self.home / "Library" / "Application Support"
        current, legacy = base / APP_NAME, base / "HorizontalWM"
        return legacy if legacy.exists() and not current.exists() else current

    @property
    def recovery_path(self) -> Path:
        return self.state_dir / "recovery.json"

    @property
    def session_lock_path(self) -> Path:
        return self.state_dir / "session.lock"

    @property
    def user(self) -> str:
        return os.environ.get("USER") or str(os.getuid())

    @property
    def yabai_lock_path(self) -> Path:
        return Path("/tmp") / f"yabai_{self.user}.lock"

    @property
    def sa_socket_path(self) -> Path:
        return Path("/tmp") / f"yabai-sa_{self.user}.socket"


class SessionLock:
    """Separate session lock; Tana itself takes yabai_USER.lock."""

    def __init__(self, path: Path) -> None:
        self.path = path
        self._file: Optional[Any] = None

    def __enter__(self) -> "SessionLock":
        self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        self._file = open(self.path, "a+", encoding="utf-8")
        try:
            fcntl.flock(self._file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            self._file.close()
            self._file = None
            raise SessionError("another Tana session operation is already running") from exc
        return self

    def __exit__(self, exc_type: object, exc: object, traceback: object) -> None:
        if self._file is not None:
            fcntl.flock(self._file.fileno(), fcntl.LOCK_UN)
            self._file.close()
            self._file = None


def atomic_write_json(path: Path, payload: dict[str, Any]) -> None:
    """Write an owner-only JSON recovery record without exposing partial data."""
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            os.fchmod(handle.fileno(), 0o600)
            json.dump(payload, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        os.chmod(path, 0o600)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def load_json(path: Path) -> dict[str, Any]:
    try:
        with path.open(encoding="utf-8") as handle:
            value = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        raise SessionError(f"cannot read recovery record {path}: {exc}") from exc
    if not isinstance(value, dict) or value.get("format") != 1:
        raise SessionError("recovery record has an unsupported format")
    return value


def parse_json_output(result: CommandResult, description: str) -> Any:
    if result.returncode != 0:
        raise SessionError(f"{description} failed: {result.stderr.strip() or result.stdout.strip() or result.returncode}")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise SessionError(f"{description} did not return JSON") from exc


def snapshot_windows(windows: Any) -> list[dict[str, Any]]:
    if not isinstance(windows, list):
        raise SessionError("yabai window query did not return an array")
    fields = ("id", "pid", "space", "is-floating", "frame", "layer", "sub-layer", "has-focus")
    snapshot: list[dict[str, Any]] = []
    for window in windows:
        if not isinstance(window, dict) or not isinstance(window.get("id"), int):
            continue
        snapshot.append({key: window.get(key) for key in fields})
    return snapshot


def process_running(runner: Runner, name: str) -> bool:
    return runner.run(["/usr/bin/pgrep", "-x", name]).returncode == 0


def process_entries(runner: Runner, name: str) -> list[dict[str, Any]]:
    """Read PID and executable path without changing the observed process."""
    result = runner.run(["/bin/ps", "-axo", "pid=,comm="])
    entries: list[dict[str, Any]] = []
    if result.returncode != 0:
        return entries
    for line in result.stdout.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) != 2:
            continue
        try:
            pid = int(parts[0])
        except ValueError:
            continue
        executable = parts[1]
        if Path(executable).name == name:
            entries.append({"pid": pid, "executable": executable})
    return entries


def launchd_service(runner: Runner) -> Optional[str]:
    target = f"gui/{os.getuid()}"
    for label in SERVICE_LABELS:
        if runner.run(["/bin/launchctl", "print", f"{target}/{label}"]).returncode == 0:
            return label
    return None


@dataclass
class Controller:
    paths: SessionPaths
    runner: Runner = field(default_factory=Runner)
    timeout: float = 12.0
    _interrupted: bool = False

    def command_json(self, args: list[str], description: str) -> Any:
        return parse_json_output(self.runner.run(args), description)

    def original_query(self, subject: str) -> Any:
        return self.command_json([str(self.paths.original_yabai), "-m", "query", subject], f"yabai query {subject}")

    def app_status(self) -> dict[str, Any]:
        value = self.command_json([str(self.paths.app_executable), "-m", "strip", "status"], "Tana status")
        if not isinstance(value, dict):
            raise SessionError("Tana status did not return an object")
        return value

    def app_pids(self, executable: Optional[str] = None) -> list[int]:
        result = self.runner.run(["/usr/bin/pgrep", "-f", executable or str(self.paths.app_executable)])
        if result.returncode != 0:
            return []
        pids: list[int] = []
        for line in result.stdout.splitlines():
            try:
                pid = int(line.strip())
            except ValueError:
                continue
            if pid > 1:
                pids.append(pid)
        return pids

    def preflight(self) -> dict[str, Any]:
        if not self.paths.app_executable.is_file():
            raise SessionError(f"packaged executable is missing: {self.paths.app_executable}")
        if not os.access(self.paths.app_executable, os.X_OK):
            raise SessionError(f"packaged executable is not executable: {self.paths.app_executable}")
        permission = parse_json_output(
            self.runner.permission_check(self.paths.app_executable, self.paths.app, timeout=min(5.0, self.timeout)),
            "Tana permission check",
        )
        if not isinstance(permission, dict) or not permission.get("accessibility"):
            raise SessionError("Tana Accessibility permission is required; grant it manually, then retry")
        if permission.get("session_unlocked") is False:
            raise SessionError("Unlock the Mac before starting Tana")
        if not self.paths.sa_socket_path.exists():
            raise SessionError(
                f"existing yabai scripting-addition socket is absent: {self.paths.sa_socket_path}; "
                "load it manually before starting Tana"
            )
        if not self.paths.original_yabai.is_file():
            raise SessionError(f"original yabai is required at {self.paths.original_yabai}")
        backend = parse_json_output(self.runner.run([str(self.paths.app_executable), "--check-backend"]), "helper handshake")
        if not isinstance(backend, dict) or not backend.get("backend"):
            raise SessionError("existing yabai helper did not pass its handshake; load it before starting Tana")
        return {"permissions": permission, "backend": backend, "sa_socket": str(self.paths.sa_socket_path)}

    def make_snapshot(self, preflight: dict[str, Any]) -> dict[str, Any]:
        windows = snapshot_windows(self.original_query("--windows"))
        spaces = self.original_query("--spaces")
        saved_spaces = spaces if isinstance(spaces, list) else []
        service = launchd_service(self.runner)
        focused_window = next((window for window in windows if window.get("has-focus")), None)
        focused_space = next((space for space in saved_spaces if isinstance(space, dict) and space.get("has-focus")), None)
        visible_spaces = [space.get("index") for space in saved_spaces
                          if isinstance(space, dict) and space.get("is-visible") and isinstance(space.get("index"), int)]
        loop = process_entries(self.runner, "Loop")
        return {
            "format": 1,
            "created_at": time.time(),
            "phase": "snapshotted",
            "preflight": preflight,
            "yabai": {
                "path": str(self.paths.original_yabai),
                "service_label": service,
                "responding": True,
                "windows": windows,
                "spaces": saved_spaces,
                "focused_space": focused_space.get("index") if isinstance(focused_space, dict) else None,
                "visible_spaces": visible_spaces,
                "focused_window": {"id": focused_window.get("id"), "pid": focused_window.get("pid")} if focused_window else None,
            },
            "processes": {"skhd_running": process_running(self.runner, "skhd"),
                          "loop_running": bool(loop) or process_running(self.runner, "Loop"),
                          "loop": loop},
            "tana": {"app": str(self.paths.app), "executable": str(self.paths.app_executable), "pids": []},
            "evidence": [],
        }

    def update_record(self, record: dict[str, Any], **changes: Any) -> None:
        record.update(changes)
        atomic_write_json(self.paths.recovery_path, record)

    def wait_for(self, predicate: Any, what: str) -> Any:
        deadline = time.monotonic() + self.timeout
        last_error = ""
        while time.monotonic() < deadline:
            if self._interrupted:
                raise SessionError("interrupted")
            try:
                return predicate()
            except SessionError as exc:
                last_error = str(exc)
            time.sleep(0.15)
        raise SessionError(f"timed out waiting for {what}{': ' + last_error if last_error else ''}")

    def stop_original_service(self, record: dict[str, Any]) -> None:
        if not record["yabai"].get("service_label"):
            raise SessionError("existing yabai is not a recognized launchd service; refusing to stop an unmanaged process")
        record["yabai"]["stop_intent"] = True
        self.update_record(record, phase="stopping_yabai")
        result = self.runner.run([str(self.paths.original_yabai), "--stop-service"])
        if result.returncode != 0:
            raise SessionError(f"could not stop existing yabai service: {result.stderr.strip() or result.stdout.strip()}")
        record["yabai"]["stopped_by_session"] = True
        self.update_record(record, phase="yabai_stopped")

    def stop_skhd(self, record: dict[str, Any]) -> None:
        if not record["processes"].get("skhd_running"):
            return
        record["processes"]["skhd_stop_intent"] = True
        self.update_record(record, phase="stopping_skhd")
        result = self.runner.run([str(self.paths.original_skhd), "--stop-service"])
        if result.returncode != 0:
            raise SessionError(f"could not stop skhd service: {result.stderr.strip() or result.stdout.strip()}")
        self.wait_for(lambda: not process_running(self.runner, "skhd") or (_ for _ in ()).throw(SessionError("skhd still running")), "skhd to stop")
        record["processes"]["skhd_stopped_by_session"] = True
        self.update_record(record, phase="skhd_stopped")

    def stop_loop(self, record: dict[str, Any]) -> None:
        if not record["processes"].get("loop_running"):
            return
        record["processes"]["loop_stop_intent"] = True
        self.update_record(record, phase="stopping_loop")
        self.runner.run(["/usr/bin/osascript", "-e", 'tell application "Loop" to quit'])
        deadline = time.monotonic() + self.timeout
        while process_running(self.runner, "Loop") and time.monotonic() < deadline:
            time.sleep(0.15)
        if process_running(self.runner, "Loop"):
            for process in record["processes"].get("loop", []):
                pid = process.get("pid")
                if isinstance(pid, int) and pid > 1:
                    self.runner.run(["/bin/kill", "-TERM", str(pid)])
            self.wait_for(lambda: not process_running(self.runner, "Loop") or (_ for _ in ()).throw(SessionError("Loop still running")), "Loop to stop")
        record["processes"]["loop_stopped_by_session"] = True
        self.update_record(record, phase="loop_stopped")

    def shared_yabai_lock_is_free(self) -> bool:
        self.paths.yabai_lock_path.parent.mkdir(exist_ok=True)
        descriptor = os.open(self.paths.yabai_lock_path, os.O_CREAT | os.O_WRONLY, 0o600)
        try:
            try:
                fcntl.lockf(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return False
            fcntl.lockf(descriptor, fcntl.LOCK_UN)
            return True
        finally:
            os.close(descriptor)

    def launch_app(self, record: dict[str, Any]) -> None:
        result = self.runner.run(["/usr/bin/open", str(self.paths.app)])
        if result.returncode != 0:
            raise SessionError(f"could not launch app: {result.stderr.strip() or result.stdout.strip()}")
        def ready_status() -> dict[str, Any]:
            status = self.app_status()
            if not status.get("ready"):
                raise SessionError("Tana daemon replied but is not ready")
            if not status.get("backend"):
                raise SessionError("Tana daemon replied but its yabai backend is unavailable")
            return status
        status = self.wait_for(ready_status, "Tana daemon")
        record["tana"]["status"] = status
        record["tana"]["pids"] = self.app_pids()

    def ensure_no_unresolved_recovery(self) -> None:
        if not self.paths.recovery_path.exists():
            return
        record = load_json(self.paths.recovery_path)
        if record.get("phase") != "restored":
            raise SessionError(
                f"unresolved recovery record is {record.get('phase', 'unknown')}; run restore and inspect its evidence before starting again"
            )

    def start(self, dry_run: bool = False) -> dict[str, Any]:
        if dry_run:
            return {"dry_run": True, "would": ["preflight", "snapshot yabai windows/spaces", "stop recognized yabai service",
                                                    "stop skhd and Loop", "open packaged app", "verify strip status", "rollback on failure"]}
        with SessionLock(self.paths.session_lock_path):
            self.ensure_no_unresolved_recovery()
            preflight = self.preflight()
            record = self.make_snapshot(preflight)
            self.update_record(record)
            try:
                self.stop_original_service(record)
                self.stop_skhd(record)
                self.stop_loop(record)
                self.update_record(record, phase="handoff")
                self.wait_for(lambda: self.shared_yabai_lock_is_free() or (_ for _ in ()).throw(SessionError("yabai lock still held")), "existing yabai lock release")
                self.launch_app(record)
                self.update_record(record, phase="active", activated_at=time.time())
                return record
            except BaseException as exc:
                record["evidence"].append({"at": time.time(), "event": "start_failed", "detail": str(exc)})
                try:
                    self.rollback(record)
                except Exception as rollback_error:  # preserve the original failure and evidence
                    record["evidence"].append({"at": time.time(), "event": "rollback_failed", "detail": str(rollback_error)})
                self.update_record(record, phase="failed")
                if isinstance(exc, KeyboardInterrupt):
                    raise SessionError("interrupted; rollback attempted") from exc
                raise

    def stop_tana(self, record: dict[str, Any]) -> None:
        recorded = record.get("tana", record.get("horizontalwm", {}))
        executables = list(dict.fromkeys((str(self.paths.app_executable), str(recorded.get("executable", self.paths.app_executable)))))
        # Ask the daemon to restore its own pre-session state before it exits.
        # An older recovery journal may predate the Tana executable/socket name.
        for executable in executables:
            self.runner.run([executable, "-m", "strip", "quit"])
        if all(self.wait_until_tana_stops(executable) for executable in executables):
            return
        for executable in executables:
            # Resolve current owners instead of signaling possibly reused IDs
            # from a saved recovery journal.
            for pid in self.app_pids(executable):
                self.runner.run(["/bin/kill", "-TERM", str(pid)])
        if all(self.wait_until_tana_stops(executable) for executable in executables):
            return
        raise SessionError("Tana daemon did not exit; refusing to restore yabai over it")

    def wait_until_tana_stops(self, executable: str) -> bool:
        """Require both a dead client socket and no matching app process."""
        deadline = time.monotonic() + self.timeout
        while time.monotonic() < deadline:
            running = bool(self.app_pids(executable))
            try:
                self.app_status()
                responding = True
            except SessionError:
                responding = False
            if not running and not responding:
                return True
            time.sleep(0.15)
        return False

    def restart_original(self, record: dict[str, Any]) -> None:
        if record.get("yabai", {}).get("stopped_by_session") or record.get("yabai", {}).get("stop_intent"):
            result = self.runner.run([str(self.paths.original_yabai), "--start-service"])
            if result.returncode != 0:
                raise SessionError(f"could not restart yabai: {result.stderr.strip() or result.stdout.strip()}")
            self.wait_for(lambda: self.original_query("--windows"), "original yabai")
        if record.get("processes", {}).get("skhd_stopped_by_session") or record.get("processes", {}).get("skhd_stop_intent"):
            result = self.runner.run([str(self.paths.original_skhd), "--start-service"])
            if result.returncode != 0:
                raise SessionError(f"could not restart skhd: {result.stderr.strip() or result.stdout.strip()}")

    def restore_windows(self, record: dict[str, Any]) -> list[str]:
        current = snapshot_windows(self.original_query("--windows"))
        current_by_id = {item["id"]: item for item in current}
        errors: list[str] = []
        for saved in record.get("yabai", {}).get("windows", []):
            identifier = saved.get("id")
            if identifier not in current_by_id:
                errors.append(f"window {identifier} no longer exists")
                continue
            now = current_by_id[identifier]
            if not isinstance(saved.get("pid"), int) or now.get("pid") != saved.get("pid"):
                errors.append(f"window {identifier} belongs to a different process; skipped")
                continue
            def apply(parts: list[str]) -> bool:
                result = self.runner.run([str(self.paths.original_yabai), "-m", "window", str(identifier), *parts])
                if result.returncode != 0:
                    errors.append(f"window {identifier}: {result.stderr.strip() or result.stdout.strip() or 'command failed'}")
                    return False
                return True
            space = saved.get("space")
            if isinstance(space, int):
                apply(["--space", str(space)])
            desired_floating = saved.get("is-floating")
            if isinstance(desired_floating, bool) and now.get("is-floating") != desired_floating:
                apply(["--toggle", "float"])
            sub_layer = saved.get("sub-layer")
            if desired_floating and isinstance(sub_layer, str) and sub_layer in ("above", "normal", "below"):
                apply(["--sub-layer", sub_layer])
            elif not desired_floating:
                apply(["--sub-layer", "auto"])
            frame = saved.get("frame")
            if desired_floating and isinstance(frame, dict):
                x, y, w, h = (frame.get(key) for key in ("x", "y", "w", "h"))
                if all(isinstance(value, (int, float)) for value in (x, y, w, h)) and w > 0 and h > 0:
                    apply(["--move", f"abs:{x:.0f}:{y:.0f}"])
                    apply(["--resize", f"abs:{w:.0f}:{h:.0f}"])
        focused_space = record.get("yabai", {}).get("focused_space")
        if not isinstance(focused_space, int):
            visible_spaces = record.get("yabai", {}).get("visible_spaces", [])
            focused_space = visible_spaces[0] if visible_spaces and isinstance(visible_spaces[0], int) else None
        if isinstance(focused_space, int):
            spaces = self.original_query("--spaces")
            already_focused = any(space.get("index") == focused_space and space.get("has-focus")
                                  for space in spaces if isinstance(space, dict))
            if not already_focused:
                result = self.runner.run([str(self.paths.original_yabai), "-m", "space", "--focus", str(focused_space)])
                if result.returncode != 0:
                    errors.append(f"could not focus original space {focused_space}")
        focused_window = record.get("yabai", {}).get("focused_window")
        if isinstance(focused_window, dict):
            identifier = focused_window.get("id")
            current_window = current_by_id.get(identifier)
            if isinstance(identifier, int) and current_window and current_window.get("pid") == focused_window.get("pid"):
                result = self.runner.run([str(self.paths.original_yabai), "-m", "window", str(identifier), "--focus"])
                if result.returncode != 0:
                    errors.append(f"could not focus original window {identifier}")
        return errors

    def rollback(self, record: dict[str, Any]) -> list[str]:
        self.stop_tana(record)
        self.restart_original(record)
        errors = self.restore_windows(record)
        if record.get("processes", {}).get("loop_stopped_by_session") or record.get("processes", {}).get("loop_stop_intent"):
            result = self.runner.run(["/usr/bin/open", "-a", "Loop"])
            if result.returncode != 0:
                errors.append("could not restart Loop")
        return errors

    def restore(self, dry_run: bool = False) -> dict[str, Any]:
        if dry_run:
            return {"dry_run": True, "would": ["quit Tana", "restart only services stopped by session", "restore surviving windows"]}
        with SessionLock(self.paths.session_lock_path):
            record = load_json(self.paths.recovery_path)
            errors = self.rollback(record)
            record["phase"] = "restored" if not errors else "restored_with_errors"
            record["restored_at"] = time.time()
            record["restore_errors"] = errors
            atomic_write_json(self.paths.recovery_path, record)
            return record

    def status(self) -> dict[str, Any]:
        result: dict[str, Any] = {"app": str(self.paths.app), "recovery_path": str(self.paths.recovery_path),
                                  "sa_socket_present": self.paths.sa_socket_path.exists(),
                                  "shared_yabai_lock_free": self.shared_yabai_lock_is_free()}
        if self.paths.recovery_path.exists():
            try:
                result["recovery"] = load_json(self.paths.recovery_path)
            except SessionError as exc:
                result["recovery_error"] = str(exc)
        try:
            result["tana"] = self.app_status()
        except SessionError as exc:
            result["tana_error"] = str(exc)
        return result


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--timeout", type=float, default=12.0, help="daemon/service wait timeout in seconds")
    parser.add_argument("--home", type=Path, default=Path.home(), help=argparse.SUPPRESS)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1], help=argparse.SUPPRESS)
    subcommands = parser.add_subparsers(dest="command", required=True)
    for name in ("start", "restore"):
        command = subcommands.add_parser(name)
        command.add_argument("--dry-run", action="store_true")
    subcommands.add_parser("preflight")
    subcommands.add_parser("status")
    return parser


def main(argv: Optional[list[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    controller = Controller(SessionPaths(args.root.resolve(), args.home.expanduser().resolve()), timeout=max(args.timeout, 0.1))
    old_handlers: dict[int, Any] = {}
    def interrupted(signum: int, frame: Any) -> None:
        del signum, frame
        controller._interrupted = True
    for signum in (signal.SIGINT, signal.SIGTERM):
        old_handlers[signum] = signal.signal(signum, interrupted)
    try:
        if args.command == "start":
            output = controller.start(args.dry_run)
        elif args.command == "restore":
            output = controller.restore(args.dry_run)
        elif args.command == "preflight":
            output = controller.preflight()
        else:
            output = controller.status()
        print(json.dumps(output, indent=2, sort_keys=True))
        return 0
    except SessionError as exc:
        print(f"session.py: {exc}", file=sys.stderr)
        return 1
    finally:
        for signum, handler in old_handlers.items():
            signal.signal(signum, handler)


if __name__ == "__main__":
    raise SystemExit(main())
