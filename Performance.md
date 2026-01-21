# Mandelbrot Performance Experiments

This document outlines independent experiments to measure performance impacts in the Mandelbrot renderer. Each experiment changes a single aspect of the computation so you can isolate effects. The hot path is the iteration loop and block fill in `MandelbrotRenderer.iterations`.

## Experiment 1 — Scalar loop tightening (cache squares + `for` loop)
**Goal:** Improve instruction count and branch predictability in the iteration loop.

**Change:** Replace the `while` condition with a `for iteration in 0..<maxIterations` loop and maintain cached squares (`zr2`, `zi2`). Update squares each iteration and break when `zr2 + zi2 > 4`.

**Hypothesis:** Fewer multiplications and simpler branching reduce cycle count in the inner loop.

**Measure:** Total render time at a fixed resolution/zoom; compare to baseline.

---

## Experiment 2 — Coordinate precompute (incremental real/imag)
**Goal:** Reduce divisions and repeated arithmetic per block.

**Change:** Precompute `realStep` and `imagStep` once, then compute `real`/`imag` using multiply-adds instead of division per block.

**Hypothesis:** Lower per-block arithmetic cost improves throughput, especially for small block sizes.

**Measure:** Render time and instruction count (if using Instruments).

---

## Experiment 3 — Unsafe buffer writes (bounds-check elimination)
**Goal:** Reduce overhead in the block fill loop.

**Change:** Use `values.withUnsafeMutableBufferPointer` to write via raw pointers, precomputing row offsets to reduce index math and bounds checks.

**Hypothesis:** Fewer bounds checks + fewer index computations improve write throughput.

**Measure:** Time spent in the fill loop vs. baseline (Time Profiler).

---

## Experiment 4 — `Float` vs `Double`
**Goal:** Trade precision for faster arithmetic and potential SIMD throughput.

**Change:** Convert the iteration math to `Float` (or add a `Float`-specialized path) while keeping output iterations as `Int`.

**Hypothesis:** Reduced register pressure and faster math yield faster renders at modest zooms.

**Measure:** Render time across zoom levels + visual inspection for artifacts.

---

## Experiment 5 — Parallel outer loop
**Goal:** Exploit multi-core scaling.

**Change:** Parallelize the outer `y` block loop using `DispatchQueue.concurrentPerform` (or a task queue of blocks).

**Hypothesis:** Near-linear speedup for larger images with enough blocks.

**Measure:** Render time vs. baseline on a multi-core device; CPU utilization.

---

## Experiment 6 — SIMD batching
**Goal:** Increase arithmetic throughput by evaluating multiple points per iteration.

**Change:** Use `SIMD4<Float>` or `SIMD8<Float>` to iterate multiple points at once (especially if `blockSize == 1`).

**Hypothesis:** Vectorization yields significant speedups in the inner loop.

**Measure:** Render time and vector instruction utilization (Instruments + performance counters).

---

## Suggested measurement protocol
- Fix `width`, `height`, `center`, `scale`, `blockSize`, and `maxIterations`.
- Run each experiment 3–5 times and record the median.
- Change one variable per experiment to isolate impact.
- Use Instruments (Time Profiler) to confirm the hot loop is consistent across runs.
