# Verification record

This file records evidence, not a release claim. A production-ready designation requires the remaining live and physical checks to pass.

## Completed

- Native arm64 release build on macOS 27.2 with Clang, warnings enabled.
- Geometry tests under AddressSanitizer and UndefinedBehaviorSanitizer: Bezier x inversion, endpoint/monotonicity checks, hard-left viewport, variable widths, centering, resizing, invalid values, randomized reorder invariants.
- Ten session recovery tests: private atomic state, concurrent operation rejection, permission and locked-session preflight failure before mutation, failed-handoff rollback, unresolved-snapshot protection, PID-qualified restoration, layer and focus restoration, already-focused Space handling, and delayed startup readiness.
- Helper transport tests under AddressSanitizer and UndefinedBehaviorSanitizer: complete writes, partial server reads, legacy EOF completion, optional acknowledgment, bounded timeout, missing socket, descriptor cleanup, fragmented handshake replies, and malformed/truncated handshake rejection.
- The read-only `--check-backend` probe passed against the installed helper. It advertises zero optional Dock capabilities; direct WindowServer movement uses separate entry points. Space recovery retains the engine's gesture fallback when Dock focus support is absent. Direct movement was subsequently verified beyond the display edge (x=4000) against live WindowServer bounds using disposable fixture windows.
- Signed local app bundle, strict signature validation.
- Existing patched yabai health check passed before handoff.
- Initial standalone app launch was blocked by missing Accessibility permission. The session rolled back; original yabai BSP, autofocus, skhd, and Loop were observed running again.
- Discovered that a child launched from a trusted development terminal can report Accessibility=true while the standalone app reports false. Session preflight now launches the app's own permission probe through Launch Services.
- Corrected restore was exercised against the original setup. Surviving accessible windows restored without command errors; two closed windows and one window without an Accessibility reference could not be restored. yabai BSP/autofocus, skhd, and Loop were confirmed running. Original `.yabairc` and `.skhdrc` hashes match their pre-handoff values.
- Added delayed-notification suppression, reconciliation of application-enforced widths, and serialized strip startup. These changes compile but still require live acceptance.

- User-authorized live handoff succeeded. Tana was observed active with the helper, while the original yabai/skhd/Loop utilities were stopped.
- WindowServer-level fixture checks confirmed tiled sublevel -20 and floating sublevel 3. The old AX query cache could report clamped coordinates even when actual WindowServer bounds were correct; queries now report actual bounds.
- Desktop screenshots verified top clearance, bottom clearance, and the left border after setting padding to top 14, bottom 8, left 8.
- Column model tests under ASan/UBSan cover weighted vertical rows, side-to-stack drops, stack-to-column drops, anchor detachment, same-column ordering, identity preservation, and invalid input.
- Added drag placement previews, new keyboard bindings, neighboring-window close focus, activation priority, and unlock rediscovery. Build and model tests pass; initial live checks were delayed when the Mac locked during the update; subsequent checks below were run after the user unlocked it.

- Live column placement passed: two disposable Cocoa windows occupied x=8, width=500, y=51/584, height=521 with the expected 12-point row gap. The rounded placement preview was visually checked against the final lower-row rectangle.
- Floating/full/restore/retile passed with fresh-process WindowServer measurements: floating sublevel 3, tiled sublevel -20, fill frame (8,51,1702,1053), and exact floating-frame restoration.
- Closed retained Cocoa windows are detected through WindowServer order reconciliation, because an AX destruction event is not guaranteed. Both manager-issued close and a normal close-button action passed: removed from strip, expected neighbor focused, neighbor x delta=0. Evidence: `build/close-focus-check.json`, `build/close-button-check.json`.
- Explicit System Settings activation was observed focused and visible after the focus change.
- Two-way viewport pan: 30 measured renderer frames, zero frames over 8 ms, zero movement failures. This excludes initial tiling/resizing and does not measure compositor delivery. Initial tiling can still take hundreds of milliseconds due to app Accessibility calls.
- Global event tap reports enabled. Computer-use key delivery bypasses the HID event tap. The user subsequently confirmed that physical Command + Shift + Return fill/restore, Command + Space float/tile, and title-bar drag with placement preview all work.
- Layer reads in the long-running manager may be cached by WindowServer. `tests/window_metrics.m` measures bounds and sublevels from a fresh process; verification uses this instead of the manager's cached layer field.
- Fill-margin correction: fresh WindowServer measurements on the 1710×1112 display gave frame (12,51,1686,1049), leaving exactly 12 points at the left, right, and bottom. This supersedes the earlier fill-frame measurement. Evidence: `build/fill-margin-check.json`.
- Settled position reconciliation now detects app-imposed movement after animations, without resizing the window again. `tests/live_position_check.py` passed six viewport snaps with zero position errors or intersecting tiled rectangles. A fixture-only 44-point displacement was corrected in 0.182 seconds as observed by fresh-process sampling. Evidence: `build/position-check.json`. This tests settled geometry, not every compositor frame during animation.

