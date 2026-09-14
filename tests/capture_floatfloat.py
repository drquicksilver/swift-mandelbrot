"""Capture the fixed deep-zoom experiment with an explicitly supplied build.

Usage: python3 tests/capture_floatfloat.py /path/to/Mandelbrot before|after OUTPUT_DIR
GPU access is required. Use a Release build with ENABLE_CODE_COVERAGE=NO.
"""

import json
from pathlib import Path
import subprocess
import sys


def capture(executable, phase, folder):
    folder.mkdir(parents=True, exist_ok=True)
    viewport = [
        "--center-real", "-0.743643987037151", "--center-imag", "0.13182597420533",
        "--scale", "10000000", "--iterations", "2000",
    ]
    for variant, name in [("parallel", "cpu-double-reference"),
                          ("metal", f"float-{phase}"), ("metal-double", f"floatfloat-{phase}")]:
        subprocess.run([
            executable, "--render", "--renderer", variant, "--size", "512x512", *viewport,
            "--output", str(folder / f"{name}.png"), "--counts", str(folder / f"{name}.u16"),
        ], check=True)
    variants = ["metal", "metal-double"] if phase == "before" else [
        "baseline", "scalar-tight", "coord-precompute", "unsafe-buffer", "float-math",
        "parallel", "simd4-float", "metal", "metal-double",
    ]
    report = None
    for size in ["512x512", "1024x1024"]:
        for variant in variants:
            result = subprocess.run([
                executable, "--benchmark", "--variants", variant, "--sizes", size,
                "--runs", "5", "--warmup", "1", "--format", "json", *viewport,
            ], check=True, capture_output=True, text=True)
            measured = json.loads(result.stdout)
            if report is None:
                report = {**measured, "results": []}
            report["results"].extend(measured["results"])
            for row in measured["results"]:
                print(f'{phase}: {variant} {size}: {row["medianSeconds"]:.6f}s', flush=True)
    (folder / f"benchmarks-{phase}.json").write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    executable, phase, folder = sys.argv[1:]
    if phase not in ["before", "after"]:
        raise SystemExit("Phase must be before or after")
    capture(str(Path(executable).resolve()), phase, Path(folder))
