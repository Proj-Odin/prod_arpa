#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

# ---------------- CONFIG ----------------
SSH_PORT="${SSH_PORT:-1492}"

# Checkmk agent (served by your Checkmk site). You provided this link:
CMK_AGENT_DEB_URL="${CMK_AGENT_DEB_URL:-http://checkmk.prod.home.arpa/monitoring/check_mk/agents/check-mk-agent_2.4.0p12-1_all.deb}"

# Optional: restrict TCP/6556 so only your Checkmk server can poll the agent
CMK_SERVER_IP="${CMK_SERVER_IP:-}"

# Optional: override smart_posix URL. If empty, derived from CMK_AGENT_DEB_URL base.
CMK_SMART_POSIX_URL="${CMK_SMART_POSIX_URL:-}"

# Reinstall agent even if present
FORCE_CMK_AGENT="${FORCE_CMK_AGENT:-0}"

# State
STATE_DIR="${STATE_DIR:-/var/lib/hdd_burnin}"
BURNIN_GROUP="${BURNIN_GROUP:-burnin}"

# WOL config (auto-detect if empty; fallback to enp34s0)
WOL_IFACE="${WOL_IFACE:-}"

# ---------------- HELPERS ----------------
log()  { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
die()  { echo "[FATAL] $*" >&2; exit 1; }

need_root() { [[ "${EUID}" -eq 0 ]] || die "Run as root: sudo $0"; }
have() { command -v "$1" >/dev/null 2>&1; }

pkg_installed() { dpkg -s "$1" >/dev/null 2>&1; }

ensure_pkg() {
  local p="$1"
  if pkg_installed "$p"; then
    log "Package already installed: $p"
  else
    log "Installing package: $p"
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$p"
  fi
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
  install -m 0644 "$tmp" "$path"
  rm -f "$tmp"
  return 0
}

ufw_has_rule_regex() {
  local re="$1"
  ufw status 2>/dev/null | grep -qE "$re"
}

ufw_add_if_missing() {
  local cmd="$1"
  local re="$2"
  if ufw_has_rule_regex "$re"; then
    log "UFW rule already present: $re"
  else
    log "Adding UFW rule: ufw $cmd"
    # Intentionally avoid ufw "comment" for compatibility across versions
    ufw $cmd
  fi
}

restart_or_enable() {
  local svc="$1"
  if systemctl list-unit-files | awk '{print $1}' | grep -qx "${svc}.service"; then
    systemctl enable --now "$svc" >/dev/null 2>&1 || true
    systemctl restart "$svc" >/dev/null 2>&1 || true
  else
    # service name might be 'ssh' not 'sshd' on Ubuntu
    systemctl enable --now "$svc" >/dev/null 2>&1 || true
    systemctl restart "$svc" >/dev/null 2>&1 || true
  fi
}

detect_iface() {
  local nic="${WOL_IFACE:-}"
  if [[ -z "$nic" ]]; then
    nic="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
  fi
  if [[ -z "${nic:-}" ]]; then
    nic="$(ip -br link 2>/dev/null | awk '$1!="lo"{print $1; exit}')"
  fi
  echo "${nic:-enp34s0}"
}

supports_wol_g() {
  local nic="$1"
  local s
  s="$(ethtool "$nic" 2>/dev/null | awk -F': ' '/Supports Wake-on/ {print $2; exit}')"
  [[ "${s:-}" == *g* ]]
}

enable_wol() {
  local nic="$1"
  if ! have ethtool; then
    warn "ethtool not installed; cannot enable WOL."
    return 0
  fi
  if ! ip link show "$nic" >/dev/null 2>&1; then
    warn "NIC '$nic' not found; skipping WOL."
    return 0
  fi

  if ! supports_wol_g "$nic"; then
    warn "NIC '$nic' does not report Supports Wake-on: g (or ethtool couldn't read it). WOL may not be possible."
    return 0
  fi

  log "Enabling WOL (wol g) on $nic now..."
  ethtool -s "$nic" wol g || warn "Failed to set WOL on $nic (driver/BIOS may block it)."

  log "Installing persistent systemd unit for WOL..."
  cat > /etc/systemd/system/wol@.service <<'EOF'
[Unit]
Description=Enable Wake-on-LAN on %i
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/ethtool -s %i wol g
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now "wol@${nic}.service" >/dev/null 2>&1 || warn "Could not enable wol@${nic}.service"

  log "WOL status (ethtool):"
  ethtool "$nic" 2>/dev/null | egrep -i 'Supports Wake-on|Wake-on' || true
}

# ---------------- MAIN ----------------
need_root

log "Updating apt cache..."
apt-get update -y

log "Installing required packages (only if missing)..."
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
ensure_pkg util-linux
ensure_pkg coreutils
ensure_pkg grep
ensure_pkg sed
ensure_pkg iproute2
ensure_pkg ethtool

# Optional sensors
if ! pkg_installed lm-sensors; then
  log "Installing optional package: lm-sensors"
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends lm-sensors || true
else
  log "Package already installed: lm-sensors"
fi

# ---------------- Option B Security (burnin group) ----------------
TARGET_USER="${SUDO_USER:-}"
if [[ -z "$TARGET_USER" || "$TARGET_USER" == "root" ]]; then
  warn "SUDO_USER not set (you ran as root directly). Group add for desktop user may not happen."
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

log "Ensuring state dir exists with root:$BURNIN_GROUP 750..."
install -d -m 0750 -o root -g "$BURNIN_GROUP" "$STATE_DIR"

RUNS_DB="$STATE_DIR/runs.tsv"
DRIVES_DB="$STATE_DIR/drives.tsv"
CUR_JSON="$STATE_DIR/current_run.json"

if [[ ! -f "$DRIVES_DB" ]]; then
  printf "sn\twwn\tmodel\tsize_bytes\tfirst_seen\tlast_seen\tnotes\n" > "$DRIVES_DB"
  chown root:"$BURNIN_GROUP" "$DRIVES_DB"
  chmod 0640 "$DRIVES_DB"
  log "Initialized: $DRIVES_DB"
fi

if [[ ! -f "$RUNS_DB" ]]; then
  printf "run_id\tts\tphase\toutcome\tsn\twwn\tmodel\tsize_bytes\tpoh\trealloc\tpending\toffline_unc\tudma_crc\tsmart_health\ttemp_max\tlog_dir\n" > "$RUNS_DB"
  chown root:"$BURNIN_GROUP" "$RUNS_DB"
  chmod 0640 "$RUNS_DB"
  log "Initialized: $RUNS_DB"
fi

if [[ ! -f "$CUR_JSON" ]]; then
  cat > "$CUR_JSON" <<EOF
{"run_id":"","status":"idle","phase":"IDLE","phase_started_at":"","last_update":"","max_temp_c":0,"block_size":0,"log_dir":"","summary_path":"","drives_text":"","drives_dev_text":"","abort_reason":"","temp_max_c":{}}
EOF
  chown root:"$BURNIN_GROUP" "$CUR_JSON"
  chmod 0640 "$CUR_JSON"
  log "Initialized: $CUR_JSON"
fi

# ---------------- SSH CONFIG ----------------
log "Configuring SSH on port ${SSH_PORT} (idempotent)..."
SSHD_DROPIN_DIR="/etc/ssh/sshd_config.d"
changed_ssh=0

if [[ -d "$SSHD_DROPIN_DIR" ]]; then
  if write_atomic_if_changed "${SSHD_DROPIN_DIR}/99-burnin.conf" <<EOF
# Managed by setup.sh (burn-in box)
Port ${SSH_PORT}
EOF
  then
    changed_ssh=1
    log "Updated SSH drop-in: ${SSHD_DROPIN_DIR}/99-burnin.conf"
  else
    log "SSH drop-in already up to date."
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
if [[ "$changed_ssh" -eq 1 ]]; then
  restart_or_enable ssh
else
  log "No SSH restart needed."
fi

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

# SSH rule (no comment)
ufw_add_if_missing "allow ${SSH_PORT}/tcp" "(^|[[:space:]])${SSH_PORT}\/tcp"

# Checkmk agent port 6556 (restricted if CMK_SERVER_IP set)
if [[ -n "${CMK_SERVER_IP}" ]]; then
  ufw_add_if_missing "allow from ${CMK_SERVER_IP} to any port 6556 proto tcp" "6556\/tcp.*ALLOW IN.*${CMK_SERVER_IP}"
else
  warn "CMK_SERVER_IP not set; allowing TCP/6556 from anywhere (LAN recommended)."
  ufw_add_if_missing "allow 6556/tcp" "(^|[[:space:]])6556\/tcp"
fi

# ---------------- WOL SETUP ----------------
NIC="$(detect_iface)"
log "Configuring Wake-on-LAN for NIC: $NIC"
enable_wol "$NIC"

# ---------------- CHECKMK AGENT + smart_posix ----------------
log "Checkmk agent + smart_posix setup..."
agent_present=0
have check_mk_agent && agent_present=1

if [[ "$agent_present" -eq 1 && "$FORCE_CMK_AGENT" != "1" ]]; then
  log "Checkmk agent already installed (check_mk_agent found). Skipping agent install."
else
  [[ -n "$CMK_AGENT_DEB_URL" ]] || die "CMK_AGENT_DEB_URL is empty."
  tmp_deb="/tmp/checkmk-agent.deb"
  log "Downloading Checkmk agent .deb: $CMK_AGENT_DEB_URL"
  curl -fsSL "$CMK_AGENT_DEB_URL" -o "$tmp_deb"
  log "Installing agent..."
  dpkg -i "$tmp_deb" || true
  apt-get -f install -y
  rm -f "$tmp_deb"
  have check_mk_agent || die "Agent install failed: check_mk_agent not found."
fi

# Install smart_posix (cached/async every 300s)
if [[ -z "$CMK_SMART_POSIX_URL" ]]; then
  base="${CMK_AGENT_DEB_URL%/*}"
  CMK_SMART_POSIX_URL="${base}/plugins/smart_posix"
fi

smart_dir="/usr/lib/check_mk_agent/plugins/300"
smart_path="${smart_dir}/smart_posix"
install -d -m 0755 "$smart_dir"

if [[ -x "$smart_path" ]]; then
  log "smart_posix already installed: $smart_path"
else
  log "Installing smart_posix: $CMK_SMART_POSIX_URL -> $smart_path"
  curl -fsSL "$CMK_SMART_POSIX_URL" -o "$smart_path"
  chmod 0755 "$smart_path"
  dos2unix "$smart_path" >/dev/null 2>&1 || true
fi

# ---------------- CHECKMK LOCAL CHECK (CurrentRun + per-drive verdicts) ----------------
lc_dir="/usr/lib/check_mk_agent/local"
lc_path="${lc_dir}/hdd_burnin_status"
install -d -m 0755 "$lc_dir"

# Always enforce our canonical local-check content (safe/idempotent: only rewrites if changed)
if write_atomic_if_changed "$lc_path" <<'EOF'
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

# ---- Current run (real-time) ----
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
  echo "1 HDD_Burnin_CurrentRun - current_run.json missing/unreadable"
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
  chmod 0755 "$lc_path"
  dos2unix "$lc_path" >/dev/null 2>&1 || true
  log "Installed/updated local check: $lc_path"
else
  chmod 0755 "$lc_path" || true
  log "Local check already up to date."
fi

# ---------------- SELF-CHECKS ----------------
log "Self-check: WOL + agent + local section preview"

if have ethtool; then
  ethtool "$NIC" 2>/dev/null | egrep -i 'Supports Wake-on|Wake-on' || true
fi

if have check_mk_agent; then
  log "Local section (first ~120 lines from <<<local>>>):"
  check_mk_agent | sed -n '/<<<local>>>/,$p' | head -n 120 || true
else
  warn "check_mk_agent not found (unexpected)."
fi

log "Done."
log "SSH: tcp/${SSH_PORT}"
log "Checkmk agent port: tcp/6556 (restricted=${CMK_SERVER_IP:-no})"
log "WOL NIC: $NIC   MAC: $(cat /sys/class/net/$NIC/address 2>/dev/null || echo '?')"
warn "For WOL reliability: also enable BIOS setting 'Restore on AC Power Loss = Power On' (recommended)."
warn "If you were added to group '$BURNIN_GROUP', log out/in (or reboot) to apply."
