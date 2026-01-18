#!/bin/bash
# hdd_validate.sh
# Interactive HDD validation + persistent history + real-time state (current_run.json)
# Critical hardening:
# - ERR + EXIT trapping (not only INT/TERM)
# - temp abort goes through unified abort path and records ABORTED rows
# - flock lock prevents concurrent runs
# - Option B security: root:burnin 750 state/log dirs, 640 files
# - SMART health (-H), selftest logs, controller fallback (-d sat/scsi)
# - nice+ionice for badblocks
# - configurable PhaseB patterns via BADBLOCKS_PASSES (1..4)
# FIXES APPLIED:
# - TSV locking uses actual file (not separate .lock)
# - Badblocks passes wrap around pattern array (no OOB access)
# - System disk detection uses resolve_dev for comparison
# - Badblocks progress reporting via progress files

set -euo pipefail
export LC_ALL=C
umask 027

# ------------------ CONFIG ------------------
BURNIN_GROUP="${BURNIN_GROUP:-burnin}"

MAX_TEMP="${MAX_TEMP:-45}"          # Celsius emergency stop threshold
MAX_PHASE0="${MAX_PHASE0:-4}"       # Phase 0 max drives (menu)
MAX_PHASEB="${MAX_PHASEB:-3}"       # Phase B max drives (destructive)

BLOCK_SIZE="${BLOCK_SIZE:-4096}"    # baseline
SMART_TIMEOUT="${SMART_TIMEOUT:-5}" # seconds for smartctl calls (prevents hangs)
BADBLOCKS_PASSES="${BADBLOCKS_PASSES:-4}" # 1..4 patterns (wraps if >4)
LOG_ROOT="${LOG_ROOT:-/var/log}"

STATE_DIR="${STATE_DIR:-/var/lib/hdd_burnin}"
DRIVES_DB="$STATE_DIR/drives.tsv"
RUNS_DB="$STATE_DIR/runs.tsv"
CURRENT_RUN_JSON="$STATE_DIR/current_run.json"

LOCK_FILE="/var/lock/hdd_validate.lock"

# Validate config early
if [[ ! "$SMART_TIMEOUT" =~ ^[0-9]+$ ]] || [[ "$SMART_TIMEOUT" -lt 1 ]]; then
  echo "[FATAL] SMART_TIMEOUT must be a positive integer (got: $SMART_TIMEOUT)" >&2
  exit 1
fi
if [[ ! "$BADBLOCKS_PASSES" =~ ^[0-9]+$ ]] || [[ "$BADBLOCKS_PASSES" -lt 1 ]]; then
  echo "[FATAL] BADBLOCKS_PASSES must be >= 1 (got: $BADBLOCKS_PASSES)" >&2
  exit 1
fi

if [[ $EUID -ne 0 ]]; then echo "Run as root (sudo)."; exit 1; fi

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
need flock
need ionice
need nice
need dmesg

# ------------------ GLOBALS ------------------
RUN_ID="$(date +%Y%m%d_%H%M%S)"
LOG_DIR="$LOG_ROOT/hdd_validate_$RUN_ID"
SUMMARY="$LOG_DIR/SUMMARY.txt"

declare -a ACTIVE_PIDS=()
declare -A TEMP_MAX
declare -A SMART_DOPT
declare -A PH0_PRE_OK
declare -A PH0_POST_OK

SELECTED=()
CURRENT_PHASE="IDLE"
CURRENT_STATUS="idle"
PHASE_STARTED_AT=""
ABORT_REASON=""
ABORTING="false"
COMPLETED="false"

ts_now() { date -Is; }

# ------------------ Setup dirs with Option B perms ------------------
install -d -m 0750 -o root -g "$BURNIN_GROUP" "$STATE_DIR"
install -d -m 0750 -o root -g "$BURNIN_GROUP" "$LOG_DIR"
touch "$SUMMARY"
chown root:"$BURNIN_GROUP" "$SUMMARY"
chmod 0640 "$SUMMARY"

# ------------------ Lock (no concurrent runs) ------------------
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "[FATAL] Another hdd_validate.sh is already running (lock: $LOCK_FILE)" >&2
  exit 1
fi

# ------------------ HELPERS ------------------
die() { echo "[FATAL] $*" | tee -a "$SUMMARY"; abort_run "fatal: $*"; }

clean_field() { echo "${1:-}" | tr '\t\r\n|' '    ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'; }

json_escape() {
  local s="${1:-}"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="${s//$'\n'/ }"; s="${s//$'\r'/ }"
  printf "%s" "$s"
}

resolve_dev() { readlink -f "$1" 2>/dev/null || echo "$1"; }
is_whole_disk() { [[ "$(lsblk -no TYPE "$1" 2>/dev/null || true)" == "disk" ]]; }
is_mounted_somewhere() { lsblk -no MOUNTPOINT "${1}"* 2>/dev/null | grep -qE '\S'; }

sanitize() { echo "${1:-}" | tr -c 'A-Za-z0-9._-' '_' ; }

