"""CPU-authored, pixel-centred PNG references for the actual tile compositor.

Generate deliberately with: python3 tests/cli/test_product_golden.py --record
Run normally with: python3 tests/cli/test_product_golden.py APP
"""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'oracles'))
from product_reference import read_png, reference, write_png

root = Path(__file__).resolve().parents[1] / 'fixtures' / 'product'
fixtures = json.loads((root/'manifest.json').read_text())['fixtures']
if sys.argv[1:] == ['--record']:
    for f in fixtures:
        write_png(root/(f['name']+'.png'), f['width'], f['height'], reference(f))
        print('Recorded independent CPU reference:', f['name'])
else:
    app = str(Path(sys.argv[1]).resolve())
    with tempfile.TemporaryDirectory() as directory:
        for f in fixtures:
            output = Path(directory)/'actual.png'
            command = [app, '--render', '--pipeline', 'tiles', '--renderer', 'metal-double',
                       '--size', f'{f["width"]}x{f["height"]}', '--scale', str(f['scale']),
                       '--center-real', str(f['center'][0]), '--center-imag', str(f['center'][1]),
                       '--iterations', str(f['iterations']), '--palette', 'ink', '--output', str(output)]
            if f.get('rotation'):
                command += ['--rotation', str(f['rotation'])]
            subprocess.run(command, check=True, capture_output=True)
            w,h,expected = read_png(root/(f['name']+'.png'))
            aw,ah,actual = read_png(output)
            assert (aw,ah) == (w,h)
            assert len(set(expected)) > 64, 'Flat reference cannot validate rendering'
            errors = [max(abs(actual[i+c]-expected[i+c]) for c in range(3)) for i in range(0,len(actual),4)]
            mismatch = sum(error > 4 for error in errors)/len(errors)
            mean = sum(errors)/len(errors)
            print(f'{f["name"]}: >4-byte error {mismatch:.4%}; mean max-channel error {mean:.4f}')
            assert mismatch <= f['maxMismatch'], 'Product pixel mismatch exceeds independent reference tolerance'
            assert mean <= f['maxMeanError'], 'Product average colour error exceeds tolerance'
    print('Independent product goldens passed')
