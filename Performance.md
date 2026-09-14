# Mandelbrot Performance Experiments

## Headless benchmarks (macOS)

Build the Release app, then invoke its executable directly with `--benchmark`.
This selects the command-line entry point before SwiftUI starts; no window is opened.

```sh
xcodebuild -project Mandelbrot.xcodeproj -scheme Mandelbrot \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath /tmp/mandelbrot-build CODE_SIGNING_ALLOWED=NO ENABLE_CODE_COVERAGE=NO build

/tmp/mandelbrot-build/Build/Products/Release/Mandelbrot.app/Contents/MacOS/Mandelbrot \
  --benchmark --variants baseline,parallel,metal \
  --sizes 1024x512,2048x1024 --iterations 200 --warmup 1 --runs 3
```

Use `--format json` to capture machine-readable results, including the viewport, each measured
sample, median seconds, and megapixels per second. The default output is Markdown.
`--help` lists all options; `--variants all` includes all nine implementations
(including the FloatFloat `metal-double` renderer). CPU-only runs can select
`--variants baseline,parallel` without requiring a Metal device.

The default sizes are fixed for repeatability, rather than the GUI's adaptive size
selection. Runs default to center (-0.5, 0) and scale 1; `--center-real`,
`--center-imag`, and `--scale` select another viewport. Block size is always 1. As in the GUI,
timings cover both iteration computation and CPU colorization, including allocations
and GPU synchronization; they are not isolated kernel timings. Each renderer/size
gets its own untimed warmups, followed by measured runs using a monotonic clock.
Zero warmups includes first-use setup costs in the first measured sample.

The process exits with status 0 on success, 2 for invalid options, and 1 if a
renderer fails (including unavailable Metal). Diagnostics go to stderr. Iterations
are limited to 65535 to fit the GPU count buffers. Sizes are limited to 16384 per
dimension and 33554432 pixels in total. Run without `--benchmark` to open the GUI
normally. Use Release builds with `ENABLE_CODE_COVERAGE=NO` for performance comparisons;
the Xcode scheme otherwise enables coverage instrumentation even in Release.

Run the headless CLI integration checks against a built executable with:

```sh
python3 tests/test_headless.py \
  /tmp/mandelbrot-build/Build/Products/Release/Mandelbrot.app/Contents/MacOS/Mandelbrot
```

These checks use CPU renderers so they can run without GPU access.
Set `MANDELBROT_TEST_METAL=1` to also run the deep-zoom accuracy regression against
CPU Double. This requires GPU access and checks square and non-square viewports.

## PNG export and deep-zoom benchmarks

`--render` exports a single full-resolution PNG without opening a window. For example:

```sh
/tmp/mandelbrot-build/Build/Products/Release/Mandelbrot.app/Contents/MacOS/Mandelbrot \
  --render --renderer metal-double --size 512x512 \
  --center-real -0.743643987037151 --center-imag 0.13182597420533 \
  --scale 10000000 --iterations 2000 --output floatfloat.png
```

Horizontal span is `3 / scale`; vertical span follows the image aspect ratio.
The real coordinate increases left to right; the imaginary coordinate increases
bottom to top. Center coordinates must be in [-4, 4], and scale in [1e-6, 1e14].
These bounds are input limits, not a promise of adequate precision at every zoom.
Image dimensions and iteration limits use the same validation as benchmarks.
`--counts counts.u16` optionally exports raw iteration counts as little-endian
UInt16 values in row-major order, starting at the top-left pixel. No header is
included; use the requested image dimensions to interpret them. Parent output
directories must already exist. PNG writing is excluded from benchmark timings.

Benchmark the exact same viewport by replacing the render/output options:

```sh
/tmp/mandelbrot-build/Build/Products/Release/Mandelbrot.app/Contents/MacOS/Mandelbrot \
  --benchmark --variants all --sizes 512x512,1024x1024 \
  --center-real -0.743643987037151 --center-imag 0.13182597420533 \
  --scale 10000000 --iterations 2000 --warmup 1 --runs 5 --format json
```

See [the FloatFloat investigation](evidence/floatfloat/README.md) for before/after
images, raw measurements, accuracy comparisons, and reproduction instructions.

This document outlines independent experiments to measure performance impacts in the Mandelbrot renderer. Each experiment changes a single aspect of the computation so you can isolate effects. The hot path is the iteration loop and block fill in `MandelbrotRenderer.iterations`.

## Phase 1

