# Implementation through 2.1

Work is staged on `feature/gpu-tile-explorer`. The target devices are iPhone 11 Pro
and iPhone 16 Pro. Minimum deployment: iOS 18, macOS 15.7. Physical-device frame
rates require testing on those devices; simulator timings are not substitutes.

Completed:
- 1.1: ignore coverage files; remove visionOS/device family 7; support iOS 18.
  These changes were included in concurrent commit `2344a77` before the cleanup
  commit attempt, which therefore had no remaining changes to commit.
- 1.2: retain strict FloatFloat arithmetic; document measured Float slowdown.
- 1.3: immutable Double reference counts and PNGs at four locations, CLI tests,
  Swift unit tests, and `make test`. Float goldens stop at their precision range.
- 1.6: shared Viewport navigation/precision cap, typed renderer registry/protocol,
  separate viewer/benchmark/help, and one command table for menu/keyboard/help.

- 1.4: private GPU sample/colour textures, asynchronous compute, MTKView presentation,
  diagnostic-only readback, kernel/end-to-end CLI timings; product goldens pass.

- 1.5: smooth radius-256 samples, seven cyclic palettes, appearance controls,
  recolouring without recomputation, and an independent smooth-count oracle.

- 1.7: hidden developer access, automatic/default clean viewer, renderer overrides,
  HUD/overlay toggles, device-tagged benchmark sharing and timing scope.

- 1.8: native anchored gestures, double/two-finger taps, cursor zoom, rectangle
  selection, arrows, and analytically integrated pan/pinch inertia. Mac tests and
  iPhone/iPad simulator compilation pass.

- 2.1(a): anchor-relative fixed-level tiles, a per-frame Metal compositor, sample
  reuse during pan, transactional recolouring, and headless integration checks.

- 2.1(b): multiple levels, coarse-first scheduling, parent fallback with zero-hole
  zoom tests, and anchor rebasing with retained coverage.

- 2.1(c): colour-space level blending, 125 ms refinement fades, and GPU tile
  borders/level labels. Shader integration verifies known RGB blend weights.

- 2.1(d): exact interior colour mip averaging, direction-aware prefetch, protected
  ancestors, LRU device budgets, resumable iteration batches, lifecycle cancellation
  and GPU cache/frame statistics. Budget pressure lowers sampling LOD without
  changing the camera. Palette-dependent mipmaps are disposable; raw data stays
  authoritative. The cache and numerical integration regressions pass.

At the end of 2.1, perturbation and automatic iteration depth were still deferred;
navigation used the agreed graceful FloatFloat precision cap. The 2.2 work below
supersedes that navigation limit. Each numbered point or tile stage has a commit;
1.6 preceded 1.4 to establish the shared models before the GPU presentation change.

Final verification: `make test`, `make ios`, unsigned generic physical-iOS Release
build, five isolated headless tile traces, and visual inspection of the deep tiled
PNG. `Architecture.md` explains the cache, precision and memory decisions.
Interactive GUI inspection could not proceed because Computer Use permissions
remained pending; no physical phone measurements were obtained. Hands-on testing
on iPhone 11 Pro and iPhone 16 Pro remains necessary before claiming frame pacing
or touch quality on those devices.

## Review stabilisation

- Failure handling: at most three attempts per failing tile/operation, delayed
  retries independent of display frames, and explicit recovery. An injected
  allocation failure verifies 120 updates cannot restart terminal failures.
- ProMotion: explicit iOS Info.plist boolean; `make ios` checks the generated app.
  The suggested custom build setting alone was ignored by this Xcode generator.
  Earlier claims that the opt-in was already enabled were incorrect.
- Deep scheduling: protect a three-level working set; regression preserves full
  1e10 detail within the iPhone budget and measures useful coverage separately
  from completion. Existing distant ancestors remain reusable LRU entries.
- Iteration changes: retain the detailed working set across repeated changes,
  prefer its detail over coarse new tiles, and fade replacements before releasing
  fallback. Tile records now carry their iteration limit.
- Palettes: immutable lookup textures shared across all tile recolours; texture
  identity and sample invariance checked by the headless tests.
- Idle work: completion-driven MTKView wakeups, motion/fade-only continuous
  drawing, unchanged-demand early returns, pressure-only LRU sorting, and hardware
  presentation timing. Refresh rate comes from the view window. Regression checks
  idle demand, palette wakeups and resume; iOS metadata/build checks pass.
- Independent product goldens: CPU Double pixel-centre images cover whole-set,
  offset fractional LOD, Seahorse detail and mip boundaries. References are
  generated without invoking the app. Legacy fixtures remain unchanged, with
  tighter precision/location-specific error budgets and explicit headroom.
- Formatting: `.swift-format`, `make format` and `make format-check`; the mechanical
  whole-project pass is separate from behaviour changes.
- Native input: command matching is centralised with key/modifier regressions;
  CPU input clocks stop when idle and remain paused for GPU rendering.
- iOS full-screen follow-up: the fractal and its geometry ignore the safe area,
  controls remain inset, and the status bar is hidden. The Mac layout is preserved.
- Reporting: Mac hardware model comes from `hw.model`; kernel-only benchmark
  exports no longer claim to include colour conversion.

