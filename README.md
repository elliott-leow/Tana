# Tana

A native macOS window manager built around one horizontal strip: a hard wall on the left, and a single screen of empty desktop past the last window on the right. Ordinary windows tile automatically in columns; dragging onto the upper or lower half of another window creates a vertical stack. Floating windows occupy a separate layer above the strip.

*Tana* (棚) is Japanese for "shelf". That is the whole idea: your windows sit side by side on one long shelf, each in its own place, and you slide along it to the one you want instead of digging through a pile. Stacked windows are things placed on top of one another on the same stretch of shelf, and the shelf has two ends.

This is a new fork of the locally patched yabai 7.1.25 engine. The strip renderer, gesture handling, controls, menu, persistence, and recovery workflow are implemented in this repository. **It is under verification, not a production-certified release.** See [verification](docs/VERIFICATION.md) for the exact checks completed and outstanding.

## Trackpad controls

| Action | Control |
| --- | --- |
| Move along the strip | Three-finger horizontal swipe |
| See every window at once | Three-finger swipe up; click a window to jump to it, drag one to rearrange the strip, or swipe down to cancel |
| Resize the focused tile | Hold Option and scroll with two fingers; horizontal movement adjusts width, vertical scrolling also works |
| Resize a floating window | Hold Option and scroll with two fingers; each axis adjusts its corresponding dimension |
| Stack or rearrange tiles | Drag a title bar, or hold Option and drag; drop on the upper/lower half to stack, or a side edge to make a column |
| Move a floating window | Hold Option and drag |
| Navigate with two fingers | Hold Option + Shift and scroll |
| Focus a window | Move the pointer over it; autofocus is on by default |
| Fill the usable screen / restore | Command + Shift + Return |
| Center the focused window | Option + Command + C |
| Float / tile the focused window | Command + Space |
| Close the focused window | Command + Q; unsaved-document prompts are preserved |
| Open a terminal | Command + Return |
| Open Firefox | Command + Shift + W |
| Focus the column to the left / right, centred | Option + Command + Left / Right |
| Swap the focused column with its left / right neighbour | Shift + Option + Command + Left / Right |
| Send the focused column to the start / end of the strip | Shift + Option + Command + , / . |
| Return to the left wall | Option + Command + 0 |

## Workflow controls

The existing shortcuts remain the defaults. Every command is also in the command palette (`Control + Option + P`): a centred, fuzzy-searched list showing each command's current shortcut.

