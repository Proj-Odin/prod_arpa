#!/usr/bin/env bash
# setup.sh (idempotent)
# - Creates burnin group (Option B security)
# - Installs deps (only if missing)
# - SSH on port 1492 (or SSH_PORT)
# - UFW adds rules (no reset). Uses syntax compatible with older/newer UFW.
# - Installs Checkmk RAW agent (2.3+/2.4+) from CMK_AGENT_DEB_URL (defaults to your URL)
# - Installs smart_posix plugin (cached)
# - Installs/patches local check: ABORTED -> CRIT + CurrentRun status service

set -euo pipefail
export LC_ALL=C

# ---------------- CONFIG ----------------
SSH_PORT="${SSH_PORT:-1492}"

# Your Checkmk agent URL as default
CMK_AGENT_DEB_URL="${CMK_AGENT_DEB_URL:-http://checkmk.prod.home.arpa/monitoring/check_mk/agents/check-mk-agent_2.4.0p12-1_all.deb}"
CMK_SERVER_IP="${CMK_SERVER_IP:-}"                 # recommended: restrict 6556 to this IP
CMK_SMART_POSIX_URL="${CMK_SMART_POSIX_URL:-}"     # optional override
FORCE_CMK_AGENT="${FORCE_CMK_AGENT:-0}"

STATE_DIR="${STATE_DIR:-/var/lib/hdd_burnin}"
LOG_ROOT="${LOG_ROOT:-/var/log}"
BURNIN_GROUP="${BURNIN_GROUP:-burnin}"

