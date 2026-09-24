// The sample record every compute kernel writes (RG32Uint): an exact escape
// count and a float smooth correction, with three reserved counts for status.
// Mirrors Core/Precision/SampleRecord.swift.

#pragma once
#include <metal_stdlib>
using namespace metal;
constant uint sampleCapped = 0xffffffffu;
constant uint sampleUnfinished = 0xfffffffeu;
constant uint sampleGlitched = 0xfffffffdu;
inline uint4 sampleStatus(uint status) { return uint4(status,0,0,0); }
inline uint4 escapeSample(uint n, float correction) {
    // Clamp the smooth value without changing the actual escape iteration.
    return uint4(n,as_type<uint>(max(correction,-float(n))),0,0);
}
