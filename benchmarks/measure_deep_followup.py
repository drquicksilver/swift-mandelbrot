"""Cold automatic-depth latency at 1e1000 and the two BLA radius candidates'
minibrot images, into docs/evidence/perturbation/followup.
Usage: python3 benchmarks/measure_deep_followup.py APP
"""
import json,pathlib,re,subprocess,sys
root=pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0,str(root/'tests/oracles'))
from product_reference import read_png
app=sys.argv[1];dest=root/'docs/evidence/perturbation/followup';dest.mkdir(parents=True,exist_ok=True)
report={'coldAutomatic':[],'radiusImages':[]}
for _ in range(3):
    text=subprocess.check_output([app,'--benchmark-reference'],text=True)
    match=re.search(r'limit (\d+), first deep tile ([\d.]+) ms, ready ([\d.]+) ms, reference length (\d+)',text)
    assert match,text
    limit,first,ready,length=match.groups()
    report['coldAutomatic'].append(dict(limit=int(limit),firstTileMS=float(first),readyMS=float(ready),referenceLength=int(length)))
    print(text.strip(),flush=True)
f=json.loads((root/'tests/fixtures/deep/minibrot.json').read_text())
for policy in ['compound','fixed']:
    path=dest/f'minibrot-{policy}.png'
    subprocess.run([app,'--render','--pipeline','tiles','--renderer','perturbation','--size','8x6',
      '--center-real',f['centerReal'],'--center-imag',f['centerImag'],'--scale',f['scale'],
      '--iterations',str(f['iterations']),'--palette','ink','--density','512','--bla-radius',policy,'--output',str(path)],check=True)
    a=read_png(path)[2];b=read_png(root/'tests/fixtures/deep/minibrot-tiles.png')[2]
    e=[abs(x-y) for x,y in zip(a,b)]
    row=dict(policy=policy,maximum=max(e),meanChannelError=sum(e)/len(e),outlierPixels=sum(max(e[i:i+4])>3 for i in range(0,len(e),4)))
    report['radiusImages'].append(row);print(row,flush=True)
(dest/'measurements.json').write_text(json.dumps(report,indent=2)+'\n')
