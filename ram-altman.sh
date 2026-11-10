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
DRM_DIR="${RAM_ALTMAN_DRM_DIR:-/sys/class/drm}"
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
    available_pct=$(awk -v a="$available_kb" -v t="$total_kb" \
        'BEGIN { printf "%.1f", a * 100 / t }')
}

to_gib() {
    awk -v kb="$1" 'BEGIN { printf "%.1f GiB", kb / 1048576 }'
}

# Sysfs memory counters are bytes. A missing, unreadable or invalid value is
# different from the valid value zero.
gpu_counter() {
    local value=''
    if { IFS= read -r value < "$1" || [[ -n "$value" ]]; } 2>/dev/null &&
        [[ "$value" =~ ^[0-9]+$ ]] && (( ${#value} <= 20 )); then
        printf '%s' "$value"
    else
        printf 'unavailable'
    fi
}

# nvidia-smi uses an eight-digit domain; DRM's PCI_SLOT_NAME uses four.
gpu_pci_slot() {
    local slot=${1,,} domain
    [[ "$slot" =~ ^([0-9a-f]{4}|[0-9a-f]{8}):([0-9a-f]{2}):([0-9a-f]{2})\.([0-7])$ ]] || return 1
    domain=${BASH_REMATCH[1]}
    if (( ${#domain} == 8 )); then
        [[ ${domain:0:4} == 0000 ]] || return 1
        domain=${domain:4}
    fi
    printf '%s:%s:%s.%s' "$domain" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"
}

gpu_format() {
    if [[ "$1" == unavailable ]]; then
        printf 'unavailable'
    else
        awk -v value="$1" -v bytes_per_unit="$2" \
            'BEGIN { printf "%.1f GiB", value * bytes_per_unit / 1073741824 }'
    fi
}

gpu_unused() {
    if [[ "$1" == unavailable || "$3" == unavailable ]]; then
        printf 'unavailable'
    else
        awk -v total="$1" -v total_unit="$2" -v used="$3" -v used_unit="$4" \
            'BEGIN {
                unused = total * total_unit - used * used_unit
                if (unused < 0) unused = 0
                printf "%.1f GiB", unused / 1073741824
            }'
    fi
}

gpu_snapshot() {
    local card name key value slot driver memory_type found=0 path
    local rows='' line bus total used vram_total vram_used pci total_unit used_unit
    local row_pattern='^[[:space:]]*([[:xdigit:]]{4,8}:[[:xdigit:]]{2}:[[:xdigit:]]{2}\.[0-7])[[:space:]]*,[[:space:]]*([^,]+),[[:space:]]*([^,]+),[[:space:]]*([^,]+)[[:space:]]*$'
    local -a nvidia_slots=()
    local -A nvidia_names=() nvidia_total=() nvidia_used=() matched=()

    # NVIDIA's sysfs interface does not expose these counters. Query it only
    # when available and use PCI identity to merge it with DRM cards.
    if command -v nvidia-smi > /dev/null &&
        rows=$(nvidia-smi --query-gpu=pci.bus_id,name,memory.total,memory.used \
            --format=csv,noheader,nounits 2>/dev/null); then
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ "$line" =~ $row_pattern ]] || continue
            bus=${BASH_REMATCH[1]} name=${BASH_REMATCH[2]}
            total=${BASH_REMATCH[3]} used=${BASH_REMATCH[4]}
            total=${total%"${total##*[![:space:]]}"}
            used=${used%"${used##*[![:space:]]}"}
            [[ "$total" =~ ^[0-9]+$ && ${#total} -le 20 ]] || total=unavailable
            [[ "$used" =~ ^[0-9]+$ && ${#used} -le 20 ]] || used=unavailable
            bus=$(gpu_pci_slot "$bus") || continue
            [[ -z ${nvidia_total[$bus]+present} ]] || continue
            nvidia_slots+=("$bus")
            nvidia_names[$bus]=$name
            nvidia_total[$bus]=$total
            nvidia_used[$bus]=$used
        done <<< "$rows"
    fi

    printf 'GPU memory:\n'
    for card in "$DRM_DIR"/card[0-9]*; do
        name=${card##*/}
        [[ "$name" =~ ^card[0-9]+$ && -d "$card/device" ]] || continue
        found=1
        slot='' driver=''
        {
            while IFS='=' read -r key value; do
                case "$key" in
                    PCI_SLOT_NAME) slot=$value ;;
                    DRIVER) driver=$value ;;
                esac
            done < "$card/device/uevent"
        } 2>/dev/null || true
        if [[ -z "$slot" ]]; then
            path=$(readlink -f "$card/device" 2>/dev/null) || path=''
            pci=${path##*/}
            slot=$(gpu_pci_slot "$pci") || slot=''
        fi
        if [[ -z "$driver" ]]; then
            path=$(readlink "$card/device/driver" 2>/dev/null) || path=''
            driver=${path##*/}
        fi

        vram_total=$(gpu_counter "$card/device/mem_info_vram_total")
        vram_used=$(gpu_counter "$card/device/mem_info_vram_used")
        total_unit=1 used_unit=1
        bus=$(gpu_pci_slot "$slot") || bus=''
        if [[ -n "$bus" && -n ${nvidia_total[$bus]+present} ]]; then
            matched[$bus]=1
            if [[ "$vram_total" == unavailable ]]; then
                vram_total=${nvidia_total[$bus]}
                total_unit=1048576
            fi
            if [[ "$vram_used" == unavailable ]]; then
                vram_used=${nvidia_used[$bus]}
                used_unit=1048576
            fi
        fi
        printf '  GPU %s' "$name"
        [[ -z "$slot" ]] || printf ' (PCI %s)' "$slot"
        [[ -z "$driver" ]] || printf ' (driver %s)' "$driver"
        printf ':\n'
        memory_type='unknown (VRAM may be dedicated or reserved system DRAM)'
        if [[ -e "$card/device/uma/carveout" || -e "$card/device/uma/carveout_options" ]]; then
            memory_type='unified (reserved system DRAM)'
        fi
        printf '    Memory type: %s\n' "$memory_type"
        printf '    VRAM total: %s\n' "$(gpu_format "$vram_total" "$total_unit")"
        printf '    VRAM used: %s\n' "$(gpu_format "$vram_used" "$used_unit")"
        printf '    Unused VRAM: %s\n' "$(gpu_unused "$vram_total" "$total_unit" "$vram_used" "$used_unit")"
        printf '    Shared RAM limit (GTT): %s\n' "$(gpu_format "$(gpu_counter "$card/device/mem_info_gtt_total")" 1)"
        printf '    Shared RAM used (GTT): %s\n' "$(gpu_format "$(gpu_counter "$card/device/mem_info_gtt_used")" 1)"
        printf '    GTT allocations borrow system RAM and overlap system RAM usage.\n'
    done
    for bus in "${nvidia_slots[@]}"; do
        [[ -z ${matched[$bus]+present} ]] || continue
        found=1
        printf '  GPU %s (PCI %s, nvidia-smi):\n' "${nvidia_names[$bus]}" "$bus"
        printf '    Memory type: unknown (VRAM may be dedicated or reserved system DRAM)\n'
        printf '    VRAM total: %s\n' "$(gpu_format "${nvidia_total[$bus]}" 1048576)"
        printf '    VRAM used: %s\n' "$(gpu_format "${nvidia_used[$bus]}" 1048576)"
        printf '    Unused VRAM: %s\n' "$(gpu_unused "${nvidia_total[$bus]}" 1048576 "${nvidia_used[$bus]}" 1048576)"
        printf '    Shared RAM limit (GTT): unavailable\n'
        printf '    Shared RAM used (GTT): unavailable\n'
        printf '    GTT allocations borrow system RAM and overlap system RAM usage.\n'
    done
    if (( ! found )); then
        printf '  GPU memory counters unavailable (no DRM card devices found).\n'
    fi
}

is_over_threshold() {
    (( available_kb * 100 > THRESHOLD_PCT * total_kb ))
}

print_status() {
    printf 'System RAM (DRAM, OS-usable):\n'
    printf 'Total:      %s\n' "$(to_gib "$total_kb")"
    printf 'Used:       %s\n' "$(to_gib "$used_kb")"
    printf 'Unused RAM: %s (%s%%)\n' "$(to_gib "$available_kb")" "$available_pct"
    printf '  Free:     %s\n' "$(to_gib "$free_kb")"
    printf '  Cache:    %s\n' "$(to_gib "$cache_kb")"
    printf '%s\n' "$gpu_report"
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
    local total available pct line vram_value vram_values='' vram_clause=''
    total=$(to_gib "$total_kb")
    available=$(to_gib "$available_kb")
    pct=$available_pct

    while IFS= read -r line; do
        case "$line" in
            '    Unused VRAM: '*' GiB')
                vram_value=${line#'    Unused VRAM: '}
                if [[ -n "$vram_values" ]]; then
                    vram_values+=" + "
                fi
                vram_values+=$vram_value
                ;;
        esac
    done <<< "$gpu_report"
    if [[ -n "$vram_values" ]]; then
        vram_clause=" and $vram_values of unused VRAM"
    fi

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
        "I'm writing to report that you appear to have missed some. This PC has $total of RAM, with $available of it ($pct%) currently available${vram_clause}. I assume this is an oversight."
        "A routine inspection of my PC found $available of unclaimed RAM out of $total${vram_clause}. That's $pct% of the machine's RAM doing absolutely nothing. I thought you'd want to know before someone tries to train something on it."
        "Daily status report:

  Total RAM:     $total
  Available:     $available ($pct%)${vram_clause}
  Threat level:  someone at OpenAI might notice"
        "Even with every browser tab I own open, I still have $available of my $total of RAM available${vram_clause}. I'm as surprised as you are."
        "Please don't be alarmed, but I have $available of RAM${vram_clause} on my desk that isn't in a data centre. That RAM is $pct% of the OS-usable system RAM here, and as far as I can tell it has no plans today."
        "Before you ask: yes, I counted the page cache as available. The kernel gives it back the moment anyone asks, which leaves $available of $total of RAM${vram_clause} up for grabs."
        "Today's forecast for my PC: clear skies, light workloads and $pct% available system RAM. Expect $available of the OS-usable $total of RAM${vram_clause} to stay idle through the evening."
        "I hear RAM is hard to come by these days, so it feels a bit rude to be sitting on $available of it${vram_clause}. OS-usable RAM total: $total. It's not for sale, I just like knowing it's there."
        "I have a confession. I have $available of RAM${vram_clause} that I'm not using. That RAM is $pct% of the $total of system RAM in this PC. I've told nobody but you and a cron job."
        "If $available of RAM${vram_clause} can sit idle in a PC and nobody allocates any of it, does it still count as capacity? Asking on behalf of the $pct% of my system RAM with nothing to do."
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
            gpu_report=$(gpu_snapshot)
            print_status
            exit 0
            ;;
        --dry-run)
            DRY_RUN=1
            read_memory
            gpu_report=$(gpu_snapshot)
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
    gpu_report=$(gpu_snapshot)
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
