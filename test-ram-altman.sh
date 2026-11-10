#!/usr/bin/env bash
# Exercises ram-altman.sh with simulated memory and a fake sendmail.
set -uo pipefail

script="$(cd "$(dirname "$0")" && pwd)/ram-altman.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/state" "$work/drm" "$work/drivers/amdgpu"

cat > "$work/bin/sendmail" <<EOF
#!/usr/bin/env bash
[[ -e "$work/fail" ]] && exit 75
cat >> "$work/outbox"
echo "=====END=====" >> "$work/outbox"
EOF
chmod +x "$work/bin/sendmail"

# Never probe a real NVIDIA device, even when nvidia-smi is installed.
cat > "$work/bin/nvidia-smi" <<'EOF'
#!/usr/bin/env bash
[[ -f "$RAM_ALTMAN_TEST_NVIDIA_OUTPUT" ]] || exit 1
cat "$RAM_ALTMAN_TEST_NVIDIA_OUTPUT"
EOF
chmod +x "$work/bin/nvidia-smi"

export PATH="$work/bin:$PATH"
export RAM_ALTMAN_TO=to@example.com RAM_ALTMAN_FROM=from@example.com
export RAM_ALTMAN_STATE_DIR="$work/state" RAM_ALTMAN_MEMINFO="$work/meminfo"
export RAM_ALTMAN_DRM_DIR="$work/drm"
export RAM_ALTMAN_TEST_NVIDIA_OUTPUT="$work/nvidia-output"

pass=0; fail=0
check() {
    if [[ "$2" == "$3" ]]; then pass=$((pass+1)); echo "ok    $1"
    else fail=$((fail+1)); echo "FAIL  $1 (expected '$3', got '$2')"; fi
}
sent() { grep -c '^=====END=====$' "$work/outbox" 2>/dev/null || true; }
mem() { # total free available buffers cached slab shmem
    cat > "$work/meminfo" <<EOF
MemTotal:       $1 kB
MemFree:        $2 kB
${3:+MemAvailable:   $3 kB}
Buffers:        $4 kB
Cached:         $5 kB
SwapCached:     999999 kB
SReclaimable:   $6 kB
Shmem:          $7 kB
EOF
}

# Extract the first value for a stable status field, regardless of indentation.
field() {
    awk -v key="$1" 'index($0, key) {
        line = substr($0, index($0, key) + length(key))
        sub(/^[[:space:]]+/, "", line); print line; exit
    }' <<<"$2"
}

# Require the RAM amount and VRAM amount in the same sentence or Available row,
# not merely somewhere in the message or in two independent paragraphs.
inline_vram() {
    awk -v ram="$2" -v vram="$3 of unused VRAM" '
        BEGIN { RS = ""; found = 0 }
        {
            r = index($0, ram); v = index($0, vram)
            if (r && v && v > r && substr($0, r + length(ram), v - r - length(ram)) !~ /[.!?][[:space:]]/)
                found = 1
        }
        END { print found }
    ' <<<"$1"
}

# The email must stay plain text and omit the detailed status/hardware report.
concise_email() {
    if grep -qi '^Content-Type: text/plain;' <<<"$1" &&
       ! grep -Eiq '(^Unused RAM:|GPU memory:|Memory type:|VRAM total:|VRAM used:|Unused VRAM:|GTT|System RAM figures refer|Content-Disposition:|multipart/|image/|card[0-9]|Fixture GPU)' <<<"$1"; then
        echo 1
    else
        echo 0
    fi
}
make_card() {
    local card=$1 slot=$2
    mkdir -p "$work/drm/$card/device"
    ln -s "$work/drivers/amdgpu" "$work/drm/$card/device/driver"
    printf 'PCI_SLOT_NAME=%s\n' "$slot" > "$work/drm/$card/device/uevent"
}

