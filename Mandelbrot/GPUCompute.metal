#include <metal_stdlib>
#include "FloatFloat.h"
#include "SampleRecord.h"
using namespace metal;
#pragma clang fp contract(off)

struct GPUParameters {
    float2 realMin, imagMax, stepX, stepY;
    uint width, height, maxIterations, precision;
    uint rowStart, rowCount, smooth, padding;
};

// Integer escape count and fractional smooth correction stay separate (8 bytes).
kernel void renderSamples(texture2d<uint, access::write> out [[texture(0)]],
                          constant GPUParameters &p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    uint2 point = uint2(gid.x, gid.y + p.rowStart);
    if (point.x >= p.width || point.y >= p.height || gid.y >= p.rowCount) return;
    uint n = 0;
    float magnitude = 0;
    float bailout = p.smooth != 0 ? 65536.0f : 4.0f;
    if (p.precision == 0) {
        float cr = p.realMin.x + float(point.x) * p.stepX.x;
        float ci = p.imagMax.x - float(point.y) * p.stepY.x;
        float zr = 0, zi = 0;
        while (zr*zr+zi*zi <= bailout && n < p.maxIterations) {
            float next = zr*zr-zi*zi+cr;
            zi = 2.0f*zr*zi+ci; zr = next; ++n;
        }
        magnitude = zr*zr+zi*zi;
    } else {
        float2 cr = dd_add(p.realMin, dd_mul_float(p.stepX,float(point.x)));
        float2 ci = dd_sub(p.imagMax, dd_mul_float(p.stepY,float(point.y)));
        float2 zr = 0, zi = 0;
        while (n < p.maxIterations) {
            float2 zr2 = dd_mul(zr,zr), zi2 = dd_mul(zi,zi);
            float2 mag = dd_add(zr2,zi2);
            magnitude = mag.x + mag.y;
            if (mag.x > bailout || (mag.x == bailout && mag.y > 0.0f)) break;
            float2 next = dd_add(dd_sub(zr2,zi2),cr);
            zi = dd_add(dd_mul_float(dd_mul(zr,zi),2),ci); zr = next; ++n;
        }
    }
    out.write(n == p.maxIterations ? sampleStatus(sampleCapped) : escapeSample(n, p.smooth ? 1-log2(log2(sqrt(magnitude))) : 0),point);
}

