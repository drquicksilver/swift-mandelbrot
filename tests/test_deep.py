"""Independent Decimal goldens, BLA equivalence and actual glitch recovery."""
import json
import pathlib
import struct
import subprocess
import sys
import tempfile
from product_reference import read_png

app = sys.argv[1]
root = pathlib.Path(__file__).parent / 'fixtures/deep'
manifest = json.loads((root / 'manifest.json').read_text())
with tempfile.TemporaryDirectory() as tmp:
    for depth in manifest['depths']:
        expected = struct.unpack('<768f', (root / f'i-{depth}.f32').read_bytes())
        expected_png = read_png(root / f'i-{depth}.png')[2]
        for bla in ['off', 'on']:
            raw, png = pathlib.Path(tmp) / 'samples.f32', pathlib.Path(tmp) / 'image.png'
            subprocess.run([app, '--render', '--pipeline', 'gpu', '--renderer', 'perturbation',
                            '--center-real', '0', '--center-imag', '1', '--scale', f'1e{depth}',
                            '--iterations', '5000', '--size', '32x24', '--density', '8',
                            '--palette', 'ink', '--bla', bla, '--samples', str(raw), '--output', str(png)],
                           check=True, stdout=subprocess.DEVNULL)
            actual = struct.unpack('<768f', raw.read_bytes())
            errors = [abs(a-b) for a,b in zip(actual, expected)]
            assert max(errors) < 0.002, (depth, bla, max(errors))
            assert len(set(round(v,2) for v in actual)) > 300, 'Flat deep image'
            pixel_error = max(abs(a-b) for a,b in zip(read_png(png)[2], expected_png))
            assert pixel_error <= 3, (depth, bla, pixel_error)
            print(f'1e{depth}, BLA {bla}: max sample error {max(errors):.7f}; PNG error {pixel_error}/255')

    # Exact c=0 is the centre of pixel (4, 2), away from the initial reference
    # at the centre pixel (3, 2): half-pixel steps of 0.5 from -2 + 0.25.
    glitchy = ['--sizes', '6x5', '--center-real', '-0.75']
    report = json.loads(subprocess.check_output([app, '--benchmark', '--pipeline', 'gpu',
        '--variants', 'perturbation', *glitchy, '--runs', '1', '--warmup', '0', '--format', 'json']))
    m = report['results'][0]['perturbation'][0]
    assert m['glitches'] == 0 and m['references'] == 1 and m['avoidedGlitches'] > 0, m
    recovery=json.loads(subprocess.check_output([app,'--benchmark','--pipeline','gpu','--variants','perturbation',*glitchy,'--runs','1','--warmup','0','--format','json','--rebasing','off']))['results'][0]['perturbation'][0]
    assert recovery['glitches']>0 and recovery['references']>1,recovery
    print('Pauldelbrot re-referencing:', m['glitches'], 'glitches,', m['references'], 'references')
    for bla in ['off', 'on']:
        report = json.loads(subprocess.check_output([app, '--benchmark', '--pipeline', 'gpu',
            '--variants', 'perturbation', '--center-real', '0', '--center-imag', '1', '--scale', '1e1000',
            '--iterations', '5000', '--sizes', '32x24', '--bla', bla, '--runs', '1', '--warmup', '0', '--format', 'json']))
        skipped = report['results'][0]['perturbation'][0]['skippedIterations']
        assert (skipped > 0) == (bla == 'on'), (bla, skipped)
        assert report['preciseScale'] == '1e1000' and 'scale' not in report
    for bad in ['1e-9223372036854775808', '1e9223372036854775807', 'nan', '1.2.3']:
        result = subprocess.run([app, '--render', '--pipeline', 'gpu', '--renderer', 'perturbation',
            '--center-real', bad, '--output', str(pathlib.Path(tmp)/'bad.png')], capture_output=True)
        assert result.returncode == 2, (bad, result.returncode)
