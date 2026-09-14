# Implementation through 2.1

Work is staged on `feature/gpu-tile-explorer`. The target devices are iPhone 11 Pro
and iPhone 16 Pro. Minimum deployment: iOS 18, macOS 15.7. Physical-device frame
rates require testing on those devices; simulator timings are not substitutes.

Completed:
- 1.1: ignore coverage files; remove visionOS/device family 7; support iOS 18.
  These changes were included in concurrent commit `2344a77` before the cleanup
  commit attempt, which therefore had no remaining changes to commit.
- 1.2: retain strict FloatFloat arithmetic; document measured Float slowdown.
- 1.3: immutable Double reference counts and PNGs at four locations, CLI tests,
  Swift unit tests, and `make test`. Float goldens stop at their precision range.
- 1.6: shared Viewport navigation/precision cap, typed renderer registry/protocol,
  separate viewer/benchmark/help, and one command table for menu/keyboard/help.

- 1.4: private GPU sample/colour textures, asynchronous compute, MTKView presentation,
  diagnostic-only readback, kernel/end-to-end CLI timings; product goldens pass.

- 1.5: smooth radius-256 samples, seven cyclic palettes, appearance controls,
  recolouring without recomputation, and an independent smooth-count oracle.

- 1.7: hidden developer access, automatic/default clean viewer, renderer overrides,
  HUD/overlay toggles, device-tagged benchmark sharing and timing scope.

- 1.8: native anchored gestures, double/two-finger taps, cursor zoom, rectangle
  selection, arrows, and analytically integrated pan/pinch inertia. Mac tests and
  iPhone/iPad simulator compilation pass.

- 2.1(a): anchor-relative fixed-level tiles, a per-frame Metal compositor, sample
  reuse during pan, transactional recolouring, and headless integration checks.

- 2.1(b): multiple levels, coarse-first scheduling, parent fallback with zero-hole
  zoom tests, and anchor rebasing with retained coverage.

- 2.1(c): colour-space level blending, 125 ms refinement fades, and GPU tile
  borders/level labels. Shader integration verifies known RGB blend weights.

Next: tile stage 2.1(d). No perturbation or automatic iteration-depth
heuristic is included in this milestone. Colour mipmaps are disposable
palette-dependent display data; raw sample tiles remain authoritative.
