"""Independent Decimal direct iteration at c = i, zoomed 1e50, 1e200 and 1e1000,
for tests/cli/test_deep.py: no perturbation, fixed point or app code.  Writes
tests/fixtures/deep/i-*.f32 and the manifest; about a minute and a half.
python3 tests/oracles/deep_oracle.py, then deep_colour.py.
"""
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
            # Pixel centres, as every renderer in the app samples.
            c=cr-span/2+span*(x+D('.5'))/w
            d=ci+span*h/w/2-span*(y+D('.5'))/w
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
(root/'manifest.json').write_text(json.dumps(dict(width=32,height=24,centerReal='0',centerImag='1',iterations=5000,depths=[50,200,1000],oracle='Python Decimal direct iteration, depth + 80 decimal digits; pixel-centre sampling'),indent=2)+'\n')
