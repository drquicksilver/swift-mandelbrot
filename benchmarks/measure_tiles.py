"""Repeat the current headless tile integration trace and retain raw measurements."""
import json
from pathlib import Path
import re
import statistics
import subprocess
import sys
app,stage=sys.argv[1:]
runs=[]
for _ in range(5):
    text=subprocess.check_output([app,'--test-tiles'],text=True)
    result=json.loads(text.split('Tile integration')[0])
    result['elapsedSeconds']=float(re.search(r'passed in ([0-9.]+)',text)[1]);runs.append(result)
Path(__file__).resolve().parents[1].joinpath('docs/evidence/gpu-pipeline',stage+'.json').write_text(json.dumps(runs,indent=2)+'\n')
print(stage,'median trace ms',statistics.median(r['elapsedSeconds'] for r in runs)*1000,
      'maximum GPU batch ms',max(r['longestBatchMS'] for r in runs))
