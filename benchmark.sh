#!/bin/sh
set -eu

# ============================================================
# Saves benchmark data to /data
# Intended to run from Portainer / Docker / Linux shell
# In the loom-harness stack, /data is bind-mounted from the host
# /var/lib/ubuntu, so results are visible to File Browser.
# ============================================================

OUT_ROOT="${OUT_ROOT:-/data/benchmarks}"
RUN_ID="$(date -u +"%Y%m%dT%H%M%SZ")"
OUT_DIR="$OUT_ROOT/$RUN_ID"

MODELS_DIR="${MODELS_DIR:-/data/models}"
LLAMA_DIR="${LLAMA_DIR:-/data/llama.cpp}"
THREADS="${THREADS:-2 4 8}"
PROMPT_TOKENS="${PROMPT_TOKENS:-512}"
GEN_TOKENS="${GEN_TOKENS:-128}"
REPETITIONS="${REPETITIONS:-3}"
# Layers to offload to GPU per run. Space-separated list. 0 = CPU only.
# 999 = all layers (full iGPU/dGPU offload, llama-bench clamps to model max).
# Default tests CPU-only and full iGPU offload back to back.
NGL_VALUES="${NGL_VALUES:-0 999}"
ENABLE_VULKAN="${ENABLE_VULKAN:-1}"
THERMAL_SAMPLE_INTERVAL="${THERMAL_SAMPLE_INTERVAL:-2}"
THERMAL_STABILIZE="${THERMAL_STABILIZE:-1}"
THERMAL_STABLE_POLL_INTERVAL="${THERMAL_STABLE_POLL_INTERVAL:-5}"
THERMAL_STABLE_SAMPLES="${THERMAL_STABLE_SAMPLES:-3}"
THERMAL_STABLE_DELTA_C="${THERMAL_STABLE_DELTA_C:-1.0}"
THERMAL_STABLE_TIMEOUT="${THERMAL_STABLE_TIMEOUT:-300}"
THERMAL_STABLE_MAX_C="${THERMAL_STABLE_MAX_C:-}"
TEST_DEVICE="${TEST_DEVICE:-OnLogic K802}"
TEST_AMBIENT_C="${TEST_AMBIENT_C:-}"
TEST_CPU_TDP_W="${TEST_CPU_TDP_W:-}"
TEST_MOUNT_ORIENTATION="${TEST_MOUNT_ORIENTATION:-}"
TEST_CLEARANCE="${TEST_CLEARANCE:-}"
TEST_EXTERNAL_FAN="${TEST_EXTERNAL_FAN:-}"
TEST_NOTES="${TEST_NOTES:-}"

# ------------------------------------------------------------
# Basic dependency installation
# ------------------------------------------------------------

install_deps() {
    # Vulkan packages are only added when ENABLE_VULKAN=1, so a CPU-only
    # run still works on hosts without Mesa or an Intel/AMD ICD.
    APT_VULKAN=""
    DNF_VULKAN=""
    APK_VULKAN=""
    if [ "${ENABLE_VULKAN:-0}" = "1" ]; then
        APT_VULKAN="libvulkan-dev mesa-vulkan-drivers vulkan-tools pciutils"
        DNF_VULKAN="vulkan-loader-devel mesa-vulkan-drivers vulkan-tools pciutils"
        APK_VULKAN="vulkan-loader-dev mesa-vulkan vulkan-tools pciutils"
    fi

    if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        # shellcheck disable=SC2086
        apt-get install -y build-essential cmake git jq curl wget procps util-linux $APT_VULKAN
    elif command -v dnf >/dev/null 2>&1; then
        # shellcheck disable=SC2086
        dnf install -y gcc gcc-c++ cmake git make jq curl wget procps-ng util-linux $DNF_VULKAN
    elif command -v apk >/dev/null 2>&1; then
        # shellcheck disable=SC2086
        apk add --no-cache build-base cmake git jq curl wget procps util-linux $APK_VULKAN
    else
        echo "[!] Could not detect package manager. Install gcc, g++, cmake, git, jq, wget manually."
    fi
}

# ------------------------------------------------------------
# Capture system information
# ------------------------------------------------------------

test_metadata_json() {
    jq -n \
        --arg device "$TEST_DEVICE" \
        --arg ambient_c "$TEST_AMBIENT_C" \
        --arg cpu_tdp_w "$TEST_CPU_TDP_W" \
        --arg mount_orientation "$TEST_MOUNT_ORIENTATION" \
        --arg clearance "$TEST_CLEARANCE" \
        --arg external_fan "$TEST_EXTERNAL_FAN" \
        --arg notes "$TEST_NOTES" \
        '
        def optional_number:
            if . == "" then null else (try tonumber catch null) end;

        {
            device: $device,
            ambient_c: ($ambient_c | optional_number),
            cpu_tdp_w: ($cpu_tdp_w | optional_number),
            mount_orientation: (if $mount_orientation == "" then null else $mount_orientation end),
            clearance: (if $clearance == "" then null else $clearance end),
            external_fan: (if $external_fan == "" then null else $external_fan end),
            notes: (if $notes == "" then null else $notes end)
        }
    '
}

read_first_existing_file() {
    for METADATA_FILE in "$@"; do
        if [ -r "$METADATA_FILE" ]; then
            cat "$METADATA_FILE" 2>/dev/null
            return
        fi
    done
    return 0
}

cpu_governors_json() {
    for CPU_GOVERNOR in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [ -r "$CPU_GOVERNOR" ] || continue
        cat "$CPU_GOVERNOR" 2>/dev/null || true
    done | sort -u | jq -R -s 'split("\n") | map(select(length > 0))'
}

cpu_frequency_json() {
    {
        for CPU_FREQ in /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq; do
            [ -r "$CPU_FREQ" ] || continue
            cat "$CPU_FREQ" 2>/dev/null || true
        done
    } | jq -R -s '
        (split("\n") | map(select(length > 0) | tonumber)) as $freqs
        | {
            available: (($freqs | length) > 0),
            min_khz: (if ($freqs | length) > 0 then ($freqs | min) else null end),
            max_khz: (if ($freqs | length) > 0 then ($freqs | max) else null end),
            avg_khz: (if ($freqs | length) > 0 then (($freqs | add) / ($freqs | length)) else null end)
        }
    '
}

