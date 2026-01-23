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