# Mostly page cache: little is free, but plenty is available.
mem 16000000 300000 9000000 200000 8000000 500000 100000
out=$("$script" --status)
check "unused RAM includes reclaimable cache, not just free RAM" "$(field 'Unused RAM:' "$out" | awk '{print $1+0, $2}')" "8.6 GiB"
"$script"; check "cache counts as available: email sent" "$(sent)" 1
message=$(cat "$work/outbox")
check "sent narrative reports reclaimable RAM as unused" "$(awk '/^Hi Sam,/{body=1} body && /8[.]6 GiB/{found=1} END{print found+0}' <<<"$message")" 1
check "email without GPUs omits unused VRAM" "$(grep -ci 'unused VRAM' <<<"$message" || true)" 0
check "email does not duplicate RAM as a standalone field" "$(grep -c '^Unused RAM:' <<<"$message" || true)" 0
"$script"; "$script"; check "second and third run same day: no more email" "$(sent)" 1
check "used = total - available" "$(tail -n 1 "$work/state/usage.csv" | cut -d, -f3)" 7000000
check "three samples logged" "$(($(wc -l < "$work/state/usage.csv") - 1))" 3

# Next day, tight on memory.
echo 2000-01-01 > "$work/state/last_sent"
mem 16000000 300000 1000000 100000 800000 100000 100000
"$script"; check "6.2% available: no email" "$(sent)" 1

# Exactly 10% is not over 10%.
mem 16000000 300000 1600000 100000 800000 100000 100000
"$script"; check "exactly 10%: no email" "$(sent)" 1
mem 16000000 300000 1600001 100000 800000 100000 100000
"$script"; check "just over 10%: email sent" "$(sent)" 2

# A failed send is retried, and only recorded once it works.
echo 2000-01-01 > "$work/state/last_sent"
touch "$work/fail"
"$script" 2>/dev/null; check "failed send exits non-zero" "$?" 1
check "failed send not recorded" "$(cat "$work/state/last_sent")" 2000-01-01
rm "$work/fail"
"$script"; check "retry succeeds" "$(sent)" 3

# Old kernel with no MemAvailable: free + buffers + cached + slab - shmem.
# SwapCached in the fixture must not be picked up as Cached.
mem 16000000 1000000 "" 200000 3000000 500000 700000
out=$("$script" --status)
check "fallback estimate" "$(field 'Unused RAM:' "$out" | awk '{print $1, $2}')" "3.8 GiB"

# A 32 GiB UMA reservation is separate from the OS-usable 16 GiB MemTotal.
# The CPU-visible subset is smaller than the authoritative VRAM total.
rm -f "$work/outbox"
make_card card1 0000:c3:00.0
mkdir -p "$work/drm/card1/device/uma"
printf '6\n' > "$work/drm/card1/device/uma/carveout"
printf '34359738368\n' > "$work/drm/card1/device/mem_info_vram_total"
printf '1073741824\n' > "$work/drm/card1/device/mem_info_vis_vram_total"
printf '2147483648\n' > "$work/drm/card1/device/mem_info_vram_used"
printf '8589934592\n' > "$work/drm/card1/device/mem_info_gtt_total"
printf '3221225472\n' > "$work/drm/card1/device/mem_info_gtt_used"
mem 16777216 1048576 2097152 0 0 0 0
out=$("$script" --status)
check "OS-usable RAM total stays 16 GiB" "$(field 'Total:' "$out" | awk '{print $1+0, $2}')" "16 GiB"
check "OS unused RAM stays 2 GiB" "$(field 'Unused RAM:' "$out" | awk '{print $1+0, $2}')" "2 GiB"
check "canonical VRAM total, not visible subset" "$(field 'VRAM total:' "$out" | awk '{print $1+0, $2}')" "32 GiB"
check "VRAM used bytes to GiB" "$(field 'VRAM used:' "$out" | awk '{print $1+0, $2}')" "2 GiB"
check "unused AMD VRAM excludes used pool" "$(field 'Unused VRAM:' "$out" | awk '{print $1+0, $2}')" "30 GiB"
check "GTT borrowing limit bytes to GiB" "$(field 'Shared RAM limit (GTT):' "$out" | awk '{print $1+0, $2}')" "8 GiB"
check "GTT usage bytes to GiB" "$(field 'Shared RAM used (GTT):' "$out" | awk '{print $1+0, $2}')" "3 GiB"
check "UMA correctly classified" "$(field 'Memory type:' "$out")" "unified (reserved system DRAM)"
check "non-card0 device identified" "$(grep -c 'card1' <<<"$out" || true)" 1
dry=$("$script" --dry-run)
check "dry run status retains canonical GPU total" "$(field 'VRAM total:' "$dry" | awk '{print $1+0, $2}')" "32 GiB"
check "dry run status retains GPU diagnostics" "$(grep -c 'Shared RAM limit (GTT):' <<<"$dry" || true)" 1
preview=$(awk '/^From:/{message=1} message' <<<"$dry")
check "preview places unused RAM and AMD VRAM together" "$(inline_vram "$preview" '2.0 GiB' '30.0 GiB')" 1
check "preview is plain text without hardware diagnostics or images" "$(concise_email "$preview")" 1