### Experiment 1.1 — Scalar loop tightening (cache squares + `for` loop) (`scalar-tight`)
**Goal:** Improve instruction count and branch predictability in the iteration loop.

**Change:** Replace the `while` condition with a `for iteration in 0..<maxIterations` loop and maintain cached squares (`zr2`, `zi2`). Update squares each iteration and break when `zr2 + zi2 > 4`.

**Hypothesis:** Fewer multiplications and simpler branching reduce cycle count in the inner loop.

---

### Experiment 1.2 — Coordinate precompute (incremental real/imag) (`coord-precompute`)
**Goal:** Reduce divisions and repeated arithmetic per block.

**Change:** Precompute `realStep` and `imagStep` once, then compute `real`/`imag` using multiply-adds instead of division per block.

**Hypothesis:** Lower per-block arithmetic cost improves throughput, especially for small block sizes.

---

### Experiment 1.3 — Unsafe buffer writes (bounds-check elimination) (`unsafe-buffer`)
**Goal:** Reduce overhead in the block fill loop.

**Change:** Use `values.withUnsafeMutableBufferPointer` to write via raw pointers, precomputing row offsets to reduce index math and bounds checks.

**Hypothesis:** Fewer bounds checks + fewer index computations improve write throughput.

---

### Experiment 1.4 — `Float` vs `Double` (`float-math`)
**Goal:** Trade precision for faster arithmetic and potential SIMD throughput.

**Change:** Convert the iteration math to `Float` (or add a `Float`-specialized path) while keeping output iterations as `Int`.

**Hypothesis:** Reduced register pressure and faster math yield faster renders at modest zooms.

---

### Experiment 1.5 — Parallel outer loop (`parallel`)
**Goal:** Exploit multi-core scaling.

**Change:** Parallelize the outer `y` block loop using `DispatchQueue.concurrentPerform` (or a task queue of blocks).

**Hypothesis:** Near-linear speedup for larger images with enough blocks.

---

### Experiment 1.6 — SIMD batching (`simd4-float`)
**Goal:** Increase arithmetic throughput by evaluating multiple points per iteration.

**Change:** Use `SIMD4<Float>` or `SIMD8<Float>` to iterate multiple points at once (especially if `blockSize == 1`).

**Hypothesis:** Vectorization yields significant speedups in the inner loop.

---

### Phase 1 Results

| Variant         | 1024x512            | 2048x1024           | 4096x2048           | 8192x4096           |
| ---             | ---                 | ---                 | ---                 | ---                 |
| baseline        | 0.121s / 4.32 Mpx/s | 0.476s / 4.41 Mpx/s | 1.901s / 4.41 Mpx/s | 7.524s / 4.46 Mpx/s |
| scalar-tight    | 0.121s / 4.33 Mpx/s | 0.470s / 4.47 Mpx/s | 1.876s / 4.47 Mpx/s | 7.487s / 4.48 Mpx/s |
| coord-precompute| 0.127s / 4.13 Mpx/s | 0.468s / 4.48 Mpx/s | 1.870s / 4.48 Mpx/s | 7.463s / 4.50 Mpx/s |
| unsafe-buffer   | 0.123s / 4.25 Mpx/s | 0.470s / 4.46 Mpx/s | 1.863s / 4.50 Mpx/s | 7.459s / 4.50 Mpx/s |
| float-math      | 0.123s / 4.28 Mpx/s | 0.471s / 4.45 Mpx/s | 1.883s / 4.46 Mpx/s | 7.491s / 4.48 Mpx/s |
| parallel        | 0.022s / 23.84 Mpx/s| 0.072s / 29.25 Mpx/s| 0.282s / 29.78 Mpx/s| 1.114s / 30.12 Mpx/s|
| simd4-float     | 0.136s / 3.85 Mpx/s | 0.533s / 3.93 Mpx/s | 2.108s / 3.98 Mpx/s | 8.424s / 3.98 Mpx/s |

## 1.2 follow-up: strict Float math cost

The controlled `evidence/floatfloat/benchmarks-{before,after}.json` measurements
at scale 1e7 show the Float kernel's end-to-end cost increasing from 8.907 ms to
9.660 ms at 512² (+8.5%), and 31.784 ms to 35.390 ms at 1024² (+11.3%). These are
whole-image timings, including CPU colour conversion, not isolated GPU timings.
Corrected FloatFloat costs 104.593 ms at 1024² versus 35.664 ms for the incorrect
shader. Precision is required; keep safe math enabled. CPU-precomputed FloatFloat
coordinates will be introduced with the shared GPU pipeline, with new measurements,
rather than adding a second temporary parameter layout to the legacy lab kernels.

