//  MandelbrotCompute.metal
//  Mandelbrot
//
//  Created by Jules Bean on 23/01/2026.
//

#include <metal_stdlib>
using namespace metal;

struct MandelbrotParams {
    uint width;
    uint height;
    float centerX;
    float centerY;
    float scale;
    uint maxIterations;
    float baseSpan;
    float padding;
};

struct MandelbrotDoubleParams {
    uint width;
    uint height;
    uint maxIterations;
    uint padding;
    float2 centerX;
    float2 centerY;
    float2 scale;
    float2 baseSpan;
};

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

kernel void mandelbrotIterations(
    device ushort *outIterations [[buffer(0)]],
    constant MandelbrotParams &params [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= params.width || gid.y >= params.height) {
        return;
    }

    float realSpan = params.baseSpan / params.scale;
    float imagSpan = realSpan * (float(params.height) / float(params.width));
    float realMin = params.centerX - realSpan * 0.5f;
    float imagMax = params.centerY + imagSpan * 0.5f;

    float real = realMin + (float(gid.x) / float(max(1u, params.width - 1))) * realSpan;
    float imag = imagMax - (float(gid.y) / float(max(1u, params.height - 1))) * imagSpan;

    float zr = 0.0f;
    float zi = 0.0f;
    uint iteration = 0;

    while (zr * zr + zi * zi <= 4.0f && iteration < params.maxIterations) {
        float temp = zr * zr - zi * zi + real;
        zi = 2.0f * zr * zi + imag;
        zr = temp;
        iteration += 1;
    }

    uint index = gid.y * params.width + gid.x;
    outIterations[index] = ushort(iteration);
}

kernel void mandelbrotIterationsDouble(
    device ushort *outIterations [[buffer(0)]],
    constant MandelbrotDoubleParams &params [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= params.width || gid.y >= params.height) {
        return;
    }

    float2 realSpan = dd_div(params.baseSpan, params.scale);
    float aspect = float(params.height) / float(params.width);
    float2 imagSpan = dd_mul_float(realSpan, aspect);
    float2 realMin = dd_sub(params.centerX, dd_mul_float(realSpan, 0.5f));
    float2 imagMax = dd_add(params.centerY, dd_mul_float(imagSpan, 0.5f));

    float denomX = float(max(1u, params.width - 1));
    float denomY = float(max(1u, params.height - 1));
    float2 normXdd = dd_div(float2(float(gid.x), 0.0f), float2(denomX, 0.0f));
    float2 normYdd = dd_div(float2(float(gid.y), 0.0f), float2(denomY, 0.0f));
    float2 real = dd_add(realMin, dd_mul(realSpan, normXdd));
    float2 imag = dd_sub(imagMax, dd_mul(imagSpan, normYdd));

    float2 zr = float2(0.0f, 0.0f);
    float2 zi = float2(0.0f, 0.0f);
    uint iteration = 0;

    while (iteration < params.maxIterations) {
        float2 zr2 = dd_mul(zr, zr);
        float2 zi2 = dd_mul(zi, zi);
        float2 mag = dd_add(zr2, zi2);
        if (mag.x + mag.y > 4.0f) {
            break;
        }

        float2 temp = dd_add(dd_sub(zr2, zi2), real);
        float2 zrzi = dd_mul(zr, zi);
        zi = dd_add(dd_mul_float(zrzi, 2.0f), imag);
        zr = temp;
        iteration += 1;
    }

    uint index = gid.y * params.width + gid.x;
    outIterations[index] = ushort(iteration);
}
