#pragma once
#include <metal_stdlib>
using namespace metal;

// The error-free transforms below depend on the written rounding points, so
// each one disables implicit multiply-add contraction for its own body:
// contracting `a * b + c` would discard the residual the transform recovers.
// dd_mul calls fma explicitly where it wants one. Scope these per function
// rather than at file scope — this header is included above the plain Float
// kernels in MandelbrotCompute.metal, GPUCompute.metal and Perturbation.metal,
// and a file-scope pragma silently slowed those down by ~10%.

inline float2 dd_from_float(float value) {
    return float2(value, 0.0f);
}

inline float2 dd_normalize(float hi, float lo) {
#pragma clang fp contract(off)
    float sum = hi + lo;
    float err = lo - (sum - hi);
    return float2(sum, err);
}

inline float2 dd_add(float2 a, float2 b) {
#pragma clang fp contract(off)
    float s = a.x + b.x;
    float v = s - a.x;
    float t = ((b.x - v) + (a.x - (s - v))) + a.y + b.y;
    return dd_normalize(s, t);
}

inline float2 dd_sub(float2 a, float2 b) {
#pragma clang fp contract(off)
    float s = a.x - b.x;
    float v = s - a.x;
    float t = ((-b.x - v) + (a.x - (s - v))) + a.y - b.y;
    return dd_normalize(s, t);
}

inline float2 dd_mul(float2 a, float2 b) {
#pragma clang fp contract(off)
    float p = a.x * b.x;
    float err = fma(a.x, b.x, -p);
    err += a.x * b.y + a.y * b.x;
    float s = p + err;
    float t = err - (s - p);
    t += a.y * b.y;
    return dd_normalize(s, t);
}

inline float2 dd_mul_float(float2 a, float b) {
    return dd_mul(a, dd_from_float(b));
}

inline float2 dd_div(float2 a, float2 b) {
#pragma clang fp contract(off)
    float q1 = a.x / b.x;
    float2 q1dd = dd_from_float(q1);
    float2 prod = dd_mul(b, q1dd);
    float2 r = dd_sub(a, prod);
    float q2 = r.x / b.x;
    return dd_add(q1dd, dd_from_float(q2));
}