## 1.4: GPU-resident product pipeline

M1 Pro, Release, coverage disabled, same 1e7 viewport and 2000 iterations as the
FloatFloat investigation; median of five samples after one warmup. Raw samples:
`evidence/product/1.4-gpu-pipeline.json`. Legacy counts and all four goldens pass.
CPU-precomputed FloatFloat coordinates remove per-pixel divisions. The product
viewer performs no image readback; MTKView samples the GPU colour texture.

| Scope | Renderer | 512² ms | 1024² ms |
| --- | --- | ---: | ---: |
| kernel | metal | 4.351 | 16.562 |
| kernel | metal-double | 20.094 | 75.324 |
| end-to-end | metal | 4.962 | 17.705 |
| end-to-end | metal-double | 20.656 | 76.025 |

Kernel time is the compute command buffer GPU duration; end-to-end includes
allocation, submission, computation and GPU colouring to a completed texture. It
excludes display synchronization and PNG readback. Use `--pipeline gpu --timing
kernel` or `--timing end-to-end`; the legacy lab path remains the default for
backward-compatible CLI comparisons.

## 1.5: smooth colouring and palettes

Same M1 Pro protocol and 1e7 viewport as 1.4. Smooth escape radius is 256
(squared threshold 65536), with `n + 1 - log2(log2(|z|))`; negative sentinel -1
marks capped samples, and far-exterior smooth values are clamped at zero.
Seven periodic gradient LUTs include a constant-lightness/chroma OKLab wheel.
Palette, density and offset changes recolour retained samples without iteration work.
The independent smooth Double oracle and all legacy/product goldens pass.

| Scope | Renderer | 512² ms | 1024² ms |
| --- | --- | ---: | ---: |
| kernel | metal | 4.279 | 12.656 |
| kernel | metal-double | 18.865 | 73.138 |
| end-to-end | metal | 4.070 | 14.011 |
| end-to-end | metal-double | 19.945 | 73.523 |

Samples: `evidence/product/1.5-smooth-palettes.json`; PNG:
`evidence/product/smooth-blue-gold.png`. GPU rendering defaults to smooth colouring.
Use `--colouring legacy` for unchanged integer-count exports, or `--samples file.f32`
for float32 smooth samples. `--palette`, `--density`, and `--offset` control appearance.

## 1.8: frame-rate-independent navigation

Pan/zoom inertia integrates exponential decay analytically. The unit test compares
half a second of motion at 60 and 120 Hz: displacement and scale differ by less
than 1e-9. GPU presentation requests each screen's maximum refresh rate; the iPhone
ProMotion Info.plist opt-in was originally reported as enabled, incorrectly.
The review stabilisation pass adds an explicit iOS plist and checks the built app. This is configuration
and numerical validation, not a measured claim of 120 fps on a physical phone.
Both macOS tests and the iPhone/iPad simulator build pass. Physical testing on the
iPhone 11 Pro and iPhone 16 Pro remains necessary for touch feel and frame pacing.

## 2.1(a): fixed-level tile renderer

The headless integration trace computes a 512×320 view, pans with overlap, and
changes palette. It verifies sample-texture reuse and no recomputation on palette
changes. Five isolated Release runs on M1 Pro: median trace 46.278 ms, maximum
observed GPU row-batch 0.237 ms, six cached tiles using 4,915,200 allocated bytes.
This includes readbacks used by assertions. Samples: `evidence/product/2.1a-tiles.json`.
Tiles have 256² interior samples plus a one-sample gutter for seam-free filtering.
The first stage deliberately holds the selected level fixed for panning; multilevel
fallback is the next stage. `--render --pipeline tiles` exercises the compositor
without opening a window. `make test` includes its headless integration checks.

## 2.1(b): multilevel fallback

The trace now includes a zoom snapshot taken before refinement finishes. A magenta
clear sentinel detects uncovered pixels: zero holes in every run. Median complete
trace: 173.095 ms; maximum observed GPU batch:
0.370 ms. This longer trace is not directly comparable to stage (a).
Samples: `evidence/product/2.1b-parent-fallback.json`. Coarse tiles precede fine tiles;
one ancestor lookup per screen cell avoids drawing every ancestor over the screen.
Anchor rebasing retains previous coverage while replacement tiles are computed.

### 2.1(c): level blending and refinement fades

