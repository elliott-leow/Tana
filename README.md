# Tana

A native macOS window manager built around one horizontal strip: a hard wall on the left and open space to the right. Ordinary windows tile automatically in columns; dragging onto the upper or lower half of another window creates a vertical stack. Floating windows occupy a separate layer above the strip.

This is a new fork of the locally patched yabai 7.1.25 engine. The strip renderer, gesture handling, controls, menu, persistence, and recovery workflow are implemented in this repository. **It is under verification, not a production-certified release.** See [verification](docs/VERIFICATION.md) for the exact checks completed and outstanding.

## Trackpad controls

| Action | Control |
| --- | --- |
| Move along the strip | Three-finger horizontal swipe |
| See every window at once | Three-finger swipe up; click a window to jump to it, or swipe down to cancel |
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
| Focus previous / next tile | Option + Command + Left / Right |
| Move the focused tile left / right | Shift + Option + Command + Left / Right |
| Return to the left wall | Option + Command + 0 |

The menu-bar `↔` control lists the commands. Normal two-finger scrolling, pinch gestures, and unassigned shortcuts pass through. The vertical three-finger gesture opens a graphical overview of the strip: the actual live windows lift into an evenly spaced grid, retain their proportions and left-to-right order, highlight on hover, and animate back around the window you choose. There are no captions or text overlays. The overview uses native WindowServer transforms, with no screenshots, cover, or replacement wallpaper. JankyBorders are hidden during selection and restored afterward. The listed shortcuts override their usual app/system actions; Command + Space replaces Spotlight and Command + Q closes a window instead of quitting its app. Option + Command + F and Option + Command + Space remain aliases. Horizontal Dock swipes follow the finger during contact and coast through a cubic Bézier curve after release. Set macOS **Swipe between full-screen applications** to three fingers; the native horizontal gesture stream follows that system setting.


Tiles reserve 14 points below the macOS menu area to clear the current top bar, and leave 12 points at both sides and above the bottom edge when filling the viewport. Full width respects those margins and the menu bar and Dock. It does not create a fullscreen Space. Centering at the first window obeys the left wall. Windows remain live during movement; the renderer does not replace them with screenshots. A dragged tile follows the pointer until release. A rounded placement preview animates with the same cubic Bézier curve as the final layout. Explicit app activation takes priority over hover focus until the transition settles and the pointer moves again.

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

Commands also include `left`, `right`, `center`, `pause`, `reflow`, and `place <source-id> <target-id> above|below|left|right`. `status` reports current order, columns, row geometry, widths, viewport offset, backend health, autofocus, render timing, and movement failures. `status` also exposes `resize_operations` to detect unintended resizing during a pan. Renderer timings measure the manager's work; they do not prove compositor frame delivery or subjective smoothness.

One ordinary macOS Space is pinned as the strip. Existing ordinary windows are consolidated there; unused macOS Spaces are retained for recovery. Native fullscreen remains an OS-owned temporary mode. Tana provides no desktop-switching commands in its own interface.

Layout order, column membership, row weights, widths, floating state, and offset are stored locally in `~/Library/Application Support/Tana/layout.json`, without window titles. Window identity is restricted to the same boot and matching process ID. The handoff snapshot is `recovery.json` in the same directory. Both use owner-only permissions. Existing HorizontalWM installations continue using their original state directory and signed bundle identity, so saved layouts, recovery records, and permissions survive the rename. No telemetry or network service is used.

## Animation and performance

New tiles, rearrangement, stacking, fill/restore, floating transitions, close requests, placement previews, and overview selection use animated transitions. Live gestures retain direct finger tracking. Interrupted transitions continue from the last displayed geometry. Native macOS minimize/fullscreen and application-owned dialogs keep their own behavior. Emergency shutdown and recovery restore geometry immediately.

Run `make test` for sanitizer and recovery checks, and `make bench` for reproducible CPU comparisons. See [performance evidence](docs/PERFORMANCE.md) for measured results and their limits.

## Source

- `src/horizontal.m`: native strip runtime, gesture input, menu, persistence, shutdown
- `src/strip_layout.m`, `src/strip_renderer.m`: dynamic layout, frame submission, delayed notification handling
- `src/window_transitions.m`: floating-window and close animations
- `src/strip_geometry.h`: portable geometry and cubic Bézier evaluation
- `vendor/yabai`: window discovery, Accessibility lifecycle, WindowServer helper protocol
- `scripts/session.py`: journaled handoff and recovery
- `tests`: geometry, session recovery, and native integration fixtures

The vendored foundation is [yabai](https://github.com/asmvik/yabai), upstream commit `02de172f8706c3e2eaa679478897d7346e82b564`, plus the existing local animation, Firefox discovery, menu recovery, and popup focus patches. Its MIT license and copyright notices are retained in `vendor/yabai/LICENSE.txt`. Native Dock gesture fields were checked against [iss](https://github.com/joshuarli/iss); Tana uses them for continuous strip navigation, not Space switching.
