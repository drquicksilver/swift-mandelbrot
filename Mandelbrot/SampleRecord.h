#pragma once
#include <metal_stdlib>
using namespace metal;
constant uint sampleCapped = 0xffffffffu;
constant uint sampleUnfinished = 0xfffffffeu;
constant uint sampleGlitched = 0xfffffffdu;
inline uint4 sampleStatus(uint status) { return uint4(status,0,0,0); }
inline uint4 escapeSample(uint n, float correction) {
    if(float(n)+correction<0) return uint4(0);
    return uint4(n,as_type<uint>(correction),0,0);
}
