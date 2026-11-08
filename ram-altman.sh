#!/usr/bin/env bash
#
# ram-altman.sh - track RAM usage and, at most once a day, tell Sam Altman
# when this PC has RAM to spare.
#
# Usage:
#   ram-altman.sh            Log a sample and send the daily email if due
#   ram-altman.sh --status   Print current memory figures and exit
#   ram-altman.sh --dry-run  Print the email that would be sent and exit
#
# Cron (every 5 minutes):
#   */5 * * * * /path/to/ram-altman.sh
#
# On a Proxmox VE node it reports the whole cluster instead of this host. Run it
# as root from cron on every node: only the first online node sends the email.
# Set RAM_ALTMAN_SOURCE=local to report just this host.
#
# How "used" is worked out:
#   used = MemTotal - MemAvailable
#
#   MemAvailable is the kernel's own estimate of how much memory can be handed
#   to new programs without swapping. It covers free memory plus the page cache
#   and slab memory that can be reclaimed, so cached RAM does not count as used.
#   It leaves out what can't really be reclaimed, such as tmpfs/shared memory,
#   which makes it more accurate than simply adding "free" and "cached" together.

set -euo pipefail

# ----- Settings: fill these in -----------------------------------------------
RECIPIENT="${RAM_ALTMAN_TO:-}"             # Who receives the email
SENDER="${RAM_ALTMAN_FROM:-}"              # A real address you can send from
SENDER_NAME="${RAM_ALTMAN_FROM_NAME:-}"    # Display name, optional
THRESHOLD_PCT="${RAM_ALTMAN_THRESHOLD:-10}" # Email when available is above this
SOURCE="${RAM_ALTMAN_SOURCE:-auto}"        # auto, local or proxmox
# -----------------------------------------------------------------------------

MEMINFO="${RAM_ALTMAN_MEMINFO:-/proc/meminfo}"
STATE_DIR="${RAM_ALTMAN_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/ram-altman}"
USAGE_LOG="$STATE_DIR/usage.csv"
LAST_SENT_FILE="$STATE_DIR/last_sent"
# Lives on the cluster filesystem so a failover can't send a second daily email.
SHARED_LAST_SENT_FILE="${RAM_ALTMAN_SHARED_STATE:-/etc/pve/ram-altman-last-sent}"
MAX_LOG_BYTES=$((10 * 1024 * 1024))   # Trim the log once it passes 10 MiB
LOG_LINES_TO_KEEP=50000
node_lines=""

# cron's PATH often leaves out the directories sendmail lives in.
export PATH="$PATH:/usr/sbin:/sbin"

die() {
    printf 'ram-altman: %s\n' "$*" >&2
    exit 1
}

resolve_source() {
    case "$SOURCE" in
        auto)
            if command -v pvesh > /dev/null; then SOURCE=proxmox; else SOURCE=local; fi
            ;;
        local|proxmox)
            ;;
        *)
            die "RAM_ALTMAN_SOURCE must be auto, local or proxmox, not '$SOURCE'"
            ;;
    esac
}

percent_of() {
    awk -v a="$1" -v t="$2" 'BEGIN { printf "%.1f", a * 100 / t }'
}

read_stats() {
    if [[ "$SOURCE" == proxmox ]]; then read_cluster; else read_memory; fi
}

# Sets: total_kb, available_kb, used_kb, free_kb, cache_kb, available_pct
read_memory() {
    [[ -r "$MEMINFO" ]] || die "cannot read $MEMINFO (this script needs Linux)"

    read -r total_kb available_kb free_kb cache_kb < <(
        awk '
            /^MemTotal:/      { total = $2 }
            /^MemFree:/       { free = $2 }
            /^MemAvailable:/  { available = $2; has_available = 1 }
            /^Buffers:/       { buffers = $2 }
            /^Cached:/        { cached = $2 }
            /^SReclaimable:/  { slab = $2 }
            /^Shmem:/         { shmem = $2 }
            END {
                cache = buffers + cached + slab - shmem
                if (cache < 0) cache = 0
                # Kernels older than 3.14 have no MemAvailable, so estimate it.
                if (!has_available) available = free + cache
                if (available > total) available = total
                print total + 0, available + 0, free + 0, cache + 0
            }
        ' "$MEMINFO"
    )

    (( total_kb > 0 )) || die "could not find MemTotal in $MEMINFO"

    used_kb=$(( total_kb - available_kb ))
    available_pct=$(percent_of "$available_kb" "$total_kb")
}

