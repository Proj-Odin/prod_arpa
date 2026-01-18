#!/bin/bash
# hdd_validate.sh
# Interactive HDD validation with persistent history + hardened safety:
# - Persistent registry/history in /var/lib/hdd_burnin/
# - Phase 0: SMART triage (short+conveyance+long) + logs + outcome
# - Phase B: DESTRUCTIVE badblocks -w (max 4 drives) + temps + SMART before/after + outcome
# - HARDENED:
#     (1) Temp polling uses timeout to avoid smartctl hangs
#     (2) Signal handling + cleanup via trap kills active badblocks jobs
#     (3) Error handling: SMART read failures become WARN (not silent PASS)
#
# NOTE: Phase B is destructive. It will erase selected drives.

set -euo pipefail

# ------------------ CONFIG ------------------
MAX_TEMP="${MAX_TEMP:-45}"          # Celsius emergency stop threshold
MAX_BATCH="${MAX_BATCH:-4}"         # max drives allowed for Phase B at once
BLOCK_SIZE="${BLOCK_SIZE:-4096}"    # safe baseline for modern HDDs
LOG_ROOT="${LOG_ROOT:-/var/log}"    # where to store run logs

STATE_DIR="${STATE_DIR:-/var/lib/hdd_burnin}"
DRIVES_DB="$STATE_DIR/drives.tsv"
RUNS_DB="$STATE_DIR/runs.tsv"

SMART_TIMEOUT="${SMART_TIMEOUT:-5}" # seconds for smartctl calls in temp polling
RUN_ID="$(date +%Y%m%d_%H%M%S)"
LOG_DIR="$LOG_ROOT/hdd_validate_$RUN_ID"
mkdir -p "$LOG_DIR"
SUMMARY="$LOG_DIR/SUMMARY.txt"

# ------------------ DEP CHECK ------------------
need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1"; exit 1; }; }
need smartctl
need badblocks
need lsblk
need udevadm
need findmnt
need awk
need sed
need sort
need readlink
need grep
need date
need timeout

if [[ $EUID -ne 0 ]]; then echo "Run as root (sudo)."; exit 1; fi

# ------------------ GLOBALS / CLEANUP ------------------
die() { echo "[FATAL] $*" | tee -a "$SUMMARY"; exit 1; }
ts_now() { date -Is; }

declare -a ACTIVE_PIDS=()
declare -A TEMP_MAX
SELECTED=()

cleanup() {
  local code=$?
  if [[ "${#ACTIVE_PIDS[@]}" -gt 0 ]]; then
    echo "[CLEANUP] Stopping running jobs (pids): ${ACTIVE_PIDS[*]}" | tee -a "$SUMMARY" || true
    for pid in "${ACTIVE_PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
    sleep 1
    for pid in "${ACTIVE_PIDS[@]}"; do kill -9 "$pid" 2>/dev/null || true; done
  fi
  exit "$code"
}

trap cleanup INT TERM

# ------------------ TSV HELPERS ------------------
clean_field() {
  echo "${1:-}" | tr '\t\r\n' '   ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
}

# ------------------ DB INIT ------------------
init_db() {
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"

  if [[ ! -f "$DRIVES_DB" ]]; then
    printf "sn\twwn\tmodel\tsize_bytes\tfirst_seen\tlast_seen\tnotes\n" > "$DRIVES_DB"
    chmod 600 "$DRIVES_DB"
  fi

  if [[ ! -f "$RUNS_DB" ]]; then
    printf "run_id\tts\tphase\toutcome\tsn\twwn\tmodel\tsize_bytes\tpoh\trealloc\tpending\toffline_unc\tudma_crc\ttemp_max\tlog_dir\n" > "$RUNS_DB"
    chmod 600 "$RUNS_DB"
  fi
}

# ------------------ DEVICE HELPERS ------------------
root_base_disk() {
  local root_src base
  root_src="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
  base="$(lsblk -no PKNAME "$root_src" 2>/dev/null || true)"
  [[ -n "$base" ]] && echo "/dev/$base" || echo ""
}

resolve_dev() { readlink -f "$1" 2>/dev/null || echo "$1"; }

is_whole_disk() { [[ "$(lsblk -no TYPE "$1" 2>/dev/null || true)" == "disk" ]]; }

is_mounted_somewhere() { lsblk -no MOUNTPOINT "${1}"* 2>/dev/null | grep -qE '\S'; }

get_serial() {
  local d="$1" out sn
  out="$(smartctl -i "$d" 2>/dev/null || true)"
  sn="$(echo "$out" | awk -F: '/Serial Number/ {gsub(/^[ \t]+/,"",$2); print $2; exit}' || true)"
  if [[ -z "${sn:-}" ]]; then
    sn="$(udevadm info --query=property --name="$d" 2>/dev/null | awk -F= '/^ID_SERIAL_SHORT=/ {print $2; exit}' || true)"
  fi
  [[ -n "${sn:-}" ]] && echo "$sn" || echo "UNKNOWN_SN"
}

get_wwn() {
  local dev="$1" wwn out
  wwn="$(udevadm info --query=property --name="$dev" 2>/dev/null | awk -F= '/^ID_WWN=/{print $2; exit}' || true)"
  if [[ -z "${wwn:-}" ]]; then
    out="$(smartctl -i "$dev" 2>/dev/null || true)"
    wwn="$(echo "$out" | awk -F: '/WWN|World Wide Name|LU WWN Device Id/ {gsub(/^[ \t]+/,"",$2); print $2; exit}' || true)"
  fi
  echo "${wwn:-}"
}

sanitize() { echo "${1:-}" | tr -c 'A-Za-z0-9._-' '_' ; }

be
