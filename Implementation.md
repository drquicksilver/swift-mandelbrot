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

Next: GPU pipeline (1.4), smooth palettes (1.5), developer panel (1.7), platform
input (1.8), then tile stages 2.1(a–d). No perturbation or automatic iteration-depth
heuristic is included in this milestone. Colour mipmaps are disposable
palette-dependent display data; raw sample tiles remain authoritative.