# ---------------- HELPERS ----------------
need_root() { [[ "${EUID}" -eq 0 ]] || { echo "[FATAL] Run as root: sudo $0" >&2; exit 1; }; }
have() { command -v "$1" >/dev/null 2>&1; }
log()  { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
fatal(){ echo "[FATAL] $*" >&2; exit 1; }

pkg_installed() { dpkg -s "$1" >/dev/null 2>&1; }
ensure_pkg() {
  local p="$1"
  if pkg_installed "$p"; then log "Package already installed: $p"
  else
    log "Installing package: $p"
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$p"
  fi
}

write_if_changed() {
  local path="$1" tmp
  tmp="$(mktemp)"
  cat > "$tmp"
  if [[ -f "$path" ]] && cmp -s "$tmp" "$path"; then rm -f "$tmp"; return 1; fi
  install -d -m 0755 "$(dirname "$path")"
  install -m 0644 "$tmp" "$path"
  rm -f "$tmp"
  return 0
}

ufw_rule_present() { ufw status 2>/dev/null | grep -qE "$1"; }
ensure_ufw_rule() {
  local cmd="$1" pattern="$2"
  if ufw_rule_present "$pattern"; then
    log "UFW rule already present: $pattern"
  else
    log "Adding UFW rule: ufw $cmd"
    # NOTE: avoid "comment" syntax for maximum UFW compatibility
    ufw $cmd
  fi
}

restart_service_if_active() {
  local svc="$1"
  if systemctl is-enabled "$svc" >/dev/null 2>&1 || systemctl is-active "$svc" >/dev/null 2>&1; then
    systemctl restart "$svc"
  else
    systemctl enable --now "$svc"
  fi
}

# ---------------- MAIN ----------------
need_root

log "Updating apt cache..."
apt-get update -y

log "Installing base packages (only if missing)..."
ensure_pkg openssh-server
ensure_pkg ufw
ensure_pkg tmux
ensure_pkg smartmontools
ensure_pkg e2fsprogs
ensure_pkg curl
ensure_pkg wget
ensure_pkg ca-certificates
ensure_pkg dos2unix
ensure_pkg gawk
ensure_pkg perl
ensure_pkg util-linux   # provides flock, lsblk, findmnt, ionice
ensure_pkg coreutils
ensure_pkg grep
ensure_pkg sed
ensure_pkg iproute2

# Optional sensors tooling
if ! pkg_installed lm-sensors; then
  log "Installing optional package: lm-sensors"
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends lm-sensors || true
else
  log "Package already installed: lm-sensors"
fi

# ---------------- Option B Security: burnin group ----------------
TARGET_USER="${SUDO_USER:-}"
if [[ -z "$TARGET_USER" || "$TARGET_USER" == "root" ]]; then
  warn "SUDO_USER not set (running as root directly). Conky user/group setup may be incomplete."
fi

if ! getent group "$BURNIN_GROUP" >/dev/null 2>&1; then
  log "Creating group: $BURNIN_GROUP"
  groupadd --system "$BURNIN_GROUP"
else
  log "Group exists: $BURNIN_GROUP"
fi

if [[ -n "$TARGET_USER" && "$TARGET_USER" != "root" ]]; then
  if id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx "$BURNIN_GROUP"; then
    log "User already in group: $TARGET_USER -> $BURNIN_GROUP"
  else
    log "Adding user to group: $TARGET_USER -> $BURNIN_GROUP"
    usermod -aG "$BURNIN_GROUP" "$TARGET_USER"
    warn "User '$TARGET_USER' must log out/in (or reboot) for group membership to take effect."
  fi
fi

log "Preparing state dir with Option B permissions: root:$BURNIN_GROUP 750"
install -d -m 0750 -o root -g "$BURNIN_GROUP" "$STATE_DIR"

RUNS_DB="$STATE_DIR/runs.tsv"
DRIVES_DB="$STATE_DIR/drives.tsv"
CUR_JSON="$STATE_DIR/current_run.json"

if [[ ! -f "$DRIVES_DB" ]]; then
  printf "sn\twwn\tmodel\tsize_bytes\tfirst_seen\tlast_seen\tnotes\n" > "$DRIVES_DB"
  chown root:"$BURNIN_GROUP" "$DRIVES_DB"
  chmod 0640 "$DRIVES_DB"
fi

if [[ ! -f "$RUNS_DB" ]]; then
  printf "run_id\tts\tphase\toutcome\tsn\twwn\tmodel\tsize_bytes\tpoh\trealloc\tpending\toffline_unc\tudma_crc\tsmart_health\ttemp_max\tlog_dir\n" > "$RUNS_DB"
  chown root:"$BURNIN_GROUP" "$RUNS_DB"
  chmod 0640 "$RUNS_DB"
fi

if [[ ! -f "$CUR_JSON" ]]; then
  cat > "$CUR_JSON" <<EOF
{"run_id":"","status":"idle","phase":"IDLE","phase_started_at":"","last_update":"","max_temp_c":0,"block_size":0,"max_phase0":0,"max_phaseb":0,"badblocks_passes":0,"log_dir":"","summary_path":"","drives_text":"","drives_dev_text":"","abort_reason":"","temp_max_c":{}}
EOF
  chown root:"$BURNIN_GROUP" "$CUR_JSON"
  chmod 0640 "$CUR_JSON"
fi

# ---------------- SSH CONFIG ----------------
log "Configuring SSH on port ${SSH_PORT} (idempotent)..."
SSHD_DROPIN_DIR="/etc/ssh/sshd_config.d"
changed_ssh=0

if [[ -d "$SSHD_DROPIN_DIR" ]]; then
  if write_if_changed "${SSHD_DROPIN_DIR}/99-burnin.conf" <<EOF
# Managed by setup.sh (burn-in box)
Port ${SSH_PORT}
EOF
  then changed_ssh=1; log "Updated SSH drop-in: ${SSHD_DROPIN_DIR}/99-burnin.conf"
  else log "SSH drop-in already up to date."
  fi
else
  if grep -qE '^\s*Port\s+' /etc/ssh/sshd_config; then
    if ! grep -qE "^\s*Port\s+${SSH_PORT}\s*$" /etc/ssh/sshd_config; then
      sed -i -E "s/^\s*Port\s+.*/Port ${SSH_PORT}/" /etc/ssh/sshd_config
      changed_ssh=1
      log "Updated Port in /etc/ssh/sshd_config"
    else
      log "SSH Port already set in /etc/ssh/sshd_config"
    fi
  else
    echo "Port ${SSH_PORT}" >> /etc/ssh/sshd_config
    changed_ssh=1
    log "Appended Port to /etc/ssh/sshd_config"
  fi
fi

systemctl enable --now ssh >/dev/null 2>&1 || true
[[ "$changed_ssh" -eq 1 ]] && restart_service_if_active ssh || log "No SSH restart needed."

# ---------------- UFW FIREWALL (no reset) ----------------
log "Configuring UFW (non-destructive)..."
if ! ufw status | grep -qi "Status: active"; then
  log "UFW not active; setting defaults and enabling..."
  ufw default deny incoming
  ufw default allow outgoing
  ufw --force enable
else
  log "UFW already active; leaving defaults as-is."
fi

# SAFEST UFW SYNTAX (no comment)
ensure_ufw_rule "allow ${SSH_PORT}/tcp" "(^|[[:space:]])${SSH_PORT}\/tcp"

if [[ -n "${CMK_SERVER_IP}" ]]; then
  ensure_ufw_rule "allow from ${CMK_SERVER_IP} to any port 6556 proto tcp" "6556\/tcp.*ALLOW IN.*${CMK_SERVER_IP}"
else
  warn "CMK_SERVER_IP not set; allowing Checkmk agent port 6556/tcp from anywhere."
  ensure_ufw_rule "allow 6556/tcp" "(^|[[:space:]])6556\/tcp"
fi

# ---------------- CHECKMK AGENT + smart_posix ----------------
log "Checkmk agent (RAW 2.3+/2.4+) + smart_posix plugin setup..."

agent_present=0
if have check_mk_agent; then agent_present=1; log "check_mk_agent already present."; fi

if [[ -n "${CMK_AGENT_DEB_URL}" ]]; then
  if [[ "$agent_present" -eq 0 || "$FORCE_CMK_AGENT" == "1" ]]; then
    tmp_deb="/tmp/checkmk-agent.deb"
    log "Downloading Checkmk agent DEB: $CMK_AGENT_DEB_URL"
    curl -fsSL "${CMK_AGENT_DEB_URL}" -o "${tmp_deb}"

    log "Installing Checkmk agent DEB..."
    dpkg -i "${tmp_deb}" || true
    apt-get -f install -y
    rm -f "${tmp_deb}"

    have check_mk_agent || fatal "Agent install failed: check_mk_agent not found."
  else
    log "Skipping agent install (already installed)."
  fi
else
  warn "CMK_AGENT_DEB_URL empty; skipping agent install."
fi

if have check_mk_agent; then
  if [[ -z "${CMK_SMART_POSIX_URL}" && -n "${CMK_AGENT_DEB_URL}" ]]; then
    base="${CMK_AGENT_DEB_URL%/*}"
    CMK_SMART_POSIX_URL="${base}/plugins/smart_posix"
  fi

  smart_dir="/usr/lib/check_mk_agent/plugins/300"
  smart_path="${smart_dir}/smart_posix"
  install -d -m 0755 "$smart_dir"

  if [[ -x "$smart_path" ]]; then
    log "smart_posix already installed: $smart_path"
  else
    [[ -n "${CMK_SMART_POSIX_URL}" ]] || fatal "CMK_SMART_POSIX_URL could not be determined."
    log "Installing smart_posix: $CMK_SMART_POSIX_URL -> $smart_path"
    curl -fsSL "${CMK_SMART_POSIX_URL}" -o "$smart_path"
    chmod 0755 "$smart_path"
    dos2unix "$smart_path" >/dev/null 2>&1 || true
  fi
else
  warn "check_mk_agent not present; skipping smart_posix install."
fi

# ---------------- Local Check ----------------
log "Installing/patching burn-in Checkmk local check (ABORTED->CRIT + CurrentRun)..."
lc_dir="/usr/lib/check_mk_agent/local"
lc_path="${lc_dir}/hdd_burnin_status"
install -d -m 0755 "$lc_dir"

if [[ ! -f "$lc_path" ]]; then
  cat > "$lc_path" <<'EOF'
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

# ---- Current run ----
if [[ -r "$CUR" ]]; then
  status="$(json_get "$CUR" status || echo "")"
  phase="$(json_get "$CUR" phase || echo "")"
  drives="$(json_get "$CUR" drives_dev_text || echo "")"
  run_id="$(json_get "$CUR" run_id || echo "")"
  last_update="$(json_get "$CUR" last_update || echo "")"
  abort_reason="$(json_get "$CUR" abort_reason || echo "")"
  summary_path="$(json_get "$CUR" summary_path || echo "")"

  st=0
  [[ "$status" == "aborted" ]] && st=2
  echo "$st HDD_Burnin_CurrentRun - status=${status:-?} phase=${phase:-?} drives='${drives:-}' run_id=${run_id:-?} last_update=${last_update:-?} abort_reason='${abort_reason:-}' summary=${summary_path:-?}"
else
  echo "1 HDD_Burnin_CurrentRun - current_run.json missing"
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
  chmod 0755 "$lc_path"
  dos2unix "$lc_path" >/dev/null 2>&1 || true
else
  log "Local check exists; leaving in place (ABORTED->CRIT already handled by our installer)."
fi

# ---------------- Quick self-test ----------------
if have check_mk_agent; then
  log "Agent local section preview:"
  check_mk_agent | sed -n '/<<<local>>>/,$p' | head -n 120 || true
fi

log "Setup complete."
log "State dir: $STATE_DIR (root:$BURNIN_GROUP 750, files 640)"
log "SSH: tcp/${SSH_PORT}"
log "Checkmk agent: tcp/6556 (restricted=${CMK_SERVER_IP:-no})"
