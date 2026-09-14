# Mandelbrot

A native SwiftUI and Metal explorer for iPhone, iPad and Mac, with a headless
rendering/performance lab. See [vision](vision.md), [plan](plan.md), and the
[implementation record](Implementation.md).

Requires Xcode 26.2 or newer with the Metal toolchain. Targets iOS 18+ and macOS
15.7+. No third-party dependencies.

```sh
make build       # Release macOS app in /tmp/mandelbrot-development
make test        # Swift unit + CLI + CPU/GPU golden-image tests; GPU required
make ios         # iPhone/iPad simulator build
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
