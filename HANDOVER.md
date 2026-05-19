# K802 Ubuntu Server Benchmark Handover

## Goal

Run local GGUF model benchmarks directly on bare-metal OnLogic K802 hardware using Ubuntu Server, with trustworthy host-level CPU sensor access and persistent storage.

This replaces the earlier container workflow. No Docker bind mounts, no File Browser export path, and no streaming/delete workaround for Granite.

## Host Assumptions

- OnLogic K802.
- Ubuntu Server 24.04 LTS installed on the internal disk.
- Headless access via normal SSH from the work Mac.
- Company NetBird may provide private network reachability, but SSH itself is normal OpenSSH.
- Benchmark repo cloned onto the K802.
- Benchmark data stored under `/opt/k802-bench`.

## First Login

From the Mac:

```sh
ssh <user>@<k802-netbird-ip-or-dns-name>
```

Confirm the host:

```sh
hostnamectl
uname -a
lsblk -f
df -h
```

## Prepare Ubuntu

From the repo root on the K802:

```sh
sudo bash scripts/setup-ubuntu-k802.sh
```

This installs build tools and sensor utilities, enables SSH, creates `/opt/k802-bench`, and attempts to load:

```text
coretemp
msr
```

## Verify Sensors Before Benchmarking

Run:

```sh
find /sys/class/hwmon -maxdepth 2 -type f -name name -exec sh -c 'echo "$1: $(cat "$1")"' _ {} \;
sensors
```

Good signs:

```text
coretemp
Package id 0
Core 0
Core ...
```

Bad sign:

```text
acpitz only
```

`acpitz` alone is not treated as CPU thermal data. The benchmark should fail preflight unless a real CPU-ish sensor is visible or `ALLOW_NO_THERMAL=1` is explicitly set.

## Main Benchmark Command

Recommended first run:

```sh
sudo DOWNLOAD_MODELS=1 \
TEST_AMBIENT_C=25 TEST_CPU_TDP_W=35 \
TEST_MOUNT_ORIENTATION="vertical, fins unobstructed" \
TEST_CLEARANCE=">=2 inches all sides" \
TEST_EXTERNAL_FAN="none" \
bash benchmark.sh
```

Defaults:

```text
DATA_ROOT=/opt/k802-bench
THREADS="2 4 6 8"
NGL_VALUES=0
ENABLE_VULKAN=0
PROMPT_TOKENS=512
GEN_TOKENS=128
REPETITIONS=3
```

CPU-only is the default baseline. Do not start with Vulkan/iGPU unless you specifically want to compare it.

## Optional iGPU/Vulkan Pass

After the CPU baseline:

```sh
sudo ENABLE_VULKAN=1 NGL_VALUES="0 999" DOWNLOAD_MODELS=1 bash benchmark.sh
```

If Vulkan fails, keep the CPU-only result as the primary baseline.

## Default Models

The script downloads these resident models into:

```text
/opt/k802-bench/models
```

Model list:

```text
Llama-3.2-3B-Instruct-Q4_K_M.gguf
HuggingFaceTB_SmolLM3-3B-Q4_K_M.gguf
google_gemma-4-E2B-it-Q4_K_M.gguf
google_gemma-4-E4B-it-Q4_K_M.gguf
Qwen_Qwen3.5-4B-Q4_K_M.gguf
microsoft_Phi-4-mini-instruct-Q4_K_M.gguf
mistralai_Ministral-3-3B-Instruct-2512-Q4_K_M.gguf
ibm-granite_granite-3.3-8b-instruct-Q4_K_M.gguf
```

Gemma 4 E2B is included explicitly. E4B is also included for comparison.

## Output Location

Each benchmark run writes:

```text
/opt/k802-bench/benchmarks/<RUN_ID>
```

Important files:

```text
system-info.txt
basic-benchmarks.txt
llama-cpp-commit.txt
llama-bench-results.json
llama-bench-results.jsonl
llama-bench-summary.csv
```

## Dashboard

Thermal dashboard:

```sh
python3 benchmark_dashboard.py \
  /opt/k802-bench/benchmarks/<RUN_ID>/llama-bench-results.json \
  -o /opt/k802-bench/benchmarks/<RUN_ID>/dashboard
```

Performance-only dashboard:

```sh
python3 benchmark_dashboard.py \
  /opt/k802-bench/benchmarks/<RUN_ID>/llama-bench-results.json \
  -o /opt/k802-bench/benchmarks/<RUN_ID>/dashboard-no-thermal \
  --no-thermal
```

The dashboard HTML embeds charts inline. The separate SVG files are not required for viewing.

## Copy Results Back To Mac

From the Mac:

```sh
scp -r <user>@<k802-netbird-ip-or-dns-name>:/opt/k802-bench/benchmarks/<RUN_ID> .
```

Or tar first on the K802:

```sh
cd /opt/k802-bench/benchmarks
sudo tar -czf <RUN_ID>.tar.gz <RUN_ID>
```

Then:

```sh
scp <user>@<k802-netbird-ip-or-dns-name>:/opt/k802-bench/benchmarks/<RUN_ID>.tar.gz .
```

## Common Failure Modes

No CPU thermal sensors:

```sh
sudo modprobe coretemp
sensors
```

Still only `acpitz`:

```text
Do not trust thermal scoring. Use --no-thermal dashboard or fix host sensor visibility first.
```

Not enough disk:

```sh
df -h /opt/k802-bench
```

Use a larger disk or set:

```sh
sudo DATA_ROOT=/path/to/big/disk DOWNLOAD_MODELS=1 bash benchmark.sh
```

Vulkan build or runtime failure:

```text
Use the CPU-only default: ENABLE_VULKAN=0 NGL_VALUES=0.
```

## Current Repo Changes To Know

- `benchmark.sh` targets installed Ubuntu bare metal.
- Default data root is `/opt/k802-bench`.
- Default run is CPU-only.
- Granite is a normal persistent model, not streamed and deleted.
- `acpitz` is no longer accepted as CPU thermal data.
- `benchmark_dashboard.py` supports `--no-thermal`.
- Dashboard charts are embedded inline in the HTML.
