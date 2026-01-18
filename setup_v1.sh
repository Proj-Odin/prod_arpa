#!/usr/bin/env bash
# setup.sh (idempotent)
# Xubuntu burn-in box bootstrap:
# - Installs required packages (only if missing)
# - Configures SSH on port 1492 (via drop-in when possible)
# - Configures UFW without wiping existing rules (adds only what’s missing)
# - Installs Checkmk RAW agent (2.3+) if not present (optional)
# - Installs smart_posix plugin (async cached) if missing
# - Installs/patches burn-in local check (ensures ABORTED -> CRIT mapping)
#
# Usage:
#   sudo CMK_AGENT_DEB_URL="https://<cmk-host>/<site>/check_mk/agents/<agent>.deb" \
#        CMK_SERVER_IP="<checkmk-server-ip>" \
#        ./setup.sh
#
# Optional env:
#   SSH_PORT=1492
#   CMK_AGENT_DEB_URL=...
#   CMK_SERVER_IP=...
#   CMK_SMART_POSIX_URL=...    # if not set, derived from CMK_AGENT_DEB_URL
#   FORCE_CMK_AGENT=1          # reinstall agent even if present

set -euo pipefail

# ---------------- CONFIG ----------------
SSH_PORT="${SSH_PORT:-1492}"

# Checkmk (RAW, 2.3+)
CMK_AGENT_DEB_URL="${CMK_AGENT_DEB_URL:-}"
CMK_SERVER_IP="${CMK_SERVER_IP:-}"
CMK_SMART_POSIX_URL="${CMK_SMART_POSIX_URL:-}"
FORCE_CMK_AGENT="${FORCE_CMK_AGENT:-0}"

STATE_DIR="${STATE_DIR:-/var/lib/hdd_burnin}"

# ---------------- HELPERS ----------------
need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "[FATAL] Run as root: sudo $0" >&2
    exit 1
  fi
}

have() { command -v "$1" >/dev/null 2>&1; }

