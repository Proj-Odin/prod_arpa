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
  local dev="$1" p
  for p in /dev/disk/by-id/wwn-* /dev/disk/by-id/ata-* /dev/disk/by-id/scsi-*; do
    [[ -e "$p" ]] || continue
    [[ "$p" == *-part* ]] && continue
    if [[ "$(readlink -f "$p")" == "$dev" ]]; then
      echo "$p"; return 0
    fi
  done
  return 1
}

# ------------------ REAL-TIME STATE (current_run.json) ------------------
current_drives_text() {
  local out="" d
  for d in "${SELECTED[@]}"; do out+="${d} "; done
  echo "${out%% }"
}

current_drives_dev_text() {
  local out="" d dev
  for d in "${SELECTED[@]}"; do
    dev="$(resolve_dev "$d")"
    out+="${dev} "
  done
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
    if [[ $first -eq 1 ]]; then
      temp_entries="\"${esc_key}\": ${v:-0}"
      first=0
    else
      temp_entries="${temp_entries}, \"${esc_key}\": ${v:-0}"
    fi
  done

  cat > "$CURRENT_RUN_JSON" <<EOF
{
  "run_id": "$(json_escape "$RUN_ID")",
  "status": "$(json_escape "$status")",
  "phase": "$(json_escape "$phase")",
  "phase_started_at": "$(json_escape "${PHASE_STARTED_AT:-}")",
  "last_update": "$(json_escape "$last_update")",
  "max_temp_c": ${MAX_TEMP},
  "block_size": ${BLOCK_SIZE},
  "max_batch": ${MAX_BATCH},
  "log_dir": "$(json_escape "$LOG_DIR")",
  "summary_path": "$(json_escape "$SUMMARY")",
  "drives_text": "$(json_escape "$drives_text")",
  "drives_dev_text": "$(json_escape "$drives_dev_text")",
  "temp_max_c": { ${temp_entries} }
}
EOF
  chmod 600 "$CURRENT_RUN_JSON" || true
}

write_current_run_json_with_pids() {
  local status="$1" phase="$2" pids_assoc_name="$3"
  local last_update; last_update="$(ts_now)"
  local drives_text drives_dev_text
  drives_text="$(current_drives_text)"
  drives_dev_text="$(current_drives_dev_text)"

  # shellcheck disable=SC1083
  declare -n PIDS_REF="$pids_assoc_name"

  local pids_entries="" first=1 d pid esc_key
  for d in "${SELECTED[@]}"; do
    pid="${PIDS_REF[$d]:-}"
    esc_key="$(json_escape "$d")"
    [[ -z "${pid:-}" ]] && continue
    if [[ $first -eq 1 ]]; then
      pids_entries="\"${esc_key}\": ${pid}"
      first=0
    else
      pids_entries="${pids_entries}, \"${esc_key}\": ${pid}"
    fi
  done

  local temp_entries="" k v first2=1 esc_key2
  for k in "${!TEMP_MAX[@]}"; do
    v="${TEMP_MAX[$k]}"
    esc_key2="$(json_escape "$k")"
    if [[ $first2 -eq 1 ]]; then
      temp_entries="\"${esc_key2}\": ${v:-0}"
      first2=0
    else
      temp_entries="${temp_entries}, \"${esc_key2}\": ${v:-0}"
    fi
  done

  cat > "$CURRENT_RUN_JSON" <<EOF
{
  "run_id": "$(json_escape "$RUN_ID")",
  "status": "$(json_escape "$status")",
  "phase": "$(json_escape "$phase")",
  "phase_started_at": "$(json_escape "${PHASE_STARTED_AT:-}")",
  "last_update": "$(json_escape "$last_update")",
  "max_temp_c": ${MAX_TEMP},
  "block_size": ${BLOCK_SIZE},
  "max_batch": ${MAX_BATCH},
  "log_dir": "$(json_escape "$LOG_DIR")",
  "summary_path": "$(json_escape "$SUMMARY")",
  "drives_text": "$(json_escape "$drives_text")",
  "drives_dev_text": "$(json_escape "$drives_dev_text")",
  "pids": { ${pids_entries} },
  "temp_max_c": { ${temp_entries} }
}
EOF
  chmod 600 "$CURRENT_RUN_JSON" || true
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
  write_current_run_json "$CURRENT_STATUS" "$CURRENT_PHASE"
}

