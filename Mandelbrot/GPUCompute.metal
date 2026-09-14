#include <metal_stdlib>
#include "FloatFloat.h"
using namespace metal;
#pragma clang fp contract(off)

struct GPUParameters {
    float2 realMin, imagMax, stepX, stepY;
    uint width, height, maxIterations, precision;
    uint rowStart, rowCount, smooth, padding;
};

// Negative samples mark points that reached the iteration cap. Raw iteration
// data stays independent of palettes and uses four bytes per pixel.
kernel void renderSamples(texture2d<float, access::write> out [[texture(0)]],
                          constant GPUParameters &p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    uint2 point = uint2(gid.x, gid.y + p.rowStart);
    if (point.x >= p.width || point.y >= p.height || gid.y >= p.rowCount) return;
    uint n = 0;
    if (p.precision == 0) {
        float cr = p.realMin.x + float(point.x) * p.stepX.x;
        float ci = p.imagMax.x - float(point.y) * p.stepY.x;
        float zr = 0, zi = 0;
        while (zr*zr+zi*zi <= 4.0f && n < p.maxIterations) {
            float next = zr*zr-zi*zi+cr;
            zi = 2.0f*zr*zi+ci; zr = next; ++n;
        }
    } else {
        float2 cr = dd_add(p.realMin, dd_mul_float(p.stepX,float(point.x)));
        float2 ci = dd_sub(p.imagMax, dd_mul_float(p.stepY,float(point.y)));
        float2 zr = 0, zi = 0;
        while (n < p.maxIterations) {
            float2 zr2 = dd_mul(zr,zr), zi2 = dd_mul(zi,zi);
            float2 mag = dd_add(zr2,zi2);
            if (mag.x > 4.0f || (mag.x == 4.0f && mag.y > 0.0f)) break;
            float2 next = dd_add(dd_sub(zr2,zi2),cr);
            zi = dd_add(dd_mul_float(dd_mul(zr,zi),2),ci); zr = next; ++n;
        }
    }
    out.write(float4(n == p.maxIterations ? -1.0f : float(n)),point);
}

float3 hsvRGB(float h, float s, float v) {
    float3 k = fract(float3(h) + float3(0,2.0/3.0,1.0/3.0));
    return v * mix(float3(1), clamp(abs(k*6-3)-1,0.0f,1.0f),s);
}
float3 legacyColour(float iteration) {
    if (iteration < 0) return 0;
    float t=iteration/200.0f, shift=0;
    if(iteration >= 200) { float l=log2(t); t=fract(l); shift=(floor(l)+1)/6; }
    float3 rgb=float3(9*(1-t)*t*t*t,15*(1-t)*(1-t)*t*t,8.5*(1-t)*(1-t)*(1-t)*t);
    if(shift != 0) {
        float hi=max(rgb.x,max(rgb.y,rgb.z)),lo=min(rgb.x,min(rgb.y,rgb.z)),delta=hi-lo;
        float h=0;
        if(delta>0) {
            if(hi==rgb.x) h=(rgb.y-rgb.z)/delta;
            else if(hi==rgb.y) h=(rgb.z-rgb.x)/delta+2;
            else h=(rgb.x-rgb.y)/delta+4;
        }
        rgb=hsvRGB(fract(h/6+shift+1),hi==0?0:delta/hi,hi);
    }
    return clamp(rgb,0.0f,1.0f);
}
kernel void colourSamples(texture2d<float,access::read> samples [[texture(0)]],
                          texture2d<float,access::write> output [[texture(1)]],
                          uint2 gid [[thread_position_in_grid]]) {
    if(gid.x>=output.get_width() || gid.y>=output.get_height()) return;
    output.write(float4(legacyColour(samples.read(gid).x),1),gid);
}

struct DrawUniforms { float4 rect; float4 uv; float opacity; float blend; uint border; uint level; };
struct QuadOutput { float4 position [[position]]; float2 uv; };
vertex QuadOutput quadVertex(uint index [[vertex_id]], constant DrawUniforms &p [[buffer(0)]]) {
    constexpr float2 corners[] = {float2(0,0),float2(1,0),float2(0,1),float2(1,0),float2(1,1),float2(0,1)};
    float2 c=corners[index];
    return {float4(mix(p.rect.x,p.rect.z,c.x),mix(p.rect.y,p.rect.w,c.y),0,1),
            mix(p.uv.xy,p.uv.zw,c)};
}
fragment float4 imageFragment(QuadOutput in [[stage_in]],texture2d<float> image [[texture(0)]],
                              constant DrawUniforms &p [[buffer(0)]]) {
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    return float4(image.sample(s,in.uv).rgb,p.opacity);
}