- Spring motion, bounded strip, centre snapping, centre-gap placement, converge-on-close, navigation cursor, column moves, drag stabilisation, built-in borders, tab bar, HUD, command palette, hot reload, and overview scrim/labels/search dimming/drag-to-reorder were added. Evidence so far is build and model level only: the release build is warning-free in `src/`, and `make test` passes, including new sanitizer tests for the damped spring (start, velocity retention, bounded overshoot, settle), rubber band, edge and centre snapping, the magnet's monotonicity, nearest-gap selection, the close camera shift for holes left of / inside / right of the viewport, the open pop and close shrink state machines (including a refused close returning to full size), spatial overview navigation, and the extended configuration (mod prefix, exec bindings, unreadable-binding fallback, colour parsing). **None of this has been exercised in a live session yet.**


- Responsiveness pass. Accessibility resize, close, focus/raise and title requests moved off the animation thread (resizes coalesced per window); the resize-notification handler no longer queries the application while the strip owns the geometry; pointer events are coalesced to one queued move and one queued drag; the usable-screen rectangle is cached; unchanged overlay snapshots are no longer sent to the main thread, which also carries the input tap; a keyboard close vacates the window's place immediately. Live measurement on the user's session with `profile`: a fill followed by a restore produced 187 frames, 1 over 8 ms (worst 12.1 ms), 38 background resize requests (worst 5.7 ms each, none blocking a frame), overlay refresh worst 0.5 ms, zero movement failures. Dragging and closing were not measured: they need physical input.

- Smoothness pass. Animations are sampled for the display link's presentation time rather than the moment a tick happens to run; everything a frame changes (moves, re-scales, preview) is presented as one compositor update, with scaled windows reset before the frame moves them; the open/close scale steps in whole points on both margins; a new window stays hidden until its application has taken the slot's size; the close fade is a single helper-side fade; windows off screen before and after a frame are not moved while the strip travels. Swipe snapping became directional with a configurable threshold. The overview mover now makes room live under a carried card. Model tests cover each of these. Live measurement after this pass (fill then restore): 140 frames, renderer worst 0.6 ms (was 12 to 14 ms when it waited on the application), 29 background resizes with 6 coalesced while one application took up to 32 ms to answer, zero movement failures. Seven frames exceeded 8 ms, worst 9.4 ms, all spent waiting in the compositor's end-of-batch call rather than computing. Whether close and open now look jitter-free was not observed: it needs eyes on the screen.

- Focus follows the strip. With `focusAfterScroll: pointer` (the default), moving the camera focuses the window that will be under the still pointer, chosen when the camera is given its destination. Live check on the user's session: pointer held at (745, 693); `scroll 0` moved focus from Firefox (window 4073) to Ghostty (window 66), the window then under the pointer, and the camera stayed at 0 rather than being pulled back to the previously focused window; scrolling back restored focus to 4073. The same call is made on swipe release and two-finger pan settle, which were not exercised because they need physical input. The process-table scan for an external border tool (about 20 ms) was moved off the animation thread.

## Pending live acceptance