mark_aborted() {
  CURRENT_STATUS="aborted"
  write_current_run_json "$CURRENT_STATUS" "$CURRENT_PHASE"
}

# ------------------ SMART/TEMP (HARDENED) ------------------
temp_of() {
  local d="$1"
  timeout "$SMART_TIMEOUT" smartctl -A "$d" 2>/dev/null | awk '
    /Temperature_Celsius|Temperature_Internal|Airflow_Temperature_Cel/ {print $10; exit}
    /Current Drive Temperature/ {print $4; exit}
    /^Temperature:/ {print $2; exit}
  ' | sed -E 's/[^0-9].*//' || true
}

check_temps_or_kill() {
  local -a pids=("$@")
  local d dev t
  [[ "${#SELECTED[@]}" -eq 0 ]] && return 0

  for d in "${SELECTED[@]}"; do
    dev="$(resolve_dev "$d")"
    t="$(temp_of "$dev")"
    if [[ -n "${t:-}" && "$t" =~ ^[0-9]+$ ]]; then
      if [[ -z "${TEMP_MAX[$d]:-}" || "$t" -gt "${TEMP_MAX[$d]}" ]]; then
        TEMP_MAX[$d]="$t"
      fi
      if [[ "$t" -ge "$MAX_TEMP" ]]; then
        echo "[EMERGENCY] $d hit ${t}C >= ${MAX_TEMP}C. Killing this run." | tee -a "$SUMMARY"
        mark_aborted
        for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
        exit 1
      fi
    fi
  done

  write_current_run_json "$CURRENT_STATUS" "$CURRENT_PHASE"
}

first_int_or_zero() { sed -E 's/[^0-9]*([0-9]+).*/\1/; t; s/.*/0/'; }

smart_attr() {
  local dev="$1" name="$2" out val
  out="$(timeout "$SMART_TIMEOUT" smartctl -A "$dev" 2>/dev/null || true)"
  val="$(echo "$out" | awk -v n="$name" '$1==n {print $10; exit}' | first_int_or_zero)"
  echo "${val:-0}"
}

smart_keyvals() {
  local d="$1"
  local realloc pending offline hours crc
  realloc="$(smart_attr "$d" Reallocated_Sector_Ct)"
  pending="$(smart_attr "$d" Current_Pending_Sector)"
  offline="$(smart_attr "$d" Offline_Uncorrectable)"
  hours="$(smart_attr "$d" Power_On_Hours)"
  crc="$(smart_attr "$d" UDMA_CRC_Error_Count)"
  echo "POH=$hours Realloc=$realloc Pending=$pending OfflineUnc=$offline UDMA_CRC=$crc"
}

smart_dump_x() {
  local dev="$1" outfile="$2"
  if timeout "$SMART_TIMEOUT" smartctl -x "$dev" > "$outfile" 2>/dev/null; then
    return 0
  else
    echo "[WARN] smartctl -x failed on $dev (see: $outfile)" | tee -a "$SUMMARY" || true
    timeout "$SMART_TIMEOUT" smartctl -a "$dev" > "$outfile" 2>/dev/null || true
    return 1
  fi
}

selftest_in_progress() {
  local out
  out="$(timeout "$SMART_TIMEOUT" smartctl -c "$1" 2>/dev/null || true)"
  echo "$out" | grep -qi "Self-test execution status:.*in progress"
}

# ------------------ DB OPS ------------------
db_drive_exists() {
  local sn="$1"
  awk -F'\t' -v sn="$sn" 'NR>1 && $1==sn {found=1} END{exit(found?0:1)}' "$DRIVES_DB"
}

db_upsert_drive() {
  local sn="$1" wwn="$2" model="$3" sizeb="$4"
  local now; now="$(ts_now)"

  sn="$(clean_field "$sn")"
  wwn="$(clean_field "$wwn")"
  model="$(clean_field "$model")"
  sizeb="$(clean_field "$sizeb")"

  [[ -z "$sn" ]] && return 0

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
}

