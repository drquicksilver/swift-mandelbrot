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

- 2.1(d): exact interior colour mip averaging, direction-aware prefetch, protected
  ancestors, LRU device budgets, resumable iteration batches, lifecycle cancellation
  and GPU cache/frame statistics. Budget pressure lowers sampling LOD without
  changing the camera. Palette-dependent mipmaps are disposable; raw data stays
  authoritative. The cache and numerical integration regressions pass.

All implementation points through 2.1 are complete. No perturbation (2.2) or
automatic iteration-depth heuristic (2.3) is included. Navigation has the agreed
graceful FloatFloat precision cap. Each numbered point or tile stage has a commit;
1.6 preceded 1.4 to establish the shared models before the GPU presentation change.

Final verification: `make test`, `make ios`, unsigned generic physical-iOS Release
build, five isolated headless tile traces, and visual inspection of the deep tiled
PNG. `Architecture.md` explains the cache, precision and memory decisions.
Interactive GUI inspection could not proceed because Computer Use permissions
remained pending; no physical phone measurements were obtained. Hands-on testing
on iPhone 11 Pro and iPhone 16 Pro remains necessary before claiming frame pacing
or touch quality on those devices.

## Review stabilisation

- Failure handling: at most three attempts per failing tile/operation, delayed
  retries independent of display frames, and explicit recovery. An injected
  allocation failure verifies 120 updates cannot restart terminal failures.
- ProMotion: explicit iOS Info.plist boolean; `make ios` checks the generated app.
  The suggested custom build setting alone was ignored by this Xcode generator.
  Earlier claims that the opt-in was already enabled were incorrect.
- Deep scheduling: protect a three-level working set; regression preserves full
  1e10 detail within the iPhone budget and measures useful coverage separately
  from completion. Existing distant ancestors remain reusable LRU entries.
- Iteration changes: retain the detailed working set across repeated changes,
  prefer its detail over coarse new tiles, and fade replacements before releasing
  fallback. Tile records now carry their iteration limit.
- Palettes: immutable lookup textures shared across all tile recolours; texture
  identity and sample invariance checked by the headless tests.
- Idle work: completion-driven MTKView wakeups, motion/fade-only continuous
  drawing, unchanged-demand early returns, pressure-only LRU sorting, and hardware
  presentation timing. Refresh rate comes from the view window. Regression checks
  idle demand, palette wakeups and resume; iOS metadata/build checks pass.
- Independent product goldens: CPU Double pixel-centre images cover whole-set,
  offset fractional LOD, Seahorse detail and mip boundaries. References are
  generated without invoking the app. Legacy fixtures remain unchanged, with
  tighter precision/location-specific error budgets and explicit headroom.