The same pan/palette/zoom trace now uses the three-source colour compositor.
Five M1 Pro runs: median 134.249 ms, longest compute batch 0.641 ms.
Raw runs: `evidence/product/2.1c-blending.json`. This is offscreen integration
time, not a measurement of display refresh rate. `make test` passes, including
an actual GPU render with known coarse/base/fine colours and blend weights.

## 2.1(d): bounded refinement, mipmaps and LRU cache

Five isolated Release runs on Apple M1 Pro, using `tests/measure_tiles.py`. Raw
results: `evidence/product/2.1d-cache.json`. All numerical and cache assertions
passed. The trace now adds 40 fractional-zoom frames with 8 ms sleeps while
refinement/prefetch run, so its 487.619 ms median duration is deliberately not a
speed comparison with earlier traces.

| Measurement | Result |
| --- | ---: |
| Median per-run p95 compositor GPU duration | 0.250 ms |
| Worst compositor GPU duration across runs | 1.339 ms |
| Worst ordinary refinement batch | 1.432 ms |
| Cold 1e10 refinement, 256², 4000 iterations (median) | 1488.170 ms |
| Worst batch during that deep refinement | 2.370 ms |
| Resident cache after animated trace | 101.5625 MiB |
| Resident cache after deep refinement | 115.625 MiB |

The deep viewport is `(-0.743643887037151, 0.13182590390533)`, with automatic
per-tile precision. Cold refinement includes the entire ancestor chain; it is
not a full-image kernel benchmark. GPU duration excludes drawable scheduling,
display synchronization and CPU overhead, and is not proof of 120 fps on a phone.
The 40 MiB constrained-cache regression recorded 24 LRU evictions, 16 prefetched
tiles and 12 mipmap builds, while preserving visible tiles and ancestors.

Row-only slicing has been replaced with resumable iteration batches targeting
1 ms, bounded to 8–512 iterations per 258² tile. Both Float and FloatFloat resumed
results match the full smooth kernel byte-for-byte in a 2000-iteration regression.
The actual mip kernel matches CPU 2×2 averaging within byte rounding for every
interior pixel; gutters are deliberately retained from direct parent colouring.
Palette changes rebuild mipmaps while preserving the exact raw sample textures.

Cache budgets are 150 MiB on iOS and 500 MiB on Mac, with reserved transient
headroom. These numbers cover cache policy, not total process allocation.
`evidence/product/tiles-deep.png` is a 1024×768 tiled FloatFloat export at the
original 1e7 accuracy-reference location, 2000 iterations, blue-gold palette.

Validation: `make test`, `make ios`, and an unsigned generic physical-iOS Release
build pass. Interactive GUI inspection was unavailable because Computer Use
permissions remained pending. Physical iPhone 11 Pro (60 Hz) and iPhone 16 Pro
(120 Hz) pacing and touch feel remain to be measured.

## Uniform threadgroup compatibility fix

All three dispatch sites now use `dispatchThreadgroups` with rounded-up group
counts. Kernels reject padded threads before reading or writing memory. This
removes the unsupported non-uniform-dispatch feature requirement from the viewer
and both legacy Metal benchmark renderers.

`make test` and `make ios` pass, including odd-sized legacy exports, 66×53
resumption comparisons and all 258×258 tile/colour/mipmap kernels. Five M1 Pro
traces are in `evidence/product/uniform-dispatch.json`: median trace 483.178 ms, median per-run p95 compositor GPU duration 0.377 ms, worst deep-refinement GPU batch 2.564 ms. These are host measurements; the device that reported the assertion still needs a rebuilt-app run.

## Review: local ancestor scheduling

Five M1 Pro traces (`evidence/product/review-local-levels.json`), now using the
iPhone 150 MiB budget for the 1e10 deep test. The requested LOD is preserved.
- deepUsefulMS: median 66.733
- deepRefinementMS: median 174.541
- deepResidentBytes: median 9830400.000

Only the visible level and two nearby ancestors are required. Distant cached
ancestors remain eligible for LRU reuse. This replaces 148 required deep tiles
with 12 (9.375 MiB), without raising the budget or changing precision.

## Review: iteration-change continuity

Old detailed tiles survive repeated iteration changes until replacement detail
has completed its 125 ms fade. Both base and fine colours can blend against
the previous generation. The regression compares the pre-change and immediate
post-change PNG pixels exactly, then checks final-generation metadata and cleanup.
Five M1 Pro traces: median per-run p95 compositor GPU time 0.144 ms; worst observed 0.773 ms. Raw: `evidence/product/review-fallback.json`.

