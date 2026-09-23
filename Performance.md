# Mandelbrot Performance

What the renderers cost, how that was measured, and what changed it. The current
state comes first, then the measurement method and how to reproduce it, then a
dated log of every experiment, oldest first. `make docs` aligns the tables for reading in
a monospace editor; `make docs-check` checks them and every link.

## Current state (2026-09-23, `f855bf5`)

| Workload                                                         | Latest measurement                                                                                 | Where the time goes                                                                   | Next lever                                                                     |
| ---------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| Cold shallow and medium Float views, 3456×2234, automatic limits | 59–177 ms to every tile ready ([The whole story](#the-whole-story))                                | GPU iteration and per-tile round trips, now overlapped                                | Periodicity checking (plan 2.14) for interior pixels                           |
| Cold FloatFloat view, 1e7, 2,200 iterations                      | 364 ms (same entry)                                                                                | Mostly GPU iteration                                                                  | Periodicity checking                                                           |
| Cold deep jumps, 1024×768, 5,000 iterations                      | 1e100: 758–794 ms; 1e1000: 565–601 ms visible (six `--test-tiles` runs, 2026-09-23)                | Perturbation tiles, not broken down at this size; unchanged by the tile batching work | Profile first; a Boost reference backend (plan 2.16) is the measured candidate |
| Compositor, 3456×2234, settled                                   | 1.30–2.19 ms per frame ([colouring in the compositor](#211-follow-up-colouring-in-the-compositor)) | Four sample fetches and blends per level                                              | —                                                                              |
| Zoom movie into the period-312 minibrot, 640×360                 | 1,236 s for 101 keyframes ([2.8](#28-zoom-movies))                                                 | Keyframe rendering; which part of it is not measured                                  | Profile one keyframe                                                           |

Open risks: since `f855bf5` a tile batch can run for up to 4 ms while another
tile shares the GPU, and whether that delays frames at 120 Hz is unmeasured (see
[Not yet measured](#not-yet-measured)).

## Method

Unless an entry says otherwise, measurements are:

- On an Apple M1 Pro (16-core GPU); macOS 26.6 as of 2026-09-23, not recorded
  before that.
- From a Release build with code coverage off (`make build`); the Xcode scheme
  otherwise instruments Release builds.
- Headless (`--benchmark`, `--render`, `--test-tiles`), so no window, display
  sync or UI work competes.
- Medians after discarded warm-up runs, with ranges where they matter.
- For before/after comparisons, both commits built and run interleaved in one
  session, so they share machine conditions.

Traps found the hard way:

- **GPU clock.** The M1 Pro GPU raises its clock only under sustained load. A
  sub-millisecond kernel separated by CPU work can run at about a third of full
  clock for dozens of runs, then switch part-way through a series, so a median
  of such a series measures the clock state, not the kernel. Render a larger
  primer size first in the same process (`--sizes PRIMER,SIZE`), take enough
  runs, and report the spread: a 10–90% spread above about 10% means the clock
  moved. Heavier kernels (FloatFloat at 4 ms and above, perturbation) are
  stable without priming. Comparisons before 2026-09-23 that used a few
  sub-millisecond GPU runs from a fresh process may be affected.
- **`powermetrics` residency is not kernel time.** It reported the GPU 96%
  active at its top clock while the tile worker's command buffers were
  executing for about a tenth of the time. Sum `gpuEndTime − gpuStartTime`
  over command buffers instead.
- **Other load.** A running copy of the app or the iOS simulator, or other
  work on the machine, can slow a run two to four times. On 2026-09-23 one
  `--test-tiles` run failed a timing check this way and twelve interleaved
  reruns passed.
- **Causes.** Isolate the variable before recording why something got faster or
  slower; see the correction in [1.2 follow-up](#12-follow-up-strict-float-math-cost).

## How to measure

### Headless benchmarks

Build the Release app (`make build` does this), then invoke its executable
directly with `--benchmark`.
This selects the command-line entry point before SwiftUI starts; no window is opened.

```sh
xcodebuild -project Mandelbrot.xcodeproj -scheme Mandelbrot \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath /tmp/mandelbrot-development CODE_SIGNING_ALLOWED=NO ENABLE_CODE_COVERAGE=NO build

/tmp/mandelbrot-development/Build/Products/Release/Mandelbrot.app/Contents/MacOS/Mandelbrot \
  --benchmark --variants baseline,parallel,metal \
  --sizes 1024x512,2048x1024 --iterations 200 --warmup 1 --runs 3
```

Use `--format json` to capture machine-readable results, including the viewport, each measured
sample, median seconds, and megapixels per second. The default output is Markdown.
`--help` lists all options; `--variants all` selects every renderer the chosen
pipeline supports (ten exist, including FloatFloat `metal-double` and
`perturbation`). CPU-only runs can select
`--variants baseline,parallel` without requiring a Metal device.

The default sizes are fixed for repeatability, rather than the GUI's adaptive size
selection. Runs default to center (-0.5, 0) and scale 1; `--center-real`,
`--center-imag`, and `--scale` select another viewport. Block size is always 1. As in the GUI,
timings cover both iteration computation and CPU colorization, including allocations
and GPU synchronization; they are not isolated kernel timings. Each renderer/size
gets its own untimed warmups, followed by measured runs using a monotonic clock.
Zero warmups includes first-use setup costs in the first measured sample.

The process exits with status 0 on success, 2 for invalid options, and 1 if a
renderer fails (including unavailable Metal). Diagnostics go to stderr. The legacy
path limits iterations to 65,535, the width of its count buffers; `--pipeline gpu`
and `--pipeline tiles` accept up to 1,000,000. Sizes are limited to 16,384 per
dimension and 33,554,432 pixels in total. Run without `--benchmark` to open the GUI
normally. Use Release builds with `ENABLE_CODE_COVERAGE=NO` for performance comparisons;
the Xcode scheme otherwise enables coverage instrumentation even in Release.

Run the headless CLI integration checks against a built executable with:

```sh
python3 tests/test_headless.py \
  /tmp/mandelbrot-development/Build/Products/Release/Mandelbrot.app/Contents/MacOS/Mandelbrot
```

These checks use CPU renderers so they can run without GPU access.
Set `MANDELBROT_TEST_METAL=1` to also run the deep-zoom accuracy regression against
CPU Double. This requires GPU access and checks square and non-square viewports.

### PNG export and raw samples

`--render` exports a single full-resolution PNG without opening a window. For example:

```sh
/tmp/mandelbrot-development/Build/Products/Release/Mandelbrot.app/Contents/MacOS/Mandelbrot \
  --render --renderer metal-double --size 512x512 \
  --center-real -0.743643987037151 --center-imag 0.13182597420533 \
  --scale 10000000 --iterations 2000 --output floatfloat.png
```

Horizontal span is `3 / scale`; vertical span follows the image aspect ratio.
The real coordinate increases left to right; the imaginary coordinate increases
bottom to top. Center coordinates must be in [-4, 4], and scale in [1e-6, 2^13000]; scales
beyond 1e14 need the perturbation renderer.
These bounds are input limits, not a promise of adequate precision at every zoom.
Image dimensions and iteration limits use the same validation as benchmarks.
`--counts counts.u16` optionally exports raw iteration counts as little-endian
UInt16 values in row-major order, starting at the top-left pixel. No header is
included; use the requested image dimensions to interpret them. Parent output
directories must already exist. PNG writing is excluded from benchmark timings.

Benchmark the exact same viewport by replacing the render/output options:

```sh
/tmp/mandelbrot-development/Build/Products/Release/Mandelbrot.app/Contents/MacOS/Mandelbrot \
  --benchmark --variants all --sizes 512x512,1024x1024 \
  --center-real -0.743643987037151 --center-imag 0.13182597420533 \
  --scale 10000000 --iterations 2000 --warmup 1 --runs 5 --format json
```

See [the FloatFloat investigation](evidence/floatfloat/README.md) for before/after
images, raw measurements, accuracy comparisons, and reproduction instructions.

### GPU zoom-depth suite

`tests/benchmark_gpu_depths.py` runs eight headless GPU cases: Float at 30× and
1000×, FloatFloat at 1e7, and Perturbation at 1e100. Each depth uses two
iteration caps. Before timing a case, the script exports raw sample records and
requires both capped and escaped pixels, so an accidentally trivial viewport
fails the suite; `--compare` also fails if any capped or escaped total differs
from an earlier results file. Light cases render a primer size with 16× the
pixels first in the same process, then 30 runs after 5 warm-ups, and the
suite reports each case's 10–90% spread (see [Method](#method)). Run it against
a Release app with:

```sh
python3 tests/benchmark_gpu_depths.py \
  /tmp/mandelbrot-development/Build/Products/Release/Mandelbrot.app/Contents/MacOS/Mandelbrot \
  --output /tmp/gpu-depths.json [--compare earlier.json]
```

### Tile renders

`--render --pipeline tiles` renders through the same tile store, worker and
compositor as the viewer. `--test-tiles` runs the tile integration checks and
prints their timings and counters as JSON; `tests/measure_tiles.py APP STAGE`
repeats it five times and saves the runs under `evidence/product`.

The ready times, summed kernel times and batch counts in the tile batching
entries came from a small measurement patch applied identically to every build
compared, not from a committed option: it printed the time from `update` to
`waitUntilReady`, and summed each tile batch's `gpuEndTime − gpuStartTime`.

## Not yet measured

- **Phones.** Frame pacing at 60 Hz (iPhone 11 Pro) and 120 Hz (iPhone 16 Pro),
  heat and throttling over a session, peak memory and idle energy (plan 2.15).
  Every measurement here is from the Mac.
- **Frame pacing under heavy refinement.** Tile batches of up to 4 ms since
  `f855bf5`; the compositor trace in `--test-tiles` refines too lightly to test
  it, and does not measure how long a frame waits to start.
- **Cold jumps in the viewer.** The tile batching gains are measured through the
  CLI, whose main actor has nothing else to do.
- **Cross-device image tolerances.** The product goldens' budgets were set on
  one Mac ([independent product image
  validation](#review-independent-product-image-validation)).
- **What a minibrot movie keyframe costs**, split into reference, BLA
  preparation and GPU time ([2.8](#28-zoom-movies)).
- **A Boost reference backend in the product** (plan 2.16); only the library
  comparison has been measured.

## Log

### Phase 1: CPU renderer experiments

*Plans 2026-01-21 · `e8d5ae6`; results 2026-01-23 · `1ea897c`*

The first experiments, on the original CPU renderer. Each variant changed one
aspect of the hot path, the iteration loop and block fill in
`MandelbrotRenderer.iterations`, so that its effect could be isolated:

- `scalar-tight`: a `for` loop with cached squares.
- `coord-precompute`: step sizes computed once, multiply-adds instead of a
  division per block.
- `unsafe-buffer`: raw-pointer writes with precomputed row offsets.
- `float-math`: `Float` instead of `Double`.
- `parallel`: the outer row loop spread over cores with
  `DispatchQueue.concurrentPerform`.
- `simd4-float`: four points per iteration with `SIMD4<Float>`.

| Variant          | 1024×512             | 2048×1024            | 4096×2048            | 8192×4096            |
| ---------------- | -------------------- | -------------------- | -------------------- | -------------------- |
| baseline         | 0.121s / 4.32 Mpx/s  | 0.476s / 4.41 Mpx/s  | 1.901s / 4.41 Mpx/s  | 7.524s / 4.46 Mpx/s  |
| scalar-tight     | 0.121s / 4.33 Mpx/s  | 0.470s / 4.47 Mpx/s  | 1.876s / 4.47 Mpx/s  | 7.487s / 4.48 Mpx/s  |
| coord-precompute | 0.127s / 4.13 Mpx/s  | 0.468s / 4.48 Mpx/s  | 1.870s / 4.48 Mpx/s  | 7.463s / 4.50 Mpx/s  |
| unsafe-buffer    | 0.123s / 4.25 Mpx/s  | 0.470s / 4.46 Mpx/s  | 1.863s / 4.50 Mpx/s  | 7.459s / 4.50 Mpx/s  |
| float-math       | 0.123s / 4.28 Mpx/s  | 0.471s / 4.45 Mpx/s  | 1.883s / 4.46 Mpx/s  | 7.491s / 4.48 Mpx/s  |
| parallel         | 0.022s / 23.84 Mpx/s | 0.072s / 29.25 Mpx/s | 0.282s / 29.78 Mpx/s | 1.114s / 30.12 Mpx/s |
| simd4-float      | 0.136s / 3.85 Mpx/s  | 0.533s / 3.93 Mpx/s  | 2.108s / 3.98 Mpx/s  | 8.424s / 3.98 Mpx/s  |

Only parallelism mattered: 6.8× at the largest size. The scalar changes and
`Float` stayed within 5% of the baseline, and `simd4-float` was about 12% slower.

### 1.2 follow-up: strict Float math cost

*2026-09-14 · `a166385`; correction 2026-09-18 · `194ce15`*

The controlled `evidence/floatfloat/benchmarks-{before,after}.json` measurements
at scale 1e7 show the Float kernel's end-to-end cost increasing from 8.907 ms to
9.660 ms at 512² (+8.5%), and 31.784 ms to 35.390 ms at 1024² (+11.3%). These are
whole-image timings, including CPU colour conversion, not isolated GPU timings.
Corrected FloatFloat costs 104.593 ms at 1024² versus 35.664 ms for the incorrect
shader. Precision is required; keep safe math enabled. CPU-precomputed FloatFloat
coordinates will be introduced with the shared GPU pipeline, with new measurements,
rather than adding a second temporary parameter layout to the legacy lab kernels.

**Correction (2026-09-18): the cause above was misattributed.** The Float kernel
did slow by roughly that amount, but `MTL_FAST_MATH=NO` was not why. Measured in
isolation, `-fno-fast-math` is *faster* for this kernel, not slower: 64.6 ms
versus 74.5 ms at 3456×2234, scale 200, 1,000 iterations. Safe math costs nothing
here.

The real cause was a file-scope `#pragma clang fp contract(off)`. It sat in
`FloatFloat.h` above the `dd_*` helpers, and that header is included at the top
of `MandelbrotCompute.metal`, `GPUCompute.metal` and `Perturbation.metal` — so it
disabled multiply-add contraction for every plain Float kernel in those files,
none of which needs it. `MandelbrotCompute.metal` carried a second, redundant
copy of the same pragma.

Confirmed by bisecting Feb (`1c02a1c`) against HEAD: swapping the two metallibs
between the two Swift binaries moved the cost with the shader and not at all with
the Swift, and the Float kernel source is byte-identical across the two versions.
Contraction is now disabled per function inside the `dd_*` bodies instead, so the
error-free transforms keep the semantics they need while the Float paths get
their multiply-adds back.

Measured after the fix, GPU compute only, 3456×2234, interleaved best-of-15:

| Case                    |      Feb | Before fix | After fix |
| ----------------------- | -------: | ---------: | --------: |
| scale 1, 1,000 iter     |  34.7 ms |    36.7 ms |   30.8 ms |
| scale 200, 1,000 iter   |  96.1 ms |   107.1 ms |   88.5 ms |
| scale 5,000, 5,000 iter | 419.6 ms |   448.9 ms |  358.2 ms |
| scale 1, 20,000 iter    | 537.1 ms |   573.5 ms |  443.0 ms |

That is 16–23% faster than before the fix and 8–17% faster than February. These
absolutes were taken on a thermally loaded machine and run high; the interleaved
ratios are the meaningful part. The product pipeline (`--pipeline gpu --timing
kernel`) improved about 10% on best-of-three at both 1,000 and 20,000 iterations.

The lesson is procedural: this doc's predicted cost and the observed cost matched
in size, which is why a real bug sat behind a plausible explanation for months.
Isolate the variable before recording a cause.

### 1.4: GPU-resident product pipeline

*2026-09-14 · `00cc5ad`*

M1 Pro, Release, coverage disabled, same 1e7 viewport and 2000 iterations as the
FloatFloat investigation; median of five samples after one warmup. Raw samples:
`evidence/product/1.4-gpu-pipeline.json`. Legacy counts and all four goldens pass.
CPU-precomputed FloatFloat coordinates remove per-pixel divisions. The product
viewer performs no image readback; MTKView samples the GPU colour texture.

| Scope      | Renderer     | 512² ms | 1024² ms |
| ---------- | ------------ | ------: | -------: |
| kernel     | metal        |   4.351 |   16.562 |
| kernel     | metal-double |  20.094 |   75.324 |
| end-to-end | metal        |   4.962 |   17.705 |
| end-to-end | metal-double |  20.656 |   76.025 |

Kernel time is the compute command buffer GPU duration; end-to-end includes
allocation, submission, computation and GPU colouring to a completed texture. It
excludes display synchronization and PNG readback. Use `--pipeline gpu --timing
kernel` or `--timing end-to-end`; the legacy lab path remains the default for
backward-compatible CLI comparisons.

### 1.5: smooth colouring and palettes

*2026-09-14 · `8c460b1`*

Same M1 Pro protocol and 1e7 viewport as 1.4. Smooth escape radius is 256
(squared threshold 65,536), with `n + 1 - log2(log2(|z|))`; negative sentinel -1
marks capped samples, and far-exterior smooth values are clamped at zero.
Seven periodic gradient LUTs include a constant-lightness/chroma OKLab wheel.
Palette, density and offset changes recolour retained samples without iteration work.
The independent smooth Double oracle and all legacy/product goldens pass.

| Scope      | Renderer     | 512² ms | 1024² ms |
| ---------- | ------------ | ------: | -------: |
| kernel     | metal        |   4.279 |   12.656 |
| kernel     | metal-double |  18.865 |   73.138 |
| end-to-end | metal        |   4.070 |   14.011 |
| end-to-end | metal-double |  19.945 |   73.523 |

Samples: `evidence/product/1.5-smooth-palettes.json`; PNG:
`evidence/product/smooth-blue-gold.png`. GPU rendering defaults to smooth colouring.
Use `--colouring legacy` for unchanged integer-count exports, or `--samples file.f32`
for float32 smooth samples. `--palette`, `--density`, and `--offset` control appearance.

### 1.8: frame-rate-independent navigation

*2026-09-14 · `ba7aa35`; revised the same day · `f478b40`*

Pan/zoom inertia integrates exponential decay analytically. The unit test compares
half a second of motion at 60 and 120 Hz: displacement and scale differ by less
than 1e-9. GPU presentation requests each screen's maximum refresh rate; the iPhone
ProMotion Info.plist opt-in was originally reported as enabled, incorrectly.
The review stabilisation pass adds an explicit iOS plist and checks the built app. This is configuration
and numerical validation, not a measured claim of 120 fps on a physical phone.
Both macOS tests and the iPhone/iPad simulator build pass. Physical testing on the
iPhone 11 Pro and iPhone 16 Pro remains necessary for touch feel and frame pacing.

### 2.1(a): fixed-level tile renderer

*2026-09-14 · `3d6a26b`*

The headless integration trace computes a 512×320 view, pans with overlap, and
changes palette. It verifies sample-texture reuse and no recomputation on palette
changes. Five isolated Release runs on M1 Pro: median trace 46.278 ms, maximum
observed GPU row-batch 0.237 ms, six cached tiles using 4,915,200 allocated bytes.
This includes readbacks used by assertions. Samples: `evidence/product/2.1a-tiles.json`.
Tiles have 256² interior samples plus a one-sample gutter for seam-free filtering.
The first stage deliberately holds the selected level fixed for panning; multilevel
fallback is the next stage. `--render --pipeline tiles` exercises the compositor
without opening a window. `make test` includes its headless integration checks.

### 2.1(b): multilevel fallback

*2026-09-14 · `d8124e0`*

The trace now includes a zoom snapshot taken before refinement finishes. A magenta
clear sentinel detects uncovered pixels: zero holes in every run. Median complete
trace: 173.095 ms; maximum observed GPU batch:
0.370 ms. This longer trace is not directly comparable to stage (a).
Samples: `evidence/product/2.1b-parent-fallback.json`. Coarse tiles precede fine tiles;
one ancestor lookup per screen cell avoids drawing every ancestor over the screen.
Anchor rebasing retains previous coverage while replacement tiles are computed.

### 2.1(c): level blending and refinement fades

*2026-09-14 · `975f832`*

The same pan/palette/zoom trace now uses the three-source colour compositor.
Five M1 Pro runs: median 134.249 ms, longest compute batch 0.641 ms.
Raw runs: `evidence/product/2.1c-blending.json`. This is offscreen integration
time, not a measurement of display refresh rate. `make test` passes, including
an actual GPU render with known coarse/base/fine colours and blend weights.

### 2.1(d): bounded refinement, mipmaps and LRU cache

*2026-09-14 · `bd79b39`*

*The deep refinement figures are superseded by [Review stabilisation](#review-stabilisation-final-measurements).*

Five isolated Release runs on Apple M1 Pro, using `tests/measure_tiles.py`. Raw
results: `evidence/product/2.1d-cache.json`. All numerical and cache assertions
passed. The trace now adds 40 fractional-zoom frames with 8 ms sleeps while
refinement/prefetch run, so its 487.619 ms median duration is deliberately not a
speed comparison with earlier traces.

| Measurement                                           |       Result |
| ----------------------------------------------------- | -----------: |
| Median per-run p95 compositor GPU duration            |     0.250 ms |
| Worst compositor GPU duration across runs             |     1.339 ms |
| Worst ordinary refinement batch                       |     1.432 ms |
| Cold 1e10 refinement, 256², 4,000 iterations (median) | 1,488.170 ms |
| Worst batch during that deep refinement               |     2.370 ms |
| Resident cache after animated trace                   | 101.5625 MiB |
| Resident cache after deep refinement                  |  115.625 MiB |

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

### Uniform threadgroup compatibility fix

*2026-09-14 · `c555ec4`*

All three dispatch sites now use `dispatchThreadgroups` with rounded-up group
counts. Kernels reject padded threads before reading or writing memory. This
removes the unsupported non-uniform-dispatch feature requirement from the viewer
and both legacy Metal benchmark renderers.

`make test` and `make ios` pass, including odd-sized legacy exports, 66×53
resumption comparisons and all 258×258 tile/colour/mipmap kernels. Five M1 Pro
traces are in `evidence/product/uniform-dispatch.json`: median trace 483.178 ms, median per-run p95 compositor GPU duration 0.377 ms, worst deep-refinement GPU batch 2.564 ms. These are host measurements; the device that reported the assertion still needs a rebuilt-app run.

### Review: local ancestor scheduling

*2026-09-14 · `a698104`*

Five M1 Pro traces (`evidence/product/review-local-levels.json`), now using the
iPhone 150 MiB budget for the 1e10 deep test. The requested LOD is preserved.
- deepUsefulMS: median 66.733
- deepRefinementMS: median 174.541
- deepResidentBytes: median 9830400.000

Only the visible level and two nearby ancestors are required. Distant cached
ancestors remain eligible for LRU reuse. This replaces 148 required deep tiles
with 12 (9.375 MiB), without raising the budget or changing precision.

### Review: iteration-change continuity

*2026-09-14 · `48a820c`*

Old detailed tiles survive repeated iteration changes until replacement detail
has completed its 125 ms fade. Both base and fine colours can blend against
the previous generation. The regression compares the pre-change and immediate
post-change PNG pixels exactly, then checks final-generation metadata and cleanup.
Five M1 Pro traces: median per-run p95 compositor GPU time 0.144 ms; worst observed 0.773 ms. Raw: `evidence/product/review-fallback.json`.

### Review: immutable palette textures

*2026-09-14 · `80ca245`*

Seven lookup textures are created once during GPU initialisation, not once per
tile recolour. Identity checks and all palette/sample tests pass. Five M1 Pro
traces (`evidence/product/review-palette-cache.json`): median elapsed 467.361 ms. The trace includes fixed sleeps, so
this is a regression measurement rather than an isolated palette speedup claim.

### Review: event-driven drawing and demand

*2026-09-14 · `1c02681`*

Settled MTKViews pause; tile completion, appearance changes and navigation wake
them. Motion and unfinished fades sustain the display timer. Unchanged demand
returns before rebuilding sets or touching LRU state; eviction sorts only under
pressure. GPU frame statistics sort at 4 Hz, not every frame. A regression
sends 120 unchanged updates and verifies no work or notifications are created.
Five M1 Pro traces (`evidence/product/review-demand.json`): median last measured
demand update 0.028 ms. The hardware HUD now measures recent drawable presentation cadence separately
from GPU duration. Simulator Metal does not expose presentation timestamps.
Actual phone idle energy use and display pacing still require device measurement.

### Review: independent product image validation

*2026-09-14 · `2f7936a`*

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

### Review stabilisation: final measurements

*2026-09-14 · `f5c9b0d`*

Five isolated M1 Pro runs: `evidence/product/review-final.json`. Deep rendering
uses 256², scale 1e10, 4,000 iterations and the iOS 150 MiB cache budget.

| Measurement                             |     Result |
| --------------------------------------- | ---------: |
| Useful deep coverage, median            |  71.333 ms |
| Complete deep detail, median            | 161.353 ms |
| Deep resident cache                     |  9.375 MiB |
| Deep GPU batch, worst observed          |   2.066 ms |
| Compositor p95, median of runs          |   0.315 ms |
| Compositor GPU duration, worst observed |   0.888 ms |
| Last demand update, median of runs      |   0.032 ms |

The earlier deep path took 1,488.170 ms and retained 115.625 MiB on Mac;
under the phone budget it also reduced sampling detail. The new regression
requires the requested LOD to survive. Frame statistics now flush their final
window when work settles, and preserve the worst observed GPU duration.
The input display link/timer is paused or absent for GPU rendering and idle CPU
rendering. These are implementation and offscreen measurements, not claims of
measured phone battery savings or sustained 120 fps. Both iOS build targets
verify the generated ProMotion boolean; `make test` and `make format-check` pass.

### 2.2a — reference arithmetic library spike

*2026-09-14 · `269be3d`*

On the M1 Pro, Release Swift `-O` and Apple Clang `-O3`, five runs of 10 ×
1,000 bounded reference iterations gave these median times:

| Zoom precision |  Bits | Swift BigInt fixed point | Boost cpp_bin_float |
| -------------- | ----: | -----------------------: | ------------------: |
| 1e100          |   397 |                33.075 ms |            6.240 ms |
| 1e1000         | 3,386 |               864.733 ms |           68.952 ms |

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

### 2.2b — validated GPU perturbation before BLA

*2026-09-14 · `9609e31`*

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

### 2.2c — BLA and shared tile references

*2026-09-14 · `eafab88`*

Controlled BLA on/off comparison on the M1 Pro: centre c=i, 256×192,
5,000 iterations, median of three runs after one warmup. End-to-end includes
fresh CPU reference creation, BLA preparation and completed GPU colour output;
it excludes readback and PNG encoding. Full-image runs do not reuse references.

| Scale  | BLA off, total | BLA on, total |    GPU off |    GPU on |
| ------ | -------------: | ------------: | ---------: | --------: |
| 1e50   |      17.481 ms |     14.422 ms |  12.867 ms | 10.444 ms |
| 1e200  |      55.531 ms |     25.916 ms |  41.604 ms | 17.758 ms |
| 1e1000 |     400.274 ms |    141.457 ms | 239.611 ms | 30.194 ms |

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

### Deep-zoom review: rebase first and harder goldens

*2026-09-14 · `5a51512`*

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

### Deep-zoom review: reusable references

*2026-09-14 · `aded6cc`*

References now use 256-bit precision bands and satisfy shorter/lower-precision
requests without recomputation. The cache is owned by the tile worker, budgeted
from its device allowance, and accepts a nearby viewport-centred reference within
four tile widths. It is independent of the grid indexing anchor. Full-image
benchmarks still create fresh references, preserving the earlier comparison scope.
Unit tests verify one computation for concurrent 400/401-bit requests, reuse at
402 bits and a shorter iteration limit, and a new computation above the 512-bit
band. Product tests verify scratch-buffer identity reuse and unchanged hard-image
error budgets. Miss computation no longer blocks unrelated actor cache hits.

### Deep-zoom review: CPU drawing geometry

*2026-09-14 · `aa304b7`*

Same-anchor UVs and cell positions now use integer keys, bounds are cached, and
one nearby tile origin is converted from high precision per frame. A 120-frame
settled 1e1000 integration run on the M1 Pro measured CPU compositor preparation
p95 **0.016 ms**, maximum **0.033 ms**. These measure encoding/preparation, not
GPU execution or total UI frame time. Raw counters are in
`evidence/review-deep/geometry.json`; the HUD now separates CPU draw preparation,
demand updates and GPU time. The iPhone 16 Pro is listed as unavailable by
`devicectl`, and no iPhone 11 Pro is connected, so phone timings remain unmeasured.

### Deep-zoom review: hierarchical BLA

*2026-09-14 · `d946115`*

*Timings superseded by [Final review validation](#final-review-validation), then by [streamed reference latency](#follow-up-review-streamed-reference-latency).*

M1 Pro, 64×48, median of three runs after one warmup, including fresh CPU
reference generation, BLA preparation and completed GPU colouring (no readback):

| Location                                      |   BLA off |  Fixed 32 | Hierarchy | Longest applied jump |
| --------------------------------------------- | --------: | --------: | --------: | -------------------: |
| c=i, 1e1000, 5,000 iterations                 | 158.94 ms | 114.14 ms | 107.98 ms |                2,048 |
| period-312 minibrot, 1e100, 60,000 iterations | 735.11 ms | 440.05 ms | 434.44 ms |               16,384 |

Raw data: `evidence/review-deep/hierarchy.json`. Run
`python3 tests/precision/measure_review.py APP hierarchy` to reproduce all three
modes. This replaces the theoretical 32-step ceiling with actual long jumps;
the end-to-end gain over fixed blocks is modest because reference construction
and the non-skippable part of the orbit still cost time.

The hierarchy retains extended-range coefficients throughout construction. A
synthetic test merges a coefficient beyond Double's exponent range and verifies
its positive, similarly extended validity radius. Five guard bits per merge
level reserve accumulated-error margin. This was necessary to pass the tiled
minibrot oracle without relaxing its tolerance: maximum PNG error is 8/255.
The full-frame minibrot test passes off/fixed/on; hierarchical maximum smooth
sample error is 207.35 with seven colour-boundary outliers out of 192 pixels.
These finite-precision boundary errors remain covered by the previously declared
budgets, rather than being presented as exact agreement.

### Deep-zoom review: iteration depth and smooth precision

*2026-09-14 · `9d8bc8b`*

Product GPU rendering now supports one million iterations, with an exact UInt32
escape count and a separate Float32 correction in each eight-byte raw record.
An integration test supplies counts near one million with corrections 0.003 and
0.02: these collapse to the same combined Float, but the GPU now produces distinct
colours matching an independent Double/LUT calculation within one byte. A real
100,000-iteration CLI render also verifies escaped and capped record exports.
Legacy UInt16 rendering and exports remain limited to 65,535.

The viewer defaults to the plan's depth-based estimate, with a detail multiplier,
10%/200-step increase hysteresis, and decreases delayed until 300 ms after input
and motion stop. Manual controls share the one-million cap. This is only the
first estimate from 2.3: periodicity, pixel-driven adaptation and selective
extension remain future work. Large bounded references can still take time;
preparation remains cancellable and shared between nearby tiles.

All existing numerical and product image budgets still pass. Reference cache
accounting now includes array capacity, and an early-escaping million-iteration
request no longer reserves a million reference entries. The mip/palette test's
cache increases from 40 to 64 MiB to keep complete sibling groups resident with
the larger raw records; separate constrained-cache and eviction tests remain.

### Deep-zoom review: reproducible library decision

*2026-09-14 · `4e0a014`*

`python3 tests/precision/reproduce.py` fetches the pinned Boost 1.90 repositories,
verifies clean revisions, and builds both comparisons. Swift now explicitly uses
`-O -whole-module-optimization`, matching the app's Release compilation mode;
C++ uses `-O3`. This is a different Swift compilation mode from the historical
arithmetic-only numbers above. Raw five-run results and pins are in
`evidence/review-deep/libraries.json`.

Saved-reference generation at the exact period-312 minibrot fixture, cap 60,000:

| Precision | Swift median | Boost median | Swift / Boost orbit length | Per-iteration speedup |
| --------- | -----------: | -----------: | -------------------------: | --------------------: |
| 461 bits  |    112.04 ms |     20.92 ms |            32,789 / 32,205 |                 5.26× |
| 512 bits  |    135.49 ms |     23.84 ms |            37,280 / 37,251 |                 5.68× |

Both include saving FloatFloat mantissas with separate exponents. Different
rounding changes these chaotic escape lengths, so the last column normalises
by actual stored length. The original arithmetic workload also favours Boost:
about 5.0× at 100 digits and 8.9× at 1,000 digits with whole-module optimisation.

Decision: retain the validated Swift backend for this review, but treat a Boost
reference backend as a worthwhile follow-up for cold deep views, not a speculative
micro-optimisation. In the hierarchy benchmark the minibrot spends about 83 ms
preparing its reference and 280 ms on the GPU; cache hits remove reference work
entirely, so a library change will not multiply steady-state product throughput
by the arithmetic speedup. The c=i cold render remains reference-dominated, and
higher iteration limits make that latency more important. A backend replacement
needs the same hard numerical/tiled goldens, cancellation and cache tests, plus
measurements on iPhone 11 Pro and iPhone 16 Pro. Neither phone was available in
this session; no on-device frame-rate claim is made.

### Final review validation

*2026-09-14 · `4e0a014`*

*Timings superseded by [streamed reference latency](#follow-up-review-streamed-reference-latency).*

Final M1 Pro runs after separate sample storage, same 64×48 scenes, median of
three measured runs after one warmup, fresh references, completed GPU colour:

| Location                           |   BLA off |  Fixed 32 | Hierarchy |
| ---------------------------------- | --------: | --------: | --------: |
| c=i, 1e1000, 5,000 iterations      | 176.77 ms | 118.66 ms | 112.58 ms |
| minibrot, 1e100, 60,000 iterations | 791.34 ms | 476.73 ms | 489.47 ms |

`evidence/review-deep/final.json` includes every timing and component counter.
The hierarchy is about 1.6× faster than BLA off in both scenes. It improves the
c=i GPU portion from 9.09 to 5.45 ms compared with fixed blocks; at the minibrot,
fixed/hierarchical end-to-end timings are similar and their three-run ranges
overlap. Long jumps alone do not establish an end-to-end win over fixed blocks
there. The earlier stage measurements above remain historical evidence.

The final 120-frame deep CPU preparation p95 is 0.021 ms, maximum 0.032 ms, on
this Mac. These are CPU compositor timings, not phone FPS. Full tile counters,
including 27 reference cache hits, are in `evidence/review-deep/final-tiles.json`.
A separate 1024×2048 render records **5,430,400,581 skipped iterations** in
`counter64.json`, exercising the widened counter. That large full-frame command
is a counter test, not a claim about the product's tile batch latency.

Final images: [minibrot, full GPU](evidence/review-deep/final-gpu.png) and
[independent-golden-sized tiled output](evidence/review-deep/final-tiles.png).
All existing error budgets pass, including maximum 8/255 error on the hard tiled
PNG. Mac tests, strict formatting, iOS Simulator and physical-target builds pass;
both iOS builds include the verified MIT notice. Neither target phone was available
for actual frame-pacing measurements.

### Follow-up review: automatic depth without cache resets

*2026-09-14 · `20161ce`*

The cache now retains iteration-labelled raw samples. Lowering the limit performs
colour/mip work but no orbit sampling; returning to an already computed higher
limit also requires no sampling. Increasing beyond stored detail recomputes only
capped pixels, preserving escaped records byte-for-byte. Fully escaped tiles need
no extension. State remains worker-local; capped pixels restart rather than
retaining a roughly 3 MiB perturbation buffer for each cached tile.

The integration fixture sampled **zero pixels** on a decrease and return, and
**820 capped pixels** on the next increase. A 201-view 1×–1e30–1× navigation trace
sampled 27,424,368 pixels with a fixed limit and 27,427,626 with automatic limits.
This trace deliberately uses an outside-set location to isolate cache behaviour;
non-flat seahorse, deep c=i and minibrot tests separately check rendering accuracy.
Returns from 1e12 and 1e1000 both rebuilt the same two shallow tiles as a fresh
session, cleared deep anchors/bounds and released cached deep reference storage.
Raw observations are in `evidence/followup/navigation.txt` and
`evidence/followup/tile-validation.json`; timings are observations, not CI limits.

### Follow-up review: streamed reference latency

*2026-09-14 · `20161ce`*

At c=i and 1e1000, the automatic policy selects 266,000 iterations. The earlier
reference-only experiment measured 0.91–0.99 seconds to prepare that complete
orbit on this M1 Pro (about 17 ms for 5,000), rather than the review's extrapolated
five seconds. Those measurements excluded tile rendering.

References now save their final BigInt state and grow only when GPU pixels reach
the available prefix. Extensions match one-shot packed orbit values exactly.
Initial prefixes contain at most 4,097 iterations, aligned to BLA leaves; a
paused frontier does not trigger a rebase or reset pixel state.

Three isolated cold product runs at the actual automatic limit produced:

| Measurement              |    Median |                 Range |
| ------------------------ | --------: | --------------------: |
| First deep tile ready    |  41.51 ms |        41.19–48.76 ms |
| All required tiles ready | 233.20 ms |      227.25–275.26 ms |
| Reference values needed  |     4,098 | identical in all runs |

Run `APP --benchmark-reference`, or
`python3 tests/precision/measure_followup.py APP` to record all runs and images.
These measure readiness after GPU-context initialisation, not display presentation
or physical-phone frame pacing. Raw data: `evidence/followup/measurements.json`.

Comparable fresh full-image runs (64×48, three runs after one warmup, reference
preparation and GPU colour included) now measure:

| Location                           |   BLA off | Fixed 32-step blocks | Hierarchy |
| ---------------------------------- | --------: | -------------------: | --------: |
| c=i, 1e1000, 5,000 iterations      | 158.90 ms |            107.97 ms | 108.62 ms |
| minibrot, 1e100, 60,000 iterations | 702.51 ms |            426.91 ms | 432.36 ms |

The last two columns are similar here; there is no claim of an end-to-end
hierarchy win. Both use the production compounded radius. Raw data and component
timings are in `evidence/review-deep/followup.json`.

### Follow-up review: BLA margin decision

*2026-09-14 · `20161ce`*

`make bla` now runs 440 isolated GPU jump cases against ordinary GPU recurrence
and independent 180-digit Decimal recurrence, using the same packed reference
and starting values. Cases include zero deltas and 12.5%, 50% and 99% of the
validity radius, with lengths through 16,384. Errors are normalised by the larger
of the final magnitude and the sum of the two linear output-term magnitudes,
so cancellation does not create misleading relative errors.

| Scene/policy             | Largest BLA-vs-Decimal error | Largest ordinary-GPU-vs-Decimal error |
| ------------------------ | ---------------------------: | ------------------------------------: |
| c=i, compound            |                     1.31e-14 |                              1.35e-14 |
| c=i, fixed per jump      |                     2.39e-15 |                              1.35e-14 |
| minibrot, compound       |                     5.99e-14 |                              9.01e-13 |
| minibrot, fixed per jump |                     7.35e-15 |                              1.11e-12 |

The strict test limits are 1e-12 for BLA versus Decimal and 1e-10 for ordinary
recurrence and BLA-versus-ordinary differences. Raw results are in
`evidence/followup/bla-errors.json`. These tests measure individual jumps, not
claims of a universal error bound or cancellation of chaotic final-orbit error.

A fixed five-bit allowance per jump therefore passes local validation, but fails
the existing independent tiled minibrot golden: maximum colour error **33/255**,
five outlier pixels, mean channel error **1.172**. The existing requirements are
maximum 12, at most 5% outliers and mean below 1. The production policy gives
maximum **8/255**, one outlier and mean **0.198**. Images:
[production](evidence/followup/minibrot-compound.png),
[fixed-margin candidate](evidence/followup/minibrot-fixed.png).

Decision: retain the production compounded margin, expose `--bla-radius fixed`
for reproducible experiments, and keep both the strict local tests and unchanged
image budgets. This does not establish that compounding is mathematically
necessary; it records why this candidate has not been promoted. No further
margin was tuned against those boundary pixels. The underlying BLA equations
remain based on [the original derivation](https://mathr.co.uk/blog/2022-02-21_deep_zoom_theory_and_practice_again.html).

Final `make test`, `make format-check`, `make ios` and `make ios-device` pass.
Neither target phone was available: devicectl lists the iPhone 16 Pro as unavailable
and no iPhone 11 Pro. Actual device validation remains outstanding.

### 2.4 coverage: sized ladder and realistic budgets

*2026-09-17 · `1166035`; revised 2026-09-18 · `c7f5e5a`*

Measured headlessly on the Apple M1 Pro with `make tiles`, with each device's real
budget. Drawables: phone 1206×2622 at 150 MiB, Mac 3456×2234 at 500 MiB. Each
scene zooms in 1.12× per step for 48 steps, then settles.

Each zoom-out offset now uses the finest level at or below quarter resolution
whose projected view fits a few tiles: 6 for offsets 1–2, otherwise 4.
Quarter resolution needed 6–18 tiles per offset on a phone and 20–35 on this
Mac display. The sparse tail is 16…512 levels. Projections stop at the viewport's
minimum scale. The coverage cap is a tenth of the budget (at least 30 MiB, and
never more than the bytes left after the detail band). When choosing detail, the
store reserves room for the root and offsets 1–2.

| Settled scene  | Coverage bytes available | Near offsets planned | Sparse offsets planned |
| -------------- | -----------------------: | -------------------: | ---------------------: |
| phone, shallow |                   10 MiB |    2 of 8, plus root |          1 (offset 15) |
| phone, 1e1000  |                   30 MiB |               5 of 8 |                 0 of 6 |
| Mac, shallow   |                   50 MiB |    8 of 8, plus root |          1 (offset 15) |
| Mac, 1e1000    |                   50 MiB |               8 of 8 |                 2 of 6 |

A shallow view reaches its minimum scale a few levels out, so its sparse tail
collapses to the single rung that still fits inside the bounds — offset 15 in both
shallow runs. The deep rows keep the full 16…512 tail.

On a phone, a full-resolution view uses almost all of the resident limit, so
only the root and the 2–4× zoom-out are guaranteed. The test asserts exactly that;
on the Mac it asserts the full near ladder. The chosen levels sit 3–4 levels below
the detail level, so they are placeholders at 1/8–1/16 resolution.

Cold jumps at 1024×768, 5,000 iterations, best of two runs per mode in the same
process:

| Cold jump   | Visible view ready, with coverage | Without coverage |
| ----------- | --------------------------------: | ---------------: |
| c=i, 1e100  |                          783.8 ms |         779.6 ms |
| c=i, 1e1000 |                          582.7 ms |         574.8 ms |

The test allows 25% + 30 ms. Moving at 1e1000 (1024×768, 120 frames alternating
zoom and pan, with the worker running): demand update p95 **0.49 ms** (limit 4 ms),
frame plan p95 **0.37 ms** (limit 2 ms).

### 2.3: observed ceiling and cheaper raises

*2026-09-17 · `89294f6`; revised 2026-09-18 · `c7f5e5a`*

Measured headlessly on the Apple M1 Pro with `make tiles`.

**Lowering from data.** Once every visible tile is complete, the viewer lowers
the automatic limit to twice the highest escaped count in view, if that count is
below a quarter of the limit. No escaped count lies between the highest observed
count and the limit, so this changes nothing on screen: the lowered store and a
fresh render at the lowered limit match to the byte. Counts reaching 1.5× those
the ceiling came from release it. Further zooming grows the ceiling at the
estimate's slope.

| View (256×192)     | Depth estimate | Highest escaped | Settled limit | Picture difference |
| ------------------ | -------------: | --------------: | ------------: | -----------------: |
| c=i, 1e1000        |        266,000 |           2,707 |         5,600 |              0/255 |
| empty space, 1024× |          1,000 |           < 100 |           200 |                  — |

The depth-only slope is unchanged at 80 per level. At c=i, 1e1000 it overshoots
about 100× (266,000 against about 2,700 needed). At the period-312 minibrot at
1e100 it undershoots (about 26,800 against up to 60,000). Raising from pixel data
needs periodicity checking (2.14).

**A changed limit repaints only what it can change.** Colour depends on counts,
and on the limit only to mark counts at or above it as capped, so moving the limit
between L1 and L2 can only change a pixel whose count lies between them. Both
directions now use that predicate, and `recolour` repaints record by record
against the same floor, rebuilding mipmaps only above the records it repainted.
The iteration diagnostic verifies both cases, that a raise without a recolour
matches a fresh render once fades settle, that a decrease repaints exactly the
records holding counts above the new limit, and that the observed ceiling's settle
at 1e1000 repaints none.

Previously every automatic raise recoloured every resident tile and rebuilt its
mipmaps first — about every 3 levels between 1e3 and 1e30, up to 500 MiB of tiles
on the Mac — and every *decrease* did so unconditionally. The observed ceiling
(2.3) made that fire on every settle at depth, where it provably changes nothing:
at 1e1000 the limit falls from 266,000 to 5,600 with the highest escaped count at
2,707.

The extension check previously ran at 64×48, where every needed tile was also
coverage and nothing was extended ("increase sampled 0 capped pixels"). At
256×192 it extends 14,536 capped pixels and verifies escaped samples are
unchanged.

### 2.8 Zoom movies

*2026-09-17 · `cbeb603`; table re-measured 2026-09-18 · `c7f5e5a`; frame borders 2026-09-18 · `a78ef64`*

Measured on the Apple M1 Pro with the CLI (`--movie`), which shares the viewer's
tile cache, compositor and encoder. Automatic depth per keyframe; HEVC. Every row
names its destination: the cost depends far more on what is at the bottom than on
how deep it is, so a row without one cannot be reproduced or compared.

| Movie                  | Destination               | Keyframes | Frames | Render time |    File |
| ---------------------- | ------------------------- | --------: | -----: | ----------: | ------: |
| 1280×720, 8 s, 30 fps  | Seahorse Valley, 4e3      |        13 |    240 |       2.6 s | 3.1 MiB |
| 1920×1080, 8 s, 30 fps | the point i, 1e12         |        41 |    240 |       9.6 s | 3.5 MiB |
| 640×360, 4 s, 30 fps   | period-312 minibrot, 1e30 |       101 |    120 |     1,236 s | 0.5 MiB |

The earlier numbers here (242.4 s to 1e12, 439.3 s to 1e30) named no destination
and are not reproducible: the 1e12 row's command takes 9.1 s at the very commit
they were recorded on, producing a byte-identical file. The rows above are today's
runs, at the current commit, with the destinations spelled out.

Frame composition is negligible: two textured quads and one encode per frame.
Essentially all of the time is keyframe rendering, and what a keyframe costs
depends on how much of it is interior. The descent to the point i is nearly all
exterior and escapes fast: 41 keyframes at 1080p in under 10 s. The descent into a
minibrot is interior almost to the last pixel, and costs 12 s per keyframe even at
640×360. Expect run-to-run variation of a few per cent on a laptop; repeats of the
1e30 row spanned 1,137–1,236 s.

**Keyframe depth: measured and left alone.** Bounding each keyframe's limit by
what the previous keyframe observed — the viewer's observed ceiling (2.3), carried
along the descent with twice the margin, re-derived every 16 levels and never
applied to the destination — was implemented, measured and removed. To the point i
it bounded 30 of 41 keyframes and gave back 59% of the summed iteration limit, for
about 6% of the wall clock; bounded keyframes were pixel-identical to renders at
the full estimate. On the minibrot descent, the case that actually takes 20
minutes, it bounded **0 of 101** keyframes: such a view always holds escaped counts
close to its limit, which is exactly when the ceiling must not engage. So the
limit is not what a deep movie spends its time on, and the cost of a keyframe is
not its iteration limit but its reference orbit and hierarchy. (That last point is
inferred, not measured. The only measured breakdown of this minibrot, at 1e100,
64×48 and 60,000 iterations in [the library decision](#deep-zoom-review-reproducible-library-decision),
found about 83 ms preparing the reference and 280 ms on the GPU.) The CLI now reports
`keyframeLimitSum`, which is the quantity any future depth policy has to move.

Periodicity checking (2.14) and the orbit follow-up below are the levers. A
shallow 720p movie is already quick.

Two follow-ups the numbers point at, both listed under 2.16: each keyframe
re-derives its reference orbit because the centre drifts between levels, so a
descent recomputes hundreds of orbits that differ slightly; and keyframes are
rendered strictly in order, so nothing overlaps the encode.

**Memory.** A render that is given no store makes one at the platform's own
budget: 500 MiB on macOS, and 96 MiB on iOS — two thirds of the viewer's 150 MiB,
since the viewer's own cache is alive behind the sheet. It was a flat 512 MiB with
no platform conditional, which on a phone was 3.4× the whole viewer budget asked
for on top of it, from a sheet the phone can open. iOS is no longer offered 4K (a
keyframe pair alone is 66 MB), and starting a render suspends the viewer's cache,
which is behind the sheet and wants the same GPU. A check renders a whole movie
through a 24 MiB store and holds it to its budget.

The headless check renders 320×180 at 30 fps, reads the file back with
AVAssetReader and compares the first and last frames against direct renders of
the start and end views: mean channel error **3.5/255** through HEVC compression
and the keyframe resampling.

**Frame borders.** A frame between two keyframes is up to twice as wide as the
deeper of them — 36% of its width lies outside that texture at the midpoint of an
interval — so the deeper keyframe's weight fades to zero as its sample leaves it,
rather than clamping and smearing its edge row across the band. The check picks
the frame whose blend is nearest a half and measures its outer 8% alone: **19.1
/255** before that fade, **5.5/255** after, against 3.3/255 for the whole frame.
It renders the triple spiral rather than the seahorse valley, whose border is a
smooth gradient that clamps to nearly the right colour and hid this.

### 2.11 follow-up: colouring in the compositor

*2026-09-23 · `7beff93`*

2.11 moved colouring from per-tile colour textures into the compositor, which
colours each level's samples as it draws, so a palette or depth mapping is a
uniform and never repaints the cache. Three things went wrong in that move,
found by `make tiles`, `make product` and `make deep`, which had failed since:

- **A one-texel stretch.** The shader read texel `uv × (size − 1)`, but the
  UVs put texel *i* at (*i* + 0.5)/size, so the right half of every tile was
  shifted by a sample. The minibrot product check was 189/255 out.
- **No filtering within a level.** Integer sample textures cannot use a
  sampler, and the shader read one sample where the colour textures had been
  bilinearly filtered. It now colours the four samples around a point and
  blends the colours, as before; the one-texel gutter keeps that continuous
  across tile edges.
- **Lost smooth shading at high counts.** Linear phase added the double-float
  halves before `fract`, and a float at a million cannot hold a correction of
  0.003. Only the high half is reduced now.

**Cost**, `--benchmark-compositor`, M1 Pro, 3456×2234, settled tiles, median
of 30 draws after 5 warm-ups:

| View                                      | 2.11 (one read) | Four reads, divide per sample | Four reads, divide per pixel |
| ----------------------------------------- | --------------: | ----------------------------: | ---------------------------: |
| Whole set, between levels, depth colour   |         1.21 ms |                       3.41 ms |                      2.19 ms |
| Whole set, between levels, fixed colour   |               — |                       4.01 ms |                      2.14 ms |
| Seahorse Valley, on a level, depth colour |    0.77–0.92 ms |                       2.04 ms |                 1.30–1.49 ms |

Removing the phase and the palette lookup entirely left 1.81 ms between
levels: the four fetches and blends of two levels are the floor, and `gather`
(one fetch per component for the 2×2 footprint) saved almost nothing. The
phase was the lever: dividing by the density once per pixel instead of once per
sample took a third off. Filtering costs about 1 ms a frame at full resolution
over 2.11's unfiltered read.

### 2.11 follow-up: tiles hold only their samples

*2026-09-23 · `409a30e`*

Each tile also carried a colour texture, painted when the tile was made,
repainted when the detail limit changed and box-averaged into its parent,
though nothing had drawn one since 2.11. Removing them removed a third of each
tile, the recolour pass, the mipmap averaging and its kernel.

The planner then needed one fix. It costs tiles from a 1 MiB guess that the
first finished tile replaces, but only upwards: with its colour copy a tile
measured over 1 MiB, so the guess always went; without it a tile measures less,
and the stale guess made the planner overcount the visible band and starve the
zoom-out ladder. It now takes the measurement either way.

`--test-tiles` diagnostics, same machine, before and after (three runs each
where noisy):

| Measure                               |                         Before |                  After |
| ------------------------------------- | -----------------------------: | ---------------------: |
| Mac shallow view: LOD / visible tiles | 17.00 / 96 (clamped by memory) | 17.60 / 306 (as asked) |
| Mac deep ladder                       |                  offsets to 32 |         offsets to 512 |
| Phone shallow ladder                  |                 2 of 8 offsets |                 8 of 8 |
| Phone deep: LOD / ladder              |               3331 / 5 offsets |       3332 / 7 offsets |
| Cache bytes, cache check              |                         149 MB |                  96 MB |
| Cold 1e100 jump, visible ready        |                     805–817 ms |             782–786 ms |
| Deep 1e1000, whole plan ready         |                     540–544 ms |             764–774 ms |

The last row is more work, not slower work: "ready" there waits for the whole
plan, whose zoom-out coverage grew by about a third (24 → 32 and 44 → 60 tiles
in the deep coverage runs), while the visible band itself arrived slightly
sooner. The same memory now buys a level more detail where the budget was
binding, and a fuller zoom-out ladder everywhere.

### Skipping the main cardioid and bulb

*2026-09-23 · `ebabdf3`, against `409a30e`*

A first attempt at this comparison took a median of seven runs, each from a
fresh process, and reported 1.1–1.4× for the 2,000-iteration Float cases, where
the true figure is about 3×: the GPU clock, not the kernel, set those medians
(see [Method](#method)). The suite was then changed to prime the clock, and the
comparison repeated.

**Results.** GPU compute kernel medians on an Apple M1 Pro (16 GPU cores),
without colour conversion, readback, or PNG encoding. The baseline is commit
`409a30e`. Each build was run twice, alternating; the table gives the second
pair. Raw samples are in [evidence/gpu-float](evidence/gpu-float/).

| Case                               |             Capped pixels |  Baseline ms |     Final ms | Speedup |          At 2048×1536 |
| ---------------------------------- | ------------------------: | -----------: | -----------: | ------: | --------------------: |
| Float, slow exterior, 500          |         144,412 / 196,608 |        0.658 |        0.220 |    3.0× |  9.72 → 2.31 ms, 4.2× |
| Float, slow exterior, 2,000        |         134,493 / 196,608 |        2.476 |        0.743 |    3.3× | 36.06 → 6.83 ms, 5.3× |
| Float, period-two bulb edge, 500   |         120,247 / 196,608 |        0.564 |        0.204 |    2.8× |  8.30 → 2.40 ms, 3.5× |
| Float, period-two bulb edge, 2,000 |         118,014 / 196,608 |        2.024 |        0.671 |    3.0× | 29.59 → 6.70 ms, 4.4× |
| FloatFloat, 2,000 / 5,000          | 19,266 / 15,147 of 49,152 |  4.13 / 9.46 |  4.12 / 9.48 |       — |                       |
| Perturbation, 25,000 / 30,000      |             44 / 4 of 192 | 87.7 / 152.1 | 87.7 / 155.8 |       — |                       |

The Float change rejects points strictly inside the main cardioid or
period-two bulb before iterating, with a small margin at their boundaries. It
is used by both the full-image and resumable tile kernels. All eight cases have
the same capped/escaped totals before and after. The Float boundary regression
also compares capped pixels against CPU Double, and the tile integration
diagnostics pass.

The skipped pixels account for 78–92% of capped pixels in these views, and a
coarse CPU count puts the iterations saved at 4.1×, 7.1×, 3.6× and 4.3× for the
four Float cases. The 2048×1536 timings follow that closely, except that the slow
exterior at 2,000 gains 5.3× against the 7.1× estimate (not yet explained). At
512×384 the gain is about 3× throughout; that grid is probably too small to fill
the GPU, though this is untested. In the
first alternating run, one light case (bulb edge, 500) settled at an
intermediate clock (0.274 ms, 27% spread); the second run is the clean one.
FloatFloat and Perturbation are unchanged; their differences are measurement
variation.

Other measured experiments were discarded before this re-measurement, using the
earlier seven-run method: caching squared orbit components changed a few
classifications and did not give a repeatable win; testing the iteration cap
before the escape condition gave mixed times; and compute threadgroup heights of
4 and 16 each improved some scenes while slowing others relative to the existing
height of 8. Because that method was sensitive to clock state, those small
differences deserve a second look with the primed harness.

### Tile refinement: fewer, longer batches

*2026-09-23 · `3d66689`, against `ebabdf3`*

*Its table is superseded by [The whole story](#the-whole-story).*

The tile worker computes a Float or FloatFloat tile as a series of resumable
batches, one command buffer each, awaited in turn. Batches were capped at 512
iterations. Summing each command buffer's own GPU timestamps showed the kernels
running for only about a tenth of a cold render's wall time: at cap 20,000 a
3456×2234 view made 12,658 batches of about 29 µs of GPU work, each costing
about 260 µs of wall time. `powermetrics` meanwhile reported the GPU 96% active
at its top clock, so its residency counts a GPU kept awake by frequent
submissions, not kernel work; use the command-buffer timestamps for questions
like this. Coverage tiles were not the cost: turning coverage off saved 1%.

Two changes:

- **The cap rises to 65,536.** The existing 1 ms target now binds. Cost per
  iteration only falls as pixels escape, and a batch at most doubles, so a batch
  overshoots the target by at most about 2×.
- **Tiles start where the costliest iteration allows.** The store keeps, per
  renderer, the highest GPU seconds per iteration it has measured (reached while
  every pixel is still active) and starts each tile at the batch that fits 1 ms
  at that rate, rather than ramping up from 64 every time. Starting from the
  previous tile's final batch would be unsafe: that size is reached once most
  pixels have escaped, and would overrun on a fresh interior tile.

Cold `--render --pipeline tiles` at 3456×2234 on the M1 Pro, all variants
from one instrumented build switched by environment variables, interleaved,
median of three. "Ready" is from demand to every planned tile finished, so it
excludes process start, compositing and PNG encoding; "GPU busy" is the summed
kernel time over that interval.

| View, cap                                      | Variant     |        Ready | GPU busy | Batches | Longest batch |
| ---------------------------------------------- | ----------- | -----------: | -------: | ------: | ------------: |
| Whole set, 1,000                               | before      |       536 ms |       6% |   1,316 |       0.45 ms |
|                                                | cap only    |       544 ms |       5% |   1,316 |       0.30 ms |
|                                                | cap + start |   **362 ms** |       6% |     526 |       0.43 ms |
| Seahorse Valley (−0.745 + 0.11i, 100×), 2,000  | before      |     1,112 ms |       9% |   2,897 |       0.87 ms |
|                                                | cap only    |     1,011 ms |      10% |   2,502 |       0.87 ms |
|                                                | cap + start |   **743 ms** |      12% |   1,253 |       0.92 ms |
| Float neck (−0.75 + 0.1i, 30×), 20,000         | before      |     3,333 ms |      11% |  12,658 |       0.40 ms |
|                                                | cap only    |     1,160 ms |      23% |   2,831 |       1.35 ms |
|                                                | cap + start |   **962 ms** |      28% |   1,924 |       1.44 ms |
| Period-3 bulb (−0.1226 + 0.7449i, 10×), 20,000 | before      |     2,907 ms |      37% |   7,546 |       1.00 ms |
|                                                | cap only    |     1,696 ms |      61% |   2,191 |       1.38 ms |
|                                                | cap + start | **1,596 ms** |      65% |   1,712 |       1.85 ms |
| FloatFloat (1e7 reference location), 5,000     | before      |     1,190 ms |      33% |   2,712 |       0.97 ms |
|                                                | cap only    |       951 ms |      40% |   1,644 |       1.13 ms |
|                                                | cap + start |   **809 ms** |      46% |   1,040 |       1.28 ms |

That is 1.5×, 1.5×, 3.5×, 1.8× and 1.5× to a finished view. Whole-command
wall time from the shipped build (median of three, against the instrumented
build at cap 512) agrees: 715 → 528 ms, 1,312 → 923, 3,547 → 1,125,
3,183 → 1,804 and 1,329 → 986. Perturbation tiles batch separately and are
unchanged.

The longest batch rose from about 1 ms to at most 1.85 ms. That is the price:
the compositor waits behind a batch, and at 120 Hz a frame is 8.3 ms. It has
not been measured on a phone.

#### Statistics in the last batch

*2026-09-23 · `546d5c5`*

*Its tables are superseded by [The whole story](#the-whole-story).*

Each finished tile then took two more round trips: a pass counting capped
pixels and the highest escaped count, and a histogram pass. Both now run in a
second compute encoder in the tile's last batch's command buffer; perturbation
tiles, which batch separately, get one combined pass instead of two. The last
batch's time then includes those passes, so it no longer feeds the per-iteration
cost estimate. It had skewed that estimate even before this change: a short
remainder batch costs more per iteration, so later tiles started smaller than
they needed to. Both effects are in the last column below.

Three builds, each with the same measurement patch (ready time, summed kernel
time, batches, longest batch), interleaved, median of three cold
`--render --pipeline tiles` runs at 3456×2234 on the M1 Pro. "Before" is
`ebabdf3`, "cap" is the change above and "fold" adds this one. The last three
views are mostly exterior with interior at the edges, chosen to catch a start
batch sized from cheap early tiles overrunning on a heavy one.

| View, cap                                      |   Before | Cap + start |       + fold | Total speedup |
| ---------------------------------------------- | -------: | ----------: | -----------: | ------------: |
| Whole set, 1,000                               |   515 ms |      338 ms |   **221 ms** |          2.3× |
| Seahorse Valley (−0.745 + 0.11i, 100×), 2,000  | 1,059 ms |      688 ms |   **494 ms** |          2.1× |
| Float neck (−0.75 + 0.1i, 30×), 20,000         | 3,296 ms |      884 ms |   **691 ms** |          4.8× |
| Period-3 bulb (−0.1226 + 0.7449i, 10×), 20,000 | 2,877 ms |    1,565 ms | **1,439 ms** |          2.0× |
| FloatFloat (1e7 reference location), 5,000     | 1,167 ms |      782 ms |   **662 ms** |          1.8× |
| Cardioid edge (0.28 + 0.53i, 3×), 20,000       | 1,514 ms |      468 ms |   **375 ms** |          4.0× |
| Period-3 minibrot (−1.77, 20×), 20,000         | 2,200 ms |      577 ms |   **430 ms** |          5.1× |
| Period-4 bulb (−0.16 + 1.035i, 30×), 20,000    | 3,215 ms |      776 ms |   **572 ms** |          5.6× |

| View              | GPU busy: before → cap → fold | Longest batch: before → cap → fold |
| ----------------- | ----------------------------: | ---------------------------------: |
| Whole set         |                 6% → 7% → 23% |              0.43 → 0.43 → 0.83 ms |
| Seahorse Valley   |               10% → 14% → 24% |              0.92 → 1.08 → 1.73 ms |
| Float neck        |               11% → 30% → 39% |              0.43 → 1.46 → 1.42 ms |
| Period-3 bulb     |               38% → 65% → 72% |              0.99 → 1.40 → 2.04 ms |
| FloatFloat        |               34% → 48% → 59% |              0.99 → 1.28 → 1.80 ms |
| Cardioid edge     |               15% → 37% → 48% |              0.47 → 1.39 → 1.23 ms |
| Period-3 minibrot |                8% → 21% → 34% |              0.36 → 1.23 → 1.42 ms |
| Period-4 bulb     |                7% → 16% → 27% |              0.90 → 1.81 → 1.36 ms |

Every image is byte-identical between the cap and fold builds. Most ranges
were within 4% of the median; the exceptions are the whole set with the fold
(165–247 ms), the period-4 bulb at cap (773–943 ms) and the cardioid edge at
cap (434–477 ms). The
fold's longest batch includes the statistics passes. None of the edge views
overran; the worst batch anywhere was 2.04 ms. That does not prove a heavy
tile can never follow cheap ones with an oversized start: seeding the cost
estimate from a calibration batch on an all-interior tile would bound that.

#### Two tiles in flight

*2026-09-23 · `f855bf5`*

The worker now runs two slots, each claiming, refining and storing tiles, so
one tile's round trips and main-actor bookkeeping overlap the other's GPU work.
Both slots run on the main actor, so claiming a tile between awaits is atomic;
a tile in flight counts towards `residentBytes` until it is stored, so eviction
leaves room for both. Only the first slot takes perturbation tiles, which share
the worker's single set of reference and scratch resources. Each worker run
refines its first tile alone, so a worker that cannot allocate at all fails and
spends its retry budget exactly as before; the tile diagnostics caught the
change in failure behaviour when both slots started at once.

#### The whole story

*2026-09-23 · `ebabdf3`, `3d66689`, `546d5c5` and `f855bf5`, measured side by side*

Four builds with the same measurement patch, interleaved, median of three cold
`--render --pipeline tiles` runs at 3456×2234 on the M1 Pro: `ebabdf3`
(before), `3d66689` (cap + start), `546d5c5` (fold) and two in flight. Every
image is byte-identical across the four builds. Raw runs:
[cold-renders.json](evidence/tile-batching/cold-renders.json).

At the limits the app chooses automatically (`IterationPolicy.estimate`),
which is what a viewer sees on arrival:

| View                                   | Limit | Before | Cap + start | + Fold | + Two in flight | Total |
| -------------------------------------- | ----: | -----: | ----------: | -----: | --------------: | ----: |
| Whole set                              |   200 | 401 ms |      277 ms | 160 ms |       **90 ms** |  4.5× |
| Seahorse Valley (−0.745 + 0.11i, 100×) |   800 | 781 ms |      587 ms | 283 ms |      **177 ms** |  4.4× |
| Float neck (−0.75 + 0.1i, 30×)         |   600 | 552 ms |      412 ms | 192 ms |      **117 ms** |  4.7× |
| Period-3 bulb (−0.1226 + 0.7449i, 10×) |   600 | 381 ms |      280 ms | 143 ms |       **99 ms** |  3.9× |
| FloatFloat (1e7 reference location)    | 2,200 | 792 ms |      547 ms | 452 ms |      **364 ms** |  2.2× |
| Cardioid edge (0.28 + 0.53i, 3×)       |   400 | 224 ms |      187 ms |  85 ms |       **59 ms** |  3.8× |
| Period-3 minibrot (−1.77, 20×)         |   600 | 400 ms |      298 ms | 141 ms |       **84 ms** |  4.7× |
| Period-4 bulb (−0.16 + 1.035i, 30×)    |   600 | 580 ms |      427 ms | 202 ms |      **116 ms** |  5.0× |

At raised limits:

| View              |  Limit |   Before | Cap + start |   + Fold | + Two in flight | Total |
| ----------------- | -----: | -------: | ----------: | -------: | --------------: | ----: |
| Whole set         |  1,000 |   538 ms |      354 ms |   164 ms |       **98 ms** |  5.5× |
| Seahorse Valley   |  2,000 | 1,105 ms |      707 ms |   514 ms |      **306 ms** |  3.6× |
| Float neck        | 20,000 | 3,445 ms |      925 ms |   719 ms |      **475 ms** |  7.3× |
| Period-3 bulb     | 20,000 | 2,981 ms |    1,559 ms | 1,455 ms |    **1,315 ms** |  2.3× |
| FloatFloat        |  5,000 | 1,191 ms |      800 ms |   672 ms |      **553 ms** |  2.2× |
| Cardioid edge     | 20,000 | 1,574 ms |      466 ms |   375 ms |      **277 ms** |  5.7× |
| Period-3 minibrot | 20,000 | 2,282 ms |      601 ms |   440 ms |      **298 ms** |  7.7× |
| Period-4 bulb     | 20,000 | 3,391 ms |      824 ms |   576 ms |      **354 ms** |  9.6× |

All but five of the 64 series spread by at most 10% of their median. Four
spread by 10–13%, and one by 43%: the whole set at 1,000 with two in flight
(95, 98, 136 ms). The fold numbers here are lower than in the previous section's run of the
same build (221 against 164 ms for the whole set at 1,000); these are the ones
to compare, since all four builds ran side by side. Each step helps
everywhere. The views that stay slow are those the GPU is genuinely busy with:
the period-3 bulb at 20,000 and FloatFloat, where most pixels iterate to the
limit; periodicity checking (2.14) is the lever there, not scheduling.

**The cost is batch length.** With two command buffers sharing the GPU, each
takes longer: summed kernel time rose (1,029 → 1,789 ms for the period-3 bulb
at 20,000, 385 → 665 ms for FloatFloat) and the longest batch rose from at most 1.9 ms with the fold to at
most 4.0 ms (FloatFloat and the period-3 bulb; 0.55–2.7 ms elsewhere at the
automatic limits). The compositor trace in `--test-tiles`, five runs per build,
shows no change in compositor GPU time while refining — p95 0.24, 0.24, 0.36
and 0.24 ms, worst frame 1.16, 2.23, 0.42 and 0.34 ms for the four builds
([compositor-frames.json](evidence/tile-batching/compositor-frames.json)) —
but that trace's refinement is light (longest batch 0.69 ms), and GPU duration
does not show how long a frame waited to start. Whether 4 ms batches delay
frames at 120 Hz, especially on the iPhone 11 Pro, is unmeasured. If they do,
halving the batch target while two are in flight is the first thing to try.
