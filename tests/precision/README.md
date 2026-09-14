# Reference arithmetic spike

`spike.swift` compiles with the vendored BigInt sources, using `swiftc -O`.
`spike.cpp` compiles with `clang++ -O3 -std=c++17`, and the include directories
of Boost.Multiprecision and Boost.Config **boost-1.90.0**. No other Boost
libraries are needed (`BOOST_MP_STANDALONE`). Boost is benchmark-only, not
shipped with the application. Both repositories carry the Boost Software License.

Pinned upstream commits:
- https://github.com/boostorg/multiprecision/tree/529dfac199191a7eb8a5eb7f47256eff6d0db993
- https://github.com/boostorg/config/tree/a7d5a9b05d70c9cfea980dc3539ca3d3461411b3

Both perform five measured repetitions of ten 1,000-step orbits at
(-0.743643887037151, 0.13182590390533), starting at zero. Precision is
ceil(log2(10) * decimal depth) + 64 bits. Decimal construction is outside the
timer; checksum keeps the result observable. This measures arithmetic, not
GPU work, BLA construction or allocation of a saved reference orbit. Swift
fixed point truncates products, whereas Boost rounds floating-point products.

Reproduce from a clean checkout on a Mac with Xcode command-line tools, Python 3
and Git:

```sh
python3 tests/precision/reproduce.py
```

The script fetches the exact commits above into `/tmp/mandelbrot-boost-repro`,
checks the revisions and rejects modified dependency trees. It compiles Swift
with `-O -whole-module-optimization` (matching the app’s Release compilation mode)
and C++ with `-O3`, and writes `evidence/review-deep/libraries.json`.
Use `--cache PATH` or `--output PATH` to choose other locations. Run on an idle
machine. Boost is fetched for these benchmarks only and is not linked into or
copied into the app.

`reference_spike.swift` calls the actual saved-reference generator at the
period-312 minibrot fixture, with a 60,000-iteration cap and 461/512 bits (full
image / cache precision band). `reference_spike.cpp` includes orbit storage,
FloatFloat mantissa/exponent conversion and the same bailout/cap. Both record
five timings and actual orbit lengths. Boost uses floating-point rounding rather
than fixed-point truncation, so chaotic escape lengths and checksums can differ;
compare per-iteration times as well as total latency. This is closer to the
application's workload than the original arithmetic-only spike, but does not
validate a replacement backend or include the GPU, cache or BLA.
