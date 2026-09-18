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

## Deep-zoom review: reusable references

References now use 256-bit precision bands and satisfy shorter/lower-precision
requests without recomputation. The cache is owned by the tile worker, budgeted
from its device allowance, and accepts a nearby viewport-centred reference within
four tile widths. It is independent of the grid indexing anchor. Full-image
benchmarks still create fresh references, preserving the earlier comparison scope.
Unit tests verify one computation for concurrent 400/401-bit requests, reuse at
402 bits and a shorter iteration limit, and a new computation above the 512-bit
band. Product tests verify scratch-buffer identity reuse and unchanged hard-image
error budgets. Miss computation no longer blocks unrelated actor cache hits.

## Deep-zoom review: CPU drawing geometry

Same-anchor UVs and cell positions now use integer keys, bounds are cached, and
one nearby tile origin is converted from high precision per frame. A 120-frame
settled 1e1000 integration run on the M1 Pro measured CPU compositor preparation
p95 **0.016 ms**, maximum **0.033 ms**. These measure encoding/preparation, not
GPU execution or total UI frame time. Raw counters are in
`evidence/review-deep/geometry.json`; the HUD now separates CPU draw preparation,
demand updates and GPU time. The iPhone 16 Pro is listed as unavailable by
`devicectl`, and no iPhone 11 Pro is connected, so phone timings remain unmeasured.

## Deep-zoom review: hierarchical BLA

M1 Pro, 64×48, median of three runs after one warmup, including fresh CPU
reference generation, BLA preparation and completed GPU colouring (no readback):

| Location | BLA off | Fixed 32 | Hierarchy | Longest applied jump |
| --- | ---: | ---: | ---: | ---: |
| c=i, 1e1000, 5,000 iterations | 158.94 ms | 114.14 ms | 107.98 ms | 2,048 |
| period-312 minibrot, 1e100, 60,000 iterations | 735.11 ms | 440.05 ms | 434.44 ms | 16,384 |

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

## Deep-zoom review: iteration depth and smooth precision

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

## Deep-zoom review: reproducible library decision

`python3 tests/precision/reproduce.py` fetches the pinned Boost 1.90 repositories,
verifies clean revisions, and builds both comparisons. Swift now explicitly uses
`-O -whole-module-optimization`, matching the app's Release compilation mode;
C++ uses `-O3`. This is a different Swift compilation mode from the historical
arithmetic-only numbers above. Raw five-run results and pins are in
`evidence/review-deep/libraries.json`.

Saved-reference generation at the exact period-312 minibrot fixture, cap 60,000:

| Precision | Swift median | Boost median | Swift / Boost orbit length | Per-iteration speedup |
| --- | ---: | ---: | ---: | ---: |
| 461 bits | 112.04 ms | 20.92 ms | 32,789 / 32,205 | 5.26× |
| 512 bits | 135.49 ms | 23.84 ms | 37,280 / 37,251 | 5.68× |

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

## Final review validation

Final M1 Pro runs after separate sample storage, same 64×48 scenes, median of
three measured runs after one warmup, fresh references, completed GPU colour:

| Location | BLA off | Fixed 32 | Hierarchy |
| --- | ---: | ---: | ---: |
| c=i, 1e1000, 5,000 iterations | 176.77 ms | 118.66 ms | 112.58 ms |
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

## Follow-up review: automatic depth without cache resets

The cache now retains iteration-labelled raw samples. Lowering the limit performs
colour/mip work but no orbit sampling; returning to an already computed higher
limit also requires no sampling. Increasing beyond stored detail recomputes only
capped pixels, preserving escaped records byte-for-byte. Fully escaped tiles need
no extension. State remains worker-local; capped pixels restart rather than
retaining a roughly 3 MiB perturbation buffer for each cached tile.

The integration fixture sampled **zero pixels** on a decrease and return, and
**820 capped pixels** on the next increase. A 201-view 1x–1e30–1x navigation trace
sampled 27,424,368 pixels with a fixed limit and 27,427,626 with automatic limits.
This trace deliberately uses an outside-set location to isolate cache behaviour;
non-flat seahorse, deep c=i and minibrot tests separately check rendering accuracy.
Returns from 1e12 and 1e1000 both rebuilt the same two shallow tiles as a fresh
session, cleared deep anchors/bounds and released cached deep reference storage.
Raw observations are in `evidence/followup/navigation.txt` and
`evidence/followup/tile-validation.json`; timings are observations, not CI limits.

## Follow-up review: streamed reference latency

At c=i and 1e1000, the automatic policy selects 266,000 iterations. The earlier
reference-only experiment measured 0.91–0.99 seconds to prepare that complete
orbit on this M1 Pro (about 17 ms for 5,000), rather than the review's extrapolated
five seconds. Those measurements excluded tile rendering.

References now save their final BigInt state and grow only when GPU pixels reach
the available prefix. Extensions match one-shot packed orbit values exactly.
Initial prefixes contain at most 4,097 iterations, aligned to BLA leaves; a
paused frontier does not trigger a rebase or reset pixel state.

Three isolated cold product runs at the actual automatic limit produced:

| Measurement | Median | Range |
| --- | ---: | ---: |
| First deep tile ready | 41.51 ms | 41.19–48.76 ms |
| All required tiles ready | 233.20 ms | 227.25–275.26 ms |
| Reference values needed | 4,098 | identical in all runs |

Run `APP --benchmark-reference`, or
`python3 tests/precision/measure_followup.py APP` to record all runs and images.
These measure readiness after GPU-context initialisation, not display presentation
or physical-phone frame pacing. Raw data: `evidence/followup/measurements.json`.

