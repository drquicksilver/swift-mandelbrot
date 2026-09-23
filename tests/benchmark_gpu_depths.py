"""Repeatable headless GPU benchmark with verified capped and escaped pixels.

Usage: python3 tests/benchmark_gpu_depths.py APP [--runs 30] [--output results.json]
       [--compare earlier.json]

The GPU raises its clock only under sustained load, and a sub-millisecond
kernel with CPU gaps between runs can stay at a low clock for dozens of runs,
or switch part-way through a series.  Light cases therefore first render a
larger primer size in the same process, which brings the clock up and keeps it
there for the measured size.  Heavy cases keep the GPU busy on their own.
"""

import argparse
import json
from pathlib import Path
import struct
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent.parent
MINIBROT = json.loads((ROOT / "tests/fixtures/deep/minibrot.json").read_text())
CASES = [
    dict(name="float-slow-500", renderer="metal", real="-0.75",
         imag="0.02", scale="1000", iterations=500, size="512x384", primer="2048x1536"),
    dict(name="float-slow-2000", renderer="metal", real="-0.75",
         imag="0.02", scale="1000", iterations=2000, size="512x384", primer="2048x1536"),
    dict(name="float-bulb-500", renderer="metal", real="-1",
         imag="0.25", scale="30", iterations=500, size="512x384", primer="2048x1536"),
    dict(name="float-bulb-2000", renderer="metal", real="-1",
         imag="0.25", scale="30", iterations=2000, size="512x384", primer="2048x1536"),
    dict(name="floatfloat-2000", renderer="metal-double", real="-0.743643987037151",
         imag="0.13182597420533", scale="10000000", iterations=2000, size="256x192", primer="1024x768"),
    dict(name="floatfloat-5000", renderer="metal-double", real="-0.743643987037151",
         imag="0.13182597420533", scale="10000000", iterations=5000, size="256x192", primer="1024x768"),
    dict(name="perturbation-25000", renderer="perturbation",
         real=MINIBROT["centerReal"], imag=MINIBROT["centerImag"],
         scale=MINIBROT["scale"], iterations=25000, size="16x12"),
    dict(name="perturbation-30000", renderer="perturbation",
         real=MINIBROT["centerReal"], imag=MINIBROT["centerImag"],
         scale=MINIBROT["scale"], iterations=30000, size="16x12"),
]


def call(app, *arguments):
    result = subprocess.run([app, *arguments], capture_output=True, text=True, check=True)
    return result.stdout


def percentile(values, fraction):
    ordered = sorted(values)
    return ordered[round(fraction * (len(ordered) - 1))]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app")
    parser.add_argument("--runs", type=int, default=30)
    parser.add_argument("--warmup", type=int, default=5)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--only", choices=["float", "floatfloat", "perturbation"])
    parser.add_argument("--compare", type=Path,
                        help="earlier results; fail if any capped or escaped total differs")
    args = parser.parse_args()
    earlier = {row["name"]: row for row in json.loads(args.compare.read_text())} if args.compare else {}
    if args.runs < 1 or args.warmup < 0:
        parser.error("--runs must be positive and --warmup must be nonnegative")
    results = []
    with tempfile.TemporaryDirectory() as folder:
        for case in CASES:
            if args.only and not case["name"].startswith(args.only + "-"):
                continue
            common = ["--pipeline", "gpu", "--center-real", case["real"],
                      "--center-imag", case["imag"], "--scale", case["scale"],
                      "--iterations", str(case["iterations"])]
            records = Path(folder) / "records.bin"
            call(args.app, "--render", *common, "--renderer", case["renderer"],
                 "--size", case["size"], "--output", str(Path(folder) / "image.png"),
                 "--sample-records", str(records))
            counts = [count for count, _ in struct.iter_unpack("<If", records.read_bytes())]
            capped = sum(count == 0xFFFFFFFF for count in counts)
            escaped = sum(count < 0xFFFFFFFD for count in counts)
            if not capped or not escaped:
                raise RuntimeError(f"{case['name']}: {capped} capped, {escaped} escaped; "+
                                   "benchmark viewport does not exercise both paths")
            previous = earlier.get(case["name"])
            if previous and (previous["capped"], previous["escaped"]) != (capped, escaped):
                raise RuntimeError(f"{case['name']}: {capped} capped, {escaped} escaped; "+
                                   f"{args.compare} has {previous['capped']} and {previous['escaped']}")
            sizes = ",".join(filter(None, [case.get("primer"), case["size"]]))
            report = json.loads(call(args.app, "--benchmark", *common,
                                     "--variants", case["renderer"], "--sizes", sizes,
                                     "--timing", "kernel", "--runs", str(args.runs),
                                     "--warmup", str(args.warmup), "--format", "json"))
            row = report["results"][-1]
            samples = row["samplesSeconds"]
            # A spread of more than a few percent usually means the clock moved.
            spread = (percentile(samples, 0.9) - percentile(samples, 0.1)) / row["medianSeconds"]
            result = {**case, "capped": capped, "escaped": escaped,
                      "medianSeconds": row["medianSeconds"], "spread": spread,
                      "samplesSeconds": samples}
            if case.get("primer"):
                result["primerMedianSeconds"] = report["results"][0]["medianSeconds"]
            results.append(result)
            print(f"{case['name']}: {row['medianSeconds'] * 1000:.3f} ms "
                  f"(10-90% spread {spread:.1%}); "
                  f"{capped}/{len(counts)} capped, {escaped} escaped", flush=True)
    if args.output:
        args.output.write_text(json.dumps(results, indent=2) + "\n")


if __name__ == "__main__":
    main()
