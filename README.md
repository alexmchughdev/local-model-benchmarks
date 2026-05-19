# Local Model Benchmarks for OnLogic K802

This repo benchmarks GGUF local models with `llama.cpp` on a bare-metal OnLogic K802 running Ubuntu Server. It records throughput, variance, hardware metadata, and CPU thermal data so the final model/thread choice is based on sustained unattended operation, not only peak tokens/sec.

## Target Host

Use an installed Ubuntu Server LTS system on the K802. The intended baseline is:

- Ubuntu Server 24.04 LTS.
- SSH access over your normal network or company NetBird network.
- Persistent benchmark data under `/opt/k802-bench`.
- Bare-metal access to `/sys`, `/dev/dri`, DMI, CPU frequency, and hardware monitor sensors.

Do not run the primary thermal benchmark in Docker. Containerized runs can hide or distort CPU package sensors.

## First-Time Setup

SSH into the K802, clone the repo, and run:

```sh
sudo bash scripts/setup-ubuntu-k802.sh
```

This installs build tools, sensor utilities, NVMe/SMART tools, OpenSSH, and loads `coretemp`/`msr` when available. It also creates:

```text
/opt/k802-bench/models
/opt/k802-bench/benchmarks
```

Verify real CPU sensors before trusting thermal results:

```sh
find /sys/class/hwmon -maxdepth 2 -type f -name name -exec sh -c 'echo "$1: $(cat "$1")"' _ {} \;
sensors
```

You want CPU-related sensors such as `coretemp`, package temperature, or core temperatures. `acpitz` alone is not enough and is intentionally ignored by the script.

## Running

Default run, CPU-only, downloading all default models:

```sh
sudo DOWNLOAD_MODELS=1 \
TEST_AMBIENT_C=25 TEST_CPU_TDP_W=35 \
TEST_MOUNT_ORIENTATION="vertical, fins unobstructed" \
TEST_CLEARANCE=">=2 inches all sides" \
TEST_EXTERNAL_FAN="none" \
bash benchmark.sh
```

Results are written to:

```text
/opt/k802-bench/benchmarks/<RUN_ID>
```

The script also builds or updates `llama.cpp` under:

```text
/opt/k802-bench/llama.cpp
```

## Default Models

With `DOWNLOAD_MODELS=1`, the script downloads all defaults as persistent resident models. Nothing is streamed and deleted.

Current defaults include:

- `Llama-3.2-3B-Instruct-Q4_K_M.gguf`
- `HuggingFaceTB_SmolLM3-3B-Q4_K_M.gguf`
- `google_gemma-4-E2B-it-Q4_K_M.gguf`
- `google_gemma-4-E4B-it-Q4_K_M.gguf`
- `Qwen_Qwen3.5-4B-Q4_K_M.gguf`
- `microsoft_Phi-4-mini-instruct-Q4_K_M.gguf`
- `mistralai_Ministral-3-3B-Instruct-2512-Q4_K_M.gguf`
- `ibm-granite_granite-3.3-8b-instruct-Q4_K_M.gguf`

The Gemma 4 E2B/E4B entries are the edge-size Gemma 4 models.

## Useful Variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `DATA_ROOT` | `/opt/k802-bench` | Root for models, build, and results. |
| `OUT_ROOT` | `$DATA_ROOT/benchmarks` | Benchmark output root. |
| `MODELS_DIR` | `$DATA_ROOT/models` | GGUF model directory. |
| `LLAMA_DIR` | `$DATA_ROOT/llama.cpp` | `llama.cpp` checkout/build directory. |
| `THREADS` | `2 4 6 8` | Thread counts to test. |
| `NGL_VALUES` | `0` | GPU layers. `0` is CPU-only. |
| `ENABLE_VULKAN` | `0` | Set `1` only when testing iGPU/Vulkan. |
| `DOWNLOAD_MODELS` | `0` | Set `1` to download defaults. |
| `PROMPT_TOKENS` | `512` | Prompt-processing tokens passed to `llama-bench`. |
| `GEN_TOKENS` | `128` | Generation tokens passed to `llama-bench`. |
| `REPETITIONS` | `3` | Repetitions passed to `llama-bench`. |
| `THERMAL_STABLE_MAX_C` | empty | Optional max CPU temp before starting next run. |
| `TEST_AMBIENT_C` | empty | Ambient temperature near the K802. |
| `TEST_CPU_TDP_W` | empty | CPU TDP class, usually `35` or `65`. |

For an iGPU pass:

```sh
sudo ENABLE_VULKAN=1 NGL_VALUES="0 999" DOWNLOAD_MODELS=1 bash benchmark.sh
```

CPU-only is the default because it is the cleanest cross-run baseline.

## Outputs

Each run contains:

- `system-info.txt`: OS, kernel, CPU, memory, disk, DMI, GPU, frequency, sensors, and metadata.
- `basic-benchmarks.txt`: simple CPU hash and disk read/write checks.
- `llama-cpp-commit.txt`: `llama.cpp` commit used.
- `llama-bench-results.json`: full enriched JSON array.
- `llama-bench-results.jsonl`: one enriched JSON row per benchmark row.
- `llama-bench-summary.csv`: flattened spreadsheet summary.

## Dashboard

Generate a thermal dashboard:

```sh
python3 benchmark_dashboard.py \
  /opt/k802-bench/benchmarks/<RUN_ID>/llama-bench-results.json \
  -o /opt/k802-bench/benchmarks/<RUN_ID>/dashboard
```

Generate a performance-only dashboard if thermal sensors are suspect:

```sh
python3 benchmark_dashboard.py \
  /opt/k802-bench/benchmarks/<RUN_ID>/llama-bench-results.json \
  -o /opt/k802-bench/benchmarks/<RUN_ID>/dashboard-no-thermal \
  --no-thermal
```

The HTML dashboard embeds charts inline, so it does not depend on external SVG rendering in the browser.

## Notes

- Run with `sudo` for the main benchmark so `/opt/k802-bench` is writable and `coretemp`/`msr` can be loaded.
- If preflight reports no CPU thermal sensors, fix that before trusting thermal results.
- If only `acpitz` appears, the script should fail rather than recording bogus CPU thermal data.
- A final production choice should still get a longer soak test with the actual model server workload.
