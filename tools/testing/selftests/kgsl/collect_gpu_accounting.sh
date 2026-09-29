#!/system/bin/sh
# SPDX-License-Identifier: GPL-2.0
# Run as root after booting the test kernel. Uses its own trace instance.
set -eu
[ "$(id -u)" = 0 ] || { echo 'Run this script as root.' >&2; exit 1; }
out=${1:-/data/local/tmp/gpu-accounting}
mkdir -p "$out"
trace=/sys/kernel/tracing
[ -d "$trace/events" ] || trace=/sys/kernel/debug/tracing
cat "$trace/events/power/gpu_work_period/format" > "$out/format.txt"
instance="$trace/instances/gpu_accounting_$$"
mkdir "$instance"
cleanup() {
    echo 0 > "$instance/events/power/gpu_work_period/enable"
    rmdir "$instance"
}
trap cleanup EXIT
trap 'exit 130' INT TERM
echo 1 > "$instance/events/power/gpu_work_period/enable"
echo 'Scroll and switch between two apps for the next 15 seconds.'
sleep 15
cat "$instance/trace" > "$out/work-period.trace"
logcat -b all -d > "$out/logcat.txt"
dmesg > "$out/dmesg.txt"
dumpsys gpu > "$out/gpu.txt" 2>&1 || true
find /sys/fs/bpf -iname '*gpu*' > "$out/bpf-paths.txt"
uname -a > "$out/kernel.txt"
echo "Saved logs to $out"