log()  { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
fatal(){ echo "[FATAL] $*" >&2; exit 1; }

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

ensure_pkgs() {
  local p
  for p in "$@"; do ensure_pkg "$p"; done
}

file_has_line_exact() {
  local file="$1" line="$2"
  [[ -f "$file" ]] || return 1
  grep -Fxq -- "$line" "$file"
}

write_if_changed() {
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

ufw_rule_present() {
  local pattern="$1"
  ufw status 2>/dev/null | grep -qE "$pattern"
}

ensure_ufw_rule() {
  local cmd="$1"
  local pattern="$2"
  if ufw_rule_present "$pattern"; then
    log "UFW rule already present: $pattern"
  else
    log "Adding UFW rule: $cmd"
    # shellcheck disable=SC2086
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
ensure_pkgs \
  openssh-server ufw tmux \
  smartmontools e2fsprogs \
  curl wget ca-certificates \
  dos2unix gawk sed grep coreutils util-linux \
  perl

# Optional sensors (nice to have)
if ! pkg_installed lm-sensors; then
  log "Installing optional package: lm-sensors"
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends lm-sensors || true
else
  log "Package already installed: lm-sensors"
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
  then
    changed_ssh=1
    log "Updated SSH drop-in: ${SSHD_DROPIN_DIR}/99-burnin.conf"
  else
    log "SSH drop-in already up to date."
  fi
else
  # Fallback: edit /etc/ssh/sshd_config safely
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

# Ensure SSH enabled
systemctl enable --now ssh >/dev/null 2>&1 || true
if [[ "$changed_ssh" -eq 1 ]]; then
  restart_service_if_active ssh
else
  log "No SSH restart needed."
fi

# ---------------- UFW FIREWALL (no reset) ----------------
log "Configuring UFW (non-destructive)..."

# Set sane defaults only if UFW isn't enabled yet
if ! ufw status | grep -qi "Status: active"; then
  log "UFW not active; setting defaults and enabling..."
  ufw default deny incoming
  ufw default allow outgoing
  ufw --force enable
else
  log "UFW already active; leaving defaults as-is."
fi

# Allow SSH port
ensure_ufw_rule "allow ${SSH_PORT}/tcp comment \"SSH\"" "(^| )${SSH_PORT}\/tcp"

# Allow Checkmk agent port 6556 (restricted if CMK_SERVER_IP is set)
if [[ -n "${CMK_SERVER_IP}" ]]; then
  # Pattern match: "6556/tcp ALLOW IN <ip>"
  ensure_ufw_rule "allow from ${CMK_SERVER_IP} to any port 6556 proto tcp comment \"Checkmk agent from server\"" "6556\/tcp.*ALLOW IN.*${CMK_SERVER_IP}"
else
  warn "CMK_SERVER_IP not set; allowing Checkmk agent port 6556/tcp from anywhere."
  ensure_ufw_rule "allow 6556/tcp comment \"Checkmk agent\"" "(^| )6556\/tcp"
fi

# ---------------- CHECKMK AGENT (2.3+) ----------------
log "Checkmk agent (RAW 2.3+) + smart_posix plugin setup..."

agent_present=0
if have check_mk_agent; then
  agent_present=1
  log "check_mk_agent already present."
fi

if [[ "$FORCE_CMK_AGENT" == "1" ]]; then
  log "FORCE_CMK_AGENT=1 set: will (re)install agent if URL is provided."
fi

if [[ -z "${CMK_AGENT_DEB_URL}" ]]; then
  warn "CMK_AGENT_DEB_URL not set; skipping agent download/install."
else
  if [[ "$agent_present" -eq 0 || "$FORCE_CMK_AGENT" == "1" ]]; then
    tmp_deb="/tmp/checkmk-agent.deb"
    log "Downloading Checkmk agent DEB..."
    curl -fsSL "${CMK_AGENT_DEB_URL}" -o "${tmp_deb}"

    log "Installing Checkmk agent DEB..."
    dpkg -i "${tmp_deb}" || true
    apt-get -f install -y
    rm -f "${tmp_deb}"

    if have check_mk_agent; then
      log "Agent install ok."
    else
      fatal "Agent install failed: check_mk_agent not found."
    fi
  else
    log "Skipping agent install (already installed)."
  fi

  # Derive smart_posix URL if not provided
  if [[ -z "${CMK_SMART_POSIX_URL}" ]]; then
    base="${CMK_AGENT_DEB_URL%/*}"
    CMK_SMART_POSIX_URL="${base}/plugins/smart_posix"
  fi

  # Install smart_posix plugin (async cached every 300s)
  smart_dir="/usr/lib/check_mk_agent/plugins/300"
  smart_path="${smart_dir}/smart_posix"
  install -d -m 0755 "$smart_dir"

  if [[ -x "$smart_path" ]]; then
    log "smart_posix already installed: $smart_path"
  else
    log "Installing smart_posix to: $smart_path"
    curl -fsSL "${CMK_SMART_POSIX_URL}" -o "$smart_path"
    chmod 0755 "$smart_path"
    dos2unix "$smart_path" >/dev/null 2>&1 || true
  fi
fi

# ---------------- LOCAL CHECK (burn-in status) ----------------
log "Installing/patching burn-in local check (ABORTED -> CRIT)..."
lc_dir="/usr/lib/check_mk_agent/local"
lc_path="${lc_dir}/hdd_burnin_status"
install -d -m 0755 "$lc_dir"
install -d -m 0700 "$STATE_DIR"

# If local check not present, create it with ABORTED=CRIT from the start
if [[ ! -f "$lc_path" ]]; then
  log "Creating local check: $lc_path"
  cat > "$lc_path" <<'EOF'
#!/bin/bash
# Checkmk local check: latest burn-in result per drive SN from /var/lib/hdd_burnin/runs.tsv
# Output format: <state> <service_name> <perfdata> - <text>

RUNS="/var/lib/hdd_burnin/runs.tsv"
[[ -r "$RUNS" ]] || { echo "3 HDD_Burnin_Status - - runs.tsv not found/readable: $RUNS"; exit 0; }

state_of() {
  case "$1" in
    PASS)    echo 0 ;;
    WARN)    echo 1 ;;
    FAIL)    echo 2 ;;
    ABORTED) echo 2 ;;  # burn-in interrupted -> CRIT
    *)       echo 3 ;;
  esac
}

