#!/usr/bin/env bash
# Standalone Checkmk local-check updater for HDD burn-in status.
# Installs/updates /usr/lib/check_mk_agent/local/hdd_burnin_status
# without requiring a full setup.sh rerun.

set -euo pipefail
export LC_ALL=C

LC_DIR="/usr/lib/check_mk_agent/local"
LC_PATH="${LC_DIR}/hdd_burnin_status"
BACKUP_DIR="/var/backups/hdd_burnin"

STATE_DIR="/var/lib/hdd_burnin"
RUNS_DB="${STATE_DIR}/runs.tsv"
CUR_JSON="${STATE_DIR}/current_run.json"

BURNIN_GROUP="${BURNIN_GROUP:-burnin}"

log()  { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
die()  { echo "[FATAL] $*" >&2; exit 1; }

need_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root: sudo $0"
}

write_atomic_if_changed() {
  local path="$1"
  local tmp
  tmp="$(mktemp)"
  cat > "$tmp"

  if [[ -f "$path" ]] && cmp -s "$tmp" "$path"; then
    rm -f "$tmp"
    return 1
  fi

  install -d -m 0755 "$(dirname "$path")"
  install -m 0755 "$tmp" "$path"
  rm -f "$tmp"
  return 0
}

state_group() {
  if getent group "$BURNIN_GROUP" >/dev/null 2>&1; then
    echo "$BURNIN_GROUP"
  else
    echo "root"
  fi
}

ensure_state_files() {
  local grp
  grp="$(state_group)"

  install -d -m 0750 -o root -g "$grp" "$STATE_DIR" 2>/dev/null || install -d -m 0750 "$STATE_DIR"

  if [[ ! -f "$RUNS_DB" ]]; then
    printf "run_id\tts\tphase\toutcome\tsn\twwn\tmodel\tsize_bytes\tpoh\trealloc\tpending\toffline_unc\tudma_crc\tsmart_health\ttemp_max\tlog_dir\n" > "$RUNS_DB"
    log "Initialized: $RUNS_DB"
  fi

  if [[ ! -f "$CUR_JSON" ]]; then
    cat > "$CUR_JSON" <<'EOF'
{"run_id":"","status":"idle","phase":"IDLE","phase_started_at":"","last_update":"","max_temp_c":0,"block_size":0,"log_dir":"","summary_path":"","drives_text":"","drives_dev_text":"","new_drives_text":"","new_drives_dev_text":"","new_drives_count":0,"abort_reason":"","temp_max_c":{}}
EOF
    log "Initialized: $CUR_JSON"
  fi

  chown root:"$grp" "$RUNS_DB" "$CUR_JSON" 2>/dev/null || true
  chmod 0640 "$RUNS_DB" "$CUR_JSON" 2>/dev/null || true
}

backup_localcheck() {
  [[ -f "$LC_PATH" ]] || return 0
  install -d -m 0750 "$BACKUP_DIR"
  local backup="${BACKUP_DIR}/hdd_burnin_status.$(date +%Y%m%d_%H%M%S).bak"
  cp -a "$LC_PATH" "$backup"
  log "Backup saved: $backup"
}

install_localcheck() {
  backup_localcheck

  if write_atomic_if_changed "$LC_PATH" <<'EOF'
#!/bin/bash
export LC_ALL=C

RUNS="/var/lib/hdd_burnin/runs.tsv"
CUR="/var/lib/hdd_burnin/current_run.json"

state_of() {
  case "$1" in
    PASS)    echo 0 ;;
    WARN)    echo 1 ;;
    FAIL)    echo 2 ;;
    ABORTED) echo 2 ;;  # interrupted burn-in => CRIT
    *)       echo 3 ;;
  esac
}

json_get() {
  local f="$1" key="$2"
  [[ -r "$f" ]] || return 1
  tr -d '\n' < "$f" | sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p"
}

json_get_num() {
  local f="$1" key="$2"
  [[ -r "$f" ]] || return 1
  tr -d '\n' < "$f" | sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\\([0-9][0-9]*\\).*/\\1/p"
}

