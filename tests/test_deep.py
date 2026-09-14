"""Deep samples are checked against independent high precision direct orbits."""
import json,pathlib,struct,subprocess,sys,tempfile
app=sys.argv[1]
root=pathlib.Path(__file__).parent/'fixtures/deep'
manifest=json.loads((root/'manifest.json').read_text())
with tempfile.TemporaryDirectory() as tmp:
 for depth in manifest['depths']:
  raw=pathlib.Path(tmp)/'samples.f32'
  subprocess.run([app,'--render','--pipeline','gpu','--renderer','perturbation','--center-real','0','--center-imag','1','--scale',f'1e{depth}','--iterations','5000','--size','32x24','--density','8','--samples',str(raw),'--output',str(pathlib.Path(tmp)/'image.png')],check=True)
  actual=struct.unpack('<768f',raw.read_bytes());expected=struct.unpack('<768f',(root/f'i-{depth}.f32').read_bytes())
  errors=[abs(a-b) for a,b in zip(actual,expected)]
  assert max(errors)<0.002,(depth,max(errors))
  assert len(set(round(v,2) for v in actual))>300,'Flat deep image'
  print(f'1e{depth}: maximum smooth-count error {max(errors):.7f}')

report=json.loads(subprocess.check_output([app,'--benchmark','--pipeline','gpu','--variants','perturbation','--sizes','7x5','--runs','1','--warmup','0','--format','json']))
m=report['results'][0]['perturbation'][0]
assert m['glitches']>0 and m['references']>1,m
print('Pauldelbrot detection and re-referencing exercised:',m['glitches'],'glitches,',m['references'],'references')
