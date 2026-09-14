"""Comparable c=i and long-orbit minibrot measurements for each review stage."""
import json,pathlib,subprocess,sys
app,stage=sys.argv[1:];root=pathlib.Path(__file__).resolve().parents[2]
f=json.loads((root/'tests/fixtures/deep/minibrot.json').read_text())
reports=[]
for name,real,imag,scale,iterations in [('i','0','1','1e1000',5000),('minibrot',f['centerReal'],f['centerImag'],f['scale'],f['iterations'])]:
 report=json.loads(subprocess.check_output([app,'--benchmark','--pipeline','gpu','--variants','perturbation','--center-real',real,'--center-imag',imag,'--scale',scale,'--iterations',str(iterations),'--sizes','64x48','--runs','3','--warmup','1','--format','json']))
 reports.append(dict(location=name,report=report));print(name,report['results'][0]['medianSeconds'],flush=True)
(root/'evidence/review-deep'/f'{stage}.json').write_text(json.dumps(reports,indent=2)+'\n')