# Either UMA attribute is positive evidence independently.
rm "$work/drm/card1/device/uma/carveout"
printf '6: Medium\n' > "$work/drm/card1/device/uma/carveout_options"
out=$("$script" --status)
check "UMA options also identifies unified memory" "$(field 'Memory type:' "$out")" "unified (reserved system DRAM)"
rm "$work/drm/card1/device/uma/carveout_options"
printf '6\n' > "$work/drm/card1/device/uma/carveout"

echo 2000-01-01 > "$work/state/last_sent"
"$script"; check "RAM threshold allows UMA email" "$(sent)" 1
message=$(cat "$work/outbox")
check "sent email places unused RAM and AMD VRAM together" "$(inline_vram "$message" '2.0 GiB' '30.0 GiB')" 1
check "sent email is plain text without hardware diagnostics or images" "$(concise_email "$message")" 1
check "CSV schema remains RAM-only" "$(head -n 1 "$work/state/usage.csv")" "timestamp,total_kb,used_kb,available_kb,available_pct"
check "CSV excludes reserved VRAM and GTT" "$(tail -n 1 "$work/state/usage.csv" | cut -d, -f2-5)" "16777216,14680064,2097152,12.5"

# Force each existing body bag selection through the real fake-sendmail path.
# Distinct RAM and VRAM values must share a sentence (or the Available row).
cp "$work/outbox" "$work/uma-outbox"
for body in $(seq 0 9); do
    printf '%s\n' "$body" > "$work/state/bag_body"
    echo 2000-01-01 > "$work/state/last_sent"
    rm -f "$work/outbox"
    "$script"
    message=$(cat "$work/outbox")
    check "body $body puts unused RAM and VRAM together" "$(inline_vram "$message" '2.0 GiB' '30.0 GiB')" 1
done
mv "$work/uma-outbox" "$work/outbox"

# Changing GTT cannot push a below-threshold RAM sample over the threshold.
printf '137438953472\n' > "$work/drm/card1/device/mem_info_gtt_total"
echo 2000-01-01 > "$work/state/last_sent"
mem 16777216 100000 1048576 0 0 0 0
"$script"; check "GTT does not alter email threshold" "$(sent)" 1
check "GTT does not alter logged RAM" "$(tail -n 1 "$work/state/usage.csv" | cut -d, -f2-5)" "16777216,15728640,1048576,6.2"

