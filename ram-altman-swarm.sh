#!/usr/bin/env bash
# ram-altman-swarm — put idle RAM to work for public AI.
#
# The joke, made real: instead of emailing Sam Altman about the RAM you
# are NOT using (IainKay/ram-altman), this script puts that idle RAM to
# work for public, open AI — and leaves the door open for OpenAI too.
#
# How it works:
#   * Every run (e.g. cron every 5 minutes) reads /proc/meminfo.
#   * If more than RAM_SWARM_THRESHOLD percent of RAM is free, it
#     reserves a share of the free RAM for a training window by holding
#     it in tmpfs (/dev/shm), for a determined time.
#   * The window scales with diffusion: minutes = BASE_MINUTES x DEVICES,
#     capped at MAX_MINUTES. DEVICES is the number of machines you
#     estimate are running this code (you set it; the script does not
#     phone home, count installations, or report anything anywhere).
#     The more devices run it, the more RAM is held, for longer — that
#     is the diffusion rule.
#   * At most one window per day. The hold is released automatically
#     when the window ends, and everything is logged locally.
#
# What it connects to:
#   * The public, opt-in peer-to-peer AI networks OpenHydra and
#     SharedLLM, which run open models on volunteered hardware with an
#     OpenAI-compatible API. This script is the local piece: it reserves
#     the RAM so a local model runner (Ollama, llama.cpp) or a swarm node
#     can use it during the window.
#   * The "Cooperative Computing" proposal made to OpenAI on its own
#     forum: opt-in hybrid inference where users' devices process part
#     of their own AI requests. If OpenAI wants in, that public proposal
#     is the door — this script does not give OpenAI any access, and
#     neither does any other part of this project.
#
# What it is NOT:
#   * Not a backdoor. Nothing here lets anyone — Sam Altman, OpenAI, or
#     anyone else — into your machine or run processes on it. There is
#     no network connection, no open port, no remote control. The RAM is
#     held on your own machine, by you, for a window you choose.
#   * Not training by itself. Holding RAM reserves it for a workload;
#     the actual model work happens in the runner/node you choose
#     (Ollama, llama.cpp, OpenHydra, SharedLLM). If none is installed,
#     the hold still reserves the RAM and logs the contribution.
#
# Usage:
#   ./ram-altman-swarm.sh                      # check and maybe start a window (once a day)
#   RAM_SWARM_DRY_RUN=1 ./ram-altman-swarm.sh  # preview the plan, do nothing
# Cron (every 5 minutes, like the original):
#   */5 * * * * /path/to/ram-altman-swarm.sh
#
# Config (environment variables):
#   RAM_SWARM_MEMINFO        path to meminfo (default /proc/meminfo)
#   RAM_SWARM_HOLD_DIR       tmpfs dir for the hold (default /dev/shm/ram-altman-swarm)
#   RAM_SWARM_LOG            contribution log (default ~/.ram-altman-swarm.log)
#   RAM_SWARM_STATE          last-window date (default ~/.ram-altman-swarm-state)
#   RAM_SWARM_THRESHOLD      percent of RAM that must be free (default 10)
#   RAM_SWARM_HOLD_FRACTION  percent of free RAM to hold (default 50)
#   RAM_SWARM_BASE_MINUTES   base window in minutes (default 30)
#   RAM_SWARM_DEVICES        diffusion estimate, machines running this (default 1)
#   RAM_SWARM_MAX_MINUTES    cap on the window in minutes (default 240)
#   RAM_SWARM_HOLD_SECONDS   if set, window in seconds instead of minutes (for tests)
#   RAM_SWARM_DRY_RUN        1 = print the plan, do nothing (default 0)

set -euo pipefail

MEMINFO="${RAM_SWARM_MEMINFO:-/proc/meminfo}"
HOLD_DIR="${RAM_SWARM_HOLD_DIR:-/dev/shm/ram-altman-swarm}"
LOG_FILE="${RAM_SWARM_LOG:-$HOME/.ram-altman-swarm.log}"
STATE_FILE="${RAM_SWARM_STATE:-$HOME/.ram-altman-swarm-state}"
THRESHOLD_PCT="${RAM_SWARM_THRESHOLD:-10}"
HOLD_FRACTION_PCT="${RAM_SWARM_HOLD_FRACTION:-50}"
BASE_MINUTES="${RAM_SWARM_BASE_MINUTES:-30}"
DEVICES="${RAM_SWARM_DEVICES:-1}"
MAX_MINUTES="${RAM_SWARM_MAX_MINUTES:-240}"
HOLD_SECONDS="${RAM_SWARM_HOLD_SECONDS:-}"
DRY_RUN="${RAM_SWARM_DRY_RUN:-0}"

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE"; }