# ------------------ DB INIT ------------------
init_db() {
  if [[ ! -f "$DRIVES_DB" ]]; then
    printf "sn\twwn\tmodel\tsize_bytes\tfirst_seen\tlast_seen\tnotes\n" > "$DRIVES_DB"
    chown root:"$BURNIN_GROUP" "$DRIVES_DB"; chmod 0640 "$DRIVES_DB"
  fi
  if [[ ! -f "$RUNS_DB" ]]; then
    printf "run_id\tts\tphase\toutcome\tsn\twwn\tmodel\tsize_bytes\tpoh\trealloc\tpending\toffline_unc\tudma_crc\tsmart_health\ttemp_max\tlog_dir\n" > "$RUNS_DB"
    chown root:"$BURNIN_GROUP" "$RUNS_DB"; chmod 0640 "$RUNS_DB"
  fi
  if [[ ! -f "$CURRENT_RUN_JSON" ]]; then
    cat > "$CURRENT_RUN_JSON" <<EOF
{"run_id":"","status":"idle","phase":"IDLE","phase_started_at":"","last_update":"","max_temp_c":0,"block_size":0,"max_phase0":0,"max_phaseb":0,"badblocks_passes":0,"log_dir":"","summary_path":"","drives_text":"","drives_dev_text":"","abort_reason":"","temp_max_c":{}}
EOF
    chown root:"$BURNIN_GROUP" "$CURRENT_RUN_JSON"; chmod 0640 "$CURRENT_RUN_JSON"
  fi
}

# ------------------ SMART wrapper (tries small -d fallbacks) ------------------
smart_try() {
  local dev="$1"; shift
  local out rc
  out="$(timeout "$SMART_TIMEOUT" smartctl "$@" "$dev" 2>/dev/null || true)"
  rc=$?
  if [[ -n "$out" ]]; then
    printf "%s" "$out"
    return 0
  fi
  return 1
}

smart_cmd() {
  local dev="$1"
  if [[ -n "${SMART_DOPT[$dev]:-}" ]]; then
    echo "${SMART_DOPT[$dev]}"
    return 0
  fi
  # Try default, then sat, then scsi (covers most cases)
  local opt
  for opt in "" "-d sat" "-d scsi" ; do
    if smart_try "$dev" ${opt} -i >/dev/null; then
      SMART_DOPT[$dev]="$opt"
      echo "$opt"
      return 0
    fi
  done
  SMART_DOPT[$dev]=""
  echo ""
  return 0
}

smart_out() {
  local dev="$1"; shift
  local opt; opt="$(smart_cmd "$dev")"
  timeout "$SMART_TIMEOUT" smartctl ${opt} "$@" "$dev" 2>/dev/null || true
}

smart_dump_x() {
  local dev="$1" outfile="$2"
  smart_out "$dev" -x > "$outfile"
  [[ -s "$outfile" ]]
}

smart_health() {
  local dev="$1"
  local o; o="$(smart_out "$dev" -H)"
  if echo "$o" | grep -qiE "SMART overall-health self-assessment test result:.*PASSED"; then
    echo "PASSED"
  elif echo "$o" | grep -qiE "SMART.*FAILED|FAILED!"; then
    echo "FAILED"
  else
    echo "UNKNOWN"
  fi
}

smart_attr() {
  local dev="$1" name="$2"
  smart_out "$dev" -A | awk -v n="$name" '$1==n {print $10; exit}' | sed -E 's/[^0-9].*//; t; s/.*/0/' | head -n1
}

temp_of() {
  local dev="$1"
  smart_out "$dev" -A | awk '
    /Temperature_Celsius|Temperature_Internal|Airflow_Temperature_Cel/ {print $10; exit}
    /Current Drive Temperature/ {print $4; exit}
    /^Temperature:/ {print $2; exit}
  ' | sed -E 's/[^0-9].*//' | head -n1 || true
}

selftest_log() {
  local dev="$1" outfile="$2"
  smart_out "$dev" -l selftest > "$outfile"
  [[ -s "$outfile" ]]
}

error_log() {
  local dev="$1" outfile="$2"
  smart_out "$dev" -l error > "$outfile"
  [[ -s "$outfile" ]]
}

selftest_has_failure() {
  local f="$1"
  # catches typical failure strings; not perfect, but useful
  grep -qiE "read failure|write failure|completed:.*failure|Completed:.*failure|Completed:.*error|Interrupted.*host reset|self-test.*failed" "$f"
}

# ------------------ Identify system disks (extra safety) ------------------
system_disks() {
  # Collect mounted sources and map down to disk(s).
  local src dev
  local -a disks=()

  while read -r src; do
    [[ -z "$src" ]] && continue
    [[ "$src" =~ ^/dev/ ]] || continue
    dev="$(resolve_dev "$src")"
    # lsblk subtree of dev; collect disks in that chain
    while read -r name type; do
      [[ "$type" == "disk" ]] && disks+=("/dev/$name")
    done < <(lsblk -rno NAME,TYPE "$dev" 2>/dev/null || true)
  done < <(findmnt -rn -o SOURCE 2>/dev/null | sort -u)

  # also include swap devices
  while read -r src; do
    [[ -z "$src" ]] && continue
    [[ "$src" =~ ^/dev/ ]] || continue
    dev="$(resolve_dev "$src")"
    while read -r name type; do
      [[ "$type" == "disk" ]] && disks+=("/dev/$name")
    done < <(lsblk -rno NAME,TYPE "$dev" 2>/dev/null || true)
  done < <(swapon --noheadings --raw --output=NAME 2>/dev/null | sort -u || true)

  # unique, resolve all to canonical paths
  printf "%s\n" "${disks[@]}" | awk 'NF' | sort -u | while read -r d; do
    resolve_dev "$d"
  done | sort -u
}