# Two real cards, plus a connector whose fake counters must never be reported.
make_card card4 0000:04:00.0
printf '4294967296\n' > "$work/drm/card4/device/mem_info_vram_total"
printf '0\n' > "$work/drm/card4/device/mem_info_vram_used"
make_card card9-DP-1 0000:09:00.0
printf '9663676416\n' > "$work/drm/card9-DP-1/device/mem_info_vram_total"
out=$("$script" --status)
check "both cards identified" "$(grep -Ec 'card1|card4' <<<"$out" || true)" 2
check "connector excluded" "$(grep -c 'card9-DP-1' <<<"$out" || true)" 0
check "both VRAM totals reported" "$(grep -c 'VRAM total:' <<<"$out" || true)" 2
card4out=$(printf '%s\n' "$out" | awk '/card4/{seen=1} seen')
check "no UMA evidence means unknown memory type" "$(field 'Memory type:' "$card4out" | grep -Eic 'unknown|not exposed' || true)" 1
check "valid zero is reported as zero" "$(field 'VRAM used:' "$card4out" | awk '{print $1+0, $2}')" "0 GiB"
check "zero VRAM usage leaves all VRAM unused" "$(field 'Unused VRAM:' "$card4out" | awk '{print $1+0, $2}')" "4 GiB"
check "absent optional GTT counter is unavailable" "$(field 'Shared RAM limit (GTT):' "$card4out" | grep -Eic 'unavailable|unknown|not exposed' || true)" 1
mem 16777216 1048576 2097152 0 0 0 0
dry=$("$script" --dry-run)
preview=$(awk '/^From:/{message=1} message' <<<"$dry")
check "large GTT limit remains visible in status" "$(field 'Shared RAM limit (GTT):' "$dry" | awk '{print $1+0, $2}')" "128 GiB"
check "multiple GPU pools remain separate and exclude GTT" "$(inline_vram "$preview" '2.0 GiB' '30.0 GiB + 4.0 GiB')" 1

# Optional metrics can be absent, malformed, or valid zero independently.
rm -rf "$work/drm/card1" "$work/drm/card9-DP-1"
printf 'not-a-number\n' > "$work/drm/card4/device/mem_info_vram_total"
printf '0\n' > "$work/drm/card4/device/mem_info_gtt_total"
printf 'broken\n' > "$work/drm/card4/device/mem_info_gtt_used"
out=$("$script" --status)
check "malformed total is unavailable" "$(field 'VRAM total:' "$out" | grep -Eic 'unavailable|unknown|not exposed' || true)" 1
check "malformed total makes unused VRAM unavailable" "$(field 'Unused VRAM:' "$out")" "unavailable"
dry=$("$script" --dry-run)
preview=$(awk '/^From:/{message=1} message' <<<"$dry")
check "malformed GPU counters omit unused VRAM from email" "$(grep -ci 'unused VRAM' <<<"$preview" || true)" 0
check "zero GTT limit remains valid" "$(field 'Shared RAM limit (GTT):' "$out" | awk '{print $1+0, $2}')" "0 GiB"
check "malformed GTT use is unavailable" "$(field 'Shared RAM used (GTT):' "$out" | grep -Eic 'unavailable|unknown|not exposed' || true)" 1
rm "$work/drm/card4/device/mem_info_vram_total" "$work/drm/card4/device/mem_info_vram_used" \
    "$work/drm/card4/device/mem_info_gtt_total" "$work/drm/card4/device/mem_info_gtt_used"
