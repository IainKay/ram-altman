#!/usr/bin/env bash
# Exercises ram-altman.sh with simulated memory and a fake sendmail.
set -uo pipefail

script="$(cd "$(dirname "$0")" && pwd)/ram-altman.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/state"

cat > "$work/bin/sendmail" <<EOF
#!/usr/bin/env bash
[[ -e "$work/fail" ]] && exit 75
if [[ -e "$work/slow" ]]; then touch "$work/sending"; sleep 1; fi
cat >> "$work/outbox"
echo "=====END=====" >> "$work/outbox"
EOF
chmod +x "$work/bin/sendmail"

export PATH="$work/bin:$PATH"
export RAM_ALTMAN_TO=to@example.com RAM_ALTMAN_FROM=from@example.com
export RAM_ALTMAN_STATE_DIR="$work/state" RAM_ALTMAN_MEMINFO="$work/meminfo"

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

# Mostly page cache: little is free, but plenty is available.
mem 16000000 300000 9000000 200000 8000000 500000 100000
"$script"; check "cache counts as available: email sent" "$(sent)" 1
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
check "fallback estimate" "$(awk '/^Available:/ {print $2, $3}' <<<"$out")" "3.8 GiB"

# Variety: 10 bodies should all appear across 10 days, with no back-to-back repeat.
rm -f "$work/outbox" "$work/state"/bag_*
mem 16000000 300000 9000000 200000 8000000 500000 100000
for _ in $(seq 40); do echo 2000-01-01 > "$work/state/last_sent"; "$script"; done
awk 'BEGIN{RS="=====END=====\n"} NF{n=split($0,l,"\n"); for(i=1;i<=n;i++) if(l[i]=="Hi Sam,"){b=l[i+2]; print b}}' \
    "$work/outbox" > "$work/bodies"
check "all opening lines used" "$(head -n 10 "$work/bodies" | sort -u | awk 'END {print NR}')" 10
check "no back-to-back repeat" "$(uniq -d "$work/bodies" | awk 'END {print NR}')" 0

# Config errors.
RAM_ALTMAN_TO='' "$script" 2>/dev/null; check "missing recipient refused" "$?" 1

# Exercise the Darwin path with native-command fixtures, on either host OS.
cat > "$work/bin/uname" <<'EOF'
#!/usr/bin/env bash
echo Darwin
EOF
cat > "$work/bin/sysctl" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == '-n hw.memsize' ]] || exit 1
[[ ! -e "$RAM_ALTMAN_STATE_DIR/sysctl-fail" ]] || exit 1
echo 17179869184
EOF
cat > "$work/bin/vm_stat" <<'EOF'
#!/usr/bin/env bash
cat "$RAM_ALTMAN_STATE_DIR/vm_stat"
EOF
chmod +x "$work/bin/uname" "$work/bin/sysctl" "$work/bin/vm_stat"
unset RAM_ALTMAN_MEMINFO
for page_size in 4096 16384; do
    cat > "$work/state/vm_stat" <<EOF
Mach Virtual Memory Statistics: (page size of $page_size bytes)
Pages free: 65536.
Pages active: 524288.
Pages inactive: 262144.
Pages speculative: 65536.
Pages purgeable: 65536.
File-backed pages: 327680.
Pages occupied by compressor: 65536.
EOF
    out=$("$script" --status)
    expected=$(awk -v p="$page_size" 'BEGIN { printf "%.1f GiB", 458752*p/1073741824 }')
    check "macOS $page_size-byte pages: reclaimable estimate" \
        "$(awk '/^Available:/ {print $2, $3}' <<<"$out")" "$expected"
    before=$(wc -l < "$work/state/usage.csv")
    "$script" --dry-run > "$work/dry-run"
    check "macOS dry-run leaves log unchanged" "$(wc -l < "$work/state/usage.csv")" "$before"
    check "macOS dry-run renders email" "$(grep -c '^Subject:' "$work/dry-run")" 1
done

# Overlapping runs must send only once, including without flock on macOS.
echo 2000-01-01 > "$work/state/last_sent"
before=$(sent)
touch "$work/slow"
"$script" & first_pid=$!
for (( i=0; i<100; i++ )); do
    [[ ! -e "$work/sending" ]] || break
    sleep 0.05
done
"$script"; second_status=$?
wait "$first_pid"; first_status=$?
check "overlapping runs succeed" "$first_status,$second_status" "0,0"
check "overlapping runs send once" "$(sent)" "$((before+1))"
check "portable lock is released" "$(test -d "$work/state/lock.d" && echo locked || echo clear)" clear
rm "$work/slow" "$work/sending"

# Oversized estimates are capped; incomplete data and command failures are errors.
sed 's/^File-backed pages:.*/File-backed pages: 99999999./' "$work/state/vm_stat" > "$work/vm_stat"
mv "$work/vm_stat" "$work/state/vm_stat"
check "macOS estimate capped at total" \
    "$("$script" --status | awk '/^Used:/ {print $2, $3}')" "0.0 GiB"
echo 'not vm_stat output' > "$work/state/vm_stat"
"$script" --status 2>/dev/null; check "invalid vm_stat rejected" "$?" 1
touch "$work/state/sysctl-fail"
"$script" --status 2>/dev/null; check "failed sysctl rejected" "$?" 1
rm "$work/bin/uname" "$work/bin/sysctl" "$work/bin/vm_stat"
export RAM_ALTMAN_MEMINFO="$work/meminfo"

echo; echo "$pass passed, $fail failed"
echo; echo "--- real machine status (optional) ---"
RAM_ALTMAN_MEMINFO='' "$script" --status || echo "Native memory statistics unavailable in this environment."
echo; echo "--- sample dry run ---"
mem 16000000 300000 9000000 200000 8000000 500000 100000
"$script" --dry-run
exit "$fail"
