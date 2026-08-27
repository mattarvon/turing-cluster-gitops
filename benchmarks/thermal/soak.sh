#!/usr/bin/env bash
# Thermal soak: load every core and find out where sustained performance lands.
#
# The architecture notes claim thermal headroom, not CPU capacity, is the real
# ceiling on the ARM modules. This turns that claim into a measurement.
#
# What matters is the gap between burst and sustained throughput. That gap is
# the node's real capacity, and it is the number worth scheduling against.
#
#   ./soak.sh rk1-w1 30        # node, minutes
#
# Watch the "Temperature by node" panel on the Cluster Overview dashboard while
# it runs. Do NOT soak the control plane unless you mean to.
set -uo pipefail

NODE="${1:?usage: $0 <node> [minutes]}"
MINUTES="${2:-20}"
KEY="${SSH_KEY:-$HOME/.ssh/turing_ed25519}"
USER_AT="${SSH_USER:-ubuntu}@${NODE}"

echo "=================================================="
echo "thermal soak : $NODE for ${MINUTES} min"
echo "=================================================="

ssh -o BatchMode=yes -i "$KEY" "$USER_AT" bash -s -- "$MINUTES" <<'REMOTE'
set -uo pipefail
MINUTES="$1"
SECS=$(( MINUTES * 60 ))

command -v stress-ng >/dev/null 2>&1 || {
    echo "installing stress-ng ..."
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq stress-ng >/dev/null 2>&1
}

hottest() {
    # Highest reading across every thermal zone, in whole degrees C.
    cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null \
      | sort -n | tail -1 | awk '{printf "%.0f", $1/1000}'
}
maxfreq() {
    cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq 2>/dev/null \
      | sort -n | tail -1 | awk '{printf "%.0f", $1/1000}'
}

CORES=$(nproc)
echo "cores: $CORES"
echo "idle temp: $(hottest)C   clock: $(maxfreq) MHz"
echo

# Burst: short run before the heatsink saturates.
echo "--- burst (20s) ---"
BURST=$(stress-ng --cpu "$CORES" --cpu-method matrixprod --timeout 20s \
        --metrics-brief 2>&1 | awk '/cpu /{print $(NF-4)}' | tail -1)
echo "bogo-ops/s : ${BURST:-n/a}"
echo "temp       : $(hottest)C   clock: $(maxfreq) MHz"
echo

echo "--- sustained (${MINUTES} min) ---"
stress-ng --cpu "$CORES" --cpu-method matrixprod --timeout "${SECS}s" \
    --metrics-brief >/tmp/soak.out 2>&1 &
SPID=$!

printf '%8s  %6s  %9s\n' 'elapsed' 'temp C' 'MHz'
for (( t = 30; t <= SECS; t += 30 )); do
    sleep 30
    kill -0 $SPID 2>/dev/null || break
    printf '%7ss  %6s  %9s\n' "$t" "$(hottest)" "$(maxfreq)"
done
wait $SPID 2>/dev/null

SUS=$(awk '/cpu /{print $(NF-4)}' /tmp/soak.out | tail -1)
echo
echo "--- result ---"
echo "burst     bogo-ops/s : ${BURST:-n/a}"
echo "sustained bogo-ops/s : ${SUS:-n/a}"
if [ -n "${BURST:-}" ] && [ -n "${SUS:-}" ]; then
    awk -v b="$BURST" -v s="$SUS" 'BEGIN{
        if (b > 0) printf "throttling           : %.1f%% of burst retained\n", (s/b)*100
    }'
fi
echo "peak temp            : $(hottest)C"
echo
echo "Cooling for 60s ..."
sleep 60
echo "recovered temp       : $(hottest)C   clock: $(maxfreq) MHz"
REMOTE