db_last_run_summary() {
  local sn="$1"
  [[ -z "${sn:-}" ]] && return 0
  awk -F'\t' -v sn="$sn" '
    NR>1 && $5==sn { last=$3" "$4" "$2 }
    END{ if(last!="") print last }
  ' "$RUNS_DB"
}

db_append_run() {
  local phase="$1" outcome="$2" sn="$3" wwn="$4" model="$5" sizeb="$6"
  local poh="$7" realloc="$8" pending="$9" offline="${10}" crc="${11}"
  local tempmax="${12}" logdir="${13}"
  local now; now="$(ts_now)"

  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "$(clean_field "$RUN_ID")" "$now" "$(clean_field "$phase")" "$(clean_field "$outcome")" \
    "$(clean_field "$sn")" "$(clean_field "$wwn")" "$(clean_field "$model")" "$(clean_field "$sizeb")" \
    "$(clean_field "$poh")" "$(clean_field "$realloc")" "$(clean_field "$pending")" "$(clean_field "$offline")" \
    "$(clean_field "$crc")" "$(clean_field "$tempmax")" "$(clean_field "$logdir")" \
    >> "$RUNS_DB"
}

# ------------------ INVENTORY ------------------
declare -a IDX
declare -A DEV SIZEB SIZEH MODEL SERIAL BYID WWN

build_inventory() {
  IDX=()
  DEV=(); SIZEB=(); SIZEH=(); MODEL=(); SERIAL=(); BYID=(); WWN=()

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
  echo "History files:"
  echo "  Drives registry: $DRIVES_DB"
  echo "  Run history:     $RUNS_DB"
  echo "  Current run:     $CURRENT_RUN_JSON"
  echo
}

