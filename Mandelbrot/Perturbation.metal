#include <metal_stdlib>
#include "FloatFloat.h"
using namespace metal;
#pragma clang fp contract(off)

struct XF { float2 m; int e; int pad; };
struct XC { XF x,y; };
XF xf(float v) { return {float2(v,0),0,0}; }
XF norm(XF a) {
  if (a.m.x == 0) { if(a.m.y==0) return xf(0); a.m=float2(a.m.y,0); }
  int e; frexp(a.m.x, e);
  a.m=ldexp(a.m,int2(-e)); a.e+=e; return a;
}
XF neg(XF a) { a.m=-a.m;return a; }
XF add(XF a,XF b) {
  if(a.m.x==0) return b; if(b.m.x==0) return a;
  int e=max(a.e,b.e);
  if(e-a.e>100) return b; if(e-b.e>100) return a;
  return norm({dd_add(ldexp(a.m,int2(a.e-e)),ldexp(b.m,int2(b.e-e))),e,0});
}
XF mul(XF a,XF b) { return norm({dd_mul(a.m,b.m),a.e+b.e,0}); }
XF times(XF a,float b) { return norm({dd_mul_float(a.m,b),a.e,0}); }
XC add(XC a,XC b) { return {add(a.x,b.x),add(a.y,b.y)}; }
XC mul(XC a,XC b) { return {add(mul(a.x,b.x),neg(mul(a.y,b.y))),add(mul(a.x,b.y),mul(a.y,b.x))}; }
XC times(XC a,float b) { return {times(a.x,b),times(a.y,b)}; }
XF abs2(XC a) { return add(mul(a.x,a.x),mul(a.y,a.y)); }
bool less(XF a,XF b) {
  a=norm(a);b=norm(b);
  if(a.m.x==0) return b.m.x>0;
  if(b.m.x==0) return false;
  return a.e==b.e ? a.m.x<b.m.x : a.e<b.e;
}
float value(XF a) { return ldexp(a.m.x,a.e); }
struct PerturbParameters {
 XC origin; XF stepX,stepY;
 uint width,height,iterations,referenceCount;
 uint start,count,pass,pad;
};
struct PerturbState { XC delta; uint n,ref,done,pad; };
// flags: first glitched pixel, number of glitches, rebases, skipped iterations.
kernel void perturbTile(texture2d<float,access::read_write> output [[texture(0)]],
 constant PerturbParameters &p [[buffer(0)]], device const XC *orbit [[buffer(1)]],
 device PerturbState *states [[buffer(2)]], device atomic_uint *flags [[buffer(3)]],
 uint2 pos [[thread_position_in_grid]]) {
 if(pos.x>=p.width||pos.y>=p.height)return;
 uint index=pos.y*p.width+pos.x;
 PerturbState s;
 if(p.start==0) {
   if(p.pass>0 && output.read(pos).x!=-3) { states[index].done=1;return; }
   s={ {xf(0),xf(0)},0,0,0,0};
 } else { s=states[index];if(s.done)return; }
 XC dc=add(p.origin,{times(p.stepX,float(pos.x)),times(p.stepY,-float(pos.y))});
 for(uint work=0;work<p.count && s.n<p.iterations;work++) {
   XC total=add(orbit[s.ref],s.delta);
   XF magnitude=abs2(total);
   if(!less(magnitude,xf(65536))) {
     output.write(float4(max(0.0f,float(s.n)+1-log2(log2(sqrt(value(magnitude)))))),pos);s.done=1;break;
   }
   // Pauldelbrot cancellation criterion. Retry at a new high-precision point.
   if(less(magnitude,times(abs2(orbit[s.ref]),1e-8f))) {
     output.write(float4(-3),pos);s.done=1;
     atomic_fetch_min_explicit(flags,index,memory_order_relaxed);
     atomic_fetch_add_explicit(flags+1,1,memory_order_relaxed);break;
   }
   // Rebase onto the critical-point reference before its stored orbit runs out.
   if(s.ref+1>=p.referenceCount || less(magnitude,abs2(s.delta))) {
     s.delta=total;s.ref=0;
     atomic_fetch_add_explicit(flags+2,1,memory_order_relaxed);
   }
   s.delta=add(add(times(mul(orbit[s.ref],s.delta),2),mul(s.delta,s.delta)),dc);
   s.n++;s.ref++;
 }
 if(!s.done && s.n>=p.iterations){output.write(float4(-1),pos);s.done=1;}
 states[index]=s;
}
