"""Integration checks: python3 tests/cli/test_headless.py /path/to/Mandelbrot"""

import json
import array
import os
from pathlib import Path
import statistics
import subprocess
import sys
import tempfile
import struct
import unittest


EXECUTABLE = str(Path(sys.argv.pop(1)).resolve())


class HeadlessTests(unittest.TestCase):
    def run_cli(self, *arguments):
        return subprocess.run(
            [EXECUTABLE, *arguments], capture_output=True, text=True, timeout=30,
            env={**os.environ, "LLVM_PROFILE_FILE": os.devnull},
        )

    def test_help_exits_without_app_event_loop(self):
        result = self.run_cli("--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--benchmark", result.stdout)

    def test_cpu_renderers_and_json_measurements(self):
        variants = [
            "baseline", "scalar-tight", "coord-precompute", "unsafe-buffer",
            "float-math", "parallel", "simd4-float",
        ]
        result = self.run_cli(
            "--benchmark", "--variants", ",".join(variants),
            "--sizes", "17x9,32x16", "--iterations", "20",
            "--runs", "2", "--warmup", "1", "--format", "json",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report["iterations"], 20)
        self.assertEqual(report["warmup"], 1)
        self.assertEqual(report["runs"], 2)
        self.assertEqual(len(report["results"]), 14)
        self.assertEqual({row["variant"] for row in report["results"]}, set(variants))
        for row in report["results"]:
            self.assertEqual(len(row["samplesSeconds"]), 2)
            self.assertTrue(all(t > 0 for t in row["samplesSeconds"]))
            self.assertEqual(row["medianSeconds"], statistics.median(row["samplesSeconds"]))
            self.assertAlmostEqual(
                row["megapixelsPerSecond"],
                row["width"] * row["height"] / row["medianSeconds"] / 1_000_000,
            )

    def test_markdown_and_zero_warmups(self):
        result = self.run_cli(
            "--benchmark", "--variants", "baseline", "--sizes", "1x1",
            "--runs", "1", "--warmup", "0",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("| baseline | 1x1 |", result.stdout)
        self.assertIn("0 warmup", result.stdout)

    def test_viewport_in_benchmark_report(self):
        result = self.run_cli(
            "--benchmark", "--variants", "baseline", "--sizes", "16x8",
            "--runs", "1", "--warmup", "0", "--format", "json",
            "--center-real", "-0.743643987037151", "--center-imag", "0.13182597420533",
            "--scale", "10000000",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report["centerReal"], -0.743643987037151)
        self.assertEqual(report["centerImag"], 0.13182597420533)
        self.assertEqual(report["scale"], 10000000)

    def test_png_and_counts_use_selected_viewport(self):
        with tempfile.TemporaryDirectory() as folder:
            png, counts = Path(folder) / "image.png", Path(folder) / "counts.u16"
            # Far outside the set, every sample escapes on the first iteration.
            result = self.run_cli(
                "--render", "--renderer", "baseline", "--size", "17x9",
                "--center-real", "3", "--center-imag", "3", "--scale", "1000",
                "--output", str(png), "--counts", str(counts),
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            data = png.read_bytes()
            self.assertEqual(data[:8], b"\x89PNG\r\n\x1a\n")
            self.assertEqual(struct.unpack(">II", data[16:24]), (17, 9))
            self.assertEqual(counts.read_bytes(), b"\x01\x00" * (17 * 9))
            # Same settings near zero are inside the set up to the chosen cap.
            result = self.run_cli(
                "--render", "--renderer", "baseline", "--size", "17x9",
                "--center-real", "0", "--center-imag", "0", "--scale", "1000",
                "--iterations", "37", "--output", str(png), "--counts", str(counts),
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(counts.read_bytes(), b"\x25\x00" * (17 * 9))

    def test_render_errors(self):
        for arguments in [[], ["--output", "x.png", "--renderer", "unknown"],
                          ["--output", "x.png", "--size", "8x8,16x16"],
                          ["--output", "x.png", "--counts", "./x.png"],
                          ["--output", "x.png", "--benchmark"],
                          ["--output", "x.png", "--pipeline", "tiles", "--scale", "1e14"],
                          ["--output", "x.png", "--pipeline", "tiles", "--scale", "0.001"],
                          ["--output", "x.png", "--pipeline", "tiles", "--colouring", "legacy"]]:
            with self.subTest(arguments=arguments):
                self.assertEqual(self.run_cli("--render", *arguments).returncode, 2)
        with tempfile.TemporaryDirectory() as folder:
            result = self.run_cli("--render", "--renderer", "baseline", "--size", "8x8",
                                  "--output", str(Path(folder) / "missing" / "x.png"))
            self.assertEqual(result.returncode, 1)
            self.assertIn("Could not write", result.stderr)

    @unittest.skipUnless(os.environ.get("MANDELBROT_TEST_METAL") == "1", "Opt in with MANDELBROT_TEST_METAL=1")
    def test_float_gpu_interior_boundary(self):
        # The period-two bulb edge contains both true interior and slow exterior
        # points. Compare capped classifications with CPU Double, allowing Float
        # rounding at the boundary rather than requiring identical escape counts.
        with tempfile.TemporaryDirectory() as folder:
            values = {}
            for variant in ("parallel", "metal"):
                counts = Path(folder) / f"{variant}.u16"
                args = ["--render", "--renderer", variant, "--size", "256x192",
                        "--center-real", "-1", "--center-imag", "0.25",
                        "--scale", "30", "--iterations", "2000",
                        "--output", str(Path(folder) / f"{variant}.png"),
                        "--counts", str(counts)]
                if variant == "metal":
                    args += ["--pipeline", "gpu", "--colouring", "legacy"]
                result = self.run_cli(*args)
                self.assertEqual(result.returncode, 0, result.stderr)
                raw = array.array("H", counts.read_bytes())
                if sys.byteorder != "little": raw.byteswap()
                values[variant] = raw
            cpu, gpu = values["parallel"], values["metal"]
            self.assertGreater(sum(value == 2000 for value in gpu), len(gpu) // 4)
            self.assertGreater(sum(value < 2000 for value in gpu), len(gpu) // 4)
            differences = sum((a == 2000) != (b == 2000) for a, b in zip(cpu, gpu))
            self.assertLess(differences, len(cpu) // 200)

    @unittest.skipUnless(os.environ.get("MANDELBROT_TEST_METAL") == "1", "Opt in with MANDELBROT_TEST_METAL=1")
    def test_floatfloat_deep_zoom_accuracy(self):
        # Compare escape counts, not palette colours; exclude capped pixels from
        # the exact-match criterion so a flat black image cannot pass.
        with tempfile.TemporaryDirectory() as folder:
            for width, height in [(512, 512), (513, 257)]:
                results = {}
                for variant in ["parallel", "metal", "metal-double"]:
                    counts = Path(folder) / "counts.u16"
                    result = self.run_cli(
                        "--render", "--renderer", variant, "--size", f"{width}x{height}",
                        "--center-real", "-0.743643987037151", "--center-imag", "0.13182597420533",
                        "--scale", "10000000", "--iterations", "2000",
                        "--output", str(Path(folder) / "image.png"), "--counts", str(counts),
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)
                    values = array.array("H", counts.read_bytes())
                    if sys.byteorder != "little": values.byteswap()
                    results[variant] = values
                reference = results["parallel"]
                escaped = [i for i, value in enumerate(reference) if value < 2000]
                self.assertGreater(len(escaped), len(reference) * 0.25)
                errors = [abs(a - b) for a, b in zip(reference, results["metal-double"])]
                self.assertGreater(sum(errors[i] == 0 for i in escaped) / len(escaped), 0.85)
                self.assertLess(sum(errors) / len(errors), 8)
                float_errors = [abs(a - b) for a, b in zip(reference, results["metal"])]
                self.assertLess(sum(errors), sum(float_errors) / 20)

    def test_invalid_options_fail_before_rendering(self):
        for arguments in [
            ["--variants", "missing"], ["--variants", ""],
            ["--sizes", "0x10"], ["--sizes", "100000000000000000x9"],
            ["--sizes", "16384x16384"], ["--sizes", "10"],
            ["--iterations", "65536"], ["--iterations", "-1"],
            ["--runs", "0"], ["--warmup", "-1"], ["--format", "csv"],
            ["--unknown"], ["--sizes"],
            ["--scale", "0"], ["--scale", "nan"], ["--center-real", "inf"],
            ["--center-imag", "-5"], ["--output", "x.png"],
        ]:
            with self.subTest(arguments=arguments):
                result = self.run_cli("--benchmark", *arguments)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(result.stdout, "")
                self.assertIn("--help", result.stderr)


if __name__ == "__main__":
    unittest.main()
