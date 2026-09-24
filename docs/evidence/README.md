# Evidence

What the recorded measurements produced -- raw timings, counters and images
-- grouped by the part of the renderer they measured. Each file is linked
from the entry in [Performance-history.md](../Performance-history.md) that
used it, and most were written by a script in
[benchmarks/](../../benchmarks/README.md).

| Folder         | Subject                                                              |
| -------------- | -------------------------------------------------------------------- |
| `floatfloat`   | 1.2: the FloatFloat precision fix, with its own README               |
| `float-kernel` | 1.2 follow-up: the Float kernel's cost under strict maths            |
| `gpu-pipeline` | 1.4 onwards: the GPU pipeline, tiles and compositor; `tile-batching` |
| `perturbation` | deep zoom: `2.2` itself, the deep-zoom `review`, and its `followup`  |

Images before 2.17 sampled the edges of the view rather than pixel centres,
so a rerun today differs from them by up to half a pixel.
