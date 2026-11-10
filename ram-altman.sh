#!/usr/bin/env bash
#
# ram-altman.sh - track RAM usage and, at most once a day, tell Sam Altman
# when this PC has RAM to spare (or has run completely out).
#
# Usage:
#   ram-altman.sh            Log a sample and send the daily email if due
#   ram-altman.sh --status   Print current memory figures and exit
#   ram-altman.sh --dry-run  Print the email that would be sent and exit
#
# Cron (every 5 minutes):
#   */5 * * * * /path/to/ram-altman.sh
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
# -----------------------------------------------------------------------------

MEMINFO="${RAM_ALTMAN_MEMINFO:-/proc/meminfo}"
STATE_DIR="${RAM_ALTMAN_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/ram-altman}"
USAGE_LOG="$STATE_DIR/usage.csv"
LAST_SENT_FILE="$STATE_DIR/last_sent"
MAX_LOG_BYTES=$((10 * 1024 * 1024))   # Trim the log once it passes 10 MiB
LOG_LINES_TO_KEEP=50000

# cron's PATH often leaves out the directories sendmail lives in.
export PATH="$PATH:/usr/sbin:/sbin"

die() {
    printf 'ram-altman: %s\n' "$*" >&2
    exit 1
}

# Sets: total_kb, available_kb, used_kb, free_kb, cache_kb, available_pct,
#       swap_total_kb, swap_free_kb, swap_used_kb
read_memory() {
    [[ -r "$MEMINFO" ]] || die "cannot read $MEMINFO (this script needs Linux)"

    read -r total_kb available_kb free_kb cache_kb swap_total_kb swap_free_kb < <(
        awk '
            /^MemTotal:/      { total = $2 }
            /^MemFree:/       { free = $2 }
            /^MemAvailable:/  { available = $2; has_available = 1 }
            /^Buffers:/       { buffers = $2 }
            /^Cached:/        { cached = $2 }
            /^SReclaimable:/  { slab = $2 }
            /^Shmem:/         { shmem = $2 }
            /^SwapTotal:/     { swap_total = $2 }
            /^SwapFree:/      { swap_free = $2 }
            END {
                cache = buffers + cached + slab - shmem
                if (cache < 0) cache = 0
                # Kernels older than 3.14 have no MemAvailable, so estimate it.
                if (!has_available) available = free + cache
                if (available > total) available = total
                if (available < 0) available = 0
                # Some mock/partial meminfo sources may omit swap entirely.
                if (swap_total < 0) swap_total = 0
                if (swap_free < 0) swap_free = 0
                if (swap_free > swap_total) swap_free = swap_total
                print total + 0, available + 0, free + 0, cache + 0, swap_total + 0, swap_free + 0
            }
        ' "$MEMINFO"
    )

    (( total_kb > 0 )) || die "could not find MemTotal in $MEMINFO"

    used_kb=$(( total_kb - available_kb ))
    swap_used_kb=$(( swap_total_kb - swap_free_kb ))
    available_pct=$(awk -v a="$available_kb" -v t="$total_kb" \
        'BEGIN { printf "%.1f", a * 100 / t }')
}

to_gib() {
    awk -v kb="$1" 'BEGIN { printf "%.1f GiB", kb / 1048576 }'
}

is_over_threshold() {
    (( available_kb * 100 > THRESHOLD_PCT * total_kb ))
}

# A distinct report for machines that have actually used their RAM.
# Strictly less than 1% available AND strictly more than 10 GiB of swap in use.
# We deliberately do not inspect processes or disclose application names.
is_memory_crisis() {
    (( available_kb * 100 < total_kb && swap_used_kb > 10 * 1048576 ))
}

is_reportable() {
    is_over_threshold || is_memory_crisis
}

