"""Independent Decimal direct iteration. No perturbation, fixed point, or app code."""
import decimal, math, struct, json, pathlib, sys
root=pathlib.Path(__file__).resolve().parents[2]/'tests/fixtures/deep'
root.mkdir(parents=True,exist_ok=True)
for depth in [50,200,1000]:
    decimal.getcontext().prec=depth+80
    D=decimal.Decimal
    w,h=32,24
    span=D(3)/(D(10)**depth)
    cr,ci=D(0),D(1)
    cap=5000
    values=[]
    for y in range(h):
        for x in range(w):
            c=cr-span/2+span*x/(w-1)
            d=ci+span*h/w/2-span*h/w*y/(h-1)
            a,b=D(0),D(0)
            for n in range(cap):
                aa,bb=a*a,b*b
                if aa+bb>65536:
                    v=max(0,n+1-math.log2(math.log2(math.sqrt(float(aa+bb)))));break
                a,b=aa-bb+c,2*a*b+d
            else: v=-1
            values.append(v)
    (root/f'i-{depth}.f32').write_bytes(struct.pack('<'+'f'*len(values),*values))
    print(depth,min(values),max(values),len(set(round(v,2) for v in values)),flush=True)
(root/'manifest.json').write_text(json.dumps(dict(width=32,height=24,centerReal='0',centerImag='1',iterations=5000,depths=[50,200,1000],oracle='Python Decimal direct iteration, depth + 80 decimal digits; endpoint sampling'),indent=2)+'\n')
