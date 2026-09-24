// The lab's first Metal kernels: whole-frame UInt16 escape counts in Float and
// FloatFloat, with the original escape radius of 2.  They are benchmark subjects
// and golden-test variants (`metal` and `metal-double` on the legacy pipeline,
// run by Lab/); the viewer's kernels are in GPUCompute.metal.

#include <metal_stdlib>
#include "FloatFloat.h"
using namespace metal;

// FloatFloat's error-free transforms require the written rounding points.
// Build with MTL_FAST_MATH=NO: reassociation can erase the low-word residuals.
// Contraction is disabled per function in FloatFloat.h rather than here: a
// file-scope pragma also covers mandelbrotIterations, which is plain Float and
// wants its multiply-adds contracted.

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

    float real = realMin + ((float(gid.x) + 0.5f) / float(params.width)) * realSpan;
    float imag = imagMax - ((float(gid.y) + 0.5f) / float(params.height)) * imagSpan;

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
    // Keep non-square viewport geometry in FloatFloat too.
    float2 aspect = dd_div(dd_from_float(float(params.height)), dd_from_float(float(params.width)));
    float2 imagSpan = dd_mul(realSpan, aspect);
    float2 realMin = dd_sub(params.centerX, dd_mul_float(realSpan, 0.5f));
    float2 imagMax = dd_add(params.centerY, dd_mul_float(imagSpan, 0.5f));

    // Pixel centres: (x + 0.5) / width of the way across, exact in a float.
    float2 normXdd = dd_div(float2(float(gid.x) + 0.5f, 0.0f), float2(float(params.width), 0.0f));
    float2 normYdd = dd_div(float2(float(gid.y) + 0.5f, 0.0f), float2(float(params.height), 0.0f));
    float2 real = dd_add(realMin, dd_mul(realSpan, normXdd));
    float2 imag = dd_sub(imagMax, dd_mul(imagSpan, normYdd));

    float2 zr = float2(0.0f, 0.0f);
    float2 zi = float2(0.0f, 0.0f);
    uint iteration = 0;

    while (iteration < params.maxIterations) {
        float2 zr2 = dd_mul(zr, zr);
        float2 zi2 = dd_mul(zi, zi);
        float2 mag = dd_add(zr2, zi2);
        if (mag.x > 4.0f || (mag.x == 4.0f && mag.y > 0.0f)) {
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