# ------------------ DB OPS ------------------
db_drive_exists() { awk -F'\t' -v sn="$1" 'NR>1 && $1==sn {f=1} END{exit(f?0:1)}' "$DRIVES_DB"; }

db_upsert_drive() {
  local sn="$1" wwn="$2" model="$3" sizeb="$4"
  local now; now="$(ts_now)"
  sn="$(clean_field "$sn")"; wwn="$(clean_field "$wwn")"; model="$(clean_field "$model")"; sizeb="$(clean_field "$sizeb")"
  [[ -z "$sn" ]] && return 0

  # FIX #1: Lock the actual DRIVES_DB file, not a separate .lock
  {
    flock -x 200
    if db_drive_exists "$sn"; then
      awk -F'\t' -v OFS='\t' -v sn="$sn" -v now="$now" -v wwn="$wwn" '
        NR==1 {print; next}
        $1==sn {
          $6=now
          if ($2=="" && wwn!="") $2=wwn
        }
        {print}
      ' "$DRIVES_DB" > "$DRIVES_DB.tmp" && mv "$DRIVES_DB.tmp" "$DRIVES_DB"
    else
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$sn" "$wwn" "$model" "$sizeb" "$now" "$now" "" >> "$DRIVES_DB"
    fi
  } 200>>"$DRIVES_DB"
}

db_last_run_summary() {
  local sn="$1"
  awk -F'\t' -v sn="$sn" 'NR>1 && $5==sn {last=$3" "$4" "$2} END{if(last!="") print last}' "$RUNS_DB"
}

db_append_run() {
  local phase="$1" outcome="$2" sn="$3" wwn="$4" model="$5" sizeb="$6"
  local poh="$7" realloc="$8" pending="$9" offline="${10}" crc="${11}" health="${12}"
  local tempmax="${13}" logdir="${14}"
  local now; now="$(ts_now)"

  # FIX #1: Lock the actual RUNS_DB file directly
  {
    flock -x 200
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
      "$(clean_field "$RUN_ID")" "$now" "$(clean_field "$phase")" "$(clean_field "$outcome")" \
      "$(clean_field "$sn")" "$(clean_field "$wwn")" "$(clean_field "$model")" "$(clean_field "$sizeb")" \
      "$(clean_field "$poh")" "$(clean_field "$realloc")" "$(clean_field "$pending")" "$(clean_field "$offline")" \
      "$(clean_field "$crc")" "$(clean_field "$health")" "$(clean_field "$tempmax")" "$(clean_field "$logdir")" \
      >> "$RUNS_DB"
  } 200>>"$RUNS_DB"
}

# ------------------ ID fields ------------------
get_serial() {
  local dev="$1" sn
  sn="$(smart_out "$dev" -i | awk -F: '/Serial Number/ {gsub(/^[ \t]+/,"",$2); print $2; exit}' || true)"
  [[ -n "${sn:-}" ]] && echo "$sn" || echo "UNKNOWN_SN"
}
get_wwn() {
  local dev="$1" wwn
  wwn="$(udevadm info --query=property --name="$dev" 2>/dev/null | awk -F= '/^ID_WWN=/{print $2; exit}' || true)"
  [[ -n "${wwn:-}" ]] && echo "$wwn" || echo ""
}
best_sn() {
  local dev="$1" sn wwn
  sn="$(get_serial "$dev")"
  if [[ "$sn" != "UNKNOWN_SN" && -n "$sn" ]]; then echo "$sn"; return 0; fi
  wwn="$(get_wwn "$dev")"
  [[ -n "$wwn" ]] && echo "WWN_${wwn}" || echo "DEV_$(basename "$dev")"
}

best_by_id() {
  local dev="$1" p
  for p in /dev/disk/by-id/wwn-* /dev/disk/by-id/ata-* /dev/disk/by-id/scsi-*; do
    [[ -e "$p" ]] || continue
    [[ "$p" == *-part* ]] && continue
    [[ "$(readlink -f "$p")" == "$dev" ]] && { echo "$p"; return 0; }
  done
  return 1
}

# ------------------ current_run.json ------------------
current_drives_text() { printf "%s " "${SELECTED[@]}" | sed 's/ $//'; }
current_drives_dev_text() {
  local out="" d
  for d in "${SELECTED[@]}"; do out+="$(resolve_dev "$d") "; done
  echo "${out%% }"
}

write_current_run_json() {
  local status="$1" phase="$2"
  local last_update; last_update="$(ts_now)"
  local drives_text drives_dev_text
  drives_text="$(current_drives_text)"
  drives_dev_text="$(current_drives_dev_text)"

  local temp_entries="" k v first=1 esc_key
  for k in "${!TEMP_MAX[@]}"; do
    v="${TEMP_MAX[$k]}"
    esc_key="$(json_escape "$k")"
    if [[ $first -eq 1 ]]; then temp_entries="\"${esc_key}\": ${v:-0}"; first=0
    else temp_entries="${temp_entries}, \"${esc_key}\": ${v:-0}"
    fi
  done
  
  # FIX: Ensure valid JSON even when temp_entries is empty
  [[ -z "$temp_entries" ]] && temp_entries='"_empty": 0'

  cat > "$CURRENT_RUN_JSON" <<EOF
{
  "run_id": "$(json_escape "$RUN_ID")",
  "status": "$(json_escape "$status")",
  "phase": "$(json_escape "$phase")",
  "phase_started_at": "$(json_escape "${PHASE_STARTED_AT:-}")",
  "last_update": "$(json_escape "$last_update")",
  "max_temp_c": ${MAX_TEMP},
  "block_size": ${BLOCK_SIZE},
  "max_phase0": ${MAX_PHASE0},
  "max_phaseb": ${MAX_PHASEB},
  "badblocks_passes": ${BADBLOCKS_PASSES},
  "log_dir": "$(json_escape "$LOG_DIR")",
  "summary_path": "$(json_escape "$SUMMARY")",
  "drives_text": "$(json_escape "$drives_text")",
  "drives_dev_text": "$(json_escape "$drives_dev_text")",
  "abort_reason": "$(json_escape "${ABORT_REASON:-}")",
  "temp_max_c": { ${temp_entries} }
}
EOF
  chown root:"$BURNIN_GROUP" "$CURRENT_RUN_JSON" || true
  chmod 0640 "$CURRENT_RUN_JSON" || true
}

