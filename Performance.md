# Mandelbrot Performance Experiments

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