// The Julia companion: one small render per frame, sampled at pixel centres,
// sharing the sample record format, the palette kernel and the draw pipeline.
struct JuliaParameters { GPUParameters image; float2 cr, ci; };
kernel void renderJulia(texture2d<uint, access::write> out [[texture(0)]],
                        constant JuliaParameters &j [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    constant GPUParameters &p = j.image;
    if (gid.x >= p.width || gid.y >= p.height) return;
    uint n = 0;
    float magnitude = 0;
    if (p.precision == 0) {
        float zr = p.realMin.x + (float(gid.x) + 0.5f) * p.stepX.x;
        float zi = p.imagMax.x - (float(gid.y) + 0.5f) * p.stepY.x;
        float cr = j.cr.x, ci = j.ci.x;
        while (zr*zr+zi*zi <= 65536.0f && n < p.maxIterations) {
            float next = zr*zr-zi*zi+cr;
            zi = 2.0f*zr*zi+ci; zr = next; ++n;
        }
        magnitude = zr*zr+zi*zi;
    } else {
        float2 zr = dd_add(p.realMin, dd_mul_float(p.stepX, float(gid.x) + 0.5f));
        float2 zi = dd_sub(p.imagMax, dd_mul_float(p.stepY, float(gid.y) + 0.5f));
        while (n < p.maxIterations) {
            float2 zr2 = dd_mul(zr,zr), zi2 = dd_mul(zi,zi);
            float2 mag = dd_add(zr2,zi2);
            magnitude = mag.x + mag.y;
            if (mag.x > 65536.0f || (mag.x == 65536.0f && mag.y > 0.0f)) break;
            float2 next = dd_add(dd_sub(zr2,zi2), j.cr);
            zi = dd_add(dd_mul_float(dd_mul(zr,zi),2), j.ci); zr = next; ++n;
        }
    }
    out.write(n == p.maxIterations ? sampleStatus(sampleCapped)
              : escapeSample(n, 1-log2(log2(sqrt(magnitude)))), gid);
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
struct ColourParameters { float density; float offset; uint smooth; uint limit; };
kernel void colourSamples(texture2d<uint,access::read> samples [[texture(0)]],
                          texture2d<float,access::write> output [[texture(1)]],
                          texture1d<float> palette [[texture(2)]],
                          constant ColourParameters &settings [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
    if(gid.x>=output.get_width() || gid.y>=output.get_height()) return;
    uint2 raw = samples.read(gid).xy;
    bool capped = raw.x >= sampleGlitched || raw.x >= settings.limit;
    float correction = as_type<float>(raw.y);
    float value = capped ? -1.0f : float(raw.x);
    float2 phase = dd_div(dd_add(float2(float(raw.x),0),float2(correction,0)),float2(settings.density,0));
    constexpr sampler lookup(coord::normalized, address::repeat, filter::linear);
    float3 rgb = capped ? float3(0.005,0.008,0.014) : palette.sample(lookup,fract(phase.x)+phase.y+settings.offset).rgb;
    output.write(float4(settings.smooth != 0 ? rgb : legacyColour(value),1),gid);
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

struct TileDrawUniforms {
    float4 rect, coarseUV, baseUV, fineUV, previousFineUV;
    float baseMix, fineMix;
    uint border;
    int level;
    float fineFade;
    float4 spin;
    float padding0, padding1, padding2;
};
vertex QuadOutput tileVertex(uint index [[vertex_id]],constant TileDrawUniforms &p [[buffer(0)]]) {
    constexpr float2 corners[] = {float2(0,0),float2(1,0),float2(0,1),float2(1,0),float2(1,1),float2(0,1)};
    float2 c=corners[index];
    float2 position=float2(mix(p.rect.x,p.rect.z,c.x),mix(p.rect.y,p.rect.w,c.y));
    // Tiles are axis-aligned in the plane, so a rotated view draws rotated quads.
    float2 middle=float2((p.rect.x+p.rect.z)*0.5,(p.rect.y+p.rect.w)*0.5);
    float2 points=float2((position.x-middle.x)*p.spin.z*0.5,-(position.y-middle.y)*p.spin.w*0.5);
    float2 turned=float2(points.x*p.spin.x-points.y*p.spin.y,points.x*p.spin.y+points.y*p.spin.x);
    position=middle+float2(turned.x*2/p.spin.z,-turned.y*2/p.spin.w);
    return {float4(position,0,1),c};
}
bool digitPixel(float2 point,uint digit) {
    constexpr uint masks[]={63,6,91,79,102,109,125,7,127,111};
    uint mask=masks[min(digit,9u)];
    float x=point.x,y=point.y;
    if(x<0 || x>=5 || y<0 || y>=9) return false;
    return ((mask&1) && y<1 && x>=1 && x<4) || ((mask&2) && x>=4 && y>=1 && y<4)
        || ((mask&4) && x>=4 && y>=5 && y<8) || ((mask&8) && y>=8 && x>=1 && x<4)
        || ((mask&16) && x<1 && y>=5 && y<8) || ((mask&32) && x<1 && y>=1 && y<4)
        || ((mask&64) && y>=4 && y<5 && x>=1 && x<4);
}
fragment float4 tileFragment(QuadOutput in [[stage_in]],texture2d<float> coarse [[texture(0)]],
                             texture2d<float> base [[texture(1)]],texture2d<float> fine [[texture(2)]],texture2d<float> previousFine [[texture(3)]],
                             constant TileDrawUniforms &p [[buffer(0)]]) {
    constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
    // Interpolate colours, never iteration counts or inside/outside flags.
    float3 rgb=base.sample(s,mix(p.baseUV.xy,p.baseUV.zw,in.uv)).rgb;
    if(p.baseMix<1) rgb=mix(coarse.sample(s,mix(p.coarseUV.xy,p.coarseUV.zw,in.uv)).rgb,rgb,p.baseMix);
    if(p.fineMix>0) {
        float3 detail=fine.sample(s,mix(p.fineUV.xy,p.fineUV.zw,in.uv)).rgb;
        if(p.fineFade<1) detail=mix(previousFine.sample(s,mix(p.previousFineUV.xy,p.previousFineUV.zw,in.uv)).rgb,detail,p.fineFade);
        rgb=mix(rgb,detail,p.fineMix);
    }
    if(p.border) {
        float2 pixel=in.uv/max(fwidth(in.uv),float2(1e-6));
        float2 edge=min(in.uv,1-in.uv)/max(fwidth(in.uv),float2(1e-6));
        if(min(edge.x,edge.y)<1.25) rgb=float3(1);
        float2 digit=(pixel-float2(5,5))/1.5f;
        uint level=uint(abs(p.level));
        bool ink=false;
        if(p.level<0) { ink=digit.x>=0 && digit.x<4 && digit.y>=4 && digit.y<5;digit.x-=6; }
        for(uint divisor=10000;divisor>=10;divisor/=10) {
            if(level>=divisor) { ink=ink || digitPixel(digit,(level/divisor)%10);digit.x-=6; }
        }
        ink=ink || digitPixel(digit,level%10);
        if(ink) rgb=float3(1,0.9,0.15);
    }
    return float4(rgb,1);
}

// Only the worker sees unfinished records; counts remain exact at the product cap.
struct TileWorkParameters { GPUParameters image; uint start, count, padding0, padding1; };
kernel void resumeTile(texture2d<uint,access::read_write> out [[texture(0)]],
                       device float4 *states [[buffer(1)]],
                       constant TileWorkParameters &work [[buffer(0)]],uint2 point [[thread_position_in_grid]]) {
    constant GPUParameters &p=work.image;
    if(point.x>=p.width || point.y>=p.height) return;
    uint index=point.y*p.width+point.x;
    if(work.start==0 && (p.padding&1u) && out.read(point).x != sampleCapped) return;
    if(work.start>0 && out.read(point).x != sampleUnfinished) return;
    float4 state=work.start==0 ? float4(0) : states[index];
    uint n=work.start,end=min(p.maxIterations,work.start+work.count);
    float magnitude=0;bool escaped=false;
    if(p.precision==0) {
        float cr=p.realMin.x+float(point.x)*p.stepX.x,ci=p.imagMax.x-float(point.y)*p.stepY.x;
        float zr=state.x,zi=state.z;
        while(n<end) {
            magnitude=zr*zr+zi*zi;
            if(magnitude>65536.0f) { escaped=true;break; }
            float next=zr*zr-zi*zi+cr;zi=2.0f*zr*zi+ci;zr=next;++n;
        }
        state=float4(zr,0,zi,0);
    } else {
        float2 cr=dd_add(p.realMin,dd_mul_float(p.stepX,float(point.x)));
        float2 ci=dd_sub(p.imagMax,dd_mul_float(p.stepY,float(point.y)));
        float2 zr=state.xy,zi=state.zw;
        while(n<end) {
            float2 zr2=dd_mul(zr,zr),zi2=dd_mul(zi,zi),mag=dd_add(zr2,zi2);
            magnitude=mag.x+mag.y;
            if(mag.x>65536.0f || (mag.x==65536.0f && mag.y>0)) { escaped=true;break; }
            float2 next=dd_add(dd_sub(zr2,zi2),cr);
            zi=dd_add(dd_mul_float(dd_mul(zr,zi),2),ci);zr=next;++n;
        }
        state=float4(zr,zi);
    }
    states[index]=state;
    out.write(escaped ? escapeSample(n,1-log2(log2(sqrt(magnitude)))) : sampleStatus(n==p.maxIterations ? sampleCapped : sampleUnfinished),point);
}

// Child ordering is top-left, top-right, bottom-left, bottom-right. Each parent
// interior pixel is the exact box average of four coloured child pixels.
// Keep the directly sampled gutter: neighbours may not be cached yet.
kernel void averageChildren(texture2d<float,access::read> a [[texture(0)]],
                            texture2d<float,access::read> b [[texture(1)]],
                            texture2d<float,access::read> c [[texture(2)]],
                            texture2d<float,access::read> d [[texture(3)]],
                            texture2d<float,access::read> parent [[texture(4)]],
                            texture2d<float,access::write> out [[texture(5)]],
                            uint2 gid [[thread_position_in_grid]]) {
    if(gid.x>=258 || gid.y>=258) return;
    if(gid.x==0 || gid.y==0 || gid.x==257 || gid.y==257) { out.write(parent.read(gid),gid);return; }
    uint2 full=(gid-1)*2,local=full%256+1;
    uint quadrant=(full.x/256)+(full.y/256)*2;
    float4 sum=0;
    for(uint y=0;y<2;++y) for(uint x=0;x<2;++x) {
        uint2 point=local+uint2(x,y);
        switch(quadrant) { case 0:sum+=a.read(point);break;case 1:sum+=b.read(point);break;case 2:sum+=c.read(point);break;default:sum+=d.read(point); }
    }
    out.write(sum*0.25f,gid);
}

// Small GPU summary; no per-pixel readback in the viewer.
kernel void summariseSamples(texture2d<uint,access::read> samples [[texture(0)]],
 device atomic_uint *summary [[buffer(0)]], uint2 pos [[thread_position_in_grid]]) {
 if(pos.x>=samples.get_width() || pos.y>=samples.get_height()) return;
 uint n=samples.read(pos).x;
 if(n==sampleCapped) atomic_fetch_add_explicit(summary,1,memory_order_relaxed);
 else if(n<sampleGlitched) atomic_fetch_max_explicit(summary+1,n,memory_order_relaxed);
}
