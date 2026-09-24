"""Kernel-only and end-to-end GPU timings at the 1e7 reference view, into
docs/evidence/gpu-pipeline/STAGE.json.
Usage: python3 benchmarks/measure_product.py APP STAGE
"""
import json
from pathlib import Path
import subprocess
import sys
app,stage=sys.argv[1:]
reports={}
for timing in ['kernel','end-to-end']:
    result=subprocess.run([app,'--benchmark','--pipeline','gpu','--timing',timing,
        '--variants','metal,metal-double','--sizes','512x512,1024x1024','--center-real','-0.743643987037151',
        '--center-imag','0.13182597420533','--scale','10000000','--iterations','2000',
        '--warmup','1','--runs','5','--format','json'],capture_output=True,text=True,check=True)
    reports[timing]=json.loads(result.stdout)
path=Path(__file__).resolve().parents[1]/'docs/evidence/gpu-pipeline'/(stage+'.json');path.parent.mkdir(parents=True,exist_ok=True)
path.write_text(json.dumps(reports,indent=2)+'\n')
for scope,r in reports.items():
    for row in r['results']:print(stage,scope,row['variant'],row['width'],round(row['medianSeconds']*1000,3),'ms')
