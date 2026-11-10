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
# The thinking is done by ram-altman.ws, which is written in Whitespace: it
# parses /proc/meminfo, does the sums, decides whether an email is due, deals
# the templates and writes the email. Whitespace can only read stdin and write
# stdout, so this script does the chores it can't: files, the clock, the dice
# and sendmail. ram-altman.wsa is the readable source, and says exactly what
# goes in and what comes back.

set -euo pipefail

# ----- Settings: fill these in -----------------------------------------------
RECIPIENT="${RAM_ALTMAN_TO:-}"             # Who receives the email
SENDER="${RAM_ALTMAN_FROM:-}"              # A real address you can send from
SENDER_NAME="${RAM_ALTMAN_FROM_NAME:-}"    # Display name, optional
THRESHOLD_PCT="${RAM_ALTMAN_THRESHOLD:-10}" # Email when available is above this
# -----------------------------------------------------------------------------

HERE=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
PROGRAM="$HERE/ram-altman.ws"
INTERPRETER="${RAM_ALTMAN_INTERPRETER:-}"  # e.g. wspace; default: ws/interpret.awk
MEMINFO="${RAM_ALTMAN_MEMINFO:-/proc/meminfo}"
STATE_DIR="${RAM_ALTMAN_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/ram-altman}"
USAGE_LOG="$STATE_DIR/usage.csv"
LAST_SENT_FILE="$STATE_DIR/last_sent"
MAX_LOG_BYTES=$((10 * 1024 * 1024))   # Trim the log once it passes 10 MiB
LOG_LINES_TO_KEEP=50000
TODAY=$(date +%F)

# cron's PATH often leaves out the directories sendmail lives in.
export PATH="$PATH:/usr/sbin:/sbin"

die() {
    printf 'ram-altman: %s\n' "$*" >&2
    exit 1
}

whitespace() {
    if [[ -n "$INTERPRETER" ]]; then
        $INTERPRETER "$PROGRAM"
    else
        LC_ALL=C awk -f "$HERE/ws/interpret.awk" "$PROGRAM"
    fi
}

# Everything ram-altman.ws reads, one value per line, in the order it reads it.
program_input() {
    local mode=$1 last_sent list bag last
    last_sent=$(cat "$LAST_SENT_FILE" 2>/dev/null || true)
    last_sent=${last_sent//-/}
    [[ "$last_sent" =~ ^[0-9]+$ ]] || last_sent=0

    printf '%s\n' "$mode" "$THRESHOLD_PCT" "${TODAY//-/}" "$last_sent" \
        "$(( RANDOM * 32768 + RANDOM ))"

    for list in subject body signoff; do
        bag=
        if [[ -f "$STATE_DIR/bag_$list" ]]; then
            bag=$(tr -cd '0-9' < "$STATE_DIR/bag_$list")
        fi
        last=$(cat "$STATE_DIR/bag_$list.last" 2>/dev/null || true)
        [[ "$last" =~ ^[0-9]+$ ]] || last=-1
        printf '%s\n' "$bag" "$last"
    done

    printf '%s\n' "${SENDER_NAME//$'\n'/ }" "${SENDER//$'\n'/}" \
        "${RECIPIENT//$'\n'/}" "$(date -R)"
    cat "$MEMINFO"
    printf '\nEOF: 0\n'
}

# Runs ram-altman.ws in the given mode and prints what it says.
think() {
    local reply
    reply=$(program_input "$1" | whitespace) ||
        die "the Whitespace interpreter failed"
    [[ "$reply" != '!'* ]] || die "${reply#!} in $MEMINFO"
    printf '%s\n' "$reply"
}

log_sample() {
    [[ -f "$USAGE_LOG" ]] ||
        echo 'timestamp,total_kb,used_kb,available_kb,available_pct' > "$USAGE_LOG"
    printf '%s,%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$1" >> "$USAGE_LOG"

    if (( $(wc -c < "$USAGE_LOG") > MAX_LOG_BYTES )); then
        {
            head -n 1 "$USAGE_LOG"
            tail -n "$LOG_LINES_TO_KEEP" "$USAGE_LOG"
        } > "$USAGE_LOG.tmp"
        mv "$USAGE_LOG.tmp" "$USAGE_LOG"
    fi
}

# What's left of a template list's shuffled bag, and what was dealt from it.
save_bag() {
    local list=$1 last=$2 bag=${3:-}
    case "$list" in subject|body|signoff) ;; *) return ;; esac
    printf '%s\n' "$bag" > "$STATE_DIR/bag_$list"
    printf '%s\n' "$last" > "$STATE_DIR/bag_$list.last"
}

send_email() {
    local message=$1 subject
    if command -v sendmail > /dev/null; then
        printf '%s' "$message" | sendmail -t -i
    elif command -v msmtp > /dev/null; then
        printf '%s' "$message" | msmtp -t
    elif command -v mail > /dev/null; then
        subject=$(sed -n '/^$/q; s/^Subject: //p' <<< "$message")
        printf '%s' "${message#*$'\n\n'}" | mail -s "$subject" "$RECIPIENT"
    else
        echo 'ram-altman: no sendmail, msmtp or mail command found' >&2
        return 1
    fi
}

main() {
    local mode
    case "${1:-}" in
        --status)
            mode=1
            ;;
        --dry-run)
            mode=2
            RECIPIENT=${RECIPIENT:-recipient-not-set@example.com}
            SENDER=${SENDER:-sender-not-set@example.com}
            ;;
        -h|--help)
            sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        "")
            mode=3
            ;;
        *)
            die "unknown option: $1 (try --help)"
            ;;
    esac

    [[ "$THRESHOLD_PCT" =~ ^[0-9]+$ ]] ||
        die "RAM_ALTMAN_THRESHOLD must be a whole number"
    [[ -r "$MEMINFO" ]] || die "cannot read $MEMINFO (this script needs Linux)"

    if (( mode < 3 )); then
        think "$mode"
        exit 0
    fi

    [[ -n "$RECIPIENT" ]] || die "RECIPIENT is not set"
    [[ -n "$SENDER" ]] || die "SENDER is not set"

    mkdir -p "$STATE_DIR"

    # Stop overlapping runs from both sending today's email.
    if command -v flock > /dev/null; then
        exec 9> "$STATE_DIR/lock"
        flock -n 9 || exit 0
    fi

    local reply line message='' mailing='' list last bag
    reply=$(think 3)
    while IFS= read -r line; do
        if [[ -n "$mailing" ]]; then
            message+=$line$'\n'
            continue
        fi
        case "$line" in
            'LOG '*) log_sample "${line#LOG }" ;;
            'BAG '*)
                read -r _ list last bag <<< "$line"
                save_bag "$list" "$last" "$bag"
                ;;
            MAIL) mailing=1 ;;
        esac
    done <<< "$reply"

    [[ -n "$mailing" ]] || exit 0

    send_email "$message" || die "email failed to send; will try again on the next run"

    # Recorded only after a successful send, so a failure gets retried.
    echo "$TODAY" > "$LAST_SENT_FILE"
}

main "$@"
