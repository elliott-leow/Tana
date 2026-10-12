# Patched yabai — floating-above-tiled *and* native Space animations

Stock yabai forces a choice between two things:

- **Floating windows above tiled ones** needs the scripting addition, because window
  sub-layers can only be set through private SkyLight APIs from inside Dock.
- **The native Space-switch animation** is destroyed by that same scripting addition.

When the payload is injected it locates the instruction that supplies Dock's
space-transition animation time and overwrites it with zero
(`src/osax/payload.m`, in `init_instances`). The write is unconditional, so it
removes the slide for *every* space switch — cmd+tab, Dock clicks, and the numeric
mission-control shortcuts — not just yabai-initiated ones. Upstream declined to make
it configurable ([issue #1501](https://github.com/koekeishiya/yabai/issues/1501):
*"I'm not particularly interested in making this customisable at this time."*).

This build skips **only that instruction write**.

## What the patch changes

`animation-preserve.patch` (2 files):

1. **`src/osax/payload.m`** — drops the `vm_protect` + instruction write. The address
   lookup is deliberately kept, so `OSAX_ATTRIB_ANIM_TIME` is still reported and the
   all-attributes check in `src/sa.m` still passes. Removing the lookup instead would
   make yabai reject its own payload with *"doesn't support this macOS version"*.

2. **`src/osax/common.h`** — bumps `OSAX_VERSION` from `2.1.29` to `2.1.30`.
   `scripting_addition_check()` compares the installed bundle's `CFBundleVersion`
   against this string. Without the bump, an already-installed stock payload looks
   current and the patched one is never written to `/Library/ScriptingAdditions`.

## Firefox tab drag discovery

`firefox-window-discovery.patch` is a second local patch. Some Firefox tab
tear-offs omit the creation notification even though the new window becomes
accessible. After a Firefox left drag, yabai checks `AXWindows` immediately,
then at 50, 100, 150 and 200 milliseconds and feeds unregistered references into its normal
`WINDOW_CREATED` handler. Existing rules, floating decisions and creation
signals still apply; already tracked windows are left alone.

`~/.config/yabai/patch-yabai.sh` preserves and reapplies the local patches on rebuild.
It refuses an ad-hoc signing fallback so the stable Accessibility identity is
preserved. Use this script for installation.

The regression check is:

```sh
cd ~/src/yabai-patched
xcrun clang -Wall -Wextra -Wno-unused-function tests/firefox-window-discovery.m \
    -framework Foundation -o /tmp/firefox-window-discovery-test
/tmp/firefox-window-discovery-test
```

This checks missed creation notifications, duplicate suppression, closed apps,
unavailable AX window lists and bounded drag retries. A live Firefox tab drag
is still required to verify macOS/Firefox behavior.

The pre-fix animation-patched binary is backed up at
`backup/yabai-7.1.25-before-firefox-discovery`.

## Upgrading yabai

A `brew upgrade` replaces the binary with the stock one. Floating-above keeps working,
but the Space animation dies again. Re-apply after every upgrade:

```sh
~/.config/yabai/patch-yabai.sh
~/.config/yabai/patch-yabai.sh --check
```

Run installation in a real terminal so `sudo` can request your password. The
script rebuilds all local patches, signs with `yabai-local-signing`, updates the
sudoers hash and restarts the service. Do not substitute ad-hoc signing: the
stable certificate preserves the Accessibility identity across rebuilds.

## Verifying the patch is live

```sh
strings -a /opt/homebrew/bin/yabai | grep "animation-time patch SKIPPED"   # patch present
log show --last 5m --predicate 'process == "Dock"' | grep yabai-sa         # payload log
yabai -m query --windows | jq '.[] | {app, "is-floating", "sub-layer"}'    # floating => above
```

A floating window should report `sub-layer: "above"`, a tiled one `"normal"`, and
cmd-1..9 should still slide.

## Reverting

```sh
CELLAR=/opt/homebrew/Cellar/yabai/7.1.25/bin/yabai
chmod u+w "$CELLAR" && cp ~/src/yabai-patched/backup/yabai-7.1.25-stock "$CELLAR" && chmod 555 "$CELLAR"
sudo rm -rf /Library/ScriptingAdditions/yabai.osax    # force a clean payload reinstall
```

A deliberate stock rollback also requires re-pinning its sudoers hash and checking
permissions. It removes the local animation, Firefox and focus fixes.

## Hover focus menu recovery

`menu-focus-recovery.patch` keeps the configured focus mode independent of menu
suppression. Menu notifications carry retained AX menu identities; duplicate opens
and unmatched closes cannot corrupt a nesting counter. During pointer movement,
stale menus are removed when their owning process exits, their AX element is invalid, or their backing window
is no longer ordered in. Checks run at most every 250 ms. AX or SkyLight query
failures keep suppression active rather than stealing focus from an open menu.
Menus without a discoverable backing window recover through close notifications
or AX invalidation; there is deliberately no unconditional timeout.

`patch-yabai.sh` reapplies this patch after the animation and Firefox patches.
Test with `xcrun clang tests/menu-focus-recovery.m -framework ApplicationServices
-framework Foundation -o /tmp/yabai-menu-focus-test && /tmp/yabai-menu-focus-test`.
Live native-menu dismissal and owner-exit recovery passed; see
`tests/live-popup/RESULTS.md` and its recorded observations.

## Hover focus around app popups

`popup-focus-guard.patch` covers app-owned popup windows that do not send AX menu
notifications. While a small, nonstandard or raised window owned by the active
app is visible, yabai holds focus on the current window. This includes the popup
itself being focused; excluding that window was the cause of the Zoom failure.
Once the popup closes, ordinary `focus_follows_mouse autofocus` resumes. Zoom's
in-meeting More popup was observed as a 248 × 330 point `AXGrid` at window layer
99, so the guard covers the gap between its invoking control and the popup.

Test with `xcrun clang tests/popup-focus-guard.m -framework ApplicationServices
-framework Foundation -o /tmp/yabai-popup-focus-test &&
/tmp/yabai-popup-focus-test`. Actual Zoom More, custom Cocoa popup and native
menu tests passed with autofocus enabled, including normal hover focus after
dismissal. See `tests/live-popup/RESULTS.md` for the tested build and observations.