awk -F'\t' '
  NR==1 {next}
  $5 != "" {last[$5]=$0}
  END{ for (sn in last) print last[sn] }
' "$RUNS" | while IFS=$'\t' read -r run_id ts phase outcome sn wwn model size_bytes poh realloc pending offline crc temp_max log_dir; do
  svc_sn="${sn//[^A-Za-z0-9._-]/_}"
  svc="HDD_Burnin_${svc_sn}"
  st="$(state_of "$outcome")"

  txt="phase=$phase outcome=$outcome model=${model:-?} poh=${poh:-?} realloc=${realloc:-?} pending=${pending:-?} offline_unc=${offline:-?} temp_max=${temp_max:-?} log_dir=${log_dir:-?} ts=${ts:-?}"
  if [[ "$outcome" == "ABORTED" ]]; then
    txt="ABORTED: run interrupted (Ctrl-C/TERM or temp kill) ${txt}"
  fi

  echo "$st $svc - $txt"
done

exit 0
EOF
  chmod 0755 "$lc_path"
  dos2unix "$lc_path" >/dev/null 2>&1 || true
else
  log "Local check already exists; verifying ABORTED mapping..."
fi

# If it exists but lacks ABORTED mapping to CRIT, patch it (perl-based, with safety backup)
if ! grep -qE 'ABORTED\)\s*echo\s*2' "$lc_path"; then
  log "Patching local check to map ABORTED -> CRIT (2)..."
  backup="${lc_path}.bak.$(date +%Y%m%d_%H%M%S)"
  cp -a "$lc_path" "$backup"
  log "Backup saved: $backup"

  if have perl; then
    perl -0777 -pe 's/state_of\(\)\s*\{\s*.*?\s*\}\s*/state_of() {\n  case "$1" in\n    PASS)    echo 0 ;;\n    WARN)    echo 1 ;;\n    FAIL)    echo 2 ;;\n    ABORTED) echo 2 ;;  # burn-in interrupted -> CRIT\n    *)       echo 3 ;;\n  esac\n}\n\n/sms' -i "$lc_path"
  else
    warn "perl not available; cannot auto-patch state_of(). (perl is recommended)"
  fi
fi

# Ensure ABORTED text annotation exists
if ! grep -q 'ABORTED: run interrupted' "$lc_path"; then
  log "Adding ABORTED text annotation (idempotent insert)..."
  if have perl; then
    perl -pe 'if (!$done && /^(\s*txt=)/) { $done=1; $_ .= "  if [[ \"\\$outcome\" == \"ABORTED\" ]]; then\n    txt=\"ABORTED: run interrupted (Ctrl-C/TERM or temp kill) \\$txt\"\n  fi\n"; }' -i "$lc_path"
  else
    warn "perl not available; skipping ABORTED text annotation insert."
  fi
fi

chmod 0755 "$lc_path"

# ---------------- QUICK SELF-TESTS ----------------
if have check_mk_agent; then
  log "Agent self-test: showing agent directories + local section preview..."
  check_mk_agent | head -n 80 || true
  check_mk_agent | sed -n '/<<<local>>>/,$p' | head -n 80 || true
else
  warn "check_mk_agent not found; skipped agent self-test."
fi

log "Setup complete."
log "SSH: tcp/${SSH_PORT}"
log "Checkmk agent: tcp/6556 (restricted=${CMK_SERVER_IP:-no})"
