#!/bin/bash
# hdd_validate.sh
# Interactive HDD validation + persistent history + real-time state (current_run.json)

set -euo pipefail

# ------------------ CONFIG ------------------
MAX_TEMP="${MAX_TEMP:-45}"          # Celsius emergency stop threshold
MAX_BATCH="${MAX_BATCH:-4}"         # Phase B max drives
BLOCK_SIZE="${BLOCK_SIZE:-4096}"    # safe baseline for modern HDDs
LOG_ROOT="${LOG_ROOT:-/var/log}"    # run logs root

STATE_DIR="${STATE_DIR:-/var/lib/hdd_burnin}"
DRIVES_DB="$STATE_DIR/drives.tsv"
RUNS_DB="$STATE_DIR/runs.tsv"
CURRENT_RUN_JSON="$STATE_DIR/current_run.json"

SMART_TIMEOUT="${SMART_TIMEOUT:-5}" # seconds for smartctl calls (prevents hangs on failing drives)

# Must-fix: validate SMART_TIMEOUT early without die()/SUMMARY dependency
if [[ ! "$SMART_TIMEOUT" =~ ^[0-9]+$ ]] || [[ "$SMART_TIMEOUT" -lt 1 ]]; then
  echo "[FATAL] SMART_TIMEOUT must be a positive integer (got: $SMART_TIMEOUT)" >&2
  exit 1
fi

RUN_ID="$(date +%Y%m%d_%H%M%S)"
LOG_DIR="$LOG_ROOT/hdd_validate_$RUN_ID"
mkdir -p "$LOG_DIR"
SUMMARY="$LOG_DIR/SUMMARY.txt"

# ------------------ DEP CHECK ------------------
need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 1; }; }
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

# ------------------ GLOBALS ------------------
die() { echo "[FATAL] $*" | tee -a "$SUMMARY"; exit 1; }
ts_now() { date -Is; }

declare -a ACTIVE_PIDS=()
declare -A TEMP_MAX
SELECTED=()
CURRENT_PHASE="IDLE"
CURRENT_STATUS="idle"
PHASE_STARTED_AT=""

# ------------------ TEXT/TSV HELPERS ------------------
clean_field() {
  # TSV-safe: remove tabs/newlines and also '|' (prevents downstream parsing/injection issues)
  echo "${1:-}" | tr '\t\r\n|' '    ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
}

json_escape() {
  local s="${1:-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/ }"
  s="${s//$'\r'/ }"
  printf "%s" "$s"
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
  out="$(timeout "$SMART_TIMEOUT" smartctl -i "$d" 2>/dev/null || true)"
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
    out="$(timeout "$SMART_TIMEOUT" smartctl -i "$dev" 2>/dev/null || true)"
    wwn="$(echo "$out" | awk -F: '/WWN|World Wide Name|LU WWN Device Id/ {gsub(/^[ \t]+/,"",$2); print $2; exit}' || true)"
  fi
  echo "${wwn:-}"
}

best_sn() {
  local dev="$1" sn wwn
  sn="$(get_serial "$dev")"
  if [[ "$sn" != "UNKNOWN_SN" && -n "$sn" ]]; then
    echo "$sn"; return 0
  fi
  wwn="$(get_wwn "$dev")"
  if [[ -n "$wwn" ]]; then
    echo "WWN_${wwn}"; return 0
  fi
  echo "DEV_$(basename "$dev")"
}

sanitize() { echo "${1:-}" | tr -c 'A-Za-z0-9._-' '_' ; }

best_by_id() {
  local dev="$