out=$("$script" --status)
check "missing VRAM total is unavailable" "$(field 'VRAM total:' "$out" | grep -Eic 'unavailable|unknown|not exposed' || true)" 1
check "missing VRAM used is unavailable" "$(field 'VRAM used:' "$out" | grep -Eic 'unavailable|unknown|not exposed' || true)" 1
check "missing VRAM counters make unused unavailable" "$(field 'Unused VRAM:' "$out")" "unavailable"
printf '4294967296\n' > "$work/drm/card4/device/mem_info_vram_total"
out=$("$script" --status)
check "missing usage makes unused VRAM unavailable" "$(field 'Unused VRAM:' "$out")" "unavailable"
dry=$("$script" --dry-run)
preview=$(awk '/^From:/{message=1} message' <<<"$dry")
check "partial GPU counters do not invent unused VRAM" "$(grep -ci 'unused VRAM' <<<"$preview" || true)" 0
printf 'broken\n' > "$work/drm/card4/device/mem_info_vram_used"
out=$("$script" --status)
check "malformed usage makes unused VRAM unavailable" "$(field 'Unused VRAM:' "$out")" "unavailable"
printf '4294967296\n' > "$work/drm/card4/device/mem_info_vram_used"
out=$("$script" --status)
check "fully used VRAM reports zero unused" "$(field 'Unused VRAM:' "$out" | awk '{print $1+0, $2}')" "0 GiB"
dry=$("$script" --dry-run)
preview=$(awk '/^From:/{message=1} message' <<<"$dry")
check "fully used GPU email reports known zero inline" "$(inline_vram "$preview" '2.0 GiB' '0.0 GiB')" 1
printf '5368709120\n' > "$work/drm/card4/device/mem_info_vram_used"
out=$("$script" --status)
check "used above total clamps unused VRAM to zero" "$(field 'Unused VRAM:' "$out" | awk '{print $1+0, $2}')" "0 GiB"
printf '0\n' > "$work/drm/card4/device/mem_info_vram_total"
printf '0\n' > "$work/drm/card4/device/mem_info_vram_used"
out=$("$script" --status)
check "zero-size VRAM pool reports zero unused" "$(field 'Unused VRAM:' "$out" | awk '{print $1+0, $2}')" "0 GiB"
# Both displayed counters round to 1.0 GiB, but their raw difference rounds to 0.1 GiB.
printf '1116691497\n' > "$work/drm/card4/device/mem_info_vram_total"
printf '1030792151\n' > "$work/drm/card4/device/mem_info_vram_used"
out=$("$script" --status)
check "VRAM subtraction precedes GiB rounding" "$(field 'Unused VRAM:' "$out" | awk '{print $1, $2}')" "0.1 GiB"
rm -rf "$work/drm/card4"
out=$("$script" --status)
check "no GPU counters report unavailable" "$(grep -Eiq 'unavailable|unknown|not exposed' <<<"$out"; echo "$?")" 0
dry=$("$script" --dry-run)
preview=$(awk '/^From:/{message=1} message' <<<"$dry")
check "no GPU email omits unused VRAM" "$(grep -ci 'unused VRAM' <<<"$preview" || true)" 0

# NVIDIA values are MiB; match one row to a DRM card and leave one standalone.
mkdir -p "$work/drivers/nvidia"
make_card card7 0000:01:00.0
rm "$work/drm/card7/device/driver"
ln -s "$work/drivers/nvidia" "$work/drm/card7/device/driver"
cat > "$work/nvidia-output" <<'EOF'
00000000:01:00.0, Fixture GPU One, 6144, 1536
00000000:02:00.0, Fixture GPU Two, 12288, 2048
EOF
out=$("$script" --status)
check "matching NVIDIA DRM card is not duplicated" "$(grep -c 'VRAM total:' <<<"$out" || true)" 2
check "NVIDIA first GPU total MiB to GiB" "$(field 'VRAM total:' "$out" | awk '{print $1+0, $2}')" "6 GiB"
check "NVIDIA first GPU used MiB to GiB" "$(field 'VRAM used:' "$out" | awk '{print $1+0, $2}')" "1.5 GiB"
check "PCI-matched NVIDIA unused MiB to GiB" "$(field 'Unused VRAM:' "$out" | awk '{print $1+0, $2}')" "4.5 GiB"
check "NVIDIA second GPU total MiB to GiB" "$(grep 'VRAM total:' <<<"$out" | awk 'NR==2 {print $(NF-1)+0, $NF}')" "12 GiB"
check "NVIDIA second GPU used MiB to GiB" "$(grep 'VRAM used:' <<<"$out" | awk 'NR==2 {print $(NF-1)+0, $NF}')" "2 GiB"
check "standalone NVIDIA unused MiB to GiB" "$(grep 'Unused VRAM:' <<<"$out" | awk 'NR==2 {print $(NF-1)+0, $NF}')" "10 GiB"
dry=$("$script" --dry-run)
preview=$(awk '/^From:/{message=1} message' <<<"$dry")
check "NVIDIA email lists each GPU's unused VRAM inline" "$(inline_vram "$preview" '2.0 GiB' '4.5 GiB + 10.0 GiB')" 1
# MiB counters also need subtraction before conversion and rounding.
cat > "$work/nvidia-output" <<'EOF'
00000000:01:00.0, Fixture GPU One, 1065, 983
00000000:02:00.0, Fixture GPU Two, 1065, 983
EOF
out=$("$script" --status)
check "PCI-matched NVIDIA subtracts before rounding" "$(field 'Unused VRAM:' "$out" | awk '{print $1, $2}')" "0.1 GiB"
check "standalone NVIDIA subtracts before rounding" "$(grep 'Unused VRAM:' <<<"$out" | awk 'NR==2 {print $(NF-1), $NF}')" "0.1 GiB"
dry=$("$script" --dry-run)
preview=$(awk '/^From:/{message=1} message' <<<"$dry")
check "email preserves independently rounded GPU pools inline" "$(inline_vram "$preview" '2.0 GiB' '0.1 GiB + 0.1 GiB')" 1

