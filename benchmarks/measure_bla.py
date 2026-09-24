"""Controlled BLA on/off comparison; each app run includes one warmup."""
import json,pathlib,statistics,subprocess,sys
app=sys.argv[1]
root=pathlib.Path(__file__).resolve().parents[1]/'docs/evidence/perturbation/2.2'
reports=[]
for depth in [50,200,1000]:
 for bla in ['off','on']:
  command=[app,'--benchmark','--pipeline','gpu','--variants','perturbation','--center-real','0','--center-imag','1','--scale',f'1e{depth}','--iterations','5000','--sizes','256x192','--runs','3','--warmup','1','--format','json','--bla',bla]
  report=json.loads(subprocess.check_output(command))
  reports.append(dict(depth=depth,bla=bla,report=report))
  row=report['results'][0];m=row['perturbation']
  print(depth,bla,'end-to-end ms',round(row['medianSeconds']*1000,3),'GPU ms',round(statistics.median(v['kernelSeconds'] for v in m)*1000,3),'reference ms',round(statistics.median(v['referenceSeconds'] for v in m)*1000,3),flush=True)
(root/'bla-comparison.json').write_text(json.dumps(reports,indent=2)+'\n')
for depth in [50,200,1000]:
 subprocess.run([app,'--render','--pipeline','gpu','--renderer','perturbation','--center-real','0','--center-imag','1','--scale',f'1e{depth}','--iterations','5000','--size','512x384','--density','8','--output',str(root/f'gpu-1e{depth}.png')],check=True)
