# Benchmarks

The scripts behind the measurements recorded in
[docs/Performance.md](../docs/Performance.md) and its
[history](../docs/Performance-history.md). Unlike the tests, they check
nothing: each drives the headless Release app (`make build`, then pass its
executable as `APP`) and writes what it measured into `docs/evidence/`,
where the history entry that used it links to it. Run them on an idle machine;
[Method](../docs/Performance.md#method) lists the traps.

| Script                     | Measures                                                        | Writes                                  |
| -------------------------- | --------------------------------------------------------------- | --------------------------------------- |
| `benchmark_gpu_depths.py`  | GPU kernels at four depths and two caps, with verified content  | a JSON file you name                    |
| `measure_tiles.py`         | five runs of `--test-tiles`: cache statistics and trace timings | `docs/evidence/gpu-pipeline/STAGE.json` |
| `measure_product.py`       | kernel-only and end-to-end GPU timings at the 1e7 view          | `docs/evidence/gpu-pipeline/STAGE.json` |
| `measure_bla.py`           | perturbation with BLA off and on at 1e50, 1e200 and 1e1000      | `docs/evidence/perturbation/2.2`        |
| `measure_deep_review.py`   | every BLA mode at c = i and the minibrot, per review stage      | `docs/evidence/perturbation/review`     |
| `measure_deep_followup.py` | cold automatic-depth latency and the BLA radius candidates      | `docs/evidence/perturbation/followup`   |
| `capture_floatfloat.py`    | the 1.2 FloatFloat experiment, before or after the fix          | a folder you name                       |
| `analyze_floatfloat.py`    | that experiment's accuracy, from its raw counts                 | standard output                         |

`reference-library/` is the spike that chose the arbitrary-precision library
for deep zoom, comparing the vendored BigInt with Boost; its
[README](reference-library/README.md) explains it.

Several scripts record a stage of work that is finished, and are kept so the
recorded numbers can be reproduced; later changes may make a rerun differ.
