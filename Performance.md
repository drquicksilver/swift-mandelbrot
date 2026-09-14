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