## Review: immutable palette textures

Seven lookup textures are created once during GPU initialisation, not once per
tile recolour. Identity checks and all palette/sample tests pass. Five M1 Pro
traces (`evidence/product/review-palette-cache.json`): median elapsed 467.361 ms. The trace includes fixed sleeps, so
this is a regression measurement rather than an isolated palette speedup claim.

## Review: event-driven drawing and demand

Settled MTKViews pause; tile completion, appearance changes and navigation wake
them. Motion and unfinished fades sustain the display timer. Unchanged demand
returns before rebuilding sets or touching LRU state; eviction sorts only under
pressure. GPU frame statistics sort at 4 Hz, not every frame. A regression
sends 120 unchanged updates and verifies no work or notifications are created.
Five M1 Pro traces (`evidence/product/review-demand.json`): median last measured
demand update 0.028 ms. The hardware HUD now measures recent drawable presentation cadence separately
from GPU duration. Simulator Metal does not expose presentation timestamps.
Actual phone idle energy use and display pacing still require device measurement.

## Review: independent product image validation

The four CPU-authored pixel-centre fixtures use the ink palette. On M1 Pro,
whole-set, fractional-offset and mip-boundary images had no pixels with a
maximum-channel difference above four byte values; their mean maximum-channel
errors were 0.0199, 0.0432 and 0.0742. Seahorse had 0.3316% above four, with
mean error 0.1786. The reference independently computes Double orbits, colours,
filtering and box mipmaps. Existing endpoint-mapped reference images are intact.
Legacy budgets now distinguish Float from FloatFloat and specific pipelines;
headroom is retained rather than fitting thresholds exactly to one device.
Cross-device tolerance calibration remains open until comparable device data
exists. `make test` includes the new product goldens.

## Review stabilisation: final measurements

Five isolated M1 Pro runs: `evidence/product/review-final.json`. Deep rendering
uses 256², scale 1e10, 4000 iterations and the iOS 150 MiB cache budget.

| Measurement | Result |
| --- | ---: |
| Useful deep coverage, median | 71.333 ms |
| Complete deep detail, median | 161.353 ms |
| Deep resident cache | 9.375 MiB |
| Deep GPU batch, worst observed | 2.066 ms |
| Compositor p95, median of runs | 0.315 ms |
| Compositor GPU duration, worst observed | 0.888 ms |
| Last demand update, median of runs | 0.032 ms |

The earlier deep path took 1488.170 ms and retained 115.625 MiB on Mac;
under the phone budget it also reduced sampling detail. The new regression
requires the requested LOD to survive. Frame statistics now flush their final
window when work settles, and preserve the worst observed GPU duration.
The input display link/timer is paused or absent for GPU rendering and idle CPU
rendering. These are implementation and offscreen measurements, not claims of
measured phone battery savings or sustained 120 fps. Both iOS build targets
verify the generated ProMotion boolean; `make test` and `make format-check` pass.

## 2.2a — reference arithmetic library spike

On the M1 Pro, Release Swift `-O` and Apple Clang `-O3`, five runs of 10 ×
1,000 bounded reference iterations gave these median times:

| Zoom precision | Bits | Swift BigInt fixed point | Boost cpp_bin_float |
| --- | ---: | ---: | ---: |
| 1e100 | 397 | 33.075 ms | 6.240 ms |
| 1e1000 | 3386 | 864.733 ms | 68.952 ms |

Boost wins arithmetic throughput (5.3× / 12.5×). For this first implementation
we choose the MIT-licensed Swift BigInt: one 1,000-step reference at 1e1000
costs about 86 ms, can run off the main actor, and needs no C++ interop or
compile-time precision tiers. Camera arithmetic shares the same implementation.
This is a deliberate latency tradeoff; Boost remains the measured replacement
if reference creation dominates real scenes. The benchmark does not establish
that reference latency is negligible, especially at high iteration limits.

Sources, pinned versions and reproduction instructions are in
[tests/precision](tests/precision/README.md); raw measurements are in
[evidence/deep](evidence/deep). No LGPL dependencies ship in the app.

## 2.2b — validated GPU perturbation before BLA