| Action | Default control |
| --- | --- |
| Cycle column width through ⅓, ½, ⅔, full | Option + Command + R |
| Fit current column and its next neighbor | Option + Command + = |
| Return to the previous explicitly focused window | Option + Command + Tab |
| Undo the last arrangement | Option + Command + Z |
| Pull next window into current stack | Option + Command + ] |
| Extract focused row into its own column | Option + Command + [ |
| Focus row or tab above / below | Option + Command + Up / Down |
| Toggle a column between stacked and tabbed | Option + Command + T |
| Mark / unmark focused window as a utility | Control + Option + Shift + Space |
| Summon / dismiss a marked utility | Control + Option + Space |
| Open or close overview from keyboard | Option + Command + O, or Control + Up (Control + Down closes it) |
| Search overview | Type an app name or window title |
| Select in overview | Arrow keys (they follow the grid: Down goes down a row), then Return |
| Rearrange from the overview | Drag a card (the others make room), or Shift + Left / Right |
| Clear overview search / cancel overview | Escape |
| Cancel a window drag | Escape |

Utility windows float above the strip and minimize individually when dismissed. Tab indicators can be clicked; hidden tabs remain live offscreen. The overview keeps members of a column together while packing columns into a balanced grid. It has no permanent captions; a search pill appears only while typing. Overview search uses window titles transiently and does not add them to saved layouts.

Native edge resizing has a dedicated interaction path. The application controls the dragged window during contact; neighbors reflow directly, a left-edge drag adjusts the viewport to preserve the opposite edge, and an internal horizontal stack divider adjusts the two neighboring row weights. The outer top/bottom edges return to the strip's available height on release. Drag placement distinguishes a new-column insertion line from a stack region, stabilizes boundary selection, opens space between neighbors, and scrolls near screen edges.

Autofocus defaults to requiring fresh pointer movement after scrolling, so a stationary pointer does not select an unrelated window that passes underneath it. Explicit focus history excludes hover changes. Arrangement undo is separate from application Cmd-Z and skips closed or replaced windows.

## Motion and navigation model

- **Springs everywhere.** Tiles, floating windows, the camera, the overview and the drop preview are driven by critically damped springs. Retargeting keeps the velocity a window already has, so chained commands bend its path instead of stopping and restarting it. `animations.windows.bounce` adds overshoot to tile positions (never to sizes).
- **A bounded strip.** The left wall is hard. The right end is one viewport past the last window, so scrolling all the way right shows an empty desktop and stops. Both ends resist a held gesture and bounce off a fling.
- **Columns gravitate to the centre.** When a three-finger swipe is released, the column nearest the projected resting point is centred. While fingers are down, columns lean weakly toward the centre without ever moving against the finger. A two-finger pan (which has no release event) settles the same way once it has been quiet for 90 ms. `snap` selects `center`, `column` (flush edges) or `none`.
- **Keyboard focus is immediate.** Option + Command + Left / Right move a navigation cursor: the camera and border follow at once and the real focus is applied when the keys rest, so quick presses never queue behind window activation.
- **New windows open where you are looking.** A new tile is inserted at the column boundary nearest the centre of the screen and its neighbours slide apart; it fades and grows into place. `newWindowPlacement` selects `center-gap`, `beside-focused` or `end`; an app rule with `openBesideCurrent` overrides it.
- **Closing converges.** When a column closes, the camera moves half the freed width, so the windows on both sides move in together. A column closed off-screen to the left or right leaves what is on screen where it was.
- **Dragging is stable.** Neighbours stay put until the drop; the preview shows the landing place. Holding a dragged window against a screen edge scrolls the strip with increasing speed.
- **Tabbed columns have a tab bar** with each window's icon and title; click a tab to switch.

## Configuration

Settings and shortcut overrides live in `~/Library/Application Support/Tana/config.json`. **Saving the file applies it**; there is no reload step (`hotReload: false` turns this off, and **Reload config file** / `build/tana -m strip reload-config` still work). A short on-screen message confirms the reload or names the first problem. Invalid JSON leaves the prior configuration active. An unreadable shortcut keeps that action's default binding and is reported, as is a duplicate binding. `build/tana -m strip config-status` lists every problem found.

```json
{
  "settings": {
    "mod": "alt+cmd",
    "motionStrength": 1,
    "autofocus": "pointer-movement",
    "showStripMap": true,
    "stripWidths": [0.333333, 0.5, 0.666667, 1],
    "snap": "center",
    "focusAfterScroll": "pointer",
    "snapThreshold": 0.15,
    "snapMagnet": 0.1,
    "swipeGain": 1,
    "newWindowPlacement": "center-gap",
    "inactiveOpacity": 1,
    "gaps": { "inner": 12, "top": 14, "bottom": 12, "left": 12, "right": 12 },
    "border": { "enabled": true, "width": 2, "radius": 12, "active": "#66b8ff", "activeEnd": "#b48cff", "inactive": "#ffffff24" },
    "animations": { "windows": { "duration": 0.36, "bounce": 0 }, "scroll": { "speed": 22 }, "overview": { "duration": 0.34 }, "open": true, "close": true },
    "overview": { "dim": 0.38 },
    "commands": { "terminal": "open -na Ghostty", "browser": "open -a Firefox" }
  },
  "shortcuts": {
    "preset-width": "mod+r",
    "utility": "ctrl+alt+space"
  },
  "exec": {
    "mod+shift+f": "open -a Finder"
  },
  "appRules": {
    "com.apple.Calculator": { "floating": true },
    "com.apple.Notes": { "width": 0.5, "openBesideCurrent": true }
  }
}
```

Every key is optional. Shortcut names match the CLI action names; omitted actions retain defaults, and `false` disables an action's default shortcut. Bindings accept `mod` (the modifiers named by `settings.mod`), `cmd`, `alt`, `ctrl`, `shift`, named keys, or `keycode:0` through `keycode:127`. `exec` maps a binding to a shell command. The legacy `float-alt`, `full-alt`, `full-keypad`, and `terminal-keypad` aliases can be overridden independently. Width values up to 1 are viewport fractions; larger values are points. App rules apply to newly discovered windows. The menu can remember an app's current width or toggle its floating/adjacent-opening preferences.

- **How readily a swipe changes window** is `snapThreshold`: the share of the way to the next column a swipe must travel (including where its release speed was taking it) to commit to that column. Lower needs less movement (0.05 is hair-trigger, 0.4 is stiff). `snapMagnet` (0 to 0.6) is how strongly columns lean toward the centre while your fingers are still down; 0 turns that off. `swipeGain` scales how far the strip moves per unit of finger travel. `snap` chooses `center`, `column` or `none`.
- `focusAfterScroll` decides what takes focus when you move the strip without moving the pointer: `pointer` (the default) focuses the window that ends up under the pointer, chosen the moment your fingers lift rather than when the strip stops; `center` focuses the window brought to the middle of the screen; `none` leaves focus alone. A floating window under the pointer keeps focus. Moving the pointer over a window still focuses it, as set by `autofocus`.
- `border.enabled` defaults to automatic: Tana draws its own focus border (a gradient from `active` to `activeEnd`, with a quiet `inactive` outline on other tiles) unless an external border tool such as JankyBorders is running. Set it to `true` or `false` to decide explicitly. Colours are `#rgb`, `#rgba`, `#rrggbb` or `#rrggbbaa`.
- `inactiveOpacity` below 1 fades unfocused windows; 1 (the default) leaves opacity alone.
- `animations.windows.duration` is the time by which a tile has settled; `motionStrength` scales all motion and macOS Reduce Motion turns it off.
- `overview.dim` is the strength of the blurred scrim behind the overview; 0 removes it.

Swipe release uses velocity-continuous damped motion; direct gestures remain attached to the finger. A transient strip map shows every column, the focused one, and the viewport. Set `showStripMap` to false to hide the map, or `autofocus` to `after-scroll` to restore the prior pointer-under-window behavior.

The menu-bar control lists the commands in sections with their shortcuts. Normal two-finger scrolling, pinch gestures, and unassigned shortcuts pass through. Control + Up and Control + Down, the Mission Control keys, open and close the same overview: Mission Control itself lays out every window of the strip as if it were on screen, which shows nothing useful. Rebind `overview-mission` and `overview-close` under `shortcuts` to give the keys back to macOS. The vertical three-finger gesture opens a graphical overview of the strip: the actual live windows lift into an evenly spaced grid over a dimmed, blurred desktop, retain their proportions and left-to-right order, and animate back around the window you choose. Every card carries a pill with its application icon and window title for as long as the overview is open, and the chosen card lifts slightly; typing searches app names and titles and fades the cards that do not match. Drag a card and the others make room for it as it passes over them, so what you see is where the window will land; release to leave it there, or press Escape to put everything back. Shift + Left / Right moves the selected window from the keyboard. A click in the gap beside a card counts as that card. A one-line reminder of these controls fades after a few seconds. The overview uses native WindowServer transforms, with no screenshots or covers of the windows. External JankyBorders are hidden during selection and restored afterward. So are the small windows an application attaches to its own (a browser's purple screen-sharing pill, for example), which cannot be scaled with their card. The listed shortcuts override their usual app/system actions; Command + Space replaces Spotlight and Command + Q closes a window instead of quitting its app (rebind them under `shortcuts` if you prefer). Option + Command + F and Option + Command + Space remain aliases. Set macOS **Swipe between full-screen applications** to three fingers; the native horizontal gesture stream follows that system setting.

Tiles reserve the configured gaps (by default 14 points below the macOS menu area and 12 at the sides and bottom). Full width respects those margins and the menu bar and Dock. It does not create a fullscreen Space. Windows remain live during movement; the renderer does not replace them with screenshots. A floated window remembers where it floated and returns there the next time it is floated. Explicit app activation takes priority over hover focus until the transition settles and the pointer moves again.

## Build and run

Requires macOS 14 or later, Xcode command-line tools, Accessibility access, and a working yabai scripting addition. The scripting addition is used for unconstrained off-screen placement and floating-window levels. Tana does not disable SIP or alter security settings for you. The current implementation has been built on Apple Silicon macOS 27.2; other OS versions and multiple-display arrangements require validation.

```sh
make all test
scripts/package.sh
python3 scripts/session.py preflight
python3 scripts/session.py start
```

The bundled app is `build/Tana.app`. Set `TANA_SIGN_ID` to a stable local signing identity for the first signed build; the packaging script remembers it locally for subsequent builds. The session script snapshots the current setup, stops competing window utilities, starts the app, and rolls back a failed handoff. A standalone app permission probe prevents inherited terminal permissions from producing a false positive.

Return to the previous setup:

```sh
python3 scripts/session.py restore
```

See [installation and recovery](docs/INSTALL.md) for session handoff and optional login startup. Reboot, wake, and Dock-restart reliability remain under verification.

## CLI

```sh
build/tana -m strip status
build/tana -m strip full
build/tana -m strip float
build/tana -m strip width 960
build/tana -m strip scroll 1800
build/tana -m strip move-right
build/tana -m strip home
build/tana -m strip quit
```

Commands also include `move-first`, `move-last`, `swap-left`, `swap-right`, `preset-width`, `fit-two`, `previous`, `undo`, `consume`, `expel`, `up`, `down`, `utility-mark`, `utility`, `tabs`, `commands`, `reload-config`, `left`, `right`, `center`, `pause`, `reflow`, and `place <source-id> <target-id> above|below|left|right`. `status` reports current order, columns, row geometry, widths, viewport offset, backend health, autofocus, render timing, and movement failures. `status` also exposes `resize_operations` to detect unintended resizing during a pan. Renderer timings measure the manager's work; they do not prove compositor frame delivery or subjective smoothness.

One ordinary macOS Space is pinned as the strip. Existing ordinary windows are consolidated there; unused macOS Spaces are retained for recovery. Native fullscreen remains an OS-owned temporary mode. Tana provides no desktop-switching commands in its own interface.

Layout order, column membership, row weights, widths, floating state, tab selection, marked utilities, and offset are stored locally in `~/Library/Application Support/Tana/layout.json`, without window titles. Window identity is restricted to the same boot and matching process ID. The handoff snapshot is `recovery.json` in the same directory. Both use owner-only permissions. Existing HorizontalWM installations continue using their original state directory and signed bundle identity, so saved layouts, recovery records, and permissions survive the rename. No telemetry or network service is used.

## Animation and performance

New tiles, rearrangement, stacking, fill/restore, floating transitions, close requests, tab switches, placement previews, and overview selection are all animated. Opening fades and grows a window into its slot; closing fades and shrinks it while its neighbours converge. Live gestures retain direct finger tracking. Interrupted transitions continue from the last displayed geometry at their current velocity. Size changes are still applied through Accessibility each frame: the installed scripting addition only offers a uniform scale, so a transform-only resize would need a new helper opcode and a reinstall of the addition. Native macOS minimize/fullscreen and application-owned dialogs keep their own behavior. Emergency shutdown and recovery restore geometry immediately.

`build/tana -m strip profile` reports the worst time spent in each part of a frame, the main-thread cost of overlay refreshes, and how many resize requests were sent or coalesced; `profile-reset` clears the counters before a measurement.

Run `make test` for sanitizer and recovery checks, and `make bench` for reproducible CPU comparisons. See [performance evidence](docs/PERFORMANCE.md) for measured results and their limits.

## Source

- `src/horizontal.m`: native strip runtime, gesture input, menu, persistence, shutdown
- `src/strip_layout.m`, `src/strip_renderer.m`: dynamic layout, frame submission, delayed notification handling
- `src/window_transitions.m`: floating-window, open, and close animations
- `src/strip_feedback.m`: borders, tab bar, strip map
- `src/strip_ax_async.m`: background, coalesced Accessibility requests (resize, close, titles) so no animation frame waits on an application
- `src/strip_hud.m`: on-screen messages and the command palette
- `src/strip_config_runtime.m`: applies settings, hot reload, new-window placement
- `src/strip_geometry.h`: portable geometry and cubic Bézier evaluation
- `vendor/yabai`: window discovery, Accessibility lifecycle, WindowServer helper protocol
- `scripts/session.py`: journaled handoff and recovery
- `tests`: geometry, session recovery, and native integration fixtures

The vendored foundation is [yabai](https://github.com/asmvik/yabai), upstream commit `02de172f8706c3e2eaa679478897d7346e82b564`, plus the existing local animation, Firefox discovery, menu recovery, and popup focus patches. Its MIT license and copyright notices are retained in `vendor/yabai/LICENSE.txt`. Native Dock gesture fields were checked against [iss](https://github.com/joshuarli/iss); Tana uses them for continuous strip navigation, not Space switching.