Comparable fresh full-image runs (64×48, three runs after one warmup, reference
preparation and GPU colour included) now measure:

| Location | BLA off | Fixed 32-step blocks | Hierarchy |
| --- | ---: | ---: | ---: |
| c=i, 1e1000, 5,000 iterations | 158.90 ms | 107.97 ms | 108.62 ms |
| minibrot, 1e100, 60,000 iterations | 702.51 ms | 426.91 ms | 432.36 ms |

The last two columns are similar here; there is no claim of an end-to-end
hierarchy win. Both use the production compounded radius. Raw data and component
timings are in `evidence/review-deep/followup.json`.

## Follow-up review: BLA margin decision

`make bla` now runs 440 isolated GPU jump cases against ordinary GPU recurrence
and independent 180-digit Decimal recurrence, using the same packed reference
and starting values. Cases include zero deltas and 12.5%, 50% and 99% of the
validity radius, with lengths through 16,384. Errors are normalised by the larger
of the final magnitude and the sum of the two linear output-term magnitudes,
so cancellation does not create misleading relative errors.

| Scene/policy | Largest BLA-vs-Decimal error | Largest ordinary-GPU-vs-Decimal error |
| --- | ---: | ---: |
| c=i, compound | 1.31e-14 | 1.35e-14 |
| c=i, fixed per jump | 2.39e-15 | 1.35e-14 |
| minibrot, compound | 5.99e-14 | 9.01e-13 |
| minibrot, fixed per jump | 7.35e-15 | 1.11e-12 |

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

## 2.4 coverage: sized ladder and realistic budgets

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

| Settled scene | Coverage bytes available | Near offsets planned | Sparse offsets planned |
| --- | ---: | ---: | ---: |
| phone, shallow | 10 MiB | 2 of 8, plus root | 1 (offset 15) |
| phone, 1e1000 | 30 MiB | 5 of 8 | 0 of 6 |
| Mac, shallow | 50 MiB | 8 of 8, plus root | 1 (offset 15) |
| Mac, 1e1000 | 50 MiB | 8 of 8 | 2 of 6 |

A shallow view reaches its minimum scale a few levels out, so its sparse tail
collapses to the single rung that still fits inside the bounds — offset 15 in both
shallow runs. The deep rows keep the full 16…512 tail.

On a phone, a full-resolution view uses almost all of the resident limit, so
only the root and the 2–4× zoom-out are guaranteed. The test asserts exactly that;
on the Mac it asserts the full near ladder. The chosen levels sit 3–4 levels below
the detail level, so they are placeholders at 1/8–1/16 resolution.

Cold jumps at 1024×768, 5,000 iterations, best of two runs per mode in the same
process:

| Cold jump | Visible view ready, with coverage | Without coverage |
| --- | ---: | ---: |
| c=i, 1e100 | 783.8 ms | 779.6 ms |
| c=i, 1e1000 | 582.7 ms | 574.8 ms |

The test allows 25% + 30 ms. Moving at 1e1000 (1024×768, 120 frames alternating
zoom and pan, with the worker running): demand update p95 **0.49 ms** (limit 4 ms),
frame plan p95 **0.37 ms** (limit 2 ms).

## 2.3: observed ceiling and cheaper raises

Measured headlessly on the Apple M1 Pro with `make tiles`.

**Lowering from data.** Once every visible tile is complete, the viewer lowers
the automatic limit to twice the highest escaped count in view, if that count is
below a quarter of the limit. No escaped count lies between the highest observed
count and the limit, so this changes nothing on screen: the lowered store and a
fresh render at the lowered limit match to the byte. Counts reaching 1.5× those
the ceiling came from release it. Further zooming grows the ceiling at the
estimate's slope.

| View (256×192) | Depth estimate | Highest escaped | Settled limit | Picture difference |
| --- | ---: | ---: | ---: | ---: |
| c=i, 1e1000 | 266,000 | 2,707 | 5,600 | 0/255 |
| empty space, 1024× | 1,000 | < 100 | 200 | — |

The depth-only slope is unchanged at 80 per level. At c=i, 1e1000 it overshoots
about 100× (266,000 against about 2,700 needed). At the period-312 minibrot at
1e100 it undershoots (about 26,800 against up to 60,000). Raising from pixel data
needs periodicity checking (2.10).

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

## 2.8 Zoom movies

Measured on the Apple M1 Pro with the CLI (`--movie`), which shares the viewer's
tile cache, compositor and encoder. Automatic depth per keyframe; HEVC. Every row
names its destination: the cost depends far more on what is at the bottom than on
how deep it is, so a row without one cannot be reproduced or compared.

| Movie | Destination | Keyframes | Frames | Render time | File |
| --- | --- | ---: | ---: | ---: | ---: |
| 1280×720, 8 s, 30 fps | Seahorse Valley, 4e3 | 13 | 240 | 2.6 s | 3.1 MiB |
| 1920×1080, 8 s, 30 fps | the point i, 1e12 | 41 | 240 | 9.6 s | 3.5 MiB |
| 640×360, 4 s, 30 fps | period-312 minibrot, 1e30 | 101 | 120 | 1,236 s | 0.5 MiB |

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
not its iteration limit but its reference orbit and hierarchy. The CLI now reports
`keyframeLimitSum`, which is the quantity any future depth policy has to move.

Periodicity checking (2.10) and the orbit follow-up below are the levers. A
shallow 720p movie is already quick.

Two follow-ups the numbers point at, both listed under 2.13: each keyframe
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

The headless check renders 320×180 at 15 fps, reads the file back with
AVAssetReader and compares the first and last frames against direct renders of
the start and end views: mean channel error **9.3/255** through HEVC
compression and the keyframe resampling.