- Everything in the paragraph above: on-screen smoothness of spring retargeting and drag, the open/close scale on real applications (it relies on the installed helper's toggle-style scale opcode while the window is also being moved), border and tab-bar tracking latency, the palette receiving keystrokes as a non-activating panel, hot reload, right-end rubber band, and overview drag-to-reorder.

- Default tile creation, closure, minimize/restore, hidden/reopened applications, and dialogs.
- Long-session horizontal placement and involuntary Space-change behavior; direct off-screen placement has passed a fixture check.
- Three-finger navigation, direction, interrupted gestures, fast reversals, momentum, and hard-left behavior on physical hardware.
- Autofocus, popup/menu protection, focus after gestures, and external Cmd-Tab activation.
- Centering, Option-scroll resizing, and Option-drag insertion; physical full-width toggle and ordinary title-bar placement have passed.
- Visual floating-above stacking; WindowServer sublevels have passed the fixture check.
- Smoothness at the actual display refresh rate, including unresponsive applications and many windows.
- Graceful quit, crash recovery, relaunch persistence, wake, Dock restart, and display changes.
- A complete active-strip restore; the blocked-launch rollback and configuration hashes have been checked.

## Boundaries

The native manager depends on the existing privileged yabai helper for off-screen movement and layering. Missing helper connectivity is reported and rendering is suspended rather than falling back to on-screen-constrained AX movement. Reconnection is retried, but automatic helper loading after a Dock restart is not yet implemented.

Existing macOS Spaces are retained as recovery targets; the interface pins one active strip. Native fullscreen and multiple displays need explicit acceptance testing. Login startup is configured and its launchd execution passed; reboot persistence has not been verified.

## Native graphical overview (2026-10-12)

- Replaced the earlier capture-based implementation completely. Actual windows use native WindowServer transforms, keeping their content live. There is no captured cover, wallpaper layer, ScreenCaptureKit dependency, or visible caption text.
- Offscreen windows enter from below; visible windows begin at their current locations. Gesture progress controls the lifted path, and release finishes with a 280 ms easing animation driven by the display clock.
- The transparent selection surface originally let clicks pass through. Pointer events now route through the existing global input tap to the selector before app/drag handling. The user confirmed on the installed build: selection works and borders are gone.
- JankyBorders window opacity is saved, set to zero for the overview, and restored on selection, cancellation, suspension, and normal shutdown. Restoration checks the original process owner. The borders process and its configuration are preserved.
- `make all test` passed: four ASan/UBSan C suites and ten Python session checks. Strict signing validation passed on the installed bundle.
- `tests/live_overview_check.py` passed with 11 real windows and 11 border windows: native transforms changed at quarter/full progress, all final window rectangles were separate, every border had zero opacity while open, and cancellation restored original positions, native transforms, and border opacity. Early cancellation also passed. Evidence: `build/overview-check.json`.
- The measured cancellation used 19 renderer frames, zero above 8.34 ms, maximum 2.726 ms. These timings measure command submission, not physical compositor delivery or perceived smoothness.

## Login startup (2026-10-12)

- Enabled the user-requested `dev.horizontalwm.login` LaunchAgent and exercised it successfully; launchd recorded exit code 0 and the manager reported ready with backend connectivity.
- Confirmed yabai/skhd launch agents disabled, both processes absent, and Loop's Launch at login toggled off before quitting Loop. Borders and SketchyBar were retained.
- Reboot/login persistence and helper recovery after a later Dock restart remain unverified.

## Tana rename, animation, and performance pass (2026-10-12)

- Renamed the app, command-line executable, packaging, and documentation to Tana. Kept the signed bundle identifier and legacy state fallback; the standalone Tana permission probe reported Accessibility and Input Monitoring granted. The new signed app was launched successfully.
- Added display-clock float/fill/restore/retile transitions, animation from actual geometry for new tiles, close fades that preserve AX save prompts, preview fades, and animated overview highlights/border opacity. Existing animation durations, easing shape, grid geometry, and live-window overview rendering remain intact.
- Fresh-process fixture measurements captured five intermediate frames for each of float, floating fill, restore, and retile. Fill/restore returned to the exact original floating rectangle. Evidence: `build/animation-check.json` (local only). These are WindowServer geometry observations, not measured compositor delivery.
- The native overview regression passed with ten real windows: transforms, nonoverlapping grid, border opacity, normal cancellation, and early cancellation. A later viewport-snap check was interrupted by changing input/state and is not counted as passing evidence for this version.
- Fixed delayed notifications that could invalidate the size cache during a gesture, trigger AX resizing, and fight scrolling. Position correction retains the size cache, active gestures defer correction, pan movement is grouped into compositor updates, and reflow uses the offset belonging to the last submitted frame. The user physically tested the running correction and reported that scrolling was smooth.
- Added deterministic tests of the production layout/renderer for delayed notifications across 80 pan frames with zero resize calls, changing columns, resize reversals, new-window placement, settled drift recovery, and balanced compositor cleanup after helper failure. Floating reversal, direct-manipulation interruption, close refusal, and close cancellation also pass.
- Native build, five sanitizer suites, twelve Python recovery tests, helper handshake, and strict app signature checks passed. CPU benchmarks and review scope are recorded in `PERFORMANCE.md`.
- A screenshot inspection attempt was blocked by ScreenCaptureKit error -3811. The new hover-highlight appearance has not received screenshot-based visual verification; physical scrolling confirmation and WindowServer geometry checks are separate evidence.

## Workflow and native edge resizing (2026-10-12)

- Added column width presets, fit-two, explicit-focus history, arrangement undo, consume/expel and row focus, live tabbed columns with clickable indicators, summonable floating utilities, per-app rules, and a searchable command menu. Shortcut overrides use a JSON file, with no shortcut editor.
- Native edge resizing now owns the dragged window until mouse-up. The renderer does not resize it during contact; neighboring columns update directly, left-edge resizing tracks viewport offset, and internal stack dividers preserve the pair's combined height. Title-bar drags beginning near the top edge are distinguished using actual size/movement evidence.
- Added velocity-continuous critically damped viewport settling, stable drag targets, animated neighbor insertion, edge autoscroll, Escape cancellation, distinct column/stack previews, transient navigation map and boundary cue, focus crossfade, drag shadow, motion strength, and system Reduce Motion handling.
- Overview now supports app/title search, arrows, Return, and Escape-clear/cancel; grouped columns pack into a balanced grid. The native live-window implementation is retained.
- `make all test` passes: seven ASan/UBSan C/Objective-C suites, the config test, the native overview input test, and twelve Python recovery tests. New production-runtime tests cover native resize ownership, left-edge anchoring, row weights, move-only tab parking, workflow actions, utility focus restoration, undo, and PID-qualified workflow persistence.
- `tests/live_workflow_check.py` passed with disposable Cocoa windows: presets and undo, two 837-point columns plus their gap, stacking, tab parking and row selection, extraction, floating utility show/hide/focus restore, and previous-window toggle. Evidence: `build/workflow-check.json` (local).
- Its live edge probe observed 22 distinct widths during a right-edge drag (600 to 716 points) and 23 during a left-edge drag (716 to 793 points), with zero width reversals in either outward drag. These are injected native mouse drags and WindowServer observations, not a claim of physical trackpad verification or compositor frame rate.
- Live testing found that resizing while parked at an extreme negative coordinate can invalidate AppKit window bounds. Hidden tabs now park by movement only at a bounded horizontal offset, retain their actual size, and reconcile delayed app position constraints. Restoring a tab avoids animating across the desktop. Invalid WindowServer frames no longer produce invalid JSON in managed-window queries.
- Native overview regression passed with seven windows and eight border windows: nonoverlap, transforms, border hiding/restoration, cancellation and early cancellation. Maximum observed command-submission time in that check was 3.556 ms; this does not measure compositor delivery.
- `tests/live_config_check.py` passed: live reload, retention after invalid JSON, per-app width application to new fixture windows, remembering width, and same-boot restart preserving tabs and marked floating utilities. It restored the exact original config afterward. Evidence: `build/config-check.json` (local).
- Signed bundle validation passed; the updated Tana was launched successfully and reports version 0.2.0, ready, with its backend connected. Config is `~/Library/Application Support/Tana/config.json` with mode 0600. Legacy saved-layout discovery remains intact when the new config directory is created.
- Screenshot-based visual review remains blocked by ScreenCaptureKit error -3811. Physical trackpad reversals, physical native resizing across different apps, perceived animation quality, multiple displays, and reboot/wake/Dock-restart acceptance remain separate checks. The new hover/drag/map/tab styling is implemented but has not received fresh screenshot-based visual verification.

## Overview swipe freeze (2026-10-12)

- Reproduced a stuck overview in the previous running build by starting a vertical gesture during its close animation. The overview remained active after 600 ms because the new begin cleared `hwm_overview_animating` before the closing-state guard; this prevented transform cleanup and kept the global input overlay active.
- Closing now rejects further gesture phases before changing animation state. A live gesture keeps the renderer scheduled and cancels safely after 800 ms without further phase updates, so a missing terminal event cannot strand the overview. Late change/end events require a live gesture session and cannot restart it.
- Added `overview_closing`, `overview_animating`, `overview_gesture_active`, and `mission_control` to `strip input-status` for diagnosis. No stuck Mission Control state was observed during these checks.
- `make all test` passed. Signed bundle validation passed and the patched app is running.
- Extended `tests/gesture_probe.m` with vertical streams and individual phases. Build it with `xcrun clang -Wall -Wextra -Werror tests/gesture_probe.m -framework Cocoa -o build/gesture_probe`, then run `python3 tests/live_overview_gesture_check.py` with Tana active and the pointer idle.
- The live gesture regression passed: a new begin during close, five up/down cycles, reversal during opening, missing terminal events in both directions, cancellation in both directions, restoration of actual window geometry/transforms, and subsequent horizontal input moving actual windows. The original viewport was restored. Evidence: `build/overview-gesture-check.json`.
- The existing native overview/border restoration check also passed with seven windows and eight border windows. Physical trackpad reproduction remains a user acceptance check; injected native events do not establish physical trackpad behavior.
