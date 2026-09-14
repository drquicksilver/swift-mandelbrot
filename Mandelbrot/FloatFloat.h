#pragma once
#include <metal_stdlib>
using namespace metal;
#pragma clang fp contract(off)

inline float2 dd_from_float(float value) {
    return float2(value, 0.0f);
}

inline float2 dd_normalize(float hi, float lo) {
    float sum = hi + lo;
    float err = lo - (sum - hi);
    return float2(sum, err);
}

inline float2 dd_add(float2 a, float2 b) {
    float s = a.x + b.x;
    float v = s - a.x;
    float t = ((b.x - v) + (a.x - (s - v))) + a.y + b.y;
    return dd_normalize(s, t);
}

inline float2 dd_sub(float2 a, float2 b) {
    float s = a.x - b.x;
    float v = s - a.x;
    float t = ((-b.x - v) + (a.x - (s - v))) + a.y - b.y;
    return dd_normalize(s, t);
}

inline float2 dd_mul(float2 a, float2 b) {
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
    float q1 = a.x / b.x;
    float2 q1dd = dd_from_float(q1);
    float2 prod = dd_mul(b, q1dd);
    float2 r = dd_sub(a, prod);
    float q2 = r.x / b.x;
    return dd_add(q1dd, dd_from_float(q2));
}

