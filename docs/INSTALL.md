# Install and recover Tana

Tana is an experimental macOS window manager built on a locally patched
yabai foundation. It is not production-certified. Test it with disposable work
before relying on it for a session.

## Build the app bundle

From the repository root:

```sh
scripts/package.sh
```

This runs `make all`, creates `build/Tana.app`, gives it the bundle ID
`dev.horizontalwm.manager`, and ad-hoc signs it by default. To use an installed
Developer ID instead, set `TANA_SIGN_ID` before packaging. Use
`scripts/package.sh --no-build` only when `build/tana` has already been
built. Packaging does not install the app, start a service, or request any
permission.

The bundle identifier deliberately retains the original HorizontalWM identity. Existing installations also keep using `~/Library/Application Support/HorizontalWM` when no Tana state directory exists. Fresh installations use `~/Library/Application Support/Tana`. Old recovery journals and `HORIZONTALWM_APP` / `HORIZONTALWM_SIGN_ID` overrides remain supported.

## Prerequisites you must set up manually

1. Build and run your existing yabai installation at
   `/opt/homebrew/bin/yabai`. Tana does not edit its configuration.
2. Manually load the existing yabai scripting addition. The per-user socket
   `/tmp/yabai-sa_$USER.socket` must exist before a handoff can start.
3. In **System Settings → Privacy & Security → Accessibility**, add the newly
   packaged `build/Tana.app` and enable it. The bundle is a different
   app identity from yabai, so yabai's existing grant does not grant this app.
4. If you use `skhd`, ensure `/opt/homebrew/bin/skhd` is available. The session
   handoff stops its launchd service temporarily to avoid global shortcut
   conflicts and starts it again only if it was running before the handoff.
   A running Loop utility is also quit temporarily because it can compete with
   the Option trackpad gestures; its observed executable path and PID are
   recorded and it is reopened after restoration.

You can inspect the new app's permission state without changing windows:

```sh
build/Tana.app/Contents/MacOS/tana --check-permissions
```

If the check reports Accessibility is missing, launch the permission request
yourself and approve it in System Settings:

```sh
build/Tana.app/Contents/MacOS/tana --request-permissions
```

The session helper does not disable SIP, change TCC, destroy Spaces, or grant
permissions automatically. The separately configured login launcher reuses the
existing authorized yabai helper loader.

## Start, inspect, and restore

Use the session helper rather than starting the bundle directly when replacing
a running yabai service:

```sh
python3 scripts/session.py preflight
python3 scripts/session.py start
python3 scripts/session.py status
python3 scripts/session.py restore
```

`start` snapshots queried yabai window positions, space indexes, floating and
layer state, and the observed yabai/skhd/Loop state before it stops a recognized
launchd yabai service. It writes an owner-only, atomic recovery record at:

```text
~/Library/Application Support/Tana/recovery.json
```

It then stops `skhd` and Loop, opens the bundle with `open`, and requires the new daemon
to answer `-m strip status`. A startup failure attempts a rollback using the
record. `restore` quits the new daemon, restarts only services stopped by the
session helper, and restores surviving windows' recorded space, floating/layer
state, and floating frames where yabai accepts those commands. It leaves the
recovery record in place with success or failure evidence.

Inspect the planned mutations first:

```sh
python3 scripts/session.py start --dry-run
python3 scripts/session.py restore --dry-run
```

The helper uses its own recovery lock to prevent concurrent handoffs. The
native daemon uses `/tmp/yabai_$USER.lock`, intentionally sharing yabai's lock
so the two managers cannot run together. If your yabai launchd label is not
one of the recognized labels, the helper refuses to stop an unmanaged process;
stop it manually and preserve your recovery plan.

## Strip controls

Once running, use the packaged executable as the client:

```sh
build/Tana.app/Contents/MacOS/tana -m strip status
build/Tana.app/Contents/MacOS/tana -m strip left
build/Tana.app/Contents/MacOS/tana -m strip right
build/Tana.app/Contents/MacOS/tana -m strip center
build/Tana.app/Contents/MacOS/tana -m strip width 720
```

The full command set is `left`, `right`, `move-left`, `move-right`, `float`,
`full`, `center`, `home`, `scroll <offset>`, `width <points>`, `pause`, and
`reflow`. Tana defaults to autofocus and keeps eligible windows in one
pinned active desktop. The menu describes the native trackpad actions.

Automated checks cover strip math, the actual layout and renderer against a fake WindowServer, floating and close transitions, and session-helper recovery logic.
They do not verify real Accessibility delivery, scripting-addition behavior,
physical trackpad gestures, window-server behavior, or recovery after a reboot.

## Existing development-machine login startup

On the development machine, `~/Library/LaunchAgents/dev.horizontalwm.login.plist`
is enabled with RunAtLoad for the Aqua session. It runs `scripts/login.sh`, waits
for an unlocked session and existing Accessibility access, checks the helper,
then opens the signed app and waits for ready/backend status. If necessary it
uses the existing passwordless `/opt/homebrew/bin/yabai --load-sa` authorization.
It retries failed startup; it does not supervise the app after a successful launch.

The `com.asmvik.yabai` and `com.koekeishiya.skhd` launch agents are disabled,
and Loop’s Launch at login setting is off. Borders and SketchyBar remain enabled.
The prior startup settings are recorded in
`~/Library/Application Support/HorizontalWM/startup-change.json`.
The launchd job was invoked and returned success with the manager ready; an
actual reboot/login cycle has not been verified. Keep this checkout and bundle
at their current paths because the launch agent references them.

To disable this login launcher before switching back to another manager:

```sh
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/dev.horizontalwm.login.plist
launchctl disable gui/$(id -u)/dev.horizontalwm.login
```

A session restore and startup configuration are separate: `session.py restore`
does not remove this login agent or reverse the later startup changes.
