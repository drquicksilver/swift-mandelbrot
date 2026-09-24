"""Independent Decimal direct-orbit oracle near a period-312 minibrot at 1e100,
for tests/cli/test_minibrot.py.

Refine z_936(c)=z_624(c) with complex Newton iteration. No app code or
perturbation is used, either to find the location or compute the golden
samples.  Writes the full-frame samples and PNG and the tiled-product PNG in
tests/fixtures/deep: python3 tests/oracles/minibrot_oracle.py
"""
from decimal import Decimal as D, getcontext
from pathlib import Path
import json, math, struct, sys
from product_reference import write_png
ROOT=Path(__file__).resolve().parents[1]/'fixtures/deep'
getcontext().prec=180

def location():
    x,y=D('-.7436439130937827'),D('.13182590182979556')
    for _ in range(30):
        a=b=dr=di=D(0)
        for n in range(1,937):
            dr,di=2*(a*dr-b*di)+1,2*(a*di+b*dr)
            a,b=a*a-b*b+x,2*a*b+y
            if n==624: ar,ai,adr,adi=a,b,dr,di
        fr,fi=a-ar,b-ai;dr-=adr;di-=adi
        denom=dr*dr+di*di
        dx,dy=(fr*dr+fi*di)/denom,(fi*dr-fr*di)/denom
        x-=dx;y-=dy
        if max(abs(dx),abs(dy))<D('1e-170'):return x,y
    raise RuntimeError('Newton did not converge')

def orbit(x,y,cap=60000):
    a=b=D(0)
    for n in range(cap):
        aa,bb=a*a,b*b
        if aa+bb>65536:return max(0,n+1-math.log2(math.log2(math.sqrt(float(aa+bb)))))
        a,b=aa-bb+x,2*a*b+y
    return -1

def colour(v):
    if v<0:return (1,2,4)
    stops=[(8,12,21),(83,97,113),(255,255,255),(83,97,113),(8,12,21)]
    def lut(i):
        p=(i%1024)/256;j=int(p);t=p-j
        return tuple(int(a*(1-t)+b*t) for a,b in zip(stops[j],stops[j+1]))
    p=v/512*1024-.5;j=math.floor(p);t=p-j
    return tuple(round(a*(1-t)+b*t) for a,b in zip(lut(j),lut(j+1)))

def main():
    cr,ci=location();span=D('3e-100')
    fixture=dict(name='minibrot-312',centerReal=str(cr),centerImag=str(ci),scale='1e100',iterations=60000,width=16,height=12,density=512,period=312,preperiod=624,decimalDigits=180)
    (ROOT/'minibrot.json').write_text(json.dumps(fixture,indent=2)+'\n')
    print('Located period-312 boundary',flush=True)
    w,h=16,12;values=[]
    for y in range(h):
        for x in range(w):
            # Pixel centres, as every renderer in the app samples.
            values.append(orbit(cr-span/2+span*(x+D('.5'))/w,ci+span*h/w/2-span*(y+D('.5'))/w))
        print('row',y,'range',min(values),max(values),flush=True)
    (ROOT/'minibrot.f32').write_bytes(struct.pack('<'+'f'*len(values),*values))
    write_png(ROOT/'minibrot.png',w,h,bytes(v for n in values for v in (*colour(n),255)))
    # Exact product sampling: centre-anchored 256-sample tiles, gutters, and
    # post-colour blending between floor/ceil LOD. This small view has no complete
    # four-child groups, so none of its visible parents can be replaced by a mip.
    w,h=8,6;lod=math.log2(1e100*w/256);base=math.floor(lod);fine=math.ceil(lod)
    cache={}
    def filtered(level,rx,ry):
        step=D(3)/(D(2)**level)/256
        gx,gy=rx/step,-ry/step
        x,y=math.floor(gx-D('.5')),math.floor(gy-D('.5'))
        fx,fy=float(gx-D('.5')-x),float(gy-D('.5')-y)
        colors=[]
        for dy in (0,1):
            for dx in (0,1):
                key=(level,x+dx,y+dy)
                if key not in cache:cache[key]=colour(orbit(cr+(D(x+dx)+D('.5'))*step,ci-(D(y+dy)+D('.5'))*step))
                colors.append(cache[key])
        return tuple((colors[0][i]*(1-fx)+colors[1][i]*fx)*(1-fy)+(colors[2][i]*(1-fx)+colors[3][i]*fx)*fy for i in range(3))
    pixels=bytearray()
    for y in range(h):
        for x in range(w):
            rx=(D(x)+D('.5')-D(w)/2)*span/w;ry=(D(h)/2-y-D('.5'))*span/w
            a,b=filtered(base,rx,ry),filtered(fine,rx,ry)
            pixels.extend(round(v*(1-(lod-base))+q*(lod-base)) for v,q in zip(a,b));pixels.append(255)
        print('tile oracle row',y,flush=True)
    write_png(ROOT/'minibrot-tiles.png',w,h,pixels)
if __name__=='__main__':main()