mark_phase() {
  CURRENT_STATUS="running"
  CURRENT_PHASE="$1"
  PHASE_STARTED_AT="$(ts_now)"
  write_current_run_json "$CURRENT_STATUS" "$CURRENT_PHASE"
}
mark_idle() {
  CURRENT_STATUS="idle"
  CURRENT_PHASE="IDLE"
  PHASE_STARTED_AT=""
  SELECTED=()
  TEMP_MAX=()
  ABORT_REASON=""
  write_current_run_json "$CURRENT_STATUS" "$CURRENT_PHASE"
}
mark_aborted() { CURRENT_STATUS="aborted"; write_current_run_json "$CURRENT_STATUS" "$CURRENT_PHASE"; }

# ------------------ Abort/Cleanup ------------------
append_aborted_rows_if_needed() {
  [[ "${#SELECTED[@]}" -gt 0 ]] || return 0
  [[ "$CURRENT_PHASE" == "IDLE" ]] && return 0

  local d dev sn wwn model sizeb tempmax health
  for d in "${SELECTED[@]}"; do
    dev="$(resolve_dev "$d")"
    sn="$(best_sn "$dev")"
    wwn="$(get_wwn "$dev")"
    model="$(lsblk -dn -o MODEL "$dev" 2>/dev/null | sed 's/[[:space:]]\+/ /g' || echo "?")"
    sizeb="$(lsblk -b -dn -o SIZE "$dev" 2>/dev/null || echo "")"
    tempmax="${TEMP_MAX[$d]:-}"
    health="$(smart_health "$dev")"
    db_append_run "$CURRENT_PHASE" "ABORTED" "$sn" "$wwn" "$model" "$sizeb" \
      "0" "0" "0" "0" "0" "$health" "${tempmax:-}" "$LOG_DIR"
  done
}

kill_active_pids() {
  [[ "${#ACTIVE_PIDS[@]}" -gt 0 ]] || return 0
  echo "[CLEANUP] Stopping running jobs (pids): ${ACTIVE_PIDS[*]}" | tee -a "$SUMMARY" 2>/dev/null || true
  for pid in "${ACTIVE_PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
  sleep 1
  for pid in "${ACTIVE_PIDS[@]}"; do kill -9 "$pid" 2>/dev/null || true; done
}

abort_run() {
  local reason="$1"
  if [[ "$ABORTING" == "true" ]]; then exit 130; fi
  ABORTING="true"
  ABORT_REASON="$reason"
  echo "[ABORT] $reason" | tee -a "$SUMMARY"
  mark_aborted
  kill_active_pids
  append_aborted_rows_if_needed
  exit 130
}

on_err() {
  local code="$?" line="$1"
  [[ "$COMPLETED" == "true" ]] && exit "$code"
  abort_run "ERR at line $line (exit=$code)"
}
on_exit() {
  local code="$1"
  if [[ "$COMPLETED" == "true" ]]; then exit "$code"; fi
  if [[ "$ABORTING" == "true" ]]; then exit "$code"; fi
  # Unexpected exit
  abort_run "Unexpected EXIT (exit=$code)"
}

trap 'abort_run "SIGINT"' INT
trap 'abort_run "SIGTERM"' TERM
trap 'on_err $LINENO' ERR
trap 'on_exit $?' EXIT

# ------------------ Temp monitoring (unified abort path) ------------------
check_temps_or_abort() {
  local d dev t
  [[ "${#SELECTED[@]}" -eq 0 ]] && return 0
  for d in "${SELECTED[@]}"; do
    dev="$(resolve_dev "$d")"
    t="$(temp_of "$dev")"
    if [[ -n "${t:-}" && "$t" =~ ^[0-9]+$ ]]; then
      if [[ -z "${TEMP_MAX[$d]:-}" || "$t" -gt "${TEMP_MAX[$d]}" ]]; then TEMP_MAX[$d]="$t"; fi
      if [[ "$t" -ge "$MAX_TEMP" ]]; then
        abort_run "TEMP ${d} hit ${t}C >= ${MAX_TEMP}C"
      fi
    fi
  done
  write_current_run_json "$CURRENT_STATUS" "$CURRENT_PHASE"
}

# ------------------ Dmesg capture ------------------
capture_dmesg() {
  local tag="$1"
  dmesg -T | tail -n 500 > "$LOG_DIR/dmesg_${tag}.log" 2>/dev/null || true
  chown root:"$BURNIN_GROUP" "$LOG_DIR/dmesg_${tag}.log" 2>/dev/null || true
  chmod 0640 "$LOG_DIR/dmesg_${tag}.log" 2>/dev/null || true
}

