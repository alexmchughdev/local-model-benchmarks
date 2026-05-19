#!/usr/bin/env bash
set -euo pipefail

DATA_ROOT="${DATA_ROOT:-/opt/k802-bench}"

if [ "$(id -u)" -ne 0 ]; then
    echo "Run with sudo: sudo DATA_ROOT=${DATA_ROOT} bash scripts/setup-ubuntu-k802.sh" >&2
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y \
    build-essential cmake git jq curl wget procps util-linux \
    pciutils lm-sensors msr-tools smartmontools nvme-cli python3 \
    openssh-server ca-certificates

modprobe coretemp 2>/dev/null || true
modprobe msr 2>/dev/null || true

install -d -m 0755 "$DATA_ROOT" "$DATA_ROOT/models" "$DATA_ROOT/benchmarks"

systemctl enable --now ssh >/dev/null 2>&1 || true

echo "[+] Ubuntu K802 benchmark host prepared."
echo "[+] DATA_ROOT=$DATA_ROOT"
echo "[+] Checking visible temperature sensors:"
find /sys/class/hwmon -maxdepth 2 -type f -name name -exec sh -c 'echo "$1: $(cat "$1")"' _ {} \; 2>/dev/null || true
find /sys/class/thermal -maxdepth 2 -type f -name type -exec sh -c 'echo "$1: $(cat "$1")"' _ {} \; 2>/dev/null || true