print_status() {
    printf 'Total:      %s\n' "$(to_gib "$total_kb")"
    printf 'Used:       %s\n' "$(to_gib "$used_kb")"
    printf 'Available:  %s (%s%%)\n' "$(to_gib "$available_kb")" "$available_pct"
    printf '  Free:     %s\n' "$(to_gib "$free_kb")"
    printf '  Cache:    %s\n' "$(to_gib "$cache_kb")"
    if (( swap_total_kb > 0 )); then
        printf 'Swap used:  %s / %s\n' "$(to_gib "$swap_used_kb")" "$(to_gib "$swap_total_kb")"
    fi
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

    local subjects=(
        "Good news: we found some RAM"
        "Unused RAM detected in the wild"
        "RAM sighting on my PC"
        "$available of RAM, just sitting there"
        "You missed a spot"
        "Daily RAM census: some survived"
        "$pct% of my RAM remains at large"
        "Still not all of it, I'm afraid"
    )

    local bodies=(
        "I'm writing to report that you appear to have missed some. This PC has $total of RAM and $available of it ($pct%) is currently available. I assume this is an oversight."
        "A routine inspection of my PC found $available of unclaimed RAM out of $total. That's $pct% of the machine doing absolutely nothing. I thought you'd want to know before someone tries to train something on it."
        "Daily status report:

  Total RAM:     $total
  Available:     $available ($pct%)
  Threat level:  someone at OpenAI might notice"
        "Even with every browser tab I own open, $available of my $total of RAM is still available. I'm as surprised as you are."
        "Please don't be alarmed, but there is $available of RAM on my desk that isn't in a data centre. That's $pct% of what's installed here, and as far as I can tell it has no plans today."
        "Before you ask: yes, I counted the page cache as available. The kernel gives it back the moment anyone asks, which leaves $available of $total up for grabs."
        "Today's forecast for my PC: clear skies, light workloads and $pct% available memory. Expect $available of the installed $total to stay idle through the evening."
        "I hear RAM is hard to come by these days, so it feels a bit rude to be sitting on $available of it. Total installed: $total. It's not for sale, I just like knowing it's there."
        "I have a confession. I have $available of RAM that I'm not using, which is $pct% of the $total in this PC. I've told nobody but you and a cron job."
        "If $available of RAM sits idle in a PC and nobody allocates it, does it still count as capacity? Asking on behalf of the $pct% of my memory with nothing to do."
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

    email_subject=${subjects[$subject_index]}
    email_body="Hi Sam,

${bodies[$body_index]}

${signoffs[$signoff_index]}
${SENDER_NAME:-A concerned RAM owner}

--
Sent automatically, at most once a day, by a small script on one PC.
Reply if you'd like it to stop."
}


# The other side of the allocation debate: nothing left to allocate.
compose_crisis_email() {
    local total available swap_used swap_total
    total=$(to_gib "$total_kb")
    available=$(to_gib "$available_kb")
    swap_used=$(to_gib "$swap_used_kb")
    swap_total=$(to_gib "$swap_total_kb")

    local subjects=(
        "URGENT: The RAM has fallen. Swap is our last line of defense."
        "Memory humanitarian crisis: reserves exhausted"
        "A formal notice from the Department of Missing RAM"
        "There is no RAM left to report, Sam"
        "All available memory has been accounted for. Regrettably."
    )
    local bodies=(
        "I regret to inform you that the local RAM reserves have been exhausted. An emergency relocation programme is underway in swap. No unused memory can be offered at this time."
        "This is a formal request to suspend the investigation into idle RAM. The memory was located, allocated, and then some. Swap is currently handling the overflow with admirable restraint."
        "Today's global allocation audit found no hoarding. Physical RAM is effectively full; the overflow has occupied swap. We are no longer discussing waste. We are discussing disaster relief."
        "Unfortunately, the owner has taken the suggestion to use their RAM literally. The system has established a provisional government in swap space. Conditions remain tense."
        "I am pleased to report a utilization success and deeply displeased to report its consequences. Not a single spare gigabyte could be located. The storage subsystem has been asked to improvise."
        "Please update the global DRAM allocation ledger: this machine is not a source of spare capacity. It is actively accepting memory refugees in swap."
    )
    local signoffs=(
        "Reporting from the allocation front,"
        "Yours in critical condition,"
        "With no memory to spare,"
        "From the emergency memory committee,"
    )
    local subject_index body_index signoff_index
    subject_index=$(pick crisis_subject "${#subjects[@]}")
    body_index=$(pick crisis_body "${#bodies[@]}")
    signoff_index=$(pick crisis_signoff "${#signoffs[@]}")

    email_subject=${subjects[$subject_index]}
    email_body="Hi Sam,

${bodies[$body_index]}

Incident report:
  Total RAM:      $total
  RAM available:  $available ($available_pct%)
  Swap used:      $swap_used / $swap_total

${signoffs[$signoff_index]}
${SENDER_NAME:-A concerned RAM owner}

--
Sent automatically, at most once a day, by a small script on one PC.
Reply if you'd like it to stop."
}

compose_report() {
    if is_memory_crisis; then
        compose_crisis_email
    else
        compose_email
    fi
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
    case "${1:-}" in
        --status)
            read_memory
            print_status
            exit 0
            ;;
        --dry-run)
            DRY_RUN=1
            read_memory
            print_status
            if ! is_reportable; then
                echo "No email: RAM is neither above ${THRESHOLD_PCT}% available nor in crisis (<1% available and >10 GiB swap used)."
                exit 0
            fi
            compose_report
            RECIPIENT=${RECIPIENT:-recipient-not-set@example.com}
            SENDER=${SENDER:-sender-not-set@example.com}
            printf '\n'
            render_message
            exit 0
            ;;
        -h|--help)
            sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'
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

    read_memory
    log_sample

    is_reportable || exit 0

    local today last_sent
    today=$(date +%F)
    last_sent=$(cat "$LAST_SENT_FILE" 2>/dev/null || true)
    [[ "$last_sent" != "$today" ]] || exit 0

    compose_report
    send_email || die "email failed to send; will try again on the next run"

    # Recorded only after a successful send, so a failure gets retried.
    echo "$today" > "$LAST_SENT_FILE"
}

main "$@"