`Implementation.md` is the completion record; `plan.md` remains the roadmap and
`Architecture.md` describes the current design. The original review document and
subsequent safe-area note remain reviewer-owned. The user's hands-on report
confirms smooth navigation before this pass; revised idle behaviour, high-refresh
presentation, both landscape orientations and touch anchors still need phone
verification. No 2.2/2.3/2.8 feature work or iteration-state retention was folded
into stabilisation. The reasons for deferring large batches and count-format
changes are documented in Architecture.md.

Final stabilisation verification: `make test`, `make format-check`, `make ios`,
`make ios-device`, final tile checks and five isolated trace runs passed. Product
PNG inspection at the mip-boundary fixture showed no visible tile seam. Final
measurements and their limits are recorded in Performance.md.

### 2.2a–b: precision foundation and perturbation

Compared pinned MIT BigInt and Boost cpp_bin_float at 1e100/1e1000 precision;
selected Swift fixed point with the measured latency tradeoff in Performance.md.
Added precise camera/anchor-relative tile geometry, logarithmic zoom,
extended-exponent FloatFloat Metal perturbation, bounded glitch re-referencing,
and critical-point rebasing. CLI accepts exact decimal centres and deep scale
strings with `--pipeline gpu|tiles --renderer perturbation`. Independent Decimal
sample goldens at 1e50, 1e200 and 1e1000 now run in `make test`.

### 2.2c: BLA acceleration and final validation

Completed 2.2 on main. Added bounded 32-iteration BLA blocks, an on/off benchmark
control, bounded shared reference caching for tiles, and status metrics. Deep
sample and independent PNG goldens pass with BLA on and off at 1e50, 1e200 and
1e1000. Tests also exercise real glitch re-referencing, deep pan/anchor zoom,
parent coverage, reference reuse, Metal ABI layout and cancellation recovery.
Deep debug overlays support five-digit levels; benchmark exports retain precise
centres and scale strings. Defaults keep precision automatic; shallow renderer
overrides resume after zooming out of a deep view.

Final validation: `make test`, `make format-check`, `make ios`, `make ios-device`,
and visual inspection of all deep evidence images. Actual iPhone frame pacing
has not been measured by these headless/build checks. Iteration depth remains
manual; no automatic-depth or periodicity feature was added ahead of the plan.

### Deep-zoom review, stage 1

Rebase before Pauldelbrot recovery. Keep an explicit rebasing-off diagnostic and
count avoided glitches separately. Added a period-312, 1e100 long-orbit Decimal
golden and a numerical/colour golden through the tile compositor. Documented
boundary-sensitive tolerances alongside the strict existing c=i fixtures. Full
`make test` passes, including both new paths and diagnostic recovery.

### Deep-zoom review, stage 2

Added precision-banded, prefix-capable, budgeted reference reuse and shared pending
requests. Preparation runs outside the cache actor; waiter cancellation cancels
unneeded work. Reference targets follow the viewport rather than the grid anchor,
with nearby orbit reuse. Tile workers recycle their GPU state buffer on completion,
failure and cancellation. One precision policy now drives product renderer choices
and override handling. `make test` passes, including the hard tiled oracle.

### Deep-zoom review, stage 3

Cached immutable bounds, added exact integer-key same-anchor relationships and
one high-precision camera conversion per draw. Added CPU preparation counters and
120-frame deep integration coverage. All existing and hard product goldens pass.
Physical iPhone profiling could not run: neither target device was available.

### Deep-zoom review, stage 4

Added extended-range BLA construction and an aligned merge hierarchy, with
`--bla off|fixed|on` controls on full-image and tile paths. A guard-bit allowance
per merge keeps the existing hard tiled error budget. Tests cover coefficients
beyond Double range; actual jumps reach 16,384 iterations at the minibrot.
BLA memory is reserved and skipped-iteration totals use two words.

### Deep-zoom review, stage 5

Replaced combined Float samples with exact integer counts and separate smooth
corrections; palette phase preserves the correction at one million iterations.
Raised the product GPU cap, added raw record export, retained legacy limits,
and implemented the depth-based first estimate from 2.3 with unified manual/detail
controls and gesture/idle hysteresis. Tests cover high-count colour, exports,
clamped smooth values, actual totals above UInt32, reference capacity accounting,
and input-driven depth changes. Full pixel adaptation and periodicity are not done.

### Deep-zoom review, stage 6 and final verification

Added visible Settings acknowledgements using the already bundled MIT notice,
verified the resource in both iOS builds, and documented signed truncation.
Added a pinned Boost fetch/build script and a saved-reference minibrot comparison,
with the measured backend decision in Performance.md. Updated current architecture,
usage and plan status. Final PNGs and off/fixed/hierarchical measurements are in
`evidence/review-deep`.

Final `make test`, `make format-check`, `make ios` and `make ios-device` all pass.
The test suite includes 21 core tests, legacy and GPU goldens, high-count colour
and CLI exports, tile cache/resumption/mip/recovery checks, strict c=i deep goldens,
and hard minibrot numerical and tiled goldens. The final 128×96 minibrot PNG was
visually inspected. Both physical target phones were unavailable; frame pacing,
CPU preparation and touch feel on iPhone 11 Pro/16 Pro remain device validation.