# ---- Current run (real-time) ----
if [[ -r "$CUR" ]]; then
  status="$(json_get "$CUR" status || echo "")"
  phase="$(json_get "$CUR" phase || echo "")"
  drives="$(json_get "$CUR" drives_dev_text || echo "")"
  run_id="$(json_get "$CUR" run_id || echo "")"
  last_update="$(json_get "$CUR" last_update || echo "")"
  abort_reason="$(json_get "$CUR" abort_reason || echo "")"
  summary_path="$(json_get "$CUR" summary_path || echo "")"
  new_drives="$(json_get "$CUR" new_drives_dev_text || echo "")"
  new_count="$(json_get_num "$CUR" new_drives_count || echo "0")"

  st=0
  [[ "$status" == "aborted" ]] && st=2
  echo "$st HDD_Burnin_CurrentRun - status=${status:-?} phase=${phase:-?} drives='${drives:-}' run_id=${run_id:-?} last_update=${last_update:-?} abort_reason='${abort_reason:-}' summary=${summary_path:-?}"

  new_st=0
  if [[ "${status:-}" == "running" && "${new_count:-0}" =~ ^[1-9][0-9]*$ ]]; then
    # WARN while actively burning in never-before-tested drives.
    new_st=1
  fi
  echo "$new_st HDD_Burnin_NewDrives - status=${status:-?} phase=${phase:-?} new_count=${new_count:-0} new_drives='${new_drives:-}' run_id=${run_id:-?} last_update=${last_update:-?}"
else
  echo "1 HDD_Burnin_CurrentRun - current_run.json missing/unreadable"
  echo "1 HDD_Burnin_NewDrives - current_run.json missing/unreadable"
fi

# ---- Per-drive latest verdict ----
if [[ ! -r "$RUNS" ]]; then
  echo "3 HDD_Burnin_DB - runs.tsv not found/readable: $RUNS"
  exit 0
fi

awk -F'\t' '
  NR==1 {next}
  $5 != "" {last[$5]=$0}
  END{ for (sn in last) print last[sn] }
' "$RUNS" | while IFS=$'\t' read -r run_id ts phase outcome sn wwn model size_bytes poh realloc pending offline crc smart_health temp_max log_dir; do
  svc_sn="${sn//[^A-Za-z0-9._-]/_}"
  svc="HDD_Burnin_${svc_sn}"
  st="$(state_of "$outcome")"
  txt="phase=$phase outcome=$outcome smart_health=${smart_health:-?} model=${model:-?} poh=${poh:-?} realloc=${realloc:-?} pending=${pending:-?} offline_unc=${offline:-?} crc=${crc:-?} temp_max=${temp_max:-?} log_dir=${log_dir:-?} ts=${ts:-?}"
  echo "$st $svc - $txt"
done

exit 0
EOF
  then
    log "Installed/updated local check: $LC_PATH"
  else
    log "Local check already up to date: $LC_PATH"
    chmod 0755 "$LC_PATH" 2>/dev/null || true
  fi
}

status() {
  if [[ -x "$LC_PATH" ]]; then
    log "Local check present: $LC_PATH"
  else
    warn "Local check missing or not executable: $LC_PATH"
    return 1
  fi

  if grep -q "HDD_Burnin_NewDrives" "$LC_PATH"; then
    log "Feature check: HDD_Burnin_NewDrives is present."
  else
    warn "Feature check: HDD_Burnin_NewDrives not found in local check."
  fi

  if command -v check_mk_agent >/dev/null 2>&1; then
    log "Agent local section preview (first matching lines):"
    check_mk_agent | sed -n '/<<<local>>>/,$p' | grep -E "HDD_Burnin_CurrentRun|HDD_Burnin_NewDrives|HDD_Burnin_DB" | head -n 20 || true
  else
    warn "check_mk_agent not found in PATH; skipping live preview."
  fi
}

usage() {
  cat <<EOF
Usage:
  sudo $0 install   # install/update local check (default)
  sudo $0 status    # show feature status and agent preview
  sudo $0 help

Notes:
- Standalone updater for Checkmk local check at:
  $LC_PATH
- Adds/keeps service:
  HDD_Burnin_NewDrives
  (WARN when burn-in is actively running on never-before-tested drives)
EOF
}

cmd="${1:-install}"

case "$cmd" in
  install)
    need_root
    ensure_state_files
    install_localcheck
    status
    ;;
  status)
    status
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    usage
    exit 2
    ;;
esac