gpu_devices_json() {
    if ! command -v lspci >/dev/null 2>&1; then
        printf '[]'
        return
    fi

    # Each line: "0000:00:02.0 VGA compatible controller [0300]: Intel Corporation Raptor Lake-S UHD Graphics [8086:a780] (rev 04)"
    GPU_LINES="$(lspci -nn 2>/dev/null | grep -iE 'vga|3d|display' || true)"
    if [ -z "$GPU_LINES" ]; then
        printf '[]'
        return
    fi

    printf '%s\n' "$GPU_LINES" | jq -Rn '
        [inputs
         | capture("^(?<addr>[0-9a-f:.]+)\\s+(?<class>[^[]+?)\\s+\\[(?<class_id>[0-9a-f]+)\\]:\\s+(?<desc>.+)$")
         | {
             pci_address: .addr,
             class: (.class | gsub("^ +| +$"; "")),
             class_id: .class_id,
             description: .desc
           }
        ]
    '
}

dri_devices_json() {
    if [ ! -d /dev/dri ]; then
        printf '[]'
        return
    fi
    ls -1 /dev/dri 2>/dev/null | jq -Rn '[inputs]'
}

lsblk_json() {
    if command -v lsblk >/dev/null 2>&1; then
        lsblk -J -b -o NAME,MODEL,SERIAL,SIZE,TYPE,TRAN,ROTA,MOUNTPOINTS 2>/dev/null || printf '{"blockdevices":[]}\n'
    else
        printf '{"blockdevices":[]}\n'
    fi
}

hardware_metadata_json() {
    CPU_MODEL="$(lscpu 2>/dev/null | awk -F: '/Model name:/ {sub(/^[ \t]+/, "", $2); print $2; exit}' || true)"
    CPU_VENDOR="$(lscpu 2>/dev/null | awk -F: '/Vendor ID:/ {sub(/^[ \t]+/, "", $2); print $2; exit}' || true)"
    CPU_ARCH="$(lscpu 2>/dev/null | awk -F: '/Architecture:/ {sub(/^[ \t]+/, "", $2); print $2; exit}' || true)"
    CPU_SOCKETS="$(lscpu 2>/dev/null | awk -F: '/Socket\(s\):/ {sub(/^[ \t]+/, "", $2); print $2; exit}' || true)"
    CPU_CORES_PER_SOCKET="$(lscpu 2>/dev/null | awk -F: '/Core\(s\) per socket:/ {sub(/^[ \t]+/, "", $2); print $2; exit}' || true)"
    CPU_THREADS_PER_CORE="$(lscpu 2>/dev/null | awk -F: '/Thread\(s\) per core:/ {sub(/^[ \t]+/, "", $2); print $2; exit}' || true)"
    CPU_MAX_MHZ="$(lscpu 2>/dev/null | awk -F: '/CPU max MHz:/ {sub(/^[ \t]+/, "", $2); print $2; exit}' || true)"
    CPU_MIN_MHZ="$(lscpu 2>/dev/null | awk -F: '/CPU min MHz:/ {sub(/^[ \t]+/, "", $2); print $2; exit}' || true)"
    LOGICAL_CPUS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || true)"
    MEM_TOTAL_KB="$(awk '/MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || true)"
    MEM_AVAILABLE_KB="$(awk '/MemAvailable:/ {print $2; exit}' /proc/meminfo 2>/dev/null || true)"
    PRODUCT_NAME="$(read_first_existing_file /sys/class/dmi/id/product_name)"
    PRODUCT_VERSION="$(read_first_existing_file /sys/class/dmi/id/product_version)"
    BOARD_VENDOR="$(read_first_existing_file /sys/class/dmi/id/board_vendor)"
    BOARD_NAME="$(read_first_existing_file /sys/class/dmi/id/board_name)"
    BOARD_VERSION="$(read_first_existing_file /sys/class/dmi/id/board_version)"
    BIOS_VENDOR="$(read_first_existing_file /sys/class/dmi/id/bios_vendor)"
    BIOS_VERSION="$(read_first_existing_file /sys/class/dmi/id/bios_version)"
    BIOS_DATE="$(read_first_existing_file /sys/class/dmi/id/bios_date)"
    KERNEL="$(uname -r 2>/dev/null || true)"
    OS_PRETTY_NAME="$(awk -F= '/^PRETTY_NAME=/ {gsub(/^"|"$/, "", $2); print $2; exit}' /etc/os-release 2>/dev/null || true)"
    CPU_GOVERNORS="$(cpu_governors_json)"
    CPU_FREQUENCY="$(cpu_frequency_json)"
    BLOCK_DEVICES="$(lsblk_json)"
    GPU_DEVICES="$(gpu_devices_json)"
    DRI_DEVICES="$(dri_devices_json)"

    jq -n \
        --arg cpu_model "$CPU_MODEL" \
        --arg cpu_vendor "$CPU_VENDOR" \
        --arg cpu_arch "$CPU_ARCH" \
        --arg logical_cpus "$LOGICAL_CPUS" \
        --arg cpu_sockets "$CPU_SOCKETS" \
        --arg cpu_cores_per_socket "$CPU_CORES_PER_SOCKET" \
        --arg cpu_threads_per_core "$CPU_THREADS_PER_CORE" \
        --arg cpu_max_mhz "$CPU_MAX_MHZ" \
        --arg cpu_min_mhz "$CPU_MIN_MHZ" \
        --arg mem_total_kb "$MEM_TOTAL_KB" \
        --arg mem_available_kb "$MEM_AVAILABLE_KB" \
        --arg product_name "$PRODUCT_NAME" \
        --arg product_version "$PRODUCT_VERSION" \
        --arg board_vendor "$BOARD_VENDOR" \
        --arg board_name "$BOARD_NAME" \
        --arg board_version "$BOARD_VERSION" \
        --arg bios_vendor "$BIOS_VENDOR" \
        --arg bios_version "$BIOS_VERSION" \
        --arg bios_date "$BIOS_DATE" \
        --arg kernel "$KERNEL" \
        --arg os_pretty_name "$OS_PRETTY_NAME" \
        --argjson cpu_governors "$CPU_GOVERNORS" \
        --argjson cpu_frequency "$CPU_FREQUENCY" \
        --argjson block_devices "$BLOCK_DEVICES" \
        --argjson gpu_devices "$GPU_DEVICES" \
        --argjson dri_devices "$DRI_DEVICES" \
        '
        def optional_string:
            if . == "" then null else . end;
        def optional_number:
            if . == "" then null else (try tonumber catch null) end;

        ($mem_total_kb | optional_number) as $mem_total_kb_num
        | ($mem_available_kb | optional_number) as $mem_available_kb_num
        | {
            collected_at_utc: (now | strftime("%Y-%m-%dT%H:%M:%SZ")),
            os: {
                pretty_name: ($os_pretty_name | optional_string),
                kernel: ($kernel | optional_string)
            },
            system: {
                product_name: ($product_name | optional_string),
                product_version: ($product_version | optional_string),
                board_vendor: ($board_vendor | optional_string),
                board_name: ($board_name | optional_string),
                board_version: ($board_version | optional_string),
                bios_vendor: ($bios_vendor | optional_string),
                bios_version: ($bios_version | optional_string),
                bios_date: ($bios_date | optional_string)
            },
            cpu: {
                model: ($cpu_model | optional_string),
                vendor: ($cpu_vendor | optional_string),
                architecture: ($cpu_arch | optional_string),
                logical_cpus: ($logical_cpus | optional_number),
                sockets: ($cpu_sockets | optional_number),
                cores_per_socket: ($cpu_cores_per_socket | optional_number),
                threads_per_core: ($cpu_threads_per_core | optional_number),
                max_mhz: ($cpu_max_mhz | optional_number),
                min_mhz: ($cpu_min_mhz | optional_number),
                governors: $cpu_governors,
                current_frequency: $cpu_frequency
            },
            memory: {
                total_kb: $mem_total_kb_num,
                available_kb: $mem_available_kb_num,
                total_gb: (if $mem_total_kb_num == null then null else ($mem_total_kb_num / 1024 / 1024) end)
            },
            storage: $block_devices.blockdevices,
            gpu: {
                devices: $gpu_devices,
                dri_nodes: $dri_devices
            }
        }
    '
}

