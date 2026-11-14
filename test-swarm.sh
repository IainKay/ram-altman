#!/usr/bin/env bash
# Tests for ram-altman-swarm.sh using a fake meminfo and temp files.
set -euo pipefail
cd "$(dirname "$0")"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

idle_meminfo() {
  cat > "$TMP/meminfo" <<'EOF'
MemTotal:        1048576 kB
MemAvailable:     614400 kB
EOF
}

idle_meminfo
export RAM_SWARM_MEMINFO="$TMP/meminfo"
export RAM_SWARM_HOLD_DIR="$TMP/hold"
export RAM_SWARM_LOG="$TMP/swarm.log"
export RAM_SWARM_STATE="$TMP/state"
export RAM_SWARM_HOLD_SECONDS=2

# 1. Dry run: prints the plan with the right numbers, writes nothing.
out="$(RAM_SWARM_DRY_RUN=1 ./ram-altman-swarm.sh)"
echo "$out" | grep -q "RAM SWARM HOLD" || { echo "FAIL: no plan header"; exit 1; }
echo "$out" | grep -q "0.3 GiB" || { echo "FAIL: expected 0.3 GiB hold"; exit 1; }
echo "$out" | grep -q "30 minutes" || { echo "FAIL: expected 30 min window"; exit 1; }
[ ! -e "$TMP/hold" ] || { echo "FAIL: dry run created hold dir"; exit 1; }

# 2. Real run: hold file created with the right size, log and state written.
./ram-altman-swarm.sh > /dev/null
[ -f "$TMP/hold/hold.bin" ] || { echo "FAIL: hold file missing"; exit 1; }
size_mb=$(( $(stat -c %s "$TMP/hold/hold.bin") / 1024 / 1024 ))
[ "$size_mb" -ge 290 ] && [ "$size_mb" -le 310 ] || { echo "FAIL: hold size $size_mb MB"; exit 1; }
grep -q "HOLD START" "$TMP/swarm.log" || { echo "FAIL: no HOLD START log"; exit 1; }
[ -f "$TMP/state" ] || { echo "FAIL: state file missing"; exit 1; }

# 3. Second run the same day: no second hold; the first hold releases on time.
./ram-altman-swarm.sh > /dev/null
sleep 3
[ ! -e "$TMP/hold/hold.bin" ] || { echo "FAIL: hold not released"; exit 1; }
grep -q "HOLD END" "$TMP/swarm.log" || { echo "FAIL: no HOLD END log"; exit 1; }

# 4. Busy RAM (5% free): no hold.
cat > "$TMP/meminfo" <<'EOF'
MemTotal:        1048576 kB
MemAvailable:      52428 kB
EOF
rm -f "$TMP/state"
./ram-altman-swarm.sh > /dev/null
[ ! -e "$TMP/hold/hold.bin" ] || { echo "FAIL: held when RAM was busy"; exit 1; }

# 5. Diffusion cap: DEVICES=100, BASE=30 -> capped at 240 min.
idle_meminfo
out="$(RAM_SWARM_DRY_RUN=1 RAM_SWARM_DEVICES=100 RAM_SWARM_BASE_MINUTES=30 ./ram-altman-swarm.sh)"
echo "$out" | grep -q "240 minutes" || { echo "FAIL: expected 240 min cap, got: $out"; exit 1; }

echo "All swarm tests passed."