A 256×192 endpoint-sampled image centred on c=i at 1e1000, 5,000 iterations,
three runs after one warmup: median **356.553 ms end to end**, including CPU
reference creation, GPU computation and colour (no PNG/readback). Median GPU
compute was **199.281 ms**, reference generation **101.608 ms**. This is the
unaccelerated reference for the next BLA stage; raw data is
[perturbation-before-bla.json](evidence/deep/perturbation-before-bla.json).
Its `preciseScale` is authoritative; the old numeric `scale` field in this
initial measurement saturates at Double range. Subsequent reports omit that
numeric field when the scale cannot be represented.

Independent Python Decimal direct orbits (depth + 80 decimal digits) validate
32×24 non-flat images at 1e50, 1e200 and 1e1000. Maximum smooth-count errors were
0.0000153, 0.0000610 and 0 respectively; each image has over 400 distinct counts
rounded to 0.01. The full 256×192 tile-compositor example at 1e1000 uses 12 tiles,
including its two nearby ancestor levels. A 7×5 whole-set diagnostic triggers
three cancellation glitches and three reference orbits. `make test` includes
the deep comparisons and verifies that re-referencing actually runs.

## 2.2c — BLA and shared tile references

Controlled BLA on/off comparison on the M1 Pro: centre c=i, 256×192,
5,000 iterations, median of three runs after one warmup. End-to-end includes
fresh CPU reference creation, BLA preparation and completed GPU colour output;
it excludes readback and PNG encoding. Full-image runs do not reuse references.

| Scale | BLA off, total | BLA on, total | GPU off | GPU on |
| --- | ---: | ---: | ---: | ---: |
| 1e50 | 17.481 ms | 14.422 ms | 12.867 ms | 10.444 ms |
| 1e200 | 55.531 ms | 25.916 ms | 41.604 ms | 17.758 ms |
| 1e1000 | 400.274 ms | 141.457 ms | 239.611 ms | 30.194 ms |

At 1e1000, BLA makes this GPU workload **7.9× faster**, and the full render
**2.8× faster**. It skips about 123 million individual pixel iterations per
image. The remaining ~102 ms CPU reference cost now dominates the full-image
path. The earlier library spike explains the next performance option: Boost
could reduce that cost substantially. We retain Swift here for runtime-selectable
precision and native integration; this is a measured tradeoff, not a claim that
the libraries perform similarly. Interactive tiles amortize reference creation
through a shared anchor and a bounded three-entry/4 MiB cache.

Both BLA modes pass all three independent Decimal sample goldens (maximum errors
0.0000153 / 0.0000610 / 0), and the independent Ink PNGs differ by at most 1/255
per colour channel. A separate exact cancellation case exercises three glitch
corrections using three reference orbits. Deep tile integration verifies
reference reuse, bounded residency, fade/fallback coverage and cancellation.

[Raw controlled measurements](evidence/deep/bla-comparison.json),
[reproduction script](tests/precision/measure.py), and full-size PNG evidence:
[1e50](evidence/deep/gpu-1e50.png), [1e200](evidence/deep/gpu-1e200.png),
[1e1000](evidence/deep/gpu-1e1000.png). These are Mac measurements, not claims
about frame rates on either iPhone. Simulator and unsigned device builds cover
compilation and packaging, not physical presentation timing.

## Deep-zoom review: rebase first and harder goldens

The new independent Decimal fixture solves z_936(c)=z_624(c) beside a period-312
minibrot, at 1e100 and 60,000 iterations. Its 16×12 samples escape between 22,734
and 34,044 iterations. Rebase-first gives one reference and 1,705 rebases. Disabling
critical-point rebasing increases sample differences over 0.02 from 7/192 to
33/192. Default rendering no longer sends those recoverable cancellations through
a new reference pass; `--rebasing off` explicitly tests the retained recovery path.

This chaotic fixture has finite-precision boundary outliers: with BLA off/on,
maximum smooth errors are 237.963/115.051, and 6/7 PNG pixels differ by more than
3/255. Mean channel errors are 1.405/1.435. The declared budgets are at most 5%
sample/colour outliers, mean sample error below 5 and maximum below 512; these
are not zero-error claims. The independent 8×6 product PNG includes tile-centre
sampling, gutters and fractional level blending. Two pixels differ by more than
3/255, with maximum 9/255; its budget is 5% outliers, maximum 12 and mean channel
error below 1. The existing c=i goldens retain their strict tolerances.

Generator: `tests/precision/minibrot_reference.py`; test: `tests/test_minibrot.py`.
Comparable 64×48, three-run/one-warmup measurements of both locations are stored
in `evidence/review-deep/rebasing.json` and reproduced by
`tests/precision/measure_review.py APP STAGE`.
