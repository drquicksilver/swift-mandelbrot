# Fixed escape-count fixtures

Each manifest entry records an immutable viewport, CPU Double reference counts
(little-endian UInt16, row-major), reference PNG, and tolerances. `make golden`
runs every applicable renderer against them. GPU access is mandatory;
unavailable GPU tests fail rather than silently passing. Float renderers are
excluded at 1e7 and 1e10 because they cannot resolve those viewports. The tests
also require real detail, preventing a uniform capped image from passing.

Every renderer samples each pixel at its centre, `left + (x + 0.5) * step`,
as the tiles do; the fixtures were re-recorded for that convention in 2.17.

References use the legacy escape radius 2 and palette, intentionally retained as
an independent numerical regression while the product pipeline evolves. Smooth
GPU output has its own tests. CPU variants must match exactly, except
`coord-precompute`, whose coordinates round differently by an ulp;
reduced-precision renderers have measured bounded boundary differences.
Reference PNG bytes are checked on this macOS toolchain; updating ImageIO may
require a reviewed re-encode.

To deliberately regenerate: `python3 tests/cli/test_golden.py APP --record`.
Never regenerate merely to make a failing renderer pass. Review counts and images.

`product/` holds pixel-centred PNGs of the tiled compositor, written by the
independent CPU oracle in `product_reference.py`, and `deep/` holds Decimal
samples at 1e50–1e1000 and the period-312 minibrot, written by the oracles in
`precision/`. Neither is ever produced by the app.