# ------------------ Inventory ------------------
declare -a IDX
declare -A DEV SIZEB SIZEH MODEL SERIAL BYID WWN

build_inventory() {
  IDX=(); DEV=(); SIZEB=(); SIZEH=(); MODEL=(); SERIAL=(); BYID=(); WWN=()
  mapfile -t lines < <(lsblk -b -dn -o NAME,TYPE,SIZE | awk '$2=="disk"{print $1" "$3}' | sort -k2,2n -k1,1)

  local i=0 name bytes dev sizeh model sn wwn byid
  for line in "${lines[@]}"; do
    name="$(awk '{print $1}' <<<"$line")"
    bytes="$(awk '{print $2}' <<<"$line")"
    dev="/dev/$name"
    sizeh="$(lsblk -dn -o SIZE "$dev" 2>/dev/null || echo "?")"
    model="$(lsblk -dn -o MODEL "$dev" 2>/dev/null | sed 's/[[:space:]]\+/ /g' || echo "?")"
    wwn="$(get_wwn "$dev")"
    sn="$(best_sn "$dev")"
    byid="$(best_by_id "$dev" 2>/dev/null || echo "$dev")"

    i=$((i+1))
    IDX+=("$i")
    DEV["$i"]="$dev"
    SIZEB["$i"]="$bytes"
    SIZEH["$i"]="$sizeh"
    MODEL["$i"]="$model"
    SERIAL["$i"]="$sn"
    WWN["$i"]="$wwn"
    BYID["$i"]="$byid"

    db_upsert_drive "$sn" "$wwn" "$model" "$bytes"
  done
}

print_inventory() {
  echo
  echo "Available disks (sorted by size):"
  printf "%-4s %-12s %-8s %-24s %-26s %-26s %s\n" "No." "Device" "Size" "Model" "Serial/ID" "Last Run" "Stable by-id"
  printf "%-4s %-12s %-8s %-24s %-26s %-26s %s\n" "----" "------------" "--------" "------------------------" "--------------------------" "--------------------------" "---------------------------"

  local i last
  for i in "${IDX[@]}"; do
    last="$(db_last_run_summary "${SERIAL[$i]}")"
    printf "%-4s %-12s %-8s %-24.24s %-26.26s %-26.26s %s\n" \
      "$i" "${DEV[$i]}" "${SIZEH[$i]}" "${MODEL[$i]}" "${SERIAL[$i]}" "${last:-}" "${BYID[$i]}"
  done
  echo
  echo "State (Option B): root:$BURNIN_GROUP 750"
  echo "  Drives registry: $DRIVES_DB"
  echo "  Run history:     $RUNS_DB"
  echo "  Current run:     $CURRENT_RUN_JSON"
  echo
}

select_drives() {
  local prompt="$1" max_allowed="${2:-0}"
  local input=()
  SELECTED=()

  echo "$prompt"
  echo "Enter numbers separated by spaces (e.g. 1 3 5). Empty = skip."
  read -r -a input || true
  [[ "${#input[@]}" -eq 0 ]] && return 0

  local seen=" " n
  for n in "${input[@]}"; do
    [[ "$n" =~ ^[0-9]+$ ]] || die "Invalid selection: '$n'"
    [[ -n "${DEV[$n]:-}" ]] || die "No such disk number: $n"
    [[ "$seen" == *" $n "* ]] && continue
    seen+=" $n "
  done

  for n in "${input[@]}"; do
    [[ "$seen" != *" $n "* ]] && continue
    SELECTED+=("${BYID[$n]}")
    seen="${seen/ $n / }"
  done

  if [[ "$max_allowed" -gt 0 && "${#SELECTED[@]}" -gt "$max_allowed" ]]; then
    die "Selected ${#SELECTED[@]} drives, but max allowed is $max_allowed."
  fi
}

