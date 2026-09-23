#include <metal_stdlib>
#include "FloatFloat.h"
#include "SampleRecord.h"
using namespace metal;
// Contraction is disabled per function in FloatFloat.h; a file-scope pragma
// here would also cover the plain Float paths below, which want contraction.

struct GPUParameters {
    float2 realMin, imagMax, stepX, stepY;
    uint width, height, maxIterations, precision;
    uint rowStart, rowCount, smooth, padding;
};

// Strictly interior points never escape. Leave a margin for Float rounding at
// the cardioid and period-two bulb boundaries.
inline bool insideMainSet(float cr, float ci) {
    float ci2 = ci * ci;
    float bulbReal = cr + 1.0f;
    float bulbRadius2 = bulbReal * bulbReal + ci2;
    float cardioidReal = cr - 0.25f;
    float q = cardioidReal * cardioidReal + ci2;
    return bulbRadius2 < 0.0624999f || q * (q + cardioidReal) < 0.249999f * ci2;
}

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
        if (insideMainSet(cr, ci)) {
            out.write(sampleStatus(sampleCapped), point);
            return;
        }
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
// The companion rotates like the main view: pixel offsets are measured from the
// centre of the panel and turned by the viewport's angle before they are scaled
// into the plane.  `step` is the same in both axes (square pixels), so one step
// can scale a rotated offset that mixes them.
struct JuliaParameters {
    GPUParameters image;
    float2 cr, ci;
    float2 centreR, centreI;
    float cosAngle, sinAngle;
};
kernel void renderJulia(texture2d<uint, access::write> out [[texture(0)]],
                        constant JuliaParameters &j [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    constant GPUParameters &p = j.image;
    if (gid.x >= p.width || gid.y >= p.height) return;
    uint n = 0;
    float magnitude = 0;
    // Offsets from the panel centre in pixels, y upwards, then rotated.
    float vx = float(gid.x) + 0.5f - float(p.width) * 0.5f;
    float vy = float(p.height) * 0.5f - (float(gid.y) + 0.5f);
    float ox = j.cosAngle * vx - j.sinAngle * vy;
    float oy = j.sinAngle * vx + j.cosAngle * vy;
    if (p.precision == 0) {
        float zr = j.centreR.x + ox * p.stepX.x;
        float zi = j.centreI.x + oy * p.stepX.x;
        float cr = j.cr.x, ci = j.ci.x;
        while (zr*zr+zi*zi <= 65536.0f && n < p.maxIterations) {
            float next = zr*zr-zi*zi+cr;
            zi = 2.0f*zr*zi+ci; zr = next; ++n;
        }
        magnitude = zr*zr+zi*zi;
    } else {
        float2 zr = dd_add(j.centreR, dd_mul_float(p.stepX, ox));
        float2 zi = dd_add(j.centreI, dd_mul_float(p.stepX, oy));
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
struct ColourParameters { float density; float offset; uint smooth; uint logarithmic; uint limit; };
// Where a sample falls in the palette's cycle, before the offset.  Linear
// phase is count / density in double-float, and only the high half may be
// reduced by fract: at a million iterations a float cannot hold a correction
// of 0.003, so adding the halves first, as 2.11 did, threw the smooth shading
// away.  Logarithmic phase is small enough for a float.  The density enters
// as its reciprocal, which a caller colouring many samples works out once:
// the compositor colours four per level per pixel, and a division each was
// most of its cost.
float2 densityReciprocal(constant ColourParameters &settings) {
    return dd_div(float2(1,0),float2(settings.density,0));
}
float palettePhase(uint2 raw, constant ColourParameters &settings, float2 reciprocal) {
    float correction=as_type<float>(raw.y);
    if(settings.logarithmic != 0) return log2(max(1.0f,float(raw.x)+correction))*reciprocal.x;
    float2 phase=dd_mul(dd_add(float2(float(raw.x),0),float2(correction,0)),reciprocal);
    return fract(phase.x)+phase.y;
}
kernel void colourSamples(texture2d<uint,access::read> samples [[texture(0)]],
                          texture2d<float,access::write> output [[texture(1)]],
                          texture1d<float> palette [[texture(2)]],
                          constant ColourParameters &settings [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
    if(gid.x>=output.get_width() || gid.y>=output.get_height()) return;
    uint2 raw = samples.read(gid).xy;
    bool capped = raw.x >= sampleGlitched || raw.x >= settings.limit;
    float value = capped ? -1.0f : float(raw.x);
    constexpr sampler lookup(coord::normalized, address::repeat, filter::linear);
    float3 rgb = capped ? float3(0.005,0.008,0.014) : palette.sample(lookup,palettePhase(raw,settings,densityReciprocal(settings))+settings.offset).rgb;
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
float3 texelColour(uint2 raw, texture1d<float> palette, constant ColourParameters &settings,
                   float2 reciprocal) {
    if(raw.x>=sampleGlitched || raw.x>=settings.limit) return float3(0.005,0.008,0.014);
    constexpr sampler lookup(coord::normalized,address::repeat,filter::linear);
    return palette.sample(lookup,palettePhase(raw,settings,reciprocal)+settings.offset).rgb;
}
// A level's colour at a point: the four samples around it, each coloured,
// then blended -- bilinear filtering of colours, as a sampler did for the
// colour textures before 2.11.  Texel i is centred on (i + 0.5) / size, which
// is what the compositor's UVs assume; the tile's one-texel gutter is what
// makes the blend continuous across tile edges.
float3 colourSample(texture2d<uint> samples, float2 uv, texture1d<float> palette,
                     constant ColourParameters &settings, float2 reciprocal) {
    float2 size=float2(samples.get_width(),samples.get_height());
    float2 position=clamp(uv,0.0f,1.0f)*size-0.5f;
    float2 corner=floor(position),t=position-corner;
    // One gather per component fetches the whole 2x2 footprint around the
    // point, in the order (left, bottom), (right, bottom), (right, top),
    // (left, top) -- where "top" is the lower row index.
    constexpr sampler nearest(coord::normalized,address::clamp_to_edge,filter::nearest);
    float2 centre=(corner+1.0f)/size;
    uint4 counts=samples.gather(nearest,centre,int2(0),component::x);
    uint4 corrections=samples.gather(nearest,centre,int2(0),component::y);
    float3 top=mix(texelColour(uint2(counts.w,corrections.w),palette,settings,reciprocal),
                   texelColour(uint2(counts.z,corrections.z),palette,settings,reciprocal),t.x);
    float3 bottom=mix(texelColour(uint2(counts.x,corrections.x),palette,settings,reciprocal),
                      texelColour(uint2(counts.y,corrections.y),palette,settings,reciprocal),t.x);
    return mix(top,bottom,t.y);
}
fragment float4 tileFragment(QuadOutput in [[stage_in]],texture2d<uint> coarse [[texture(0)]],
                             texture2d<uint> base [[texture(1)]],texture2d<uint> fine [[texture(2)]],texture2d<uint> previousFine [[texture(3)]],
                             texture1d<float> palette [[texture(4)]],
                             constant TileDrawUniforms &p [[buffer(0)]], constant ColourParameters &colour [[buffer(1)]]) {
    // Interpolate colours, never iteration counts or inside/outside flags.
    float2 reciprocal=densityReciprocal(colour);
    float3 rgb=colourSample(base,mix(p.baseUV.xy,p.baseUV.zw,in.uv),palette,colour,reciprocal);
    if(p.baseMix<1) rgb=mix(colourSample(coarse,mix(p.coarseUV.xy,p.coarseUV.zw,in.uv),palette,colour,reciprocal),rgb,p.baseMix);
    if(p.fineMix>0) {
        float3 detail=colourSample(fine,mix(p.fineUV.xy,p.fineUV.zw,in.uv),palette,colour,reciprocal);
        if(p.fineFade<1) detail=mix(colourSample(previousFine,mix(p.previousFineUV.xy,p.previousFineUV.zw,in.uv),palette,colour,reciprocal),detail,p.fineFade);
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

// Zoom movies: each output frame samples the two keyframes that bracket it,
// through an affine map built on the CPU from the two viewports, and cross-fades.
struct MovieUniforms { float2 originA, duA, dvA, originB, duB, dvB; float blend, pad0, pad1, pad2; };
vertex QuadOutput movieVertex(uint index [[vertex_id]]) {
    constexpr float2 corners[] = {float2(0,0),float2(1,0),float2(0,1),float2(1,0),float2(1,1),float2(0,1)};
    float2 c=corners[index];
    return {float4(c.x*2-1,1-c.y*2,0,1),c};
}
fragment float4 movieFragment(QuadOutput in [[stage_in]],texture2d<float> first [[texture(0)]],
                              texture2d<float> second [[texture(1)]],
                              constant MovieUniforms &p [[buffer(0)]]) {
    constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
    float2 a=p.originA+in.uv.x*p.duA+in.uv.y*p.dvA;
    float2 b=p.originB+in.uv.x*p.duB+in.uv.y*p.dvB;
    // A frame is up to twice as wide as the deeper keyframe it samples, so its
    // outer band falls outside that texture, where clamping would smear the edge
    // row across it.  The shallower keyframe always covers the frame, so the
    // deeper one's weight fades out as its sample leaves it.
    float2 edge=min(b,1.0f-b);
    float inside=smoothstep(0.0f,0.01f,min(edge.x,edge.y));
    return float4(mix(first.sample(s,a).rgb,second.sample(s,b).rgb,p.blend*inside),1);
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
        if(insideMainSet(cr,ci)) { out.write(sampleStatus(sampleCapped),point);return; }
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

// Small GPU summary; no per-pixel readback in the viewer.
kernel void summariseSamples(texture2d<uint,access::read> samples [[texture(0)]],
 device atomic_uint *summary [[buffer(0)]], uint2 pos [[thread_position_in_grid]]) {
 if(pos.x>=samples.get_width() || pos.y>=samples.get_height()) return;
 uint n=samples.read(pos).x;
 if(n==sampleCapped) atomic_fetch_add_explicit(summary,1,memory_order_relaxed);
 else if(n<sampleGlitched) atomic_fetch_max_explicit(summary+1,n,memory_order_relaxed);
}

kernel void histogramSamples(texture2d<uint,access::read> samples [[texture(0)]],
 device atomic_uint *histogram [[buffer(0)]], uint2 pos [[thread_position_in_grid]]) {
 if(pos.x>=samples.get_width() || pos.y>=samples.get_height()) return;
 uint n=samples.read(pos).x;
 if(n>=sampleGlitched) return;
 uint bucket=min(255u,uint(log2(max(1.0f,float(n)))*8.0f));
 atomic_fetch_add_explicit(histogram+bucket,1,memory_order_relaxed);
}
