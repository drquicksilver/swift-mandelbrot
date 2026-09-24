"""Summarize raw iteration-count evidence; no image-processing dependencies.

Usage: python3 benchmarks/analyze_floatfloat.py docs/evidence/floatfloat
"""

import array
import itertools
import json
from pathlib import Path
import sys


def read_counts(path):
    values = array.array("H", path.read_bytes())
    if sys.byteorder != "little":
        values.byteswap()
    return values


def run_lengths(values):
    return [sum(1 for _ in group) for _, group in itertools.groupby(values)]


def analyze(folder):
    width = height = 512
    reference = read_counts(folder / "cpu-double-reference.u16")
    escaped = [i for i, value in enumerate(reference) if value < 2000]
    results = {}
    for name in ["cpu-double-reference", "float-before", "floatfloat-before", "float-after", "floatfloat-after"]:
        values = read_counts(folder / f"{name}.u16")
        assert len(values) == width * height
        errors = [abs(a - b) for a, b in zip(values, reference)]
        columns = [tuple(values[y * width + x] for y in range(height)) for x in range(width)]
        rows = [tuple(values[y * width:(y + 1) * width]) for y in range(height)]
        column_runs, row_runs = run_lengths(columns), run_lengths(rows)
        results[name] = {
            "exactMatchPercent": 100 * sum(e == 0 for e in errors) / len(errors),
            "escapedExactMatchPercent": 100 * sum(errors[i] == 0 for i in escaped) / len(escaped),
            "withinOnePercent": 100 * sum(e <= 1 for e in errors) / len(errors),
            "meanAbsoluteIterationError": sum(errors) / len(errors),
            "distinctIterationCounts": len(set(values)),
            "distinctColumns": len(set(columns)),
            "distinctRows": len(set(rows)),
            "longestRepeatedColumnRun": max(column_runs),
            "longestRepeatedRowRun": max(row_runs),
        }
        if "before" in name:
            results[name]["columnRuns"] = column_runs
            results[name]["rowRuns"] = row_runs
    return {"width": width, "height": height, "maxIterations": 2000, "results": results}


if __name__ == "__main__":
    print(json.dumps(analyze(Path(sys.argv[1])), indent=2))
