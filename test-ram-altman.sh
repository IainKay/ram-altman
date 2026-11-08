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
cat >> "$work/outbox"
echo "=====END=====" >> "$work/outbox"
EOF
chmod +x "$work/bin/sendmail"

export PATH="$work/bin:$PATH"
export RAM_ALTMAN_TO=to@example.com RAM_ALTMAN_FROM=from@example.com
export RAM_ALTMAN_STATE_DIR="$work/state" RAM_ALTMAN_MEMINFO="$work/meminfo"
export RAM_ALTMAN_SOURCE=local RAM_ALTMAN_SHARED_STATE="$work/shared_last_sent"

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
check "all opening lines used" "$(head -n 10 "$work/bodies" | sort -u | wc -l)" 10
check "no back-to-back repeat" "$(uniq -d "$work/bodies" | wc -l)" 0

# Config errors.
RAM_ALTMAN_TO='' "$script" 2>/dev/null; check "missing recipient refused" "$?" 1
RAM_ALTMAN_SOURCE=bogus "$script" --status 2>/dev/null; check "unknown source refused" "$?" 1

# Proxmox: a fake pvesh serves canned JSON. 64 + 32 GiB online, pve3 offline.
cat > "$work/bin/pvesh" <<EOF
#!/usr/bin/env bash
[[ -e "$work/pvesh_fail" ]] && exit 1
case "\$2" in
    /cluster/resources) cat "$work/resources.json" ;;
    /cluster/status)    cat "$work/status.json" ;;
esac
EOF
chmod +x "$work/bin/pvesh"
GIB=1073741824
cat > "$work/resources.json" <<EOF
[{"node":"pve2","status":"online","mem":$((16*GIB)),"maxmem":$((32*GIB))},
 {"node":"pve1","status":"online","mem":$((32*GIB)),"maxmem":$((64*GIB))},
 {"node":"pve3","status":"offline"}]
EOF
cluster() { # local-node quorate online-nodes...
    local me=$1 quorate=$2 entries="" n; shift 2
    for n in pve1 pve2 pve3; do
        entries+=",{\"type\":\"node\",\"name\":\"$n\",\"online\":$([[ " $* " == *" $n "* ]] && echo 1 || echo 0),\"local\":$([[ $n == "$me" ]] && echo 1 || echo 0)}"
    done
    echo "[{\"type\":\"cluster\",\"quorate\":$quorate}$entries]" > "$work/status.json"
}

export RAM_ALTMAN_SOURCE=proxmox
rm -f "$work/state/last_sent" "$work/state/usage.csv"
: > "$work/outbox"

cluster pve1 1 pve1 pve2
out=$("$script" --status)
check "cluster total adds online nodes" "$(awk '/^Total:/ {print $2}' <<<"$out")" "96.0"
check "cluster available adds online nodes" "$(awk '/^Available:/ {print $4}' <<<"$out")" "(50.0%)"
check "offline node is listed by number" "$(grep -c 'node 3 .*offline' <<<"$out")" 1
check "numbered in name order" "$(grep -c 'node 2 .*16.0 GiB of 32.0 GiB' <<<"$out")" 1
check "status hides node names" "$(grep -c 'pve' <<<"$out")" 0

cluster pve2 1 pve1 pve2
"$script"; check "non-reporting node sends nothing" "$(sent)" 0
check "non-reporting node logs nothing" "$([[ -e "$work/state/usage.csv" ]] && echo yes || echo no)" no

cluster pve1 0 pve1 pve2
"$script"; check "no quorum: nothing sent" "$(sent)" 0

cluster pve1 1 pve1 pve2
"$script"; check "reporting node sends the email" "$(sent)" 1
check "email lists each node" "$(grep -cE '^  node [123] ' "$work/outbox")" 3
check "email hides node names" "$(grep -c 'pve' "$work/outbox")" 0
check "email sign-off names a cluster" "$(grep -c 'script on one cluster' "$work/outbox")" 1

cluster pve2 1 pve2
"$script"; check "failover the same day: no second email" "$(sent)" 1

echo 2000-01-01 > "$work/shared_last_sent"
"$script"; check "failover node reports the next day" "$(sent)" 2

touch "$work/pvesh_fail"
"$script" --status 2>/dev/null; check "pvesh failure exits non-zero" "$?" 1
rm "$work/pvesh_fail"
export RAM_ALTMAN_SOURCE=local

echo; echo "$pass passed, $fail failed"
echo; echo "--- real machine status ---"; RAM_ALTMAN_MEMINFO=/proc/meminfo "$script" --status
echo; echo "--- sample dry run ---"
mem 16000000 300000 9000000 200000 8000000 500000 100000
"$script" --dry-run
exit "$fail"
