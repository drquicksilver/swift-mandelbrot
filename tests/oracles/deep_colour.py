"""Colour the independent Decimal samples; never invokes the app."""
import math,pathlib,struct,sys
from product_reference import write_png
root=pathlib.Path(__file__).resolve().parents[1]/'fixtures/deep'
stops=[(8,12,21),(83,97,113),(255,255,255),(83,97,113),(8,12,21)]
lut=[]
for i in range(1024):
 p=i/256;j=int(p);t=p-j
 lut.append(tuple(int(a*(1-t)+b*t) for a,b in zip(stops[j],stops[j+1])))
for depth in [50,200,1000]:
 values=struct.unpack('<768f',(root/f'i-{depth}.f32').read_bytes())
 pixels=bytearray()
 for value in values:
  p=value/8*1024-0.5;j=math.floor(p);t=p-j
  pixels.extend(round(a*(1-t)+b*t) for a,b in zip(lut[j%1024],lut[(j+1)%1024]))
  pixels.append(255)
 write_png(root/f'i-{depth}.png',32,24,pixels)
