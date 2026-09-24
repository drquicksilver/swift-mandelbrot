"""Long-orbit independent goldens, including the actual tiled product path."""
import json,pathlib,struct,subprocess,sys,tempfile
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]/'oracles'))
from product_reference import read_png
app=sys.argv[1];root=pathlib.Path(__file__).resolve().parents[1]/'fixtures/deep'
f=json.loads((root/'minibrot.json').read_text())
base=[app,'--pipeline','gpu','--renderer','perturbation','--center-real',f['centerReal'],'--center-imag',f['centerImag'],'--scale',f['scale'],'--iterations',str(f['iterations']),'--palette','ink','--density','512']
with tempfile.TemporaryDirectory() as folder:
 raw=pathlib.Path(folder)/'samples.f32';png=pathlib.Path(folder)/'image.png'
 for bla in ['off','fixed','on']:
  subprocess.run(base+['--render','--size','16x12','--bla',bla,'--samples',str(raw),'--output',str(png)],check=True,stdout=subprocess.DEVNULL)
  actual=struct.unpack('<192f',raw.read_bytes());expected=struct.unpack('<192f',(root/'minibrot.f32').read_bytes())
  errors=[abs(a-b) for a,b in zip(actual,expected)]
  print('minibrot',bla,'max sample error',max(errors),flush=True)
  assert sum(e>.05 for e in errors)/len(errors)<=.05 and sum(errors)/len(errors)<5 and max(errors)<512, errors
  pe=[abs(a-b) for a,b in zip(read_png(png)[2],read_png(root/'minibrot.png')[2])]
  bad=sum(max(pe[i:i+4])>3 for i in range(0,len(pe),4))
  print("PNG outlier pixels",bad,"mean channel error",sum(pe)/len(pe),flush=True)
  assert bad/192<=.05 and sum(pe)/len(pe)<5,(bad,max(pe))
 tiled=base.copy();tiled[tiled.index('gpu')]='tiles'
 subprocess.run(tiled+['--render','--size','8x6','--output',str(png)],check=True,stdout=subprocess.DEVNULL)
 errors=[abs(a-b) for a,b in zip(read_png(png)[2],read_png(root/'minibrot-tiles.png')[2])]
 print('minibrot product PNG max error',max(errors),flush=True)
 assert sum(max(errors[i:i+4])>3 for i in range(0,len(errors),4))/48<=.05 and max(errors)<=12 and sum(errors)/len(errors)<1, max(errors)
 bench=[app,'--benchmark','--pipeline','gpu','--variants','perturbation','--center-real',f['centerReal'],'--center-imag',f['centerImag'],'--scale',f['scale'],'--iterations',str(f['iterations']),'--sizes','16x12','--runs','1','--warmup','0','--format','json']
 m=json.loads(subprocess.check_output(bench))['results'][0]['perturbation'][0]
 assert m['references']<=2 and m['rebases']>0,m
 print('minibrot references',m['references'],'rebases',m['rebases'])
