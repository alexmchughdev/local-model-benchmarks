#!/bin/bash
# Unit tests for benchmark.sh plus a wrapper around preflight_checks
# that can be used as a standalone smoke test.
#
# Usage:
#   bash test.sh              # run all unit tests + preflight tests
#   bash test.sh smoke        # run preflight only against current env
#                             # (exits non-zero if env is not benchmark-ready)
#
# Tests run in subshells so set -eu from benchmark.sh does not leak.

HERE="$(cd "$(dirname "$0")" && pwd)"
BENCH="$HERE/benchmark.sh"
TMP_ROOT="${TMP_ROOT:-/tmp/bench-test}"

PASS=0
FAIL=0
FAILED_NAMES=""

# Source benchmark.sh inside a subshell, then drop strictness so test
# bodies can use assertions without aborting on the first non-zero rc.
load_bench() {
    export BENCH_NOMAIN=1
    # Use :- so callers can override these before invoking load_bench.
    export OUT_ROOT="${OUT_ROOT:-$TMP_ROOT/benchmarks}"
    export MODELS_DIR="${MODELS_DIR:-$TMP_ROOT/models}"
    export LLAMA_DIR="${LLAMA_DIR:-$TMP_ROOT/llama.cpp}"
    # shellcheck disable=SC1090
    . "$BENCH"
    set +e
    set +u
}

# Run a test body in a subshell. Body should return 0 on pass.
run_test() {
    name="$1"
    body="$2"
    output=$(
        load_bench
        $body
    ) 2>&1
    rc=$?
    if [ "$rc" -eq 0 ]; then
        printf "  PASS: %s\n" "$name"
        PASS=$((PASS + 1))
    else
        printf "  FAIL: %s (rc=%d)\n" "$name" "$rc"
        [ -n "$output" ] && printf "    %s\n" "$output"
        FAIL=$((FAIL + 1))
        FAILED_NAMES="$FAILED_NAMES\n  - $name"
    fi
}

# Run preflight in a subshell with the given env overrides prepended.
# Args: <name> <expected: pass|fail> <env assignments...>
run_preflight() {
    name="$1"
    expect="$2"
    shift 2
    output=$(
        # shellcheck disable=SC2086
        export "$@" 2>/dev/null || true
        for kv in "$@"; do
            key="${kv%%=*}"
            val="${kv#*=}"
            export "$key=$val"
        done
        load_bench
        preflight_checks
    ) 2>&1
    rc=$?
    if { [ "$expect" = "pass" ] && [ "$rc" -eq 0 ]; } \
       || { [ "$expect" = "fail" ] && [ "$rc" -ne 0 ]; }; then
        printf "  PASS: %s\n" "$name"
        PASS=$((PASS + 1))
    else
        printf "  FAIL: %s (rc=%d, expected %s)\n" "$name" "$rc" "$expect"
        printf "%s\n" "$output" | tail -5 | sed 's/^/    /'
        FAIL=$((FAIL + 1))
        FAILED_NAMES="$FAILED_NAMES\n  - $name"
    fi
}

# ---- Pure-function unit tests ----

test_thermal_label_positive() {
    is_cpu_thermal_label "coretemp" || return 1
    is_cpu_thermal_label "x86_pkg_temp" || return 2
    is_cpu_thermal_label "CPU thermal" || return 3
    is_cpu_thermal_label "acpitz" || return 4
    is_cpu_thermal_label "k10temp" || return 5
    is_cpu_thermal_label "Package" || return 6
}

test_thermal_label_negative() {
    if is_cpu_thermal_label "nvme"; then return 1; fi
    if is_cpu_thermal_label "amdgpu"; then return 2; fi
    if is_cpu_thermal_label "wifi"; then return 3; fi
    if is_cpu_thermal_label "battery"; then return 4; fi
    if is_cpu_thermal_label ""; then return 5; fi
    return 0
}

test_temperature_value_valid() {
    is_temperature_value "55000" || return 1
    is_temperature_value "27.8" || return 2
    is_temperature_value "0" || return 3
    is_temperature_value "-1" || return 4
}

test_temperature_value_invalid() {
    if is_temperature_value ""; then return 1; fi
    if is_temperature_value "hot"; then return 2; fi
    if is_temperature_value "55C"; then return 3; fi
    if is_temperature_value "n/a"; then return 4; fi
    return 0
}

test_read_first_existing_file() {
    t1=$(mktemp) || return 9
    echo "hello" > "$t1"
    got=$(read_first_existing_file /does/not/exist "$t1")
    [ "$got" = "hello" ] || { rm -f "$t1"; return 1; }
    got=$(read_first_existing_file /does/not/exist /also/no)
    [ -z "$got" ] || { rm -f "$t1"; return 2; }
    rm -f "$t1"
}

test_snapshot_json_is_object() {
    out=$(cpu_thermal_snapshot_json 2>/dev/null)
    [ -n "$out" ] || return 1
    printf '%s' "$out" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); assert isinstance(d, dict)" >/dev/null 2>&1 || return 2
}

# ---- Smoke test mode: just run preflight against current env ----

if [ "${1:-}" = "smoke" ]; then
    export BENCH_NOMAIN=1
    # shellcheck disable=SC1090
    . "$BENCH"
    preflight_checks
    exit $?
fi

# ---- Run everything ----

rm -rf "$TMP_ROOT"
mkdir -p "$TMP_ROOT/benchmarks" "$TMP_ROOT/models" "$TMP_ROOT/llama.cpp/.git" "$TMP_ROOT/bin"
# Stub out build deps so the "pass" preflight test is hermetic on dev
# machines that don't have cmake/wget/etc. installed.
for c in git cmake make gcc g++ wget; do
    printf '%s\n%s\n' '#!/bin/sh' 'exit 0' > "$TMP_ROOT/bin/$c"
    chmod +x "$TMP_ROOT/bin/$c"
done
export PATH="$TMP_ROOT/bin:$PATH"

echo "Unit tests:"
run_test "is_cpu_thermal_label: accepts CPU labels"      test_thermal_label_positive
run_test "is_cpu_thermal_label: rejects non-CPU labels"  test_thermal_label_negative
run_test "is_temperature_value: accepts valid numbers"   test_temperature_value_valid
run_test "is_temperature_value: rejects invalid input"   test_temperature_value_invalid
run_test "read_first_existing_file: returns first found" test_read_first_existing_file
run_test "cpu_thermal_snapshot_json: returns JSON object" test_snapshot_json_is_object

echo
echo "Preflight tests:"
# Defaults: ALLOW_NO_THERMAL=1 so dev machines without /sys/class/thermal
# (Macs, restricted containers) don't fail every test.
run_preflight "preflight passes on writable tmp + ALLOW_NO_THERMAL" pass ALLOW_NO_THERMAL=1
run_preflight "preflight fails on unwritable OUT_ROOT"              fail ALLOW_NO_THERMAL=1 OUT_ROOT=/proc/forbidden/out

echo
echo "============================="
printf "  Total: %d passed, %d failed\n" "$PASS" "$FAIL"
echo "============================="
if [ "$FAIL" -gt 0 ]; then
    printf "%b\n" "$FAILED_NAMES"
    exit 1
fi
