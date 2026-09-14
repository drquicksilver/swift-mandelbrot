"""Independent smooth-iteration oracle and palette/sample invariants."""
import array
import json
import math
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
APP = str(Path(sys.argv.pop(1)).resolve())

class SmoothTests(unittest.TestCase):
    def test_smooth_samples_and_palette_independence(self):
        width,height,limit=64,48,200
        reference=[]
        for y in range(height):
            ci=3*height/width/2-y/(height-1)*(3*height/width)
            for x in range(width):
                cr=-2+x/(width-1)*3
                zr=zi=0.;n=0
                while zr*zr+zi*zi <= 256**2 and n < limit:
                    zr,zi=zr*zr-zi*zi+cr,2*zr*zi+ci;n+=1
                reference.append(-1 if n==limit else max(0,n+1-math.log2(math.log2(math.hypot(zr,zi)))))
        with tempfile.TemporaryDirectory() as folder:
            p=Path(folder);first=None;pngs=set()
            for palette in ['blue-gold','fire','ice','ink','twilight','forest','orbit']:
                subprocess.run([APP,'--render','--pipeline','gpu','--renderer','metal-double','--size',f'{width}x{height}',
                    '--iterations',str(limit),'--palette',palette,'--output',str(p/'x.png'),'--samples',str(p/'x.f32')],check=True,capture_output=True)
                raw=(p/'x.f32').read_bytes()
                pngs.add((p/'x.png').read_bytes())
                if first is None:first=raw
                self.assertEqual(first,raw,'Palette changes must not affect stored sample data')
            self.assertEqual(len(pngs),7)
            samples=array.array('f',first)
            if sys.byteorder!='little':samples.byteswap()
            self.assertTrue(all(math.isfinite(s) for s in samples))
            mismatches=sum(abs(a-b)>0.002 for a,b in zip(samples,reference))
            self.assertLess(mismatches/len(samples),0.01)
            self.assertGreater(sum(s>=0 and abs(s-round(s))>.01 for s in samples),len(samples)/2)

    def test_gpu_timing_and_invalid_export(self):
        result=subprocess.run([APP,'--benchmark','--pipeline','gpu','--variants','metal-double','--sizes','32x32',
            '--timing','kernel','--runs','2','--warmup','0','--format','json'],capture_output=True,text=True,check=True)
        report=json.loads(result.stdout)
        self.assertEqual(report['timingScope'],'gpu-compute-only')
        self.assertGreater(report['results'][0]['medianSeconds'],0)
        invalid=subprocess.run([APP,'--render','--pipeline','gpu','--output','unused.png','--counts','unused.u16'],capture_output=True)
        self.assertEqual(invalid.returncode,2)

if __name__=='__main__':unittest.main()