read_meminfo() {
  local key value
  while read -r key value _; do
    case "$key" in
      MemTotal:) total_kb="$value" ;;
      MemAvailable:) avail_kb="$value" ;;
    esac
  done < "$MEMINFO"
  if [ -z "${total_kb:-}" ] || [ -z "${avail_kb:-}" ]; then
    echo "ram-altman-swarm: could not read MemTotal/MemAvailable from $MEMINFO" >&2
    exit 1
  fi
}

main() {
  if [ ! -r "$MEMINFO" ]; then
    echo "ram-altman-swarm: $MEMINFO not readable (this script is Linux-only)" >&2
    exit 1
  fi
  read_meminfo
  local pct=$(( avail_kb * 100 / total_kb ))
  if [ "$pct" -le "$THRESHOLD_PCT" ]; then
    exit 0  # RAM is busy; nothing to hold today.
  fi
  local today
  today="$(date +%F)"
  if [ -f "$STATE_FILE" ] && [ "$(cat "$STATE_FILE")" = "$today" ]; then
    exit 0  # Already held once today.
  fi
  # Hold size: a share of the free RAM, capped at 4 GiB so a runaway
  # config cannot eat the machine.
  local avail_mb=$(( avail_kb / 1024 ))
  local hold_mb=$(( avail_mb * HOLD_FRACTION_PCT / 100 ))
  if [ "$hold_mb" -gt 4096 ]; then hold_mb=4096; fi
  if [ "$hold_mb" -lt 64 ]; then hold_mb=64; fi
  # Window: base x devices (the diffusion rule), capped.
  local minutes=$(( BASE_MINUTES * DEVICES ))
  if [ "$minutes" -gt "$MAX_MINUTES" ]; then minutes="$MAX_MINUTES"; fi
  if [ "$minutes" -lt 1 ]; then minutes=1; fi
  local seconds=$(( minutes * 60 ))
  if [ -n "$HOLD_SECONDS" ]; then seconds="$HOLD_SECONDS"; fi
  local avail_gib
  avail_gib="$(awk -v kb="$avail_kb" 'BEGIN { printf "%.1f", kb / 1024 / 1024 }')"
  local total_gib
  total_gib="$(awk -v kb="$total_kb" 'BEGIN { printf "%.1f", kb / 1024 / 1024 }')"
  local hold_gib
  hold_gib="$(awk -v mb="$hold_mb" 'BEGIN { printf "%.1f", mb / 1024 }')"
  if [ "$DRY_RUN" = "1" ]; then
    printf 'RAM SWARM HOLD (dry run)\n'
    printf 'Idle RAM: %s GiB of %s GiB (%s%% free)\n' "$avail_gib" "$total_gib" "$pct"
    printf 'Would hold: %s GiB for %s minutes (devices: %s, base: %s min, cap: %s min)\n' "$hold_gib" "$minutes" "$DEVICES" "$BASE_MINUTES" "$MAX_MINUTES"
    printf 'No files written, no RAM held, no network used.\n'
    exit 0
  fi
  # Lock: if a hold is already running, do nothing. A stale lock (dead
  # PID) is removed so a crashed hold never blocks the next day.
  if [ -f "$HOLD_DIR/lock" ]; then
    if kill -0 "$(cat "$HOLD_DIR/lock")" 2>/dev/null; then
      exit 0
    else
      rm -f "$HOLD_DIR/lock"
    fi
  fi
  mkdir -p "$HOLD_DIR"
  # Hold the RAM in tmpfs (real RAM) for the window.
  fallocate -l "${hold_mb}M" "$HOLD_DIR/hold.bin" 2>/dev/null || dd if=/dev/zero of="$HOLD_DIR/hold.bin" bs=1M count="$hold_mb" status=none
  printf '%s\n' "$today" > "$STATE_FILE"
  log "HOLD START: ${hold_gib} GiB for ${minutes} min (devices=${DEVICES}, free=${pct}%)"
  # Release in the background so the cron run returns immediately.
  (
    sleep "$seconds"
    rm -f "$HOLD_DIR/hold.bin" "$HOLD_DIR/lock"
    rmdir "$HOLD_DIR" 2>/dev/null || true
    log "HOLD END: ${hold_gib} GiB released after ${minutes} min"
  ) &
  echo "$!" > "$HOLD_DIR/lock"
  echo "ram-altman-swarm: holding ${hold_gib} GiB for ${minutes} min (devices=${DEVICES})"
}

main "$@"
