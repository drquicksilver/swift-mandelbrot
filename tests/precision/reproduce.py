#!/usr/bin/env python3
"""Fetch pinned benchmark-only Boost sources, build both spikes, and write JSON."""
import argparse, json, pathlib, subprocess
ROOT = pathlib.Path(__file__).resolve().parents[2]
PINS = {'multiprecision': '529dfac199191a7eb8a5eb7f47256eff6d0db993',
        'config': 'a7d5a9b05d70c9cfea980dc3539ca3d3461411b3'}
def run(args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)
def fetch(cache, name, commit):
    path = cache / (name + '-' + commit)
    if not path.exists():
        run(['git', 'init', path], stdout=subprocess.DEVNULL)
        run(['git', '-C', path, 'remote', 'add', 'origin', f'https://github.com/boostorg/{name}.git'])
    if not (path/'include').exists():
        run(['git', '-C', path, 'fetch', '--depth', '1', 'origin', commit])
        run(['git', '-C', path, 'checkout', '--detach', commit], stdout=subprocess.DEVNULL)
    actual = subprocess.check_output(['git', '-C', str(path), 'rev-parse', 'HEAD'], text=True).strip()
    if actual != commit: raise RuntimeError(f'Unexpected revision in {path}: {actual}')
    if subprocess.check_output(['git','-C',str(path),'status','--porcelain'],text=True).strip():
        raise RuntimeError(f'Modified benchmark dependencies in {path}')
    return path/'include'
def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cache', type=pathlib.Path, default=pathlib.Path('/tmp/mandelbrot-boost-repro'))
    parser.add_argument('--output', type=pathlib.Path, default=ROOT/'evidence/review-deep/libraries.json')
    args=parser.parse_args();args.cache.mkdir(parents=True,exist_ok=True)
    includes=[fetch(args.cache,n,c) for n,c in PINS.items()]
    vendor=sorted((ROOT/'Mandelbrot/Core/Vendor/BigInt').glob('*.swift'))
    reports=[]
    for name in ['spike','reference_spike']:
        cpp=args.cache/(name+'-boost');swift=args.cache/(name+'-swift')
        run(['clang++','-O3','-std=c++17',*[f'-I{p}' for p in includes],ROOT/f'tests/precision/{name}.cpp','-o',cpp])
        sources=vendor+[ROOT/f'tests/precision/{name}.swift']
        if name=='reference_spike': sources += [ROOT/'Mandelbrot/Core/DeepNumber.swift',ROOT/'Mandelbrot/Core/ReferenceOrbit.swift']
        run(['swiftc','-O','-whole-module-optimization','-module-cache-path',args.cache/'modules',*sources,'-o',swift])
        fixture=json.loads((ROOT/'tests/fixtures/deep/minibrot.json').read_text())
        extra=[fixture['centerReal'],fixture['centerImag']] if name=='reference_spike' else []
        for binary in [swift,cpp]:
            for line in subprocess.check_output([str(binary),*extra],text=True).splitlines():
                report=json.loads(line);report['experiment']=name;reports.append(report)
                print(json.dumps(report),flush=True)
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps({'pins':PINS,'swiftFlags':['-O','-whole-module-optimization'],'cppFlags':['-O3','-std=c++17'],'measurements':reports},indent=2)+'\n')
if __name__=='__main__': main()
