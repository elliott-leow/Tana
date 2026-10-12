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

## Pending live acceptance

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
