"""Comparable c = i and minibrot timings with every BLA mode, one file per stage
of the deep-zoom review, into docs/evidence/perturbation/review.
Usage: python3 benchmarks/measure_deep_review.py APP STAGE
"""
import json,pathlib,subprocess,sys
app,stage=sys.argv[1:];root=pathlib.Path(__file__).resolve().parents[1]
f=json.loads((root/'tests/fixtures/deep/minibrot.json').read_text())
reports=[]
for name,real,imag,scale,iterations in [('i','0','1','1e1000',5000),('minibrot',f['centerReal'],f['centerImag'],f['scale'],f['iterations'])]:
 for bla in ['off','fixed','on']:
  report=json.loads(subprocess.check_output([app,'--benchmark','--pipeline','gpu','--variants','perturbation','--center-real',real,'--center-imag',imag,'--scale',scale,'--iterations',str(iterations),'--sizes','64x48','--runs','3','--warmup','1','--format','json','--bla',bla]))
  reports.append(dict(location=name,bla=bla,report=report));print(name,bla,report['results'][0]['medianSeconds'],flush=True)
(root/'docs/evidence/perturbation/review'/f'{stage}.json').write_text(json.dumps(reports,indent=2)+'\n')