# ------------------ SELECTION ------------------
select_drives() {
  local prompt="$1"
  local max_allowed="${2:-0}"   # 0 = no limit
  local input=()

  SELECTED=()
  echo "$prompt"
  echo "Enter numbers separated by spaces (e.g. 1 3 5). Empty = skip."
  read -r -a input || true
  [[ "${#input[@]}" -eq 0 ]] && return 0

  local seen=" "
  local n
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

# ------------------ CLEANUP HANDLER ------------------
cleanup() {
  if [[ "${CURRENT_STATUS}" == "running" ]]; then
    mark_aborted
  fi

  if [[ "${#ACTIVE_PIDS[@]}" -gt 0 ]]; then
    echo "[CLEANUP] Stopping running jobs (pids): ${ACTIVE_PIDS[*]}" | tee -a "$SUMMARY" 2>/dev/null || true
    for pid in "${ACTIVE_PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
    sleep 1
    for pid in "${ACTIVE_PIDS[@]}"; do kill -9 "$pid" 2>/dev/null || true; done
  fi

  if [[ "${#SELECTED[@]}" -gt 0 && "${CURRENT_PHASE}" != "IDLE" ]]; then
    local d dev sn wwn model sizeb tempmax
    for d in "${SELECTED[@]}"; do
      dev="$(resolve_dev "$d")"
      sn="$(best_sn "$dev")"
      wwn="$(get_wwn "$dev")"
      model="$(lsblk -dn -o MODEL "$dev" 2>/dev/null | sed 's/[[:space:]]\+/ /g' || echo "?")"
      sizeb="$(lsblk -b -dn -o SIZE "$dev" 2>/dev/null || echo "")"
      tempmax="${TEMP_MAX[$d]:-}"
      db_append_run "$CURRENT_PHASE" "ABORTED" "$sn" "$wwn" "$model" "$sizeb" \
        "0" "0" "0" "0" "0" "${tempmax:-}" "$LOG_DIR"
    done
  fi

  exit 130
}
trap cleanup INT TERM

# ------------------ PHASE 0 ------------------
phase0() {
  local -a drives=("$@")
  [[ "${#drives[@]}" -gt 0 ]] || { echo "[INFO] Phase 0 skipped."; return 0; }

  mark_phase "PHASE0"
  echo "[PHASE 0] SMART triage starting..." | tee -a "$SUMMARY"

  TEMP_MAX=()
  declare -A PH0_PRE_OK
  declare -A PH0_POST_OK

  local d dev sn s

  for d in "${drives[@]}"; do
    dev="$(resolve_dev "$d")"
    sn="$(best_sn "$dev")"; s="$(sanitize "$sn")"
    echo "[INFO] Phase0 init: $d (ID=$sn)" | tee -a "$SUMMARY"

    PH0_PRE_OK["$d"]="true"
    if ! smart_dump_x "$dev" "$LOG_DIR/phase0_smart_pre_${s}.log"; then
      PH0_PRE_OK["$d"]="false"
    fi

    smartctl -t short "$dev" >/dev/null 2>&1 || true
    smartctl -t conveyance "$dev" >/dev/null 2>&1 || true
  done

  echo "[INFO] Waiting 5 minutes for short/conveyance tests..." | tee -a "$SUMMARY"
  for _ in {1..5}; do check_temps_or_kill; sleep 60; done

  for d in "${drives[@]}"; do
    dev="$(resolve_dev "$d")"
    sn="$(best_sn "$dev")"; s="$(sanitize "$sn")"
    timeout "$SMART_TIMEOUT" smartctl -l selftest "$dev" > "$LOG_DIR/phase0_selftest_after_short_${s}.log" 2>/dev/null || true
    timeout "$SMART_TIMEOUT" smartctl -l error   "$dev" > "$LOG_DIR/phase0_errorlog_after_short_${s}.log" 2>/dev/null || true
  done

  echo "[INFO] Starting SMART long tests..." | tee -a "$SUMMARY"
  for d in "${drives[@]}"; do
    dev="$(resolve_dev "$d")"
    smartctl -t long "$dev" >/dev/null 2>&1 || true
  done

  echo "[INFO] Polling for long test completion (every 5 minutes)..." | tee -a "$SUMMARY"
  while :; do
    check_temps_or_kill
    local any=0
    for d in "${drives[@]}"; do
      dev="$(resolve_dev "$d")"
      if selftest_in_progress "$dev"; then any=1; fi
    done
    [[ "$any" -eq 0 ]] && break
    sleep 300
  done

  echo "[INFO] Capturing post SMART + updating history..." | tee -a "$SUMMARY"
  local wwn model sizeb poh realloc pending offline crc outcome tempmax
  for d in "${drives[@]}"; do
    dev="$(resolve_dev "$d")"
    sn="$(best_sn "$dev")"; s="$(sanitize "$sn")"
    wwn="$(get_wwn "$dev")"
    model="$(lsblk -dn -o MODEL "$dev" 2>/dev/null | sed 's/[[:space:]]\+/ /g' || echo "?")"
    sizeb="$(lsblk -b -dn -o SIZE "$dev" 2>/dev/null || echo "")"

    PH0_POST_OK["$d"]="true"
    if ! smart_dump_x "$dev" "$LOG_DIR/phase0_smart_post_${s}.log"; then
      PH0_POST_OK["$d"]="false"
    fi

    timeout "$SMART_TIMEOUT" smartctl -l selftest "$dev" > "$LOG_DIR/phase0_selftest_after_long_${s}.log" 2>/dev/null || true
    timeout "$SMART_TIMEOUT" smartctl -l error   "$dev" > "$LOG_DIR/phase0_errorlog_after_long_${s}.log" 2>/dev/null || true

    poh="$(smart_attr "$dev" Power_On_Hours)"
    realloc="$(smart_attr "$dev" Reallocated_Sector_Ct)"
    pending="$(smart_attr "$dev" Current_Pending_Sector)"
    offline="$(smart_attr "$dev" Offline_Uncorrectable)"
    crc="$(smart_attr "$dev" UDMA_CRC_Error_Count)"

    outcome="PASS"
    [[ "$realloc" -gt 0 || "$pending" -gt 0 || "$offline" -gt 0 ]] && outcome="FAIL"
    if [[ "${PH0_PRE_OK[$d]}" == "false" || "${PH0_POST_OK[$d]}" == "false" ]]; then
      [[ "$outcome" == "PASS" ]] && outcome="WARN"
    fi

    tempmax="${TEMP_MAX[$d]:-}"
    echo "[PHASE 0 RESULT] $d : $(smart_keyvals "$dev") Outcome=$outcome TempMax=${tempmax:-NA}" | tee -a "$SUMMARY"

    db_append_run "PHASE0" "$outcome" "$sn" "$wwn" "$model" "$sizeb" \
      "$poh" "$realloc" "$pending" "$offline" "$crc" "${tempmax:-}" "$LOG_DIR"
  done

  echo "[PHASE 0] Done." | tee -a "$SUMMARY"
  echo | tee -a "$SUMMARY"
}

# ------------------ PHASE B (DESTRUCTIVE) ------------------
phaseB() {
  local -a drives=("$@")
  [[ "${#drives[@]}" -gt 0 ]] || { echo "[INFO] Phase B skipped."; return 0; }
  [[ "${#drives[@]}" -le "$MAX_BATCH" ]] || die "Phase B max is $MAX_BATCH drives."

  mark_phase "PHASEB"
  echo "[PHASE B] DESTRUCTIVE surface test (badblocks -w) starting..." | tee -a "$SUMMARY"
  echo "[WARN] This WILL ERASE all data on selected drives." | tee -a "$SUMMARY"
  echo

  local root_disk; root_disk="$(root_base_disk)"
  local d dev
  for d in "${drives[@]}"; do
    dev="$(resolve_dev "$d")"
    [[ -b "$dev" ]] || die "Not a block device: $dev"
    is_whole_disk "$dev" || die "Not a whole disk: $dev"
    [[ -n "$root_disk" && "$dev" == "$root_disk" ]] && die "Refusing to test OS disk: $dev"
    is_mounted_somewhere "$dev" && die "Refusing: $dev (or partition) is mounted"
  done

  echo "Selected for Phase B:"
  for d in "${drives[@]}"; do
    dev="$(resolve_dev "$d")"
    echo " - $d  (dev=$dev  ID=$(best_sn "$dev")  SIZE=$(lsblk -dn -o SIZE "$dev"))"
  done
  echo
  echo "Type ERASE to proceed:"
  read -r confirm
  [[ "$confirm" == "ERASE" ]] || die "Aborted."

  TEMP_MAX=()
  ACTIVE_PIDS=()

  declare -A PIDS
  local sn s bb_log bb_bad pid

  for d in "${drives[@]}"; do
    dev="$(resolve_dev "$d")"
    sn="$(best_sn "$dev")"; s="$(sanitize "$sn")"

    smart_dump_x "$dev" "$LOG_DIR/phaseB_smart_pre_${s}.log" || true

    bb_log="$LOG_DIR/phaseB_badblocks_${s}.log"
    bb_bad="$LOG_DIR/phaseB_badblocks_${s}.bad"

    badblocks -b "$BLOCK_SIZE" -wsv -o "$bb_bad" "$dev" > "$bb_log" 2>&1 &
    pid=$!
    PIDS["$d"]=$pid
    ACTIVE_PIDS+=("$pid")

    echo "[INFO] badblocks started: $d pid=$pid log=$bb_log" | tee -a "$SUMMARY"
  done

  write_current_run_json_with_pids "$CURRENT_STATUS" "$CURRENT_PHASE" PIDS

  while :; do
    check_temps_or_kill "${ACTIVE_PIDS[@]}"
    local any=0
    for d in "${drives[@]}"; do
      if kill -0 "${PIDS[$d]}" 2>/dev/null; then any=1; fi
    done
    [[ "$any" -eq 0 ]] && break
    sleep 60
  done

  local bb_failed=0
  for d in "${drives[@]}"; do
    if ! wait "${PIDS[$d]}"; then
      echo "[!] badblocks exit non-zero: $d" | tee -a "$SUMMARY"
      bb_failed=1
    fi
  done

  ACTIVE_PIDS=()

  echo "[INFO] badblocks complete. Capturing post SMART + verdicts..." | tee -a "$SUMMARY"

  local wwn model sizeb poh realloc pending offline crc outcome tempmax smart_ok_post
  for d in "${drives[@]}"; do
    dev="$(resolve_dev "$d")"
    sn="$(best_sn "$dev")"; s="$(sanitize "$sn")"
    wwn="$(get_wwn "$dev")"
    model="$(lsblk -dn -o MODEL "$dev" 2>/dev/null | sed 's/[[:space:]]\+/ /g' || echo "?")"
    sizeb="$(lsblk -b -dn -o SIZE "$dev" 2>/dev/null || echo "")"

    bb_bad="$LOG_DIR/phaseB_badblocks_${s}.bad"

    smart_ok_post="true"
    if ! smart_dump_x "$dev" "$LOG_DIR/phaseB_smart_post_${s}.log"; then smart_ok_post="false"; fi

    poh="$(smart_attr "$dev" Power_On_Hours)"
    realloc="$(smart_attr "$dev" Reallocated_Sector_Ct)"
    pending="$(smart_attr "$dev" Current_Pending_Sector)"
    offline="$(smart_attr "$dev" Offline_Uncorrectable)"
    crc="$(smart_attr "$dev" UDMA_CRC_Error_Count)"

    outcome="PASS"
    [[ "$realloc" -gt 0 || "$pending" -gt 0 || "$offline" -gt 0 ]] && outcome="FAIL"
    if [[ -s "$bb_bad" ]]; then outcome="FAIL"; bb_failed=1; fi
    if [[ "$smart_ok_post" == "false" && "$outcome" == "PASS" ]]; then outcome="WARN"; fi

    tempmax="${TEMP_MAX[$d]:-}"

    echo "---- PHASE B RESULT: $d (ID=$sn) ----" | tee -a "$SUMMARY"
    echo "$(smart_keyvals "$dev") Outcome=$outcome TempMax=${tempmax:-NA}" | tee -a "$SUMMARY"
    if [[ -s "$bb_bad" ]]; then
      echo "[FAIL] badblocks found bad LBAs: $bb_bad" | tee -a "$SUMMARY"
    else
      echo "[PASS] badblocks bad list empty" | tee -a "$SUMMARY"
    fi
    echo | tee -a "$SUMMARY"

    db_append_run "PHASEB" "$outcome" "$sn" "$wwn" "$model" "$sizeb" \
      "$poh" "$realloc" "$pending" "$offline" "$crc" "${tempmax:-}" "$LOG_DIR"
  done

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
  echo "Config: MAX_TEMP=${MAX_TEMP}C MAX_BATCH=$MAX_BATCH BLOCK_SIZE=$BLOCK_SIZE SMART_TIMEOUT=${SMART_TIMEOUT}s"
  echo "Hardening: timeout-wrapped smartctl; trap cleanup kills badblocks + records ABORTED; clean_field strips |; Phase0 SMART dump WARN is per-drive"
  echo
} > "$SUMMARY"

mark_idle

build_inventory
[[ "${#IDX[@]}" -gt 0 ]] || die "No disks found."

while :; do
  build_inventory
  print_inventory

  echo "Choose an action:"
  echo "  1) Run Phase 0 (SMART triage) on selected drives"
  echo "  2) Run Phase B (DESTRUCTIVE badblocks -w) on selected drives (max $MAX_BATCH)"
  echo "  3) Run BOTH (Phase 0 then Phase B) on selected drives (Phase B max $MAX_BATCH)"
  echo "  4) Exit"
  read -r choice

  case "$choice" in
    1)
      select_drives "[SELECT] Phase 0 drives:" 0
      if [[ "${#SELECTED[@]}" -gt 0 ]]; then
        phase0 "${SELECTED[@]}"
        mark_idle
      fi
      ;;
    2)
      select_drives "[SELECT] Phase B drives (max $MAX_BATCH):" "$MAX_BATCH"
      if [[ "${#SELECTED[@]}" -gt 0 ]]; then
        phaseB "${SELECTED[@]}" || true
        mark_idle
      fi
      ;;
    3)
      select_drives "[SELECT] Drives for BOTH (Phase B max $MAX_BATCH):" "$MAX_BATCH"
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
      exit 0
      ;;
    *)
      echo "Invalid choice."
      ;;
  esac

  echo "Summary so far: $SUMMARY"
done
