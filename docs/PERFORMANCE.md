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
