# Implementation through 2.4

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

### Follow-up review: iteration-aware reuse

Iteration changes retain tile records. Lower limits transactionally recolour raw
samples and rebuild colour mipmaps; higher limits lazily replace only insufficient
records, copying escaped samples and recomputing only capped pixels. A GPU summary
allows fully escaped tiles to satisfy any later limit. No per-tile orbit buffers
are retained; capped pixels restart in the worker's bounded scratch allocation.
Decrease hysteresis matches increases. Tests verify lower-cap images against fresh
renders, zero sampling on a decrease/return, exact escaped-sample preservation,
and continued refinement/cancellation/fallback correctness. Core, CLI, tile and
independent numerical/product goldens pass.

### Follow-up review: shallow anchor and navigation regression

Returning to shallow coordinates now restores the canonical shallow grid and
clears cached deep bounds. Using the canonical grid also preserves the same tile
coverage as a fresh session. Regression traces exercise returns from 1e12 and
1e1000 and a 201-view 1x–1e30–1x trip with fixed versus automatic limits. They
check anchor demotion, fresh-session tile work, and sampling counts rather than
flaky timing thresholds; timings are printed for profiling. Tile integration passes.

### Follow-up review: extendable, streamed references

Reference orbits retain their final BigInt state and extend by an exact suffix;
unit tests compare every packed value against one-shot computation. The cache
reuses compatible prefixes, retains completed prefixes while extensions are in
flight, and budgets saved state. GPU work starts with at most 4,097 reference
iterations, pauses at a temporary frontier, then resumes after geometric prefix
growth. Frontiers align with BLA leaves and do not masquerade as escaped references.

A cold product view at c=i, 1e1000, using the actual automatic limit of 266,000,
produced its first deep tile in 35 ms and settled in 231 ms on the M1 Pro. It
needed only 4,098 reference values. These are headless tile-readiness timings,
not phone frame-pacing measurements. An exact-centre capped pixel separately
forces reference extension. Full tests and unchanged deep/minibrot budgets pass.

### Follow-up review: isolated BLA metrology and final checks

Added diagnostic GPU jumps from identical packed starting states and independent
180-digit Decimal recurrence. Across both scenes, 440 cases include zero deltas
and 12.5%, 50% and 99% of each validity radius, with lengths through 16,384.
Approximation error must be below 1e-12 relative to the output-term scale;
ordinary GPU recurrence and on/off differences must remain below 1e-10.

A fixed five-bit allowance per jump passes these strict local tests and is
available via `--bla-radius fixed`. It still fails the unchanged tiled minibrot
image budget (33/255 maximum versus 12 allowed), so production retains the
compounded margin. No tolerance was loosened or margin fitted to the failing
pixels. Both policies remain reproducibly testable; this validation limitation
is documented rather than claiming the hierarchy issue is fully resolved.

Shallow transition cleanup now waits for the old worker before releasing its
reference cache and spare state buffer. Final full tests, strict formatting,
iOS Simulator and physical-device builds pass. The iPhone 16 Pro remains listed
as unavailable and no iPhone 11 Pro is present; actual phone measurements remain
outstanding. Final timings, images and test counters are in `evidence/followup`.

### 2.4 Coverage pyramid

Added a separately marked, LRU-protected coverage set with a 30 MiB / 40-tile
reservation drawn only from bytes left after the visible band. It plans a root tile, eight near zoom-out projections, and a sparse
tail, then schedules root before the local preview/visible band and all
lower-priority work. Composition now considers a bounds-ordered coverage index,
so it is not limited by the local 62-level ancestor walk. Old-anchor coverage
remains valid through rebasing until the new root completes. Coverage uses its
own level estimate and does not extend at higher detail limits. A budget-pressure
skip removes the key from every coverage queue, preventing the main-actor retry
spin found in review. Unit and headless tests cover projected selection, a
phone-shaped constrained budget, non-extension, and a sentinel-free 128× deep
zoom-out after a cold jump. `make test` and `make format-check` pass.

### 2.3 and 2.4 completion

A review on 2026-09-17 found 2.4's root missing past about 1e308 (fixed in
`909d32d`) and three open follow-up findings, and 2.3 half done.

**2.4.**
- Root coverage is bounded: the planned footprint plus up to nine retained cells.
- The root is never deferred, and deferred coverage returns when memory eases.
- Each zoom-out offset is sized to fit a few tiles instead of quarter resolution.
- Projections stop at the minimum scale.
- The store replans when the measured tile size changes.
- The coverage cap scales with the budget, and choosing detail reserves the root
  and offsets 1–2.
- Eviction keeps records the current frame still draws.

New headless checks run phone- and Mac-shaped drawables at their real budgets
(with a watchdog), zoom-out quality, cold-jump latency with coverage on and
off, and moving preparation cost. See `Performance.md`.

**2.3.**
- The viewer lowers the automatic limit to twice the highest escaped count in a
  settled view; this is exact, and higher counts release it.
- A raise recolours only when it reveals counts coloured as capped.
- Tiles with no capped pixels are no longer stand-ins after a raise.
- The iteration reuse diagnostic now runs at a size where extension actually
  happens.

Raising from data, the reference-orbit hint and resuming capped pixels move to
2.10. `make test`, strict formatting of the changed files and `make ios` pass.

### 2.5–2.8

Rotation, navigation feel, locations, the Julia companion and zoom movies, in
four commits with their own tests:

- **2.5** `Viewport.angle` with rotated conversions, coverage and quads; trackpad
  panning with AppKit momentum; a single two-touch gesture on iOS that pins both
  fingers; a 10° twist threshold, ±3° snapping with a haptic tick, a compass
  button; rotation inertia; gentle bounds springs and a precision-limit bounce.
  A 30° product golden validates rotation against the independent oracle.
- **2.6** `Location`, `mandelbrot://` links with the scheme registered on both
  platforms, back/forward history over settled views, bookmarks in user
  defaults, and a nine-place starter gallery.
- **2.7** A live Julia companion (side by side, or inset on iPhone) with swap,
  checked against the mathematics: for c = 0 the set is exactly the unit disc.
- **2.8** `ZoomPath` plus keyframe rendering, affine frame composition and
  AVAssetWriter encoding, with a `--movie` CLI and a headless render read back
  through AVAssetReader.

`make test`, `make ios` and strict formatting of the changed files pass. Phone
hardware measurements remain outstanding (2.11).
