# Mandelbrot

A native SwiftUI and Metal explorer for iPhone, iPad and Mac, with a headless
rendering/performance lab. See [vision](vision.md), [plan](plan.md), and the
[implementation record](Implementation.md).

Requires Xcode 26.2 or newer with the Metal toolchain. Targets iOS 18+ and macOS
15.7+. No third-party dependencies.

```sh
make build       # Release macOS app in /tmp/mandelbrot-development
make test        # Swift unit + CLI + CPU/GPU golden-image tests; GPU required
make ios         # iPhone/iPad simulator build + generated plist check
make ios-device  # unsigned physical-iOS build + generated plist check
make format-check # enforce the committed Swift formatting convention
```

Run `/tmp/mandelbrot-development/Build/Products/Release/Mandelbrot.app/Contents/MacOS/Mandelbrot`
with no arguments for the viewer, or `--help` for headless rendering/benchmarks.
[Performance.md](Performance.md) documents timings, precision, and CLI examples.

`Mandelbrot/Core` contains the independently tested numerical and navigation
models. SwiftUI views coordinate through `ExplorerModel`; `RendererRegistry`
provides the CPU/GPU laboratory implementations. Legacy escape-count fixtures
remain fixed so renderer changes can be checked against an independent reference.

Developer tools: in Settings → About, tap the version seven times. On Mac, hold
Option to reveal Debug, or launch with `-DeveloperMenuEnabled YES` to keep that
menu available. The main view uses automatic precision; the developer panel has
renderer overrides, benchmark sharing, a HUD, and tile overlays. Benchmark scope
can be GPU compute only or end-to-end (GPU computation/colouring; CPU legacy
rendering). Reports include the device and exact viewport.

The viewer now uses a GPU quadtree cache with parent fallback, colour-level
blending, refinement fades, upward mip averaging, prefetching and LRU budgets.
See [Architecture.md](Architecture.md) for the data flow and precision limits.
Until perturbation is implemented, navigation stops gracefully at the FloatFloat
precision limit. Iteration depth remains a manual control.

Export the same tiled compositor without opening a window:

```sh
/tmp/mandelbrot-development/Build/Products/Release/Mandelbrot.app/Contents/MacOS/Mandelbrot \
  --render --pipeline tiles --renderer metal-double --size 1024x768 \
  --center-real -0.743643987037151 --center-imag 0.13182597420533 \
  --scale 10000000 --iterations 2000 --palette blue-gold --output deep.png
```

![Deep tiled rendering](evidence/product/tiles-deep.png)

The user has reported smooth navigation on a phone and Mac. The review fixes add
bounded retries, a small deep working set, iteration-change continuity and idle
sleeping. Physical frame pacing and the revised full-screen touch layout still
need device verification. The [implementation record](Implementation.md) tracks
completed work and the remaining validation. Independent CPU product-image
references run as part of `make test`; regenerate deliberately with
`python3 tests/test_product_golden.py --record`.