# ------------------ Phase 0 ------------------
phase0() {
  local -a drives=("$@")
  [[ "${#drives[@]}" -gt 0 ]] || { echo "[INFO] Phase 0 skipped." | tee -a "$SUMMARY"; return 0; }

  mark_phase "PHASE0"
  capture_dmesg "pre_phase0"
  echo "[PHASE 0] SMART triage starting..." | tee -a "$SUMMARY"

  TEMP_MAX=()
  PH0_PRE_OK=(); PH0_POST_OK=()

  local d dev sn s
  for d in "${drives[@]}"; do
    dev="$(resolve_dev "$d")"
    sn="$(best_sn "$dev")"; s="$(sanitize "$sn")"
    echo "[INFO] Phase0 init: $d (ID=$sn dev=$dev)" | tee -a "$SUMMARY"

    PH0_PRE_OK["$d"]="true"
    if ! smart_dump_x "$dev" "$LOG_DIR/phase0_smart_pre_${s}.log"; then PH0_PRE_OK["$d"]="false"; fi

    smart_out "$dev" -t short >/dev/null 2>&1 || true
    smart_out "$dev" -t conveyance >/dev/null 2>&1 || true
  done

  echo "[INFO] Waiting 5 minutes for short/conveyance..." | tee -a "$SUMMARY"
  for _ in {1..5}; do check_temps_or_abort; sleep 60; done

  for d in "${drives[@]}"; do
    dev="$(resolve_dev "$d")"
    sn="$(best_sn "$dev")"; s="$(sanitize "$sn")"
    selftest_log "$dev" "$LOG_DIR/phase0_selftest_after_short_${s}.log" || true
    error_log   "$dev" "$LOG_DIR/phase0_errorlog_after_short_${s}.log" || true
  done

  echo "[INFO] Starting SMART long tests..." | tee -a "$SUMMARY"
  for d in "${drives[@]}"; do
    dev="$(resolve_dev "$d")"
    smart_out "$dev" -t long >/dev/null 2>&1 || true
  done

  # Poll (simple): wait until all drives no longer say "in progress" in selftest log
  echo "[INFO] Polling long test completion (every 5 minutes)..." | tee -a "$SUMMARY"
  while :; do
    check_temps_or_abort
    local any=0
    for d in "${drives[@]}"; do
      dev="$(resolve_dev "$d")"
      if smart_out "$dev" -c | grep -qi "in progress"; then any=1; fi
    done
    [[ "$any" -eq 0 ]] && break
    sleep 300
  done

  echo "[INFO] Capturing post SMART + updating history..." | tee -a "$SUMMARY"
  local wwn model sizeb poh realloc pending offline crc outcome tempmax health stfail
  for d in "${drives[@]}"; do
    dev="$(resolve_dev "$d")"
    sn="$(best_sn "$dev")"; s="$(sanitize "$sn")"
    wwn="$(get_wwn "$dev")"
    model="$(lsblk -dn -o MODEL "$dev" 2>/dev/null | sed 's/[[:space:]]\+/ /g' || echo "?")"
    sizeb="$(lsblk -b -dn -o SIZE "$dev" 2>/dev/null || echo "")"

    PH0_POST_OK["$d"]="true"
    if ! smart_dump_x "$dev" "$LOG_DIR/phase0_smart_post_${s}.log"; then PH0_POST_OK["$d"]="false"; fi

    selftest_log "$dev" "$LOG_DIR/phase0_selftest_after_long_${s}.log" || true
    error_log   "$dev" "$LOG_DIR/phase0_errorlog_after_long_${s}.log" || true

    health="$(smart_health "$dev")"
    poh="$(smart_attr "$dev" Power_On_Hours)"
    realloc="$(smart_attr "$dev" Reallocated_Sector_Ct)"
    pending="$(smart_attr "$dev" Current_Pending_Sector)"
    offline="$(smart_attr "$dev" Offline_Uncorrectable)"
    crc="$(smart_attr "$dev" UDMA_CRC_Error_Count)"

    stfail="false"
    if [[ -s "$LOG_DIR/phase0_selftest_after_long_${s}.log" ]] && selftest_has_failure "$LOG_DIR/phase0_selftest_after_long_${s}.log"; then
      stfail="true"
    fi

    outcome="PASS"
    [[ "$health" == "FAILED" ]] && outcome="FAIL"
    [[ "$realloc" -gt 0 || "$pending" -gt 0 || "$offline" -gt 0 ]] && outcome="FAIL"
    [[ "$stfail" == "true" ]] && outcome="FAIL"

    if [[ "${PH0_PRE_OK[$d]}" == "false" || "${PH0_POST_OK[$d]}" == "false" ]]; then
      [[ "$outcome" == "PASS" ]] && outcome="WARN"
    fi

    tempmax="${TEMP_MAX[$d]:-}"

    echo "[PHASE 0 RESULT] $d health=$health POH=$poh realloc=$realloc pending=$pending offline=$offline crc=$crc selftest_fail=$stfail outcome=$outcome tempMax=${tempmax:-NA}" | tee -a "$SUMMARY"

    db_append_run "PHASE0" "$outcome" "$sn" "$wwn" "$model" "$sizeb" \
      "$poh" "$realloc" "$pending" "$offline" "$crc" "$health" "${tempmax:-}" "$LOG_DIR"
  done

  capture_dmesg "post_phase0"
  echo "[PHASE 0] Done." | tee -a "$SUMMARY"
  echo | tee -a "$SUMMARY"
}

# ------------------ Phase B worker (per-drive; patterns loop with progress) ------------------
run_badblocks_worker() {
  local dev="$1" s="$2" badfile="$3" progressfile="$4"
  local -a patterns=(0xaa 0x55 0xff 0x00)
  local i total_passes="$BADBLOCKS_PASSES"
  : > "$badfile"
  : > "$progressfile"

  # FIX #2: Wrap pattern index around array to prevent OOB access
  for ((i=1; i<=total_passes; i++)); do
    local pat_idx=$(( (i-1) % 4 ))
    local pat="${patterns[$pat_idx]}"
    local logf="$LOG_DIR/phaseB_badblocks_${s}_pass${i}_${pat}.log"
    
    # FIX #4: Write progress to file for monitoring
    echo "pass=$i/$total_passes pattern=$pat status=running" > "$progressfile"
    echo "[INFO] badblocks pass $i/$total_passes pattern=$pat dev=$dev" >> "$SUMMARY"

    # Nice + ionice to keep system responsive
    # -wsv destructive, -t pattern single pass, -b blocksize
    if ! ionice -c3 nice -n 10 badblocks -b "$BLOCK_SIZE" -wsv -t "$pat" -o "$badfile.tmp" "$dev" > "$logf" 2>&1; then
      # badblocks non-zero may indicate errors; still collect bad list if produced
      echo "pass=$i/$total_passes pattern=$pat status=error" > "$progressfile"
    else
      echo "pass=$i/$total_passes pattern=$pat status=complete" > "$progressfile"
    fi
    
    if [[ -s "$badfile.tmp" ]]; then
      cat "$badfile.tmp" >> "$badfile"
    fi
    rm -f "$badfile.tmp"
  done

  # normalize unique
  sort -u -n "$badfile" -o "$badfile" 2>/dev/null || true
  echo "status=finished total_passes=$total_passes" > "$progressfile"

  return 0
}

