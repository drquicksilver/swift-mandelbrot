# Mandelbrot Performance

What the renderers cost now, how that is measured, and how to reproduce it.
How each number came about -- every experiment, oldest first, including the
ones that were discarded -- is in [the history](Performance-history.md); the
design these numbers justify is in [Architecture.md](Architecture.md).
`make docs` aligns the tables for reading in a monospace editor, and
`make docs-check` checks them and every link.

## Current state (2026-09-23, `f855bf5`)

| Workload                                                         | Latest measurement                                                                                                       | Where the time goes                                                                   | Next lever                                                                     |
| ---------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| Cold shallow and medium Float views, 3456×2234, automatic limits | 59–177 ms to every tile ready ([The whole story](Performance-history.md#the-whole-story))                                | GPU iteration and per-tile round trips, now overlapped                                | Periodicity checking (plan 2.14) for interior pixels                           |
| Cold FloatFloat view, 1e7, 2,200 iterations                      | 364 ms (same entry)                                                                                                      | Mostly GPU iteration                                                                  | Periodicity checking                                                           |
| Cold deep jumps, 1024×768, 5,000 iterations                      | 1e100: 758–794 ms; 1e1000: 565–601 ms visible (six `--test-tiles` runs, 2026-09-23)                                      | Perturbation tiles, not broken down at this size; unchanged by the tile batching work | Profile first; a Boost reference backend (plan 2.16) is the measured candidate |
| Compositor, 3456×2234, settled                                   | 1.30–2.19 ms per frame ([colouring in the compositor](Performance-history.md#211-follow-up-colouring-in-the-compositor)) | Four sample fetches and blends per level                                              | —                                                                              |
| Zoom movie into the period-312 minibrot, 640×360                 | 1,236 s for 101 keyframes ([2.8](Performance-history.md#28-zoom-movies))                                                 | Keyframe rendering; which part of it is not measured                                  | Profile one keyframe                                                           |

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
  slower; see the correction in [1.2 follow-up](Performance-history.md#12-follow-up-strict-float-math-cost).

## How to measure

Everything here drives the Release app headless.  `make build` puts it at
`/tmp/mandelbrot-development/Build/Products/Release/Mandelbrot.app/Contents/MacOS/Mandelbrot`,
called `APP` below; `APP --help` lists every option.  The command line is
`Mandelbrot/CLI/BenchmarkCLI.swift`, and it selects its mode before SwiftUI
starts, so no window opens.

### Benchmarks

```sh
APP --benchmark --variants baseline,parallel,metal \
  --sizes 1024x512,2048x1024 --iterations 200 --warmup 1 --runs 3
```

`--pipeline` chooses what is timed.  `legacy` (the default) runs the lab
renderers -- the CPU variants and the first Metal kernels -- and includes
their CPU colouring.  `gpu` runs the product's full-frame kernels, either the
kernel alone (`--timing kernel`) or through the coloured texture
(`--timing end-to-end`, which for perturbation includes preparing the
reference orbit).  `--variants all` selects every renderer the pipeline
supports; ten exist.  Each renderer and size gets its own untimed warm-ups,
then measured runs on a monotonic clock; `--format json` records every
sample and the exact viewport, which the default Markdown table summarises.

Runs default to centre (-0.5, 0) and scale 1; `--center-real`,
`--center-imag` and `--scale` choose another view, with the horizontal span
`3 / scale`.  The legacy pipeline stops at 65,535 iterations, the width of
its counts; the GPU pipelines accept 1,000,000.  Every renderer samples each
pixel at its centre.  The process exits 0 on success, 2 for invalid options
and 1 when a renderer fails.

### PNG export and raw samples

```sh
APP --render --pipeline gpu --renderer metal-double --size 512x512 \
  --center-real -0.743643987037151 --center-imag 0.13182597420533 \
  --scale 10000000 --iterations 2000 --output floatfloat.png
```

`--pipeline tiles` renders through the viewer's own tile store and
compositor instead, and is the only path that takes `--rotation`.  Raw data
comes out of the full-frame paths: `--counts` (UInt16 counts; on the
GPU pipeline only with `--colouring legacy`), `--samples` (Float32 smooth values, -1 for capped) and
`--sample-records` (the exact eight-byte records: UInt32 count, Float32
correction).  All are little-endian, row-major from the top-left pixel, with
no header.  PNG writing is never part of a timing.

### The GPU zoom-depth suite

`benchmarks/benchmark_gpu_depths.py` times eight headless GPU cases: Float at
30× and 1000×, FloatFloat at 1e7 and perturbation at 1e100, each at two
iteration caps.  Before timing a case it exports raw records and requires
both capped and escaped pixels, so an accidentally trivial view fails;
`--compare` also fails if any total differs from an earlier run.  Light cases
render a primer first (see [Method](#method)).

```sh
python3 benchmarks/benchmark_gpu_depths.py APP --output /tmp/gpu-depths.json \
  [--compare earlier.json]
```

### Tiles

`APP --test-tiles` runs the headless integration suite and prints its
statistics and timings as JSON; `benchmarks/measure_tiles.py APP STAGE`
repeats it five times and keeps the runs.  `APP --benchmark-compositor` and
`APP --benchmark-reference` time the compositor and a cold deep view.  The
ready times and summed kernel times in the tile-batching entries of the
history came from a small measurement patch applied identically to every
build compared, not from a committed option: it printed the time from
`update` to `waitUntilReady`, and summed each batch's
`gpuEndTime − gpuStartTime`.

### Other recorded measurements

`benchmarks/` holds the script behind each recorded measurement, and
`docs/evidence/` what they recorded, grouped by subject; the history entry
that used a result links to it.

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
  validation](Performance-history.md#review-independent-product-image-validation)).
- **What a minibrot movie keyframe costs**, split into reference, BLA
  preparation and GPU time ([2.8](Performance-history.md#28-zoom-movies)).
- **A Boost reference backend in the product** (plan 2.16); only the library
  comparison has been measured.

