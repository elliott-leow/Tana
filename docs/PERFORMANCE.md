# Performance and animation verification

The optimization constraint is unchanged behavior: keep the dynamic strip,
animations, live overview content, geometry, gestures, stacking, and recovery.
No frame-rate limit, shorter animation, static screenshot, or removal of visual
effects was used as a speedup.

## Measured CPU work

Run `make bench` on macOS with the Xcode command-line tools. The benchmark uses
an optimized build and reports the median of five runs. These measurements
compare CPU routines, not end-to-end latency or compositor frame delivery.

Measured on the development Mac on 2026-10-12:

| Workload | Reference | Optimized | Ratio |
| --- | ---: | ---: | ---: |
| 300,000 standard easing evaluations | 91.358 ms | 1.531 ms | 59.67× |
| 16 independent columns, repeated layouts | 5.943 ms | 2.752 ms | 2.16× |
| 64 independent columns, repeated layouts | 18.030 ms | 2.820 ms | 6.39× |
| 256 independent columns, repeated layouts | 74.001 ms | 3.183 ms | 23.25× |
| 1,024 independent columns, repeated layouts | 257.158 ms | 3.118 ms | 82.48× |

Layout workloads process approximately 200,000 items in total per run. The large
counts are scaling tests, not a claim about typical desktop window counts.
Small strips retain the simpler allocation-free layout. The indexed layout
includes allocation cost in the timing and falls back if allocation fails.

The fixed easing curve uses bounded Newton inversion instead of 56 bisection
steps. Its output matches the reference within 1e-12 in dense and randomized
checks. Arbitrary curves retain the general evaluator. Indexed layout matches
the scan implementation exactly across randomized columns, interleaved rows,
invalid weights, extreme dimensions, and invalid identities.

Small helper writes now attempt the nonblocking send before polling. The
transport regression verifies zero readiness polls on a writable socket and
bounded timeout under backpressure, alongside partial reads, EOF/ACK, fragmented
handshakes, and descriptor cleanup.

## Review passes

1. **Math and transport:** optimized fixed-curve inversion, indexed larger
   column layouts, and removed the redundant writable-socket readiness poll.
2. **Animation and repeated work:** added the missing interactive transitions;
   eliminated duplicate display-bound reads within layout/preview operations,
   redundant enhanced-UI guards around AX frame calls, and preview path/region
   allocation when only opacity is changing.
3. **Dynamic scrolling:** corrected movement-notification invalidation that
   turned pans into resizes; preserved each window's last submitted viewport
   offset when retargeting; grouped pan moves for compositor submission. The
   production renderer passes 80 simulated gesture frames with delayed
   notifications and zero AX resize calls. The user confirmed smooth physical
   scrolling on the installed correction.
4. **Final review:** checked rendering, retargeting, gestures, reconciliation,
   overview, transport, persistence, and rename compatibility. No further
   actionable speedup was found that had evidence of benefit while preserving
   the current behavior. This is a bounded review result, not a proof that the
   application cannot be optimized further.

## Evidence and remaining limits

`make test` includes the production layout, renderer, floating transitions, and
close behavior against deterministic OS stubs under ASan/UBSan. It covers dynamic
stack changes, late movement notifications, resize reversals, new windows,
helper failure, canceled transitions, and refused closes.

`tests/live_animation_check.py` observed five intermediate WindowServer frames
for each fixture float/fill/restore/retile transition and exact restoration.
`tests/live_overview_check.py` passed transform, grid, border, and cancellation
checks. Physical scrolling was confirmed by the user. Screenshot inspection of
the new overview highlight was blocked by a local ScreenCaptureKit error.

Accessibility sizing remains application-dependent and can stall the serialized
renderer; CPU microbenchmarks do not remove that platform constraint. The
manager releases compositor suppression before any AX sizing call. Performance
with unresponsive applications, multiple displays, wake, and Dock restart still
requires separate live acceptance testing.

## Frame pacing pass (2026-10-12)

The earlier passes measured how long a frame takes to compute. That number was
already small and did not explain a swipe that sometimes lagged, so this pass
measured pacing instead: when frames are drawn, what delays them, and how
evenly the strip advances. `strip pacing` reports tick latency, dropped frames
and the cost of every event-loop handler; `strip frame-log` returns the camera
position of recent frames next to the swipe reports that drove them.
`pacing-reset` clears both.

All figures are from the development Mac (60 Hz built-in display) with the
user's own windows, driven by synthetic three-finger swipes posted as Dock
gesture events with accurate timestamps. Physical swipes were not measured.

| Finding | Before | After |
| --- | --- | --- |
| Per-frame step of a steady held swipe, standard deviation over mean, reports every 11 ms | 0.33 | 0.10 |
| Same, reports every 13.5 ms | 0.34 | 0.10 |
| Housekeeping sweep on the frame thread during a swipe | 2 to 3 ms, ten times a second, up to 10 ms | does not run while frames are drawn |
| Housekeeping sweep with the desktop at rest | about 3% of one core | twice a second |
| Frame thread scheduling priority | 31 (default) | 46 (user-interactive) |
| Stall when focus follows a swipe | 8 to 16 ms | 5 to 9 ms |
| Overview opening, frames over 8 ms of about 310 | 40 to 58 | 1 to 11 |

What changed:

- **Held swipes are drawn where the fingers are at the frame.** Finger reports
  and display refreshes are not in step, so a frame followed one report, two,
  or none, and a steady swipe advanced 16, 48, 16, 48 points. Each frame now
  carries the strip on from a line fitted through the last 50 ms of reports,
  for at most 12 ms past the newest. Speeds are measured between the reports'
  own timestamps rather than the times this process got to them. The overview
  gesture is resampled the same way.
- **The frame thread runs at user-interactive priority** and the process opts
  out of App Nap.
- **Helper commands of a frame are handed over together and awaited once.**
  Eight sequential moves cost a median 0.82 ms against the live helper; the
  same eight pipelined cost 0.38 ms. An overview frame sends two per card.
- **The housekeeping sweep waits while frames are drawn**, runs at 10 Hz for a
  second afterwards (when a correction can be needed) and at 2 Hz at rest.
  WindowServer already reports ordering changes as they happen.
- **Blocking Accessibility round trips left the frame thread.** A window's
  title is fetched when something asks for it, not on every title change, and
  an activation Tana requested no longer asks the application which window it
  focused.
- **The usable-screen rectangle is cached** until the display, Dock or menu bar
  reports a change, and is never refreshed mid-swipe.
- **Saving the layout writes on its own queue**, not at the end of every glide.
- **The overview's scrim is faded by the helper on its own clock.** Setting the
  blurred window's opacity from this process every frame, to follow the
  fingers, was the cause of nearly all slow overview frames: with the scrim
  disabled the same test showed none. The scrim now fades in once when the
  overview opens and out when it closes; it no longer tracks the fingers.
  The outline and captions are drawn at the cards' resting places and shown as
  the cards arrive, instead of being redrawn under every frame of the flight.
- **Opening the overview no longer waits for the main thread** to raise the
  overlay, and the overlay's windows are built at startup.
- **The frame clock stops while a native fullscreen Space is in front**, and
  the idle fallback timer runs at 10 Hz instead of 60 Hz.

Not improved: each card of the overview still costs two helper commands per
frame, each of which is three WindowServer round trips inside Dock. Removing
that needs a new helper opcode and a reinstall of the scripting addition.