# An unavailable NVIDIA metric must not hide the device or its valid metric.
cat > "$work/nvidia-output" <<'EOF'
00000000:01:00.0, Fixture GPU One, invalid, 1024
00000000:02:00.0, Fixture GPU Two, 4096, N/A
EOF
out=$("$script" --status)
standalone=$(awk '/GPU Fixture GPU Two/{seen=1} seen' <<<"$out")
check "PCI-matched malformed NVIDIA total is unavailable" "$(field 'VRAM total:' "$out")" "unavailable"
check "PCI-matched NVIDIA retains valid usage" "$(field 'VRAM used:' "$out" | awk '{print $1+0, $2}')" "1 GiB"
check "PCI-matched missing total makes unused unavailable" "$(field 'Unused VRAM:' "$out")" "unavailable"
check "standalone NVIDIA retains valid total" "$(field 'VRAM total:' "$standalone" | awk '{print $1+0, $2}')" "4 GiB"
check "standalone unavailable NVIDIA usage is unavailable" "$(field 'VRAM used:' "$standalone")" "unavailable"
check "standalone missing usage makes unused unavailable" "$(field 'Unused VRAM:' "$standalone")" "unavailable"
dry=$("$script" --dry-run)
preview=$(awk '/^From:/{message=1} message' <<<"$dry")
check "unknown NVIDIA pools do not invent unused VRAM" "$(grep -ci 'unused VRAM' <<<"$preview" || true)" 0
cat > "$work/nvidia-output" <<'EOF'
00000000:01:00.0, Fixture GPU One, 6144, 1536
00000000:02:00.0, Fixture GPU Two, 4096, N/A
EOF
dry=$("$script" --dry-run)
preview=$(awk '/^From:/{message=1} message' <<<"$dry")
check "partial GPU availability lists only the known pool inline" "$(inline_vram "$preview" '2.0 GiB' '4.5 GiB')" 1
rm -rf "$work/drm/card7"
rm "$work/nvidia-output"

# Variety: 10 bodies should all appear across 10 days, with no back-to-back repeat.
rm -f "$work/outbox" "$work/state"/bag_*
mem 16000000 300000 9000000 200000 8000000 500000 100000
for _ in $(seq 40); do echo 2000-01-01 > "$work/state/last_sent"; "$script"; done
awk 'BEGIN{RS="=====END=====\n"} NF{n=split($0,l,"\n"); for(i=1;i<=n;i++) if(l[i]=="Hi Sam,"){b=l[i+2]; print b}}' \
    "$work/outbox" > "$work/bodies"
check "all opening lines used" "$(head -n 10 "$work/bodies" | sort -u | wc -l)" 10
check "no back-to-back repeat" "$(uniq -d "$work/bodies" | wc -l)" 0
check "all sent message narratives include numeric unused RAM" "$(awk 'BEGIN{RS="=====END=====\n"} {body=index($0,"Hi Sam,"); if(body && substr($0,body) ~ /8[.]6 GiB/) n++} END{print n+0}' "$work/outbox")" 40

# Config errors.
RAM_ALTMAN_TO='' "$script" 2>/dev/null; check "missing recipient refused" "$?" 1

echo; echo "$pass passed, $fail failed"
echo; echo "--- real machine RAM (GPU fixture empty) ---"; RAM_ALTMAN_MEMINFO=/proc/meminfo "$script" --status
echo; echo "--- sample dry run ---"
mem 16000000 300000 9000000 200000 8000000 500000 100000
"$script" --dry-run
exit "$fail"
