"""Isolated BLA jumps versus GPU recurrence and independent Decimal recurrence,
from the app's --test-bla report.  Run by `make bla`.

Normalise by the sum of the linear output terms, avoiding misleading relative
errors when the two terms cancel. No escaped-count or image tolerance is used.
"""
import base64,json,pathlib,struct,subprocess,sys
from decimal import Decimal as D,getcontext
getcontext().prec=180
root=pathlib.Path(__file__).resolve().parents[1]
reports=json.loads(subprocess.check_output([sys.argv[1],'--test-bla',str(root/'fixtures/deep/minibrot.json')]))
def xc(raw):
    a,b,e,_pad,c,d,f,_pad=struct.unpack('<ffiiffii',raw)
    return ((D(a)+D(b))*D(2)**e,(D(c)+D(d))*D(2)**f)
def add(a,b):return (a[0]+b[0],a[1]+b[1])
def mul(a,b):return (a[0]*b[0]-a[1]*b[1],a[0]*b[1]+a[1]*b[0])
def norm(a):return (a[0]*a[0]+a[1]*a[1]).sqrt()
def error(a,b):return norm((a[0]-b[0],a[1]-b[1]))
summary=[]
for report in reports:
    raw=base64.b64decode(report['orbit']);orbit=[xc(raw[i:i+32]) for i in range(0,len(raw),32)]
    raw=base64.b64decode(report['results']);maxima=[D(0)]*3
    for i,case in enumerate(report['cases']):
        seed,dc,a,b=(xc(base64.b64decode(case[k])) for k in ['delta','dc','a','b'])
        exact=seed
        for z in orbit[case['start']:case['start']+case['length']]:
            exact=add(add(mul((2*z[0],2*z[1]),exact),mul(exact,exact)),dc)
        ordinary=xc(raw[i*64:i*64+32]);approx=xc(raw[i*64+32:i*64+64])
        scale=max(norm(mul(a,seed))+norm(mul(b,dc)),norm(exact))
        errors=[error(ordinary,exact)/scale,error(approx,exact)/scale,error(approx,ordinary)/scale]
        maxima=[max(a,b) for a,b in zip(maxima,errors)]
        assert errors[1]<D('1e-12') and max(errors)<D('1e-10'),(report['scene'],report['policy'],case['start'],case['length'],errors)
    row=dict(scene=report['scene'],policy=report['policy'],cases=len(report['cases']),
      longest=max(c['length'] for c in report['cases']),maximumErrors=[float(x) for x in maxima])
    summary.append(row);print(json.dumps(row),flush=True)
if len(sys.argv)>2:pathlib.Path(sys.argv[2]).write_text(json.dumps(summary,indent=2)+'\n')
