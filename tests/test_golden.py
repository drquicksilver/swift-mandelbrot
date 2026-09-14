"""Fixed CPU-Double escape-count and PNG fixtures. Refresh only deliberately.
python3 tests/test_golden.py APP [--record]
"""
import array
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest

APP = str(Path(sys.argv.pop(1)).resolve())
RECORD = '--record' in sys.argv
if RECORD: sys.argv.remove('--record')
ROOT = Path(__file__).parent / 'fixtures'
FIXTURES = json.loads((ROOT / 'manifest.json').read_text())['fixtures']
DOUBLE = ['baseline', 'scalar-tight', 'coord-precompute', 'unsafe-buffer', 'parallel', 'metal-double']
ALL = DOUBLE + ['float-math', 'simd4-float', 'metal']

def render(fixture, renderer, folder):
    png, raw = folder / 'image.png', folder / 'counts.u16'
    subprocess.run([APP, '--render', '--renderer', renderer, '--size', f'{fixture["width"]}x{fixture["height"]}',
                    '--center-real', str(fixture['centerReal']), '--center-imag', str(fixture['centerImag']),
                    '--scale', str(fixture['scale']), '--iterations', str(fixture['iterations']),
                    '--output', str(png), '--counts', str(raw)], check=True, capture_output=True,
                   env={**os.environ, 'LLVM_PROFILE_FILE': os.devnull})
    counts = array.array('H', raw.read_bytes())
    if sys.byteorder != 'little': counts.byteswap()
    return counts, png.read_bytes(), raw.read_bytes()

class GoldenTests(unittest.TestCase):
    def test_fixed_locations(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            for fixture in FIXTURES:
                name = fixture['name']
                if RECORD:
                    _, png, raw = render(fixture, 'baseline', folder)
                    (ROOT / f'{name}.png').write_bytes(png)
                    (ROOT / f'{name}.u16').write_bytes(raw)
                reference = array.array('H', (ROOT / f'{name}.u16').read_bytes())
                if sys.byteorder != 'little': reference.byteswap()
                self.assertGreater(len(set(reference)), 20, name + ' must contain detail')
                for variant in ALL if fixture['renderers'] == 'all' else DOUBLE:
                    with self.subTest(location=name, renderer=variant):
                        counts, png, _ = render(fixture, variant, folder)
                        errors = [abs(a-b) for a,b in zip(counts, reference)]
                        self.assertEqual(len(counts), len(reference))
                        self.assertEqual(struct.unpack('>II', png[16:24]), (fixture['width'], fixture['height']))
                        mismatch = sum(e != 0 for e in errors) / len(errors)
                        mean = sum(errors) / len(errors)
                        print(f'{name:20} {variant:17} mismatch={mismatch:.4%} MAE={mean:.4f}', flush=True)
                        # CPU variants must reproduce the reference exactly; GPU FloatFloat
                        # and Float have less precision and a bounded escape-boundary error.
                        tolerance = fixture['maxMismatch'] if variant in ['metal-double','metal','float-math','simd4-float'] else 0
                        self.assertLessEqual(mismatch, tolerance)
                        self.assertLessEqual(mean, fixture['maxMeanError'] if tolerance else 0)
                        if variant == 'baseline':
                            self.assertEqual(png, (ROOT / f'{name}.png').read_bytes())

if __name__ == '__main__': unittest.main()
