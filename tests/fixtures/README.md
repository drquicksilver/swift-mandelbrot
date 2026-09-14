# Fixed escape-count fixtures

Each manifest entry records an immutable viewport, CPU Double reference counts
(little-endian UInt16, row-major), reference PNG, and tolerances. `make test` runs
all applicable renderers, unit tests and CLI tests. GPU access is mandatory;
unavailable GPU tests fail rather than silently passing. Float renderers are
excluded at 1e7 and 1e10 because they cannot resolve those viewports. The tests
also require real detail, preventing a uniform capped image from passing.

References use the legacy escape radius 2 and palette, intentionally retained as
an independent numerical regression while the product pipeline evolves. Smooth
GPU output has its own tests. CPU variants must match exactly; reduced-precision
renderers have measured bounded boundary differences. Reference PNG bytes are
checked on this macOS toolchain; updating ImageIO may require a reviewed re-encode.

To deliberately regenerate: `python3 tests/test_golden.py APP --record`.
Never regenerate merely to make a failing renderer pass. Review counts and images.