# ------------------ Phase B ------------------
phaseB() {
  local -a drives=("$@")
  [[ "${#drives[@]}" -gt 0 ]] || { echo "[INFO] Phase B skipped." | tee -a "$SUMMARY"; return 0; }
  [[ "${#drives[@]}" -le "$MAX_PHASEB" ]] || die "Phase B max is $MAX_PHASEB drives."

  mark_phase "PHASEB"
  capture_dmesg "pre_phaseb"
  echo "[PHASE B] DESTRUCTIVE surface test (badblocks -w) starting..." | tee -a "$SUMMARY"
  echo "[WARN] This WILL ERASE all data on selected drives." | tee -a "$SUMMARY"
  echo "[INFO] BADBLOCKS_PASSES=$BADBLOCKS_PASSES" | tee -a "$SUMMARY"
  echo

  # Determine system disks (extra safety)
  mapfile -t sysdisks < <(system_disks || true)
  if [[ "${#sysdisks[@]}" -gt 0 ]]; then
    echo "[INFO] System disks detected (will be refused for Phase B): ${sysdisks[*]}" | tee -a "$SUMMARY"
  else
    echo "[WARN] Could not detect system disks via mounts. Mounted-disk check still applies." | tee -a "$SUMMARY"
  fi

  local d dev resolved_dev
  for d in "${drives[@]}"; do
    dev="$(resolve_dev "$d")"
    [[ -b "$dev" ]] || die "Not a block device: $dev"
    is_whole_disk "$dev" || die "Not a whole disk: $dev"
    is_mounted_somewhere "$dev" && die "Refusing: $dev (or partition) is mounted"

    # FIX #3: Use resolve_dev for both sides of comparison
    resolved_dev="$(resolve_dev "$dev")"
    for sd in "${sysdisks[@]}"; do
      local resolved_sd="$(resolve_dev "$sd")"
      [[ "$resolved_dev" == "$resolved_sd" ]] && die "Refusing to test detected system disk: $dev (resolves to $resolved_dev, matches system disk $sd)"
    done
  done

  echo "Selected for Phase B:"
  for d in "${drives[@]}"; do
    dev="$(resolve_dev "$d")"
    echo " - $d (dev=$dev ID=$(best_sn "$dev") SIZE=$(lsblk -dn -o SIZE "$dev"))"
  done
  echo
  echo "Type ERASE to proceed:"
  read -r confirm
  [[ "$confirm" == "ERASE" ]] || die "Aborted."

  TEMP_MAX=()
  ACTIVE_PIDS=()

  declare -A PIDS
  declare -A PROGRESS_FILES
  local sn s bb_bad pid progressfile

  for d in "${drives[@]}"; do
    dev="$(resolve_dev "$d")"
    sn="$(best_sn "$dev")"; s="$(sanitize "$sn")"

    smart_dump_x "$dev" "$LOG_DIR/phaseB_smart_pre_${s}.log" || true

    bb_bad="$LOG_DIR/phaseB_badblocks_${s}.bad"
    progressfile="$LOG_DIR/phaseB_progress_${s}.txt"
    PROGRESS_FILES["$d"]="$progressfile"

    ( run_badblocks_worker "$dev" "$s" "$bb_bad" "$progressfile" ) &
    pid=$!
    PIDS["$d"]=$pid
    ACTIVE_PIDS+=("$pid")

    echo "[INFO] badblocks worker started: $d pid=$pid badlist=$bb_bad progress=$progressfile" | tee -a "$SUMMARY"
  done

  # FIX #4: Monitor with progress display
  echo "[INFO] Monitoring badblocks progress (check every 60s)..." | tee -a "$SUMMARY"
  while :; do
    check_temps_or_abort
    local any=0
    
    # Display progress for all drives
    for d in "${drives[@]}"; do
      if kill -0 "${PIDS[$d]}" 2>/dev/null; then
        any=1
        local pf="${PROGRESS_FILES[$d]}"
        if [[ -s "$pf" ]]; then
          local progress_info
          progress_info="$(cat "$pf" 2>/dev/null || echo "status=unknown")"
          echo "[PROGRESS] $d: $progress_info" | tee -a "$SUMMARY"
        fi
      fi
    done
    
    [[ "$any" -eq 0 ]] && break
    sleep 60
  done

  local bb_failed=0
  for d in "${drives[@]}"; do
    if ! wait "${PIDS[$d]}"; then
      echo "[!] badblocks worker exit non-zero: $d" | tee -a "$SUMMARY"
      bb_failed=1
    fi
  done
  ACTIVE_PIDS=()

  echo "[INFO] badblocks complete. Capturing post SMART + verdicts..." | tee -a "$SUMMARY"
  local wwn model sizeb poh realloc pending offline crc outcome tempmax health smart_ok_post
  for d in "${drives[@]}"; do
    dev="$(resolve_dev "$d")"
    sn="$(best_sn "$dev")"; s="$(sanitize "$sn")"
    wwn="$(get_wwn "$dev")"
    model="$(lsblk -dn -o MODEL "$dev" 2>/dev/null | sed 's/[[:space:]]\+/ /g' || echo "?")"
    sizeb="$(lsblk -b -dn -o SIZE "$dev" 2>/dev/null || echo "")"

    bb_bad="$LOG_DIR/phaseB_badblocks_${s}.bad"

    smart_ok_post="true"
    if ! smart_dump_x "$dev" "$LOG_DIR/phaseB_smart_post_${s}.log"; then smart_ok_post="false"; fi

    health="$(smart_health "$dev")"
    poh="$(smart_attr "$dev" Power_On_Hours)"
    realloc="$(smart_attr "$dev" Reallocated_Sector_Ct)"
    pending="$(smart_attr "$dev" Current_Pending_Sector)"
    offline="$(smart_attr "$dev" Offline_Uncorrectable)"
    crc="$(smart_attr "$dev" UDMA_CRC_Error_Count)"

    outcome="PASS"
    [[ "$health" == "FAILED" ]] && outcome="FAIL"
    [[ "$realloc" -gt 0 || "$pending" -gt 0 || "$offline" -gt 0 ]] && outcome="FAIL"
    [[ -s "$bb_bad" ]] && outcome="FAIL"
    [[ "$smart_ok_post" == "false" && "$outcome" == "PASS" ]] && outcome="WARN"

    tempmax="${TEMP_MAX[$d]:-}"

    echo "---- PHASE B RESULT: $d (ID=$sn) ----" | tee -a "$SUMMARY"
    echo "health=$health POH=$poh realloc=$realloc pending=$pending offline=$offline crc=$crc outcome=$outcome tempMax=${tempmax:-NA}" | tee -a "$SUMMARY"
    if [[ -s "$bb_bad" ]]; then
      echo "[FAIL] badblocks found bad LBAs (see): $bb_bad" | tee -a "$SUMMARY"
      bb_failed=1
    else
      echo "[PASS] badblocks bad list empty" | tee -a "$SUMMARY"
    fi
    echo | tee -a "$SUMMARY"

    db_append_run "PHASEB" "$outcome" "$sn" "$wwn" "$model" "$sizeb" \
      "$poh" "$realloc" "$pending" "$offline" "$crc" "$health" "${tempmax:-}" "$LOG_DIR"
  done

  capture_dmesg "post_phaseb"
  echo "[PHASE B] Done. Phase B exit code: $bb_failed" | tee -a "$SUMMARY"
  echo | tee -a "$SUMMARY"
  return "$bb_failed"
}