pvesh_json() {
    pvesh get "$@" --output-format json ||
        die "pvesh failed (run as root on a Proxmox node, or set RAM_ALTMAN_SOURCE=local)"
}

# Sets: total_kb, available_kb, used_kb, available_pct, node_lines
# Offline nodes are listed but not counted: they have no memory to report.
# Nodes appear as numbers in name order, so hostnames never leave the cluster.
read_cluster() {
    local json rows status mem max line node_total node_available label index=0
    json=$(pvesh_json /cluster/resources --type node)
    rows=$(perl -MJSON::PP -0777 -ne '
        for my $n (sort { $a->{node} cmp $b->{node} } @{ decode_json($_) }) {
            printf "%s %s %d %d\n", $n->{node}, $n->{status} // "unknown",
                $n->{mem} // 0, $n->{maxmem} // 0;
        }
    ' <<< "$json") || die "could not parse the node list from pvesh"

    total_kb=0
    available_kb=0
    node_lines=""
    while read -r _ status mem max; do
        index=$(( index + 1 ))
        label="node $index"
        if [[ "$status" == online ]] && (( max > 0 )); then
            (( mem <= max )) || mem=$max
            node_total=$(( max / 1024 ))
            node_available=$(( (max - mem) / 1024 ))
            total_kb=$(( total_kb + node_total ))
            available_kb=$(( available_kb + node_available ))
            printf -v line '  %-16s %s of %s available (%s%%)' "$label" \
                "$(to_gib "$node_available")" "$(to_gib "$node_total")" \
                "$(percent_of "$node_available" "$node_total")"
        else
            printf -v line '  %-16s offline, not counted' "$label"
        fi
        node_lines+="${node_lines:+$'\n'}$line"
    done <<< "$rows"

    (( total_kb > 0 )) || die "pvesh reported no online nodes with memory"

    used_kb=$(( total_kb - available_kb ))
    available_pct=$(percent_of "$available_kb" "$total_kb")
}

# Succeeds only on the node that should report: the first online node by name,
# in a cluster with quorum. Every node reaches the same answer independently.
is_cluster_reporter() {
    local json local_node quorate reporter
    json=$(pvesh_json /cluster/status)
    read -r local_node quorate reporter < <(perl -MJSON::PP -0777 -ne '
        my @entries = @{ decode_json($_) };
        my ($cluster) = grep { $_->{type} eq "cluster" } @entries;
        my @nodes = grep { $_->{type} eq "node" } @entries;
        my ($me) = grep { $_->{local} } @nodes;
        my ($first) = sort map { $_->{name} } grep { $_->{online} || $_->{local} } @nodes;
        printf "%s %d %s\n", $me ? $me->{name} : "-",
            (!$cluster || $cluster->{quorate}) ? 1 : 0, $first // "-";
    ' <<< "$json") || die "could not parse the cluster status from pvesh"

    [[ "$local_node" != "-" ]] || die "pvesh did not identify the local node"
    (( quorate )) && [[ "$local_node" == "$reporter" ]]
}

to_gib() {
    awk -v kb="$1" 'BEGIN { printf "%.1f GiB", kb / 1048576 }'
}

is_over_threshold() {
    (( available_kb * 100 > THRESHOLD_PCT * total_kb ))
}

print_status() {
    printf 'Total:      %s\n' "$(to_gib "$total_kb")"
    printf 'Used:       %s\n' "$(to_gib "$used_kb")"
    printf 'Available:  %s (%s%%)\n' "$(to_gib "$available_kb")" "$available_pct"
    if [[ -n "$node_lines" ]]; then
        printf '%s\n' "$node_lines"
        return
    fi
    printf '  Free:     %s\n' "$(to_gib "$free_kb")"
    printf '  Cache:    %s\n' "$(to_gib "$cache_kb")"
}

log_sample() {
    [[ -f "$USAGE_LOG" ]] ||
        echo 'timestamp,total_kb,used_kb,available_kb,available_pct' > "$USAGE_LOG"
    printf '%s,%s,%s,%s,%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" \
        "$total_kb" "$used_kb" "$available_kb" "$available_pct" >> "$USAGE_LOG"

    if (( $(wc -c < "$USAGE_LOG") > MAX_LOG_BYTES )); then
        {
            head -n 1 "$USAGE_LOG"
            tail -n "$LOG_LINES_TO_KEEP" "$USAGE_LOG"
        } > "$USAGE_LOG.tmp"
        mv "$USAGE_LOG.tmp" "$USAGE_LOG"
    fi
}

# Deals out every option once, in random order, before any can come up again.
# Prints an index from 0 to count-1. A dry run changes nothing on disk.
pick() {
    local name=$1 count=$2 bag last next
    if [[ -n "${DRY_RUN:-}" ]]; then
        echo $(( RANDOM % count ))
        return
    fi

    bag="$STATE_DIR/bag_$name"
    if [[ ! -s "$bag" ]]; then
        seq 0 $(( count - 1 )) | shuf > "$bag"
        # Stop the last pick of the old round opening the new one.
        last=$(cat "$bag.last" 2>/dev/null || true)
        if [[ "$(head -n 1 "$bag")" == "$last" ]] && (( count > 1 )); then
            { tail -n +2 "$bag"; head -n 1 "$bag"; } > "$bag.tmp"
            mv "$bag.tmp" "$bag"
        fi
    fi

    next=$(head -n 1 "$bag")
    tail -n +2 "$bag" > "$bag.tmp"
    mv "$bag.tmp" "$bag"
    echo "$next" > "$bag.last"

    # Covers the template lists being shortened after the bag was dealt.
    (( next < count )) || next=$(( RANDOM % count ))
    echo "$next"
}

compose_email() {
    local total available pct
    total=$(to_gib "$total_kb")
    available=$(to_gib "$available_kb")
    pct=$available_pct

    local machine=PC unit=machine place="on my desk" busy="browser tab I own open"
    if [[ "$SOURCE" == proxmox ]]; then
        machine=cluster unit=cluster place="in my rack" busy="VM I own running"
    fi

    local subjects=(
        "Good news: we found some RAM"
        "Unused RAM detected in the wild"
        "RAM sighting on my $machine"
        "$available of RAM, just sitting there"
        "You missed a spot"
        "Daily RAM census: some survived"
        "$pct% of my RAM remains at large"
        "Still not all of it, I'm afraid"
    )

    local bodies=(
        "I'm writing to report that you appear to have missed some. This $machine has $total of RAM and $available of it ($pct%) is currently available. I assume this is an oversight."
        "A routine inspection of my $machine found $available of unclaimed RAM out of $total. That's $pct% of the $unit doing absolutely nothing. I thought you'd want to know before someone tries to train something on it."
        "Daily status report:

  Total RAM:     $total
  Available:     $available ($pct%)
  Threat level:  someone at OpenAI might notice"
        "Even with every $busy, $available of my $total of RAM is still available. I'm as surprised as you are."
        "Please don't be alarmed, but there is $available of RAM $place that isn't in a data centre. That's $pct% of what's installed here, and as far as I can tell it has no plans today."
        "Before you ask: yes, I counted the page cache as available. The kernel gives it back the moment anyone asks, which leaves $available of $total up for grabs."
        "Today's forecast for my $machine: clear skies, light workloads and $pct% available memory. Expect $available of the installed $total to stay idle through the evening."
        "I hear RAM is hard to come by these days, so it feels a bit rude to be sitting on $available of it. Total installed: $total. It's not for sale, I just like knowing it's there."
        "I have a confession. I have $available of RAM that I'm not using, which is $pct% of the $total in this $machine. I've told nobody but you and a cron job."
        "If $available of RAM sits idle in a $machine and nobody allocates it, does it still count as capacity? Asking on behalf of the $pct% of my memory with nothing to do."
    )

    local signoffs=(
        "Yours in abundance,"
        "Regards from the last free RAM in the county,"
        "Hoarding responsibly,"
        "Stay allocated,"
        "Yours, with memory to spare,"
        "Kind regards,"
    )

    local subject_index body_index signoff_index
    subject_index=$(pick subject "${#subjects[@]}")
    body_index=$(pick body "${#bodies[@]}")
    signoff_index=$(pick signoff "${#signoffs[@]}")

    local breakdown=""
    [[ -z "$node_lines" ]] || breakdown=$'\n\nNode by node:\n'"$node_lines"

    email_subject=${subjects[$subject_index]}
    email_body="Hi Sam,

${bodies[$body_index]}$breakdown

${signoffs[$signoff_index]}
${SENDER_NAME:-A concerned RAM owner}

--
Sent automatically, at most once a day, by a small script on one $machine.
Reply if you'd like it to stop."
}

render_message() {
    local from=$SENDER
    [[ -n "$SENDER_NAME" ]] && from="$SENDER_NAME <$SENDER>"
    printf 'From: %s\n' "$from"
    printf 'To: %s\n' "$RECIPIENT"
    printf 'Subject: %s\n' "$email_subject"
    printf 'Date: %s\n' "$(date -R)"
    printf 'MIME-Version: 1.0\n'
    printf 'Content-Type: text/plain; charset=UTF-8\n'
    printf 'Auto-Submitted: auto-generated\n'
    printf '\n%s\n' "$email_body"
}

send_email() {
    if command -v sendmail > /dev/null; then
        render_message | sendmail -t -i
    elif command -v msmtp > /dev/null; then
        render_message | msmtp -t
    elif command -v mail > /dev/null; then
        printf '%s\n' "$email_body" | mail -s "$email_subject" "$RECIPIENT"
    else
        echo 'ram-altman: no sendmail, msmtp or mail command found' >&2
        return 1
    fi
}

main() {
    resolve_source

    case "${1:-}" in
        --status)
            read_stats
            print_status
            exit 0
            ;;
        --dry-run)
            DRY_RUN=1
            read_stats
            print_status
            if ! is_over_threshold; then
                echo "No email: available RAM is not above ${THRESHOLD_PCT}%."
                exit 0
            fi
            compose_email
            RECIPIENT=${RECIPIENT:-recipient-not-set@example.com}
            SENDER=${SENDER:-sender-not-set@example.com}
            printf '\n'
            render_message
            exit 0
            ;;
        -h|--help)
            sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        "")
            ;;
        *)
            die "unknown option: $1 (try --help)"
            ;;
    esac

    [[ -n "$RECIPIENT" ]] || die "RECIPIENT is not set"
    [[ -n "$SENDER" ]] || die "SENDER is not set"

    mkdir -p "$STATE_DIR"

    # Stop overlapping runs from both sending today's email.
    if command -v flock > /dev/null; then
        exec 9> "$STATE_DIR/lock"
        flock -n 9 || exit 0
    fi

    if [[ "$SOURCE" == proxmox ]]; then
        is_cluster_reporter || exit 0
        LAST_SENT_FILE=$SHARED_LAST_SENT_FILE
    fi

    read_stats
    log_sample

    is_over_threshold || exit 0

    local today last_sent
    today=$(date +%F)
    last_sent=$(cat "$LAST_SENT_FILE" 2>/dev/null || true)
    [[ "$last_sent" != "$today" ]] || exit 0

    compose_email
    send_email || die "email failed to send; will try again on the next run"

    # Recorded only after a successful send, so a failure gets retried.
    echo "$today" > "$LAST_SENT_FILE"
}

main "$@"