is_cpu_thermal_label() {
    CPU_THERMAL_LABEL="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"

    case "$CPU_THERMAL_LABEL" in
        *cpu*|*x86*|*pkg*|*package*|*coretemp*|*k10temp*|*zenpower*|*tctl*|*tdie*|*acpitz*|*soc*|*bcm2835*|*arm*thermal*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

is_temperature_value() {
    case "$1" in
        ''|*[!0-9.-]*)
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

read_cpu_thermal_rows() {
    for THERMAL_ZONE in /sys/class/thermal/thermal_zone*; do
        [ -r "$THERMAL_ZONE/temp" ] || continue

        THERMAL_ZONE_TYPE="$(cat "$THERMAL_ZONE/type" 2>/dev/null || basename "$THERMAL_ZONE")"
        is_cpu_thermal_label "$THERMAL_ZONE_TYPE" || continue

        THERMAL_TEMP="$(cat "$THERMAL_ZONE/temp" 2>/dev/null || true)"
        is_temperature_value "$THERMAL_TEMP" || continue

        printf 'thermal_zone\t%s\t%s\t%s\n' "$THERMAL_ZONE_TYPE" "$THERMAL_ZONE/temp" "$THERMAL_TEMP"
    done

    for HWMON in /sys/class/hwmon/hwmon*; do
        [ -d "$HWMON" ] || continue

        HWMON_NAME="$(cat "$HWMON/name" 2>/dev/null || basename "$HWMON")"

        for HWMON_INPUT in "$HWMON"/temp*_input; do
            [ -r "$HWMON_INPUT" ] || continue

            HWMON_TEMP_ID="$(basename "$HWMON_INPUT")"
            HWMON_TEMP_ID="${HWMON_TEMP_ID#temp}"
            HWMON_TEMP_ID="${HWMON_TEMP_ID%_input}"
            HWMON_LABEL_PATH="$HWMON/temp${HWMON_TEMP_ID}_label"

            if [ -r "$HWMON_LABEL_PATH" ]; then
                HWMON_LABEL="$(cat "$HWMON_LABEL_PATH" 2>/dev/null || printf 'temp%s' "$HWMON_TEMP_ID")"
            else
                HWMON_LABEL="temp${HWMON_TEMP_ID}"
            fi

            is_cpu_thermal_label "$HWMON_NAME $HWMON_LABEL" || continue

            THERMAL_TEMP="$(cat "$HWMON_INPUT" 2>/dev/null || true)"
            is_temperature_value "$THERMAL_TEMP" || continue

            printf 'hwmon\t%s: %s\t%s\t%s\n' "$HWMON_NAME" "$HWMON_LABEL" "$HWMON_INPUT" "$THERMAL_TEMP"
        done
    done
}

cpu_thermal_snapshot_json() {
    THERMAL_SAMPLED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

    read_cpu_thermal_rows | jq -R -s --arg sampled_at "$THERMAL_SAMPLED_AT" '
        def temp_c:
            tonumber
            | if . > 1000 or . < -1000 then . / 1000 else . end;

        (split("\n")
            | map(select(length > 0))
            | map(split("\t"))
            | map(select(length == 4))
            | map({
                source: .[0],
                label: .[1],
                path: .[2],
                temp_c: (.[3] | temp_c)
            })) as $sensors
        | {
            sampled_at_utc: $sampled_at,
            available: (($sensors | length) > 0),
            max_c: (if ($sensors | length) > 0 then ($sensors | map(.temp_c) | max) else null end),
            avg_c: (if ($sensors | length) > 0 then (($sensors | map(.temp_c) | add) / ($sensors | length)) else null end),
            sensors: $sensors
        }
    '
}

start_cpu_thermal_sampler() {
    THERMAL_SAMPLES_FILE="$1"
    : > "$THERMAL_SAMPLES_FILE"

    (
        while :; do
            THERMAL_SAMPLED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

            read_cpu_thermal_rows | while IFS="$(printf '\t')" read -r THERMAL_SOURCE THERMAL_LABEL THERMAL_PATH THERMAL_TEMP; do
                printf '%s\t%s\t%s\t%s\t%s\n' \
                    "$THERMAL_SAMPLED_AT" \
                    "$THERMAL_SOURCE" \
                    "$THERMAL_LABEL" \
                    "$THERMAL_PATH" \
                    "$THERMAL_TEMP"
            done >> "$THERMAL_SAMPLES_FILE"

            sleep "$THERMAL_SAMPLE_INTERVAL"
        done
    ) &

    THERMAL_SAMPLER_PID="$!"
}

stop_cpu_thermal_sampler() {
    THERMAL_SAMPLER_PID_TO_STOP="$1"

    kill "$THERMAL_SAMPLER_PID_TO_STOP" 2>/dev/null || true
    wait "$THERMAL_SAMPLER_PID_TO_STOP" 2>/dev/null || true
}

cpu_thermal_samples_json() {
    THERMAL_SAMPLES_FILE="$1"

    jq -R -s '
        def temp_c:
            tonumber
            | if . > 1000 or . < -1000 then . / 1000 else . end;

        (split("\n")
            | map(select(length > 0))
            | map(split("\t"))
            | map(select(length == 5))
            | map({
                sampled_at_utc: .[0],
                source: .[1],
                label: .[2],
                path: .[3],
                temp_c: (.[4] | temp_c)
            })) as $samples
        | ($samples
            | group_by(.source + "\t" + .label + "\t" + .path)
            | map({
                source: .[0].source,
                label: .[0].label,
                path: .[0].path,
                sample_count: length,
                min_c: (map(.temp_c) | min),
                max_c: (map(.temp_c) | max),
                avg_c: ((map(.temp_c) | add) / length)
            })) as $sensors
        | {
            available: (($samples | length) > 0),
            sample_count: ($samples | length),
            started_at_utc: (if ($samples | length) > 0 then $samples[0].sampled_at_utc else null end),
            ended_at_utc: (if ($samples | length) > 0 then $samples[-1].sampled_at_utc else null end),
            min_c: (if ($samples | length) > 0 then ($samples | map(.temp_c) | min) else null end),
            max_c: (if ($samples | length) > 0 then ($samples | map(.temp_c) | max) else null end),
            avg_c: (if ($samples | length) > 0 then (($samples | map(.temp_c) | add) / ($samples | length)) else null end),
            sensors: $sensors
        }
    ' "$THERMAL_SAMPLES_FILE"
}

cpu_thermal_stabilization_json() {
    THERMAL_STABILIZATION_FILE="$1"
    THERMAL_STABILIZATION_CONTEXT="$2"
    THERMAL_STABILIZATION_STARTED_AT="$3"
    THERMAL_STABILIZATION_ENDED_AT="$4"
    THERMAL_STABILIZATION_REASON="$5"

    jq -R -s \
        --arg context "$THERMAL_STABILIZATION_CONTEXT" \
        --arg started_at "$THERMAL_STABILIZATION_STARTED_AT" \
        --arg ended_at "$THERMAL_STABILIZATION_ENDED_AT" \
        --arg reason "$THERMAL_STABILIZATION_REASON" \
        --arg poll_interval "$THERMAL_STABLE_POLL_INTERVAL" \
        --arg required_samples "$THERMAL_STABLE_SAMPLES" \
        --arg stable_delta "$THERMAL_STABLE_DELTA_C" \
        --arg max_limit "$THERMAL_STABLE_MAX_C" \
        '
        def maybe_number:
            if . == "" then null else tonumber end;

        (split("\n")
            | map(select(length > 0))
            | map(split("\t"))
            | map(select(length == 2))
            | map({
                sampled_at_utc: .[0],
                max_c: (.[1] | tonumber)
            })) as $samples
        | ($required_samples | tonumber) as $required_samples_num
        | ($stable_delta | tonumber) as $stable_delta_num
        | ($max_limit | maybe_number) as $max_limit_num
        | ($samples[-$required_samples_num:] // []) as $window
        | {
            enabled: true,
            context: $context,
            stable: ($reason == "stable"),
            timed_out: ($reason == "timeout"),
            reason: $reason,
            started_at_utc: $started_at,
            ended_at_utc: $ended_at,
            waited_seconds: (($ended_at | fromdateiso8601) - ($started_at | fromdateiso8601)),
            poll_interval_seconds: ($poll_interval | tonumber),
            required_samples: $required_samples_num,
            stable_delta_c: $stable_delta_num,
            max_limit_c: $max_limit_num,
            sample_count: ($samples | length),
            initial_max_c: (if ($samples | length) > 0 then $samples[0].max_c else null end),
            final_max_c: (if ($samples | length) > 0 then $samples[-1].max_c else null end),
            window_min_c: (if ($window | length) > 0 then ($window | map(.max_c) | min) else null end),
            window_max_c: (if ($window | length) > 0 then ($window | map(.max_c) | max) else null end),
            window_delta_c: (if ($window | length) > 0 then (($window | map(.max_c) | max) - ($window | map(.max_c) | min)) else null end),
            samples: $samples
        }
    ' "$THERMAL_STABILIZATION_FILE"
}

wait_for_cpu_thermal_stabilization() {
    THERMAL_STABILIZATION_CONTEXT="$1"
    THERMAL_STABILIZATION_STARTED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    THERMAL_STABILIZATION_STARTED_EPOCH="$(date -u +"%s")"
    THERMAL_STABILIZATION_FILE="$OUT_DIR/tmp-thermal-stabilization.tsv"
    : > "$THERMAL_STABILIZATION_FILE"

    if [ "$THERMAL_STABILIZE" != "1" ]; then
        THERMAL_STABILIZATION_ENDED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
        jq -n \
            --arg context "$THERMAL_STABILIZATION_CONTEXT" \
            --arg started_at "$THERMAL_STABILIZATION_STARTED_AT" \
            --arg ended_at "$THERMAL_STABILIZATION_ENDED_AT" \
            '{
                enabled: false,
                context: $context,
                stable: false,
                timed_out: false,
                reason: "disabled",
                started_at_utc: $started_at,
                ended_at_utc: $ended_at,
                waited_seconds: 0,
                samples: []
            }'
        return
    fi

    echo "[+] Waiting for CPU temps to stabilise before $THERMAL_STABILIZATION_CONTEXT..." >&2

    while :; do
        THERMAL_SNAPSHOT="$(cpu_thermal_snapshot_json)"
        THERMAL_AVAILABLE="$(printf '%s' "$THERMAL_SNAPSHOT" | jq -r '.available')"
        THERMAL_NOW_AT="$(printf '%s' "$THERMAL_SNAPSHOT" | jq -r '.sampled_at_utc')"

        if [ "$THERMAL_AVAILABLE" != "true" ]; then
            echo "[!] No CPU thermal sensors found; continuing without stabilization wait." >&2
            THERMAL_STABILIZATION_ENDED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
            cpu_thermal_stabilization_json \
                "$THERMAL_STABILIZATION_FILE" \
                "$THERMAL_STABILIZATION_CONTEXT" \
                "$THERMAL_STABILIZATION_STARTED_AT" \
                "$THERMAL_STABILIZATION_ENDED_AT" \
                "no_cpu_thermal_sensors"
            return
        fi

        THERMAL_MAX_C="$(printf '%s' "$THERMAL_SNAPSHOT" | jq -r '.max_c')"
        printf '%s\t%s\n' "$THERMAL_NOW_AT" "$THERMAL_MAX_C" >> "$THERMAL_STABILIZATION_FILE"

        THERMAL_STABLE_STATUS="$(tail -n "$THERMAL_STABLE_SAMPLES" "$THERMAL_STABILIZATION_FILE" | jq -R -s \
            --arg required_samples "$THERMAL_STABLE_SAMPLES" \
            --arg stable_delta "$THERMAL_STABLE_DELTA_C" \
            --arg max_limit "$THERMAL_STABLE_MAX_C" \
            '
            def maybe_number:
                if . == "" then null else tonumber end;

            (split("\n")
                | map(select(length > 0))
                | map(split("\t"))
                | map(select(length == 2))
                | map({
                    sampled_at_utc: .[0],
                    max_c: (.[1] | tonumber)
                })) as $window
            | ($required_samples | tonumber) as $required_samples_num
            | ($stable_delta | tonumber) as $stable_delta_num
            | ($max_limit | maybe_number) as $max_limit_num
            | ($window | map(.max_c)) as $temps
            | {
                window_count: ($window | length),
                latest_max_c: (if ($window | length) > 0 then $window[-1].max_c else null end),
                window_delta_c: (if ($window | length) > 0 then (($temps | max) - ($temps | min)) else null end),
                stable: (
                    ($window | length) >= $required_samples_num
                    and ((($temps | max) - ($temps | min)) <= $stable_delta_num)
                    and ($max_limit_num == null or $window[-1].max_c <= $max_limit_num)
                )
            }
        ')"

        if [ "$(printf '%s' "$THERMAL_STABLE_STATUS" | jq -r '.stable')" = "true" ]; then
            THERMAL_STABILIZATION_ENDED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
            echo "[+] CPU temps stabilised at $(printf '%s' "$THERMAL_STABLE_STATUS" | jq -r '.latest_max_c') C before $THERMAL_STABILIZATION_CONTEXT." >&2
            cpu_thermal_stabilization_json \
                "$THERMAL_STABILIZATION_FILE" \
                "$THERMAL_STABILIZATION_CONTEXT" \
                "$THERMAL_STABILIZATION_STARTED_AT" \
                "$THERMAL_STABILIZATION_ENDED_AT" \
                "stable"
            return
        fi

        THERMAL_NOW_EPOCH="$(date -u +"%s")"
        if [ "$((THERMAL_NOW_EPOCH - THERMAL_STABILIZATION_STARTED_EPOCH))" -ge "$THERMAL_STABLE_TIMEOUT" ]; then
            THERMAL_STABILIZATION_ENDED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
            echo "[!] CPU temps did not stabilise within ${THERMAL_STABLE_TIMEOUT}s; continuing." >&2
            cpu_thermal_stabilization_json \
                "$THERMAL_STABILIZATION_FILE" \
                "$THERMAL_STABILIZATION_CONTEXT" \
                "$THERMAL_STABILIZATION_STARTED_AT" \
                "$THERMAL_STABILIZATION_ENDED_AT" \
                "timeout"
            return
        fi

        sleep "$THERMAL_STABLE_POLL_INTERVAL"
    done
}

capture_system_info() {
    echo "[+] Capturing system info..."

    {
        echo "=== DATE UTC ==="
        date -u

        echo ""
        echo "=== HOSTNAME ==="
        hostname || true

        echo ""
        echo "=== OS ==="
        cat /etc/os-release || true

        echo ""
        echo "=== KERNEL ==="
        uname -a || true

        echo ""
        echo "=== CPU ==="
        lscpu || true

        echo ""
        echo "=== MEMORY ==="
        free -h || true

        echo ""
        echo "=== DISK ==="
        df -h || true

        echo ""
        echo "=== LOAD ==="
        uptime || true

        echo ""
        echo "=== HARDWARE METADATA JSON ==="
        hardware_metadata_json || true

        echo ""
        echo "=== TEST METADATA ==="
        test_metadata_json || true

        echo ""
        echo "=== CPU THERMAL SNAPSHOT ==="
        cpu_thermal_snapshot_json || true

        echo ""
        echo "=== CPU FREQUENCY GOVERNOR ==="
        for CPU_GOVERNOR in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
            [ -r "$CPU_GOVERNOR" ] || continue
            printf '%s: ' "$CPU_GOVERNOR"
            cat "$CPU_GOVERNOR" || true
        done

        echo ""
        echo "=== CPU CURRENT FREQUENCY KHZ ==="
        for CPU_FREQ in /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq; do
            [ -r "$CPU_FREQ" ] || continue
            printf '%s: ' "$CPU_FREQ"
            cat "$CPU_FREQ" || true
        done

        echo ""
        echo "=== CONTAINER CGROUP LIMITS ==="
        echo "CPU quota:"
        cat /sys/fs/cgroup/cpu.max 2>/dev/null || true

        echo ""
        echo "Memory max:"
        cat /sys/fs/cgroup/memory.max 2>/dev/null || true

        echo ""
        echo "=== GPU / DISPLAY DEVICES (lspci) ==="
        if command -v lspci >/dev/null 2>&1; then
            lspci -nn 2>/dev/null | grep -iE 'vga|3d|display' || echo "(no VGA/3D/Display devices found)"
        else
            echo "(lspci not installed)"
        fi

        echo ""
        echo "=== /dev/dri ==="
        ls -la /dev/dri 2>/dev/null || echo "(no /dev/dri exposed)"

        echo ""
        echo "=== VULKAN DEVICES (vulkaninfo --summary) ==="
        if command -v vulkaninfo >/dev/null 2>&1; then
            vulkaninfo --summary 2>&1 | head -80 || true
        else
            echo "(vulkaninfo not installed)"
        fi

        echo ""
        echo "=== INTEL GPU INFO (intel_gpu_top -L) ==="
        if command -v intel_gpu_top >/dev/null 2>&1; then
            intel_gpu_top -L 2>&1 || true
        else
            echo "(intel_gpu_top not installed)"
        fi

        echo ""
        echo "=== MEMORY DETAIL (dmidecode --type 17) ==="
        if command -v dmidecode >/dev/null 2>&1; then
            dmidecode --type 17 2>/dev/null | head -200 || echo "(dmidecode requires root and /dev/mem)"
        else
            echo "(dmidecode not installed)"
        fi

        echo ""
        echo "=== CURRENT PROCESSES TOP ==="
        ps aux --sort=-%cpu | head -20 || true
    } > "$OUT_DIR/system-info.txt"
}

# ------------------------------------------------------------
# Build llama.cpp if needed
# ------------------------------------------------------------

build_llama_cpp() {
    if [ ! -d "$LLAMA_DIR/.git" ]; then
        echo "[+] Cloning llama.cpp into $LLAMA_DIR..."
        git clone https://github.com/ggml-org/llama.cpp "$LLAMA_DIR"
    else
        echo "[+] Updating llama.cpp..."
        cd "$LLAMA_DIR"
        git pull --ff-only || true
    fi

    echo "[+] Building llama.cpp..."
    cd "$LLAMA_DIR"

    CMAKE_EXTRA_FLAGS=""
    if [ "${ENABLE_VULKAN:-0}" = "1" ]; then
        CMAKE_EXTRA_FLAGS="-DGGML_VULKAN=ON"
    fi

    # shellcheck disable=SC2086
    cmake -B build \
        -DGGML_NATIVE=ON \
        -DGGML_AVX512=OFF \
        $CMAKE_EXTRA_FLAGS

    cmake --build build --config Release -j "$(nproc)"

    "$LLAMA_DIR/build/bin/llama-bench" --help >/dev/null

    git rev-parse HEAD > "$OUT_DIR/llama-cpp-commit.txt" || true
}

# ------------------------------------------------------------
# Optional model downloads
# Set DOWNLOAD_MODELS=1 to enable
# ------------------------------------------------------------

download_models() {
    if [ "${DOWNLOAD_MODELS:-0}" != "1" ]; then
        echo "[+] Skipping model download. Set DOWNLOAD_MODELS=1 to download defaults."
        return
    fi

    echo "[+] Downloading default GGUF models to $MODELS_DIR..."

    cd "$MODELS_DIR"

    download_if_missing() {
        FILE="$1"
        URL="$2"

        if [ -f "$FILE" ]; then
            echo "[+] Already exists: $FILE"
        else
            echo "[+] Downloading: $FILE"
            wget -O "$FILE" "$URL"
        fi
    }

    download_if_missing \
        "Llama-3.2-3B-Instruct-Q4_K_M.gguf" \
        "https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf"

    download_if_missing \
        "HuggingFaceTB_SmolLM3-3B-Q4_K_M.gguf" \
        "https://huggingface.co/bartowski/HuggingFaceTB_SmolLM3-3B-GGUF/resolve/main/HuggingFaceTB_SmolLM3-3B-Q4_K_M.gguf"

    download_if_missing \
        "google_gemma-3-4b-it-Q4_K_M.gguf" \
        "https://huggingface.co/bartowski/google_gemma-3-4b-it-GGUF/resolve/main/google_gemma-3-4b-it-Q4_K_M.gguf"

    download_if_missing \
        "google_gemma-4-E4B-it-Q4_K_M.gguf" \
        "https://huggingface.co/bartowski/google_gemma-4-E4B-it-GGUF/resolve/main/google_gemma-4-E4B-it-Q4_K_M.gguf"

    download_if_missing \
        "Qwen_Qwen3.5-4B-Q4_K_M.gguf" \
        "https://huggingface.co/bartowski/Qwen_Qwen3.5-4B-GGUF/resolve/main/Qwen_Qwen3.5-4B-Q4_K_M.gguf"

    download_if_missing \
        "microsoft_Phi-4-mini-instruct-Q4_K_M.gguf" \
        "https://huggingface.co/bartowski/microsoft_Phi-4-mini-instruct-GGUF/resolve/main/microsoft_Phi-4-mini-instruct-Q4_K_M.gguf"

    download_if_missing \
        "mistralai_Ministral-3-3B-Instruct-2512-Q4_K_M.gguf" \
        "https://huggingface.co/bartowski/mistralai_Ministral-3-3B-Instruct-2512-GGUF/resolve/main/mistralai_Ministral-3-3B-Instruct-2512-Q4_K_M.gguf"

    download_if_missing \
        "ibm-granite_granite-3.3-8b-instruct-Q4_K_M.gguf" \
        "https://huggingface.co/bartowski/ibm-granite_granite-3.3-8b-instruct-GGUF/resolve/main/ibm-granite_granite-3.3-8b-instruct-Q4_K_M.gguf"
}

# ------------------------------------------------------------
# Run benchmarks
# ------------------------------------------------------------

run_llm_benchmarks() {
    BENCH_BIN="$LLAMA_DIR/build/bin/llama-bench"
    RAW_JSON="$OUT_DIR/llama-bench-results.json"
    JSONL="$OUT_DIR/llama-bench-results.jsonl"
    CSV="$OUT_DIR/llama-bench-summary.csv"
    TEST_METADATA="$(test_metadata_json)"
    HARDWARE_METADATA="$(hardware_metadata_json)"

    echo "[+] Running LLM benchmarks..."
    : > "$JSONL"

    MODEL_COUNT="$(find "$MODELS_DIR" -maxdepth 1 -name "*.gguf" | wc -l | tr -d ' ')"

    if [ "$MODEL_COUNT" = "0" ]; then
        echo "[!] No .gguf models found in $MODELS_DIR"
        echo "[!] Put models in /data/models or run with DOWNLOAD_MODELS=1"
        return
    fi

    for model in "$MODELS_DIR"/*.gguf; do
        for t in $THREADS; do
            for ngl in $NGL_VALUES; do
                if [ "$ngl" -eq 0 ]; then
                    BACKEND_LABEL="cpu"
                else
                    BACKEND_LABEL="gpu"
                fi
                RUN_LABEL="$(basename "$model") t=$t ngl=$ngl ($BACKEND_LABEL)"
                echo "[+] Benchmarking $RUN_LABEL..."

                THERMAL_STABILIZATION="$(wait_for_cpu_thermal_stabilization "$RUN_LABEL")"
                THERMAL_BEFORE="$(cpu_thermal_snapshot_json)"
                THERMAL_SAMPLES_FILE="$OUT_DIR/tmp-thermal-samples.tsv"
                start_cpu_thermal_sampler "$THERMAL_SAMPLES_FILE"
                BENCH_STATUS=0

                "$BENCH_BIN" \
                    -m "$model" \
                    -t "$t" \
                    -p "$PROMPT_TOKENS" \
                    -n "$GEN_TOKENS" \
                    -r "$REPETITIONS" \
                    -ngl "$ngl" \
                    -o json \
                    > "$OUT_DIR/tmp-result.json" || BENCH_STATUS="$?"

                stop_cpu_thermal_sampler "$THERMAL_SAMPLER_PID"
                THERMAL_DURING="$(cpu_thermal_samples_json "$THERMAL_SAMPLES_FILE")"
                THERMAL_AFTER="$(cpu_thermal_snapshot_json)"

                if [ "$BENCH_STATUS" -ne 0 ]; then
                    echo "[!] llama-bench failed for $RUN_LABEL"
                    if [ "$ngl" -eq 0 ]; then
                        # CPU run is the baseline. A failure here is fatal.
                        exit "$BENCH_STATUS"
                    else
                        # GPU run failed (no Vulkan device, OOM on iGPU,
                        # backend mismatch). Log and continue with the
                        # other configs so the run still produces data.
                        continue
                    fi
                fi

                jq -c \
                    --arg run_id "$RUN_ID" \
                    --arg model_file "$(basename "$model")" \
                    --arg threads "$t" \
                    --arg ngl "$ngl" \
                    --arg backend_label "$BACKEND_LABEL" \
                    --argjson test_metadata "$TEST_METADATA" \
                    --argjson hardware_metadata "$HARDWARE_METADATA" \
                    --argjson cpu_thermal_stabilization "$THERMAL_STABILIZATION" \
                    --argjson cpu_thermal_before "$THERMAL_BEFORE" \
                    --argjson cpu_thermal_during "$THERMAL_DURING" \
                    --argjson cpu_thermal_after "$THERMAL_AFTER" \
                    '.[] + {
                        run_id: $run_id,
                        model_file: $model_file,
                        threads_requested: ($threads | tonumber),
                        n_gpu_layers_requested: ($ngl | tonumber),
                        backend_label: $backend_label,
                        test_metadata: $test_metadata,
                        hardware_metadata: $hardware_metadata,
                        cpu_thermal_stabilization: $cpu_thermal_stabilization,
                        cpu_thermal_before: $cpu_thermal_before,
                        cpu_thermal_during: $cpu_thermal_during,
                        cpu_thermal_after: $cpu_thermal_after
                    }' \
                    "$OUT_DIR/tmp-result.json" >> "$JSONL"
            done
        done
    done

    jq -s '.' "$JSONL" > "$RAW_JSON"

    jq -r '
        [
            "run_id",
            "model_file",
            "threads",
            "n_gpu_layers",
            "backend_label",
            "type",
            "avg_ts",
            "stddev_ts",
            "test_device",
            "hardware_product",
            "cpu_model",
            "logical_cpus",
            "memory_total_gb",
            "gpu_description",
            "ambient_c",
            "cpu_tdp_w",
            "cpu_temp_before_max_c",
            "cpu_temp_during_max_c",
            "cpu_temp_after_max_c",
            "cpu_temp_during_avg_c",
            "cpu_temp_during_sample_count",
            "cpu_temp_stabilized",
            "cpu_temp_stabilization_timed_out",
            "cpu_temp_stabilization_waited_seconds",
            "cpu_temp_stabilization_final_max_c"
        ],
        (
            .[] |
            [
                .run_id,
                .model_file,
                .threads,
                (.n_gpu_layers // .n_gpu_layers_requested),
                .backend_label,
                .type,
                .avg_ts,
                .stddev_ts,
                .test_metadata.device,
                .hardware_metadata.system.product_name,
                .hardware_metadata.cpu.model,
                .hardware_metadata.cpu.logical_cpus,
                .hardware_metadata.memory.total_gb,
                ((.hardware_metadata.gpu.devices // []) | map(.description) | join("; ")),
                .test_metadata.ambient_c,
                .test_metadata.cpu_tdp_w,
                .cpu_thermal_before.max_c,
                .cpu_thermal_during.max_c,
                .cpu_thermal_after.max_c,
                .cpu_thermal_during.avg_c,
                .cpu_thermal_during.sample_count,
                .cpu_thermal_stabilization.stable,
                .cpu_thermal_stabilization.timed_out,
                .cpu_thermal_stabilization.waited_seconds,
                .cpu_thermal_stabilization.final_max_c
            ]
        )
        | @csv
    ' "$RAW_JSON" > "$CSV"

    rm -f "$OUT_DIR/tmp-result.json" "$OUT_DIR/tmp-thermal-samples.tsv" "$OUT_DIR/tmp-thermal-stabilization.tsv"

    echo "[+] LLM benchmark JSON: $RAW_JSON"
    echo "[+] LLM benchmark JSONL: $JSONL"
    echo "[+] LLM benchmark CSV: $CSV"
}

# ------------------------------------------------------------
# Simple CPU / disk benchmark fallback
# ------------------------------------------------------------

run_basic_benchmarks() {
    echo "[+] Running basic CPU and disk benchmarks..."

    BASIC_OUT="$OUT_DIR/basic-benchmarks.txt"

    {
        echo "=== CPU SHA256 BENCHMARK ==="
        time sh -c 'dd if=/dev/zero bs=1M count=1024 2>/dev/null | sha256sum >/dev/null'

        echo ""
        echo "=== DISK WRITE BENCHMARK ==="
        time dd if=/dev/zero of="$OUT_DIR/disk-test.bin" bs=1M count=1024 conv=fdatasync 2>&1

        echo ""
        echo "=== DISK READ BENCHMARK ==="
        time dd if="$OUT_DIR/disk-test.bin" of=/dev/null bs=1M 2>&1

        rm -f "$OUT_DIR/disk-test.bin"
    } > "$BASIC_OUT" 2>&1

    echo "[+] Basic benchmark output: $BASIC_OUT"
}

# ------------------------------------------------------------
# Preflight (smoke test) — verify the environment can run a full
# benchmark before doing anything expensive. Exits non-zero if any
# critical check fails.
#
# Set ALLOW_NO_THERMAL=1 to demote the thermal-sensor check from
# fail to warn (useful for ad-hoc test runs where you don't need
# real thermal data).
# ------------------------------------------------------------

preflight_checks() {
    echo "[+] Running preflight checks..."

    PREFLIGHT_FAILED=0
    PREFLIGHT_WARNINGS=0

    preflight_fail() {
        echo "[!] FAIL: $1"
        PREFLIGHT_FAILED=$((PREFLIGHT_FAILED + 1))
    }

    preflight_warn() {
        echo "[~] WARN: $1"
        PREFLIGHT_WARNINGS=$((PREFLIGHT_WARNINGS + 1))
    }

    # Shell: 'time' as a reserved word requires bash, not dash.
    if [ -z "${BASH_VERSION:-}" ]; then
        preflight_fail "Must run with bash (uses 'time' as a reserved word). Try: bash $0"
    fi

    # Writable output, models, and llama.cpp parent directories.
    if ! mkdir -p "$OUT_ROOT" 2>/dev/null || [ ! -w "$OUT_ROOT" ]; then
        preflight_fail "OUT_ROOT=$OUT_ROOT is not writable"
    fi
    if ! mkdir -p "$MODELS_DIR" 2>/dev/null || [ ! -w "$MODELS_DIR" ]; then
        preflight_fail "MODELS_DIR=$MODELS_DIR is not writable"
    fi
    LLAMA_PARENT="$(dirname "$LLAMA_DIR")"
    if ! mkdir -p "$LLAMA_PARENT" 2>/dev/null || [ ! -w "$LLAMA_PARENT" ]; then
        preflight_fail "LLAMA_DIR parent=$LLAMA_PARENT is not writable"
    fi

    # Disk space: rough lower bound to fit llama.cpp build + default models.
    REQUIRED_KB=20971520
    AVAILABLE_KB="$(df -k "$OUT_ROOT" 2>/dev/null | awk 'NR==2 {print $4}')"
    if [ -n "$AVAILABLE_KB" ] && [ "$AVAILABLE_KB" -lt "$REQUIRED_KB" ]; then
        AVAIL_GB=$((AVAILABLE_KB / 1048576))
        preflight_fail "Need >=20 GB free in $OUT_ROOT, only ${AVAIL_GB} GB available"
    fi

    # Network reach: huggingface.co (model downloads) or github.com (llama.cpp).
    NEED_NET=0
    [ "${DOWNLOAD_MODELS:-0}" = "1" ] && NEED_NET=1
    [ ! -d "$LLAMA_DIR/.git" ] && NEED_NET=1
    if [ "$NEED_NET" -eq 1 ]; then
        if ! wget -q --spider --timeout=10 https://huggingface.co 2>/dev/null \
           && ! wget -q --spider --timeout=10 https://github.com 2>/dev/null; then
            preflight_fail "Cannot reach huggingface.co or github.com (network down?)"
        fi
    fi

    # CPU thermal sensors visible: thermal_zone OR hwmon with CPU-ish label.
    THERMAL_FOUND=0
    for ZONE in /sys/class/thermal/thermal_zone*; do
        [ -r "$ZONE/temp" ] || continue
        TYPE="$(cat "$ZONE/type" 2>/dev/null || true)"
        if is_cpu_thermal_label "$TYPE"; then
            THERMAL_FOUND=1
            break
        fi
    done
    if [ "$THERMAL_FOUND" -eq 0 ]; then
        for HWM in /sys/class/hwmon/hwmon*; do
            [ -d "$HWM" ] || continue
            NAME="$(cat "$HWM/name" 2>/dev/null || true)"
            if is_cpu_thermal_label "$NAME"; then
                THERMAL_FOUND=1
                break
            fi
        done
    fi
    if [ "$THERMAL_FOUND" -eq 0 ]; then
        if [ "${ALLOW_NO_THERMAL:-0}" = "1" ]; then
            preflight_warn "No CPU thermal sensors visible; thermal data will be empty (ALLOW_NO_THERMAL=1 set, continuing)"
        else
            preflight_fail "No CPU thermal sensors visible at /sys/class/thermal or /sys/class/hwmon. Bind-mount /sys/class/thermal, /sys/class/hwmon, /sys/devices into the container; or set ALLOW_NO_THERMAL=1 to ignore."
        fi
    fi

    # GPU offload check: only when any non-zero NGL value is requested.
    GPU_WANTED=0
    for ngl in $NGL_VALUES; do
        if [ "$ngl" -ne 0 ] 2>/dev/null; then
            GPU_WANTED=1
            break
        fi
    done
    if [ "$GPU_WANTED" -eq 1 ]; then
        if [ ! -d /dev/dri ] || [ -z "$(ls -A /dev/dri 2>/dev/null)" ]; then
            if [ "${ALLOW_NO_GPU:-0}" = "1" ]; then
                preflight_warn "/dev/dri not visible; GPU offload runs will fail (ALLOW_NO_GPU=1 set, continuing with CPU-only data)"
            else
                preflight_fail "/dev/dri not visible. Expose the iGPU to the container (devices: /dev/dri:/dev/dri, group_add: video render) or set NGL_VALUES=0 to skip GPU runs, or set ALLOW_NO_GPU=1 to ignore."
            fi
        fi
    fi

    # Build deps: present OR installable via apt-get as root.
    NEED_APT=0
    for cmd in git cmake make gcc g++ wget; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            NEED_APT=1
            break
        fi
    done
    if [ "$NEED_APT" -eq 1 ]; then
        if ! command -v apt-get >/dev/null 2>&1; then
            preflight_fail "Missing build deps and apt-get unavailable. Install git, cmake, make, gcc, g++, wget manually."
        elif [ "$(id -u)" -ne 0 ]; then
            preflight_fail "Need root for apt-get install of missing build deps. Run as root or pre-install: git cmake make gcc g++ wget."
        fi
    fi

    if [ "$PREFLIGHT_FAILED" -gt 0 ]; then
        echo "[!] Preflight failed: $PREFLIGHT_FAILED error(s), $PREFLIGHT_WARNINGS warning(s). Aborting before benchmark."
        exit 1
    fi
    if [ "$PREFLIGHT_WARNINGS" -gt 0 ]; then
        echo "[+] Preflight passed with $PREFLIGHT_WARNINGS warning(s)"
    else
        echo "[+] Preflight passed"
    fi
}

# ------------------------------------------------------------
# Main
# ------------------------------------------------------------

main() {
    mkdir -p "$OUT_DIR" "$MODELS_DIR"
    echo "[+] Benchmark output directory: $OUT_DIR"
    echo "[+] Starting benchmark run: $RUN_ID"

    preflight_checks
    install_deps
    capture_system_info
    build_llama_cpp
    download_models
    run_basic_benchmarks
    run_llm_benchmarks

    echo "[+] Complete."
    echo "[+] Results saved to: $OUT_DIR"
}

# Allow sourcing for tests by skipping the main flow when BENCH_NOMAIN=1.
if [ "${BENCH_NOMAIN:-0}" != "1" ]; then
    main
fi