# ------------------ MAIN ------------------
init_db

{
  echo "HDD Validation Run: $RUN_ID"
  echo "Logs: $LOG_DIR"
  echo "State: $STATE_DIR"
  echo "Config:"
  echo "  MAX_TEMP=${MAX_TEMP}C  BLOCK_SIZE=$BLOCK_SIZE  SMART_TIMEOUT=${SMART_TIMEOUT}s"
  echo "  MAX_PHASE0=$MAX_PHASE0  MAX_PHASEB=$MAX_PHASEB  BADBLOCKS_PASSES=$BADBLOCKS_PASSES"
  echo "Hardening:"
  echo "  - ERR+EXIT traps; unified abort path records ABORTED rows"
  echo "  - flock lock: $LOCK_FILE"
  echo "  - nice/ionice for badblocks"
  echo "  - SMART health (-H), selftest/error logs"
  echo "  - Option B perms: root:$BURNIN_GROUP 750 (dirs) 640 (files)"
  echo "Fixes Applied:"
  echo "  - TSV locking uses actual file (not separate .lock)"
  echo "  - Badblocks passes wrap around pattern array"
  echo "  - System disk detection uses resolve_dev"
  echo "  - Badblocks progress reporting via progress files"
  echo
} > "$SUMMARY"

mark_idle

build_inventory
[[ "${#IDX[@]}" -gt 0 ]] || die "No disks found."

while :; do
  build_inventory
  print_inventory

  echo "Choose an action:"
  echo "  1) Run Phase 0 (SMART triage) on selected drives (max $MAX_PHASE0)"
  echo "  2) Run Phase B (DESTRUCTIVE badblocks -w) on selected drives (max $MAX_PHASEB)"
  echo "  3) Run BOTH (Phase 0 then Phase B) (Phase B max $MAX_PHASEB)"
  echo "  4) Exit"
  read -r choice

  case "$choice" in
    1)
      select_drives "[SELECT] Phase 0 drives:" "$MAX_PHASE0"
      if [[ "${#SELECTED[@]}" -gt 0 ]]; then
        phase0 "${SELECTED[@]}"
        mark_idle
      fi
      ;;
    2)
      select_drives "[SELECT] Phase B drives (max $MAX_PHASEB):" "$MAX_PHASEB"
      if [[ "${#SELECTED[@]}" -gt 0 ]]; then
        phaseB "${SELECTED[@]}" || true
        mark_idle
      fi
      ;;
    3)
      select_drives "[SELECT] Drives for BOTH (Phase B max $MAX_PHASEB):" "$MAX_PHASEB"
      if [[ "${#SELECTED[@]}" -gt 0 ]]; then
        phase0 "${SELECTED[@]}"
        phaseB "${SELECTED[@]}" || true
        mark_idle
      fi
      ;;
    4)
      echo "Exiting."
      echo "Summary: $SUMMARY"
      mark_idle
      COMPLETED="true"
      exit 0
      ;;
    *)
      echo "Invalid choice."
      ;;
  esac

  echo "Summary so far: $SUMMARY"
done
