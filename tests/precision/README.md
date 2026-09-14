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
