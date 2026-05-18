# Local Model Benchmarks for OnLogic K802

This repo benchmarks GGUF local models with `llama.cpp` and produces a dashboard for choosing the best model/thread configuration for unattended operation on fanless OnLogic K802 industrial PCs.

The goal is not just maximum tokens/sec. The useful result is the model that is fast enough, thermally stable, low variance, and able to run indefinitely without heat soak, throttling, crashes, or long cooldown waits.

## K802 Context

Relevant OnLogic K802 details for this test:

- System: Karbon 802 high-performance rugged computer with ModBay.
- Processor platform: Intel 12th Gen Alder Lake-S, LGA1700.
- CPU options: Core i3/i5/i7/i9, up to 16 cores and 24 threads, up to 5 GHz depending on CPU.
- Chipset: Intel W680.
- Memory: up to 64 GB DDR4-2666 ECC or non-ECC.
- Power input: 5-pin terminal block, 12 to 48 V DC. The support docs also call for a UL Listed external power supply rated 24 to 36 Vdc.
- Cooling/install: fanless chassis with 1 external fan connector. OnLogic recommends at least 2 inches of clearance around all sides and, for vertical mounting, orienting the heatsink fins so air can rise unobstructed.
- Operating temperature: -40 to 70 C with a 35 W CPU, or -40 to 50 C with a 65 W CPU.

Those OnLogic temperature values are system/ambient operating ratings. They are not the same thing as CPU package temperature. The benchmark records CPU thermal sensor readings because those are useful for comparing model load, but you should also record ambient temperature near the PC.

Sources:

- K802 spec sheet: https://static.onlogic.com/resources/spec-sheets/OnLogic-K802-Spec-Sheet-V2.pdf
- K800 support docs: https://support.onlogic.com/product-documentation/rugged-products/karbon-k800-series/k801-k802-k803-k804

## Files

- `benchmark.sh`: builds or updates `llama.cpp`, runs `llama-bench` across models and thread counts, records CPU thermal data, and waits for temperatures to stabilize between runs.
- `benchmark_dashboard.py`: converts `llama-bench-results.json` or JSONL into an offline HTML dashboard, CSV summaries, and standalone SVG figures for Word.

## Benchmark Output

Each run writes to:

```sh
/data/benchmarks/<RUN_ID>/
```

Main outputs:

- `system-info.txt`: OS, CPU, memory, disk, load, cgroup limits, structured hardware metadata, CPU governor/frequency where exposed, thermal snapshot, and test metadata.
- `basic-benchmarks.txt`: simple CPU and disk checks.
- `llama-cpp-commit.txt`: `llama.cpp` git commit used for the run.
- `llama-bench-results.json`: full JSON array for dashboard input.
- `llama-bench-results.jsonl`: one JSON object per `llama-bench` row.
- `llama-bench-summary.csv`: flattened summary for spreadsheet use.

## Thermal Collection

The benchmark reads Linux CPU thermal data from:

- `/sys/class/thermal/thermal_zone*`
- `/sys/class/hwmon/hwmon*/temp*_input`

Each benchmark row includes:

- `hardware_metadata`: structured OS, system, CPU, memory, BIOS, and block-device details.
- `test_metadata`: K802-specific test context such as ambient temperature, TDP class, mount orientation, clearance, and fan state.
- `cpu_thermal_stabilization`: pre-run cooldown/stabilization status, samples, wait time, and timeout state.
- `cpu_thermal_before`: CPU thermal snapshot immediately before `llama-bench`.
- `cpu_thermal_during`: sampled CPU thermals while `llama-bench` is running.
- `cpu_thermal_after`: CPU thermal snapshot immediately after `llama-bench`.

Hardware metadata is collected from `lscpu`, `/proc/meminfo`, `/etc/os-release`, `uname`, `lsblk`, CPU frequency sysfs paths, and `/sys/class/dmi/id` when available. Containers may hide DMI and some CPU frequency data, so run on the host or mount the relevant sysfs paths if you need complete hardware identity.

If the script cannot see CPU thermal sensors, it records that and continues. In Docker/Portainer, make sure `/sys` is visible to the container if you need thermal data.

## Temperature Stabilization

Before each model/thread benchmark, the script waits for CPU max temperature to stabilize. By default, it samples every 5 seconds and starts the benchmark when the last 3 samples are within 1.0 C of each other.

Relevant defaults:

```sh
THERMAL_STABILIZE=1
THERMAL_STABLE_POLL_INTERVAL=5
THERMAL_STABLE_SAMPLES=3
THERMAL_STABLE_DELTA_C=1.0
THERMAL_STABLE_TIMEOUT=300
THERMAL_STABLE_MAX_C=
```

Set `THERMAL_STABLE_MAX_C` if you want to require the CPU to cool below a ceiling before the next test:

```sh
THERMAL_STABLE_MAX_C=55 sh benchmark.sh
```

If the CPU does not stabilize before `THERMAL_STABLE_TIMEOUT`, the script continues and marks that run as a thermal stabilization timeout. Treat those runs as weak candidates for indefinite fanless operation.

## Running Benchmarks

Put GGUF models in `/data/models`, or set `DOWNLOAD_MODELS=1` to fetch the default small models.

Example K802 run:

```sh
TEST_AMBIENT_C=25 \
TEST_CPU_TDP_W=35 \
TEST_MOUNT_ORIENTATION="vertical, fins unobstructed" \
TEST_CLEARANCE=">=2 inches all sides" \
TEST_EXTERNAL_FAN="none" \
THREADS="2 4 6 8" \
PROMPT_TOKENS=512 \
GEN_TOKENS=128 \
REPETITIONS=3 \
sh benchmark.sh
```

Useful environment variables:

| Variable | Default | Purpose |
| --- | --- | --- |
| `OUT_ROOT` | `/data/benchmarks` | Root output directory. |
| `MODELS_DIR` | `/data/models` | Directory containing `.gguf` files. |
| `LLAMA_DIR` | `/data/llama.cpp` | `llama.cpp` checkout/build directory. |
| `THREADS` | `2 4 8` | Thread counts to test. |
| `PROMPT_TOKENS` | `512` | Prompt processing token count. |
| `GEN_TOKENS` | `128` | Generation token count. |
| `REPETITIONS` | `3` | Repetitions passed to `llama-bench`. |
| `DOWNLOAD_MODELS` | `0` | Set to `1` to download default models. |
| `THERMAL_SAMPLE_INTERVAL` | `2` | Seconds between samples during each benchmark. |
| `THERMAL_STABILIZE` | `1` | Set to `0` to disable pre-run stabilization waits. |
| `THERMAL_STABLE_POLL_INTERVAL` | `5` | Seconds between cooldown/stabilization checks. |
| `THERMAL_STABLE_SAMPLES` | `3` | Number of recent samples used to decide stability. |
| `THERMAL_STABLE_DELTA_C` | `1.0` | Maximum temperature spread in the stability window. |
| `THERMAL_STABLE_TIMEOUT` | `300` | Max seconds to wait before continuing. |
| `THERMAL_STABLE_MAX_C` | empty | Optional max CPU temperature before starting the next test. |
| `TEST_DEVICE` | `OnLogic K802` | Device name recorded into results. |
| `TEST_AMBIENT_C` | empty | Ambient temperature near the PC. |
| `TEST_CPU_TDP_W` | empty | CPU TDP class, usually 35 or 65 for K802 testing. |
| `TEST_MOUNT_ORIENTATION` | empty | Mount position and fin orientation. |
| `TEST_CLEARANCE` | empty | Clearance around the chassis. |
| `TEST_EXTERNAL_FAN` | empty | External fan state, if any. |
| `TEST_NOTES` | empty | Free-form test notes. |

## Generating the Dashboard

Run the dashboard generator against the benchmark JSON:

```sh
python3 benchmark_dashboard.py \
  /data/benchmarks/<RUN_ID>/llama-bench-results.json \
  -o /data/benchmarks/<RUN_ID>/dashboard \
  --thermal-limit-c 85
```

Outputs:

- `index.html`: offline dashboard.
- `figures/*.svg`: standalone figures suitable for inserting into Word.
- `sustained-use-ranking.csv`: model/thread ranking for unattended fanless operation.
- `benchmark-summary.csv`: throughput summary.
- `thermal-summary.csv`: thermal summary by benchmark invocation.
- `figure-manifest.csv`: figure file list.

The dashboard also surfaces hardware identity from the benchmark JSON, including detected product name, CPU model, logical CPU count, total memory, OS, and BIOS where available.

To use figures in Word, insert the SVG files from the `figures` directory. The dashboard embeds the same SVGs for review in a browser.

## Sustained-Use Score

The dashboard creates a composite sustained-use score. It favors:

- Higher generation throughput.
- Lower throughput variance.
- More CPU thermal headroom below `--thermal-limit-c`.
- Smaller temperature rise during the benchmark.
- Shorter stabilization wait before the run.
- No thermal stabilization timeout.

By default, the dashboard uses `tg` rows from `llama-bench` as the primary generation metric when present. You can override that:

```sh
python3 benchmark_dashboard.py results.json --primary-type pp
```

The score is a decision aid, not a pass/fail certification. The final choice should also pass a long soak test with your real workload.

## How To Interpret Results

For K802 fanless deployment, prefer a model/thread configuration that:

- Meets your minimum tokens/sec for generation.
- Has low `stddev_ts` and low `cv_pct` in `sustained-use-ranking.csv`.
- Peaks well below your CPU package temperature threshold.
- Shows small temperature rise from before to during the run.
- Needs little or no stabilization wait between runs.
- Never hits `stabilization_reason=timeout`.
- Leaves enough ambient headroom for the actual installation, especially for 65 W CPU configurations rated to 50 C ambient.

After short benchmarks, rerun finalists as longer tests:

- 30 minutes for quick screening.
- 2 hours for heat-soak behavior.
- Overnight or 24 hours for the final unattended candidate.

## Additional Data Worth Collecting

For the most defensible decision, also collect:

- Ambient temperature near the chassis and inside any cabinet.
- Wall/DC input power: average watts and peak watts.
- CPU package power, frequency, governor, Turbo state, and throttling flags.
- Memory RSS, available memory, swap usage, page faults, and OOM events.
- SSD temperature and SMART health.
- Service-level metrics from the actual local model server: request count, errors, restarts, queue depth, time to first token, p50/p95/p99 total response time.
- Installation details: mount orientation, clearance, nearby heat sources, external fan state, BIOS version, kernel version, CPU SKU, RAM, SSD model, and model server version.

The benchmark now records the most important test metadata fields directly into JSON. Power, throttling, SSD SMART data, and real request latency are still best collected by your deployment monitoring or a separate soak-test harness.
