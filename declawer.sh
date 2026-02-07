#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Hardened Guest Bootstrap + OpenClaw Gateway
# Target: Debian/Ubuntu guest VM/LXC (NOT Proxmox host)
# ============================================================

# -------- Defaults (can be overridden via env) ---------------
DEFAULT_SSH_PORT="${DEFAULT_SSH_PORT:-1492}"
DEFAULT_OPENCLAW_PORT="${DEFAULT_OPENCLAW_PORT:-18789}"
DEFAULT_OPENCLAW_BIND="${DEFAULT_OPENCLAW_BIND:-lan}"   # lan|loopback
INSTALL_FAIL2BAN="${INSTALL_FAIL2BAN:-1}"
INSTALL_UNATTENDED_UPGRADES="${INSTALL_UNATTENDED_UPGRADES:-1}"
NONINTERACTIVE="${NONINTERACTIVE:-0}"

timestamp() { date +"%Y%m%d_%H%M%S"; }
log() { echo -e "\n==> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# -------- Port validation (your addition) -------------------
validate_port() {
  local port="$1"
  if [[ ! "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
    echo "ERROR: Invalid port number: $port"
    exit 1
  fi
}

need_root() { [[ "${EUID}" -eq 0 ]] || die "Run as root (sudo -i)."; }
has_apt() { command -v apt-get >/dev/null 2>&1 || die "This script expects Debian/Ubuntu (apt-get)."; }

# More robust "am I on Proxmox host?"
is_proxmox_host() {
  [[ -d /etc/pve ]] && return 0
  command -v pveversion >/dev/null 2>&1 && return 0
  return 1
}

# Detect primary interface and CIDR (for default allowlist suggestion)
detect_default_cidr() {
  local def_if cidr
  def_if="$(ip route show default 0.0.0.0/0 2>/dev/null | awk '{print $5}' | head -n1 || true)"
  if [[ -n "${def_if}" ]]; then
    cidr="$(ip -o -f inet addr show dev "${def_if}" scope global 2>/dev/null | awk '{print $4}' | head -n1 || true)"
    [[ -n "${cidr}" ]] && echo "${cidr}" && return 0
  fi
  return 1
}

# Normalize a list: accepts commas/spaces/newlines -> space-separated unique values
normalize_list_unique() {
  local raw="${1:-}"
  raw="$(echo "${raw}" | tr ',\n\t' '   ' | tr -s ' ')"
  echo "${raw}" | awk '
    {
      for(i=1;i<=NF;i++){
        if(!seen[$i]++){ out=out $i " " }
      }
    }
    END { sub(/[[:space:]]+$/,"",out); print out }
  '
}

# Basic CIDR sanity check (not perfect, but catches obvious garbage)
valid_cidrish() {
  local x="$1"
  [[ "${x}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]
}

# Read an SSH public key robustly:
# - Reads multiple lines until a blank line
# - Extracts first line beginning with ssh-
read_ssh_pubkey() {
  local buf line key
  buf=""
  while IFS= read -r line; do
    [[ -z "${line}" ]] && break
    buf+="${line}"$'\n'
  done
  key="$(echo "${buf}" | awk '/^ssh-/{print; exit}')"
  [[ -n "${key}" ]] || return 1
  echo "${key}"
}

# Ensure sshd_config includes the drop-in directory
ensure_sshd_include() {
  local cfg="/etc/ssh/sshd_config"
  if ! grep -qiE '^\s*Include\s+/etc/ssh/sshd_config\.d/\*\.conf' "${cfg}"; then
    echo "" >> "${cfg}"
    echo "Include /etc/ssh/sshd_config.d/*.conf" >> "${cfg}"
  fi
  mkdir -p /etc/ssh/sshd_config.d
}

# Write a drop-in sshd hardening file (idempotent)
write_sshd_dropin() {
  local ssh_port="$1"
  local drop="/etc/ssh/sshd_config.d/99-hardening.conf"
  cat > "${drop}" <<EOF
# Managed by hardened-openclaw bootstrap
Port ${ssh_port}

PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes

X11Forwarding no
AllowTcpForwarding yes

ClientAliveInterval 300
ClientAliveCountMax 2

# Restrict to admin group
AllowGroups sshusers
EOF
  chmod 0644 "${drop}"
}

# Install Node.js 22 via NodeSource repo without curl|bash
install_node22_nodesource() {
  log "Installing Node.js 22 (NodeSource repo, keyring-based)..."

  apt-get update -y
  apt-get install -y ca-certificates curl gnupg

  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg

  local distro_codename
  distro_codename="$(. /etc/os-release && echo "${VERSION_CODENAME}")"

  cat > /etc/apt/sources.list.d/nodesource.list <<EOF
deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x ${distro_codename} main
deb-src [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x ${distro_codename} main
EOF

  apt-get update -y
  apt-get install -y nodejs
  node -v
  npm -v
}

# Configure sudo NOPASSWD for sshusers (required if passwords are locked)
setup_sudoers_sshusers() {
  log "Configuring sudoers for sshusers (NOPASSWD)..."
  cat > /etc/sudoers.d/sshusers <<'EOF'
%sshusers ALL=(ALL) NOPASSWD:ALL
EOF
  chmod 0440 /etc/sudoers.d/sshusers
  visudo -cf /etc/sudoers.d/sshusers >/dev/null
}

# ============================================================
# MAIN
# ============================================================

need_root
has_apt
if is_proxmox_host; then
  die "This looks like a Proxmox HOST (/etc/pve or pveversion found). Run inside a guest VM/LXC."
fi

# -------- Logging (your addition) ---------------------------
LOGFILE="/var/log/openclaw-install-$(timestamp).log"
exec > >(tee -a "${LOGFILE}") 2>&1
log "Logging to ${LOGFILE}"

export DEBIAN_FRONTEND=noninteractive

# ------------------ Prompts (or env overrides) --------------
SSH_PORT="${SSH_PORT:-}"
LAN_CIDRS="${LAN_CIDRS:-}"
OPENCLAW_PORT="${OPENCLAW_PORT:-}"
OPENCLAW_BIND="${OPENCLAW_BIND:-}"
ADMIN_USERS="${ADMIN_USERS:-}"

DEFAULT_LAN_FALLBACK="10.0.0.0/8 172.16.0.0/12 192.168.0.0/16"
DEFAULT_LAN="$(detect_default_cidr || true)"
DEFAULT_LAN="${DEFAULT_LAN:-$DEFAULT_LAN_FALLBACK}"

prompt_if_needed() {
  local varname="$1" prompt="$2" default="$3"
  local current="${!varname:-}"
  if [[ -n "${current}" ]]; then return 0; fi
  if [[ "${NONINTERACTIVE}" == "1" ]]; then
    printf -v "${varname}" "%s" "${default}"
    return 0
  fi
  read -r -p "${prompt} [${default}]: " reply
  reply="${reply:-$default}"
  printf -v "${varname}" "%s" "${reply}"
}

prompt_if_needed SSH_PORT      "SSH port to configure"                 "${DEFAULT_SSH_PORT}"
prompt_if_needed LAN_CIDRS     "Allowed LAN CIDR(s) (space/comma)"     "${DEFAULT_LAN}"
prompt_if_needed OPENCLAW_PORT "OpenClaw gateway port"                 "${DEFAULT_OPENCLAW_PORT}"
prompt_if_needed OPENCLAW_BIND "OpenClaw bind (lan|loopback)"          "${DEFAULT_OPENCLAW_BIND}"
prompt_if_needed ADMIN_USERS   "Comma-separated admin SSH usernames"   "admin"

# -------- Port validation (your addition) -------------------
validate_port "${SSH_PORT}"
validate_port "${OPENCLAW_PORT}"

# Normalize + validate LAN CIDRs
LAN_CIDRS="$(normalize_list_unique "${LAN_CIDRS}")"
for cidr in ${LAN_CIDRS}; do
  valid_cidrish "${cidr}" || die "LAN_CIDRS contains invalid CIDR-ish value: '${cidr}'"
done

# Normalize admin list
ADMIN_USERS="$(echo "${ADMIN_USERS}" | tr -d ' ' )"
IFS=',' read -r -a ADMINS <<< "${ADMIN_USERS}"
[[ "${#ADMINS[@]}" -ge 1 && -n "${ADMINS[0]}" ]] || die "Need at least one admin user."

echo
echo "=== Planned Settings ==="
echo "SSH_PORT       : ${SSH_PORT}"
echo "LAN_CIDRS      : ${LAN_CIDRS}"
echo "OPENCLAW_PORT  : ${OPENCLAW_PORT}"
echo "OPENCLAW_BIND  : ${OPENCLAW_BIND}"
echo "ADMIN_USERS    : ${ADMIN_USERS}"
echo "========================"
echo

# ------------------ Base packages ---------------------------
log "Updating OS + installing baseline packages..."
apt-get update -y
apt-get upgrade -y

apt-get install -y \
  openssh-server ufw \
  git jq openssl \
  ca-certificates curl gnupg \
  build-essential

if [[ "${INSTALL_FAIL2BAN}" == "1" ]]; then
  apt-get install -y fail2ban
fi

if [[ "${INSTALL_UNATTENDED_UPGRADES}" == "1" ]]; then
  apt-get install -y unattended-upgrades
  dpkg-reconfigure -f noninteractive unattended-upgrades || true
fi

# ------------------ Groups + sudoers ------------------------
log "Creating sshusers group..."
getent group sshusers >/dev/null || groupadd --system sshusers
setup_sudoers_sshusers

# ------------------ Create admins + keys --------------------
declare -A ADMIN_KEYS

for u in "${ADMINS[@]}"; do
  [[ -z "${u}" ]] && continue
  if [[ "${NONINTERACTIVE}" == "1" ]]; then
    envvar="ADMIN_KEYS_${u}"
    key="${!envvar:-}"
    [[ -n "${key}" && "${key}" =~ ^ssh- ]] || die "NONINTERACTIVE=1 requires env var ${envvar} with a valid ssh-* public key."
    ADMIN_KEYS["${u}"]="${key}"
  else
    echo
    echo "Paste SSH public key for admin user '${u}', then press ENTER on a blank line:"
    key="$(read_ssh_pubkey)" || die "No valid ssh-* public key captured for ${u}."
    ADMIN_KEYS["${u}"]="${key}"
  fi
done

log "Creating admin users + installing keys..."
for u in "${ADMINS[@]}"; do
  [[ -z "${u}" ]] && continue

  id -u "${u}" >/dev/null 2>&1 || useradd -m -s /bin/bash "${u}"
  usermod -aG sudo,sshusers "${u}"

  install -d -m 0700 -o "${u}" -g "${u}" "/home/${u}/.ssh"
  printf '%s\n' "${ADMIN_KEYS[$u]}" > "/home/${u}/.ssh/authorized_keys"
  chown "${u}:${u}" "/home/${u}/.ssh/authorized_keys"
  chmod 0600 "/home/${u}/.ssh/authorized_keys"

  # Lock only AFTER key exists (prevents accidental lockout)
  passwd -l "${u}" >/dev/null 2>&1 || true
done

# ------------------ openclaw service user -------------------
log "Creating openclaw service user (nologin + locked)..."
id -u openclaw >/dev/null 2>&1 || useradd -m -s /usr/sbin/nologin openclaw
passwd -l openclaw >/dev/null 2>&1 || true
install -d -m 0700 -o openclaw -g openclaw /home/openclaw/.openclaw

# ------------------ SSH hardening (drop-in) -----------------
log "Hardening sshd via sshd_config.d drop-in (idempotent)..."
ensure_sshd_include
write_sshd_dropin "${SSH_PORT}"

sshd -t
systemctl restart ssh

# ------------------ UFW firewall ----------------------------
log "Configuring UFW (reset + allow only from LAN CIDRs)..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing

CURRENT_SSH_PORTS="$(ss -ltnp 2>/dev/null | awk '/sshd/ {print $4}' | sed -E 's/.*:([0-9]+)$/\1/' | sort -u | tr '\n' ' ')"
CURRENT_SSH_PORTS="$(normalize_list_unique "${CURRENT_SSH_PORTS}")"

for cidr in ${LAN_CIDRS}; do
  ufw allow from "${cidr}" to any port "${SSH_PORT}" proto tcp

  for p in ${CURRENT_SSH_PORTS}; do
    [[ -n "${p}" ]] && ufw allow from "${cidr}" to any port "${p}" proto tcp || true
  done

  ufw allow from "${cidr}" to any port "${OPENCLAW_PORT}" proto tcp
done

ufw --force enable

# ------------------ Fail2Ban (systemd backend) --------------
if [[ "${INSTALL_FAIL2BAN}" == "1" ]]; then
  log "Configuring Fail2Ban (sshd jail; backend=systemd; banaction=ufw)..."

  cat > /etc/fail2ban/jail.d/sshd.local <<EOF
[DEFAULT]
backend = systemd
banaction = ufw

[sshd]
enabled = true
port = ${SSH_PORT}
maxretry = 5
findtime = 10m
bantime  = 1h
mode = normal
EOF

  systemctl enable --now fail2ban
  systemctl restart fail2ban
fi

# ------------------ Node.js 22 + OpenClaw -------------------
install_node22_nodesource

log "Installing OpenClaw CLI..."
npm install -g openclaw@latest
command -v openclaw >/dev/null

# ------------------ OpenClaw config + systemd ---------------
log "Configuring OpenClaw gateway service..."
OC_STATE="/home/openclaw/.openclaw"
OC_CFG="${OC_STATE}/openclaw.json"
OC_ENV="${OC_STATE}/.env"

cat > "${OC_CFG}" <<'EOF'
{
  "gateway": {
    "mode": "local"
  }
}
EOF
chown openclaw:openclaw "${OC_CFG}"
chmod 0600 "${OC_CFG}"

# -------- Secure .env creation (your addition) --------------
OC_TOKEN="$(openssl rand -hex 32)"
( umask 077 && cat >"${OC_ENV}" <<EOF
OPENCLAW_GATEWAY_TOKEN=${OC_TOKEN}
EOF
)
chown openclaw:openclaw "${OC_ENV}"

OPENCLAW_BIN="$(command -v openclaw)"

cat > /etc/systemd/system/openclaw-gateway.service <<EOF
[Unit]
Description=OpenClaw Gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=openclaw
Group=openclaw
WorkingDirectory=/home/openclaw
EnvironmentFile=${OC_ENV}
ExecStart=${OPENCLAW_BIN} gateway --port ${OPENCLAW_PORT} --bind ${OPENCLAW_BIND} --auth token --token \${OPENCLAW_GATEWAY_TOKEN} --verbose
Restart=on-failure
RestartSec=2
UMask=0077

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now openclaw-gateway

# ------------------ Summary + quick checks ------------------
log "Completed."
echo
echo "==================== IMPORTANT OUTPUT ===================="
echo "Log file          : ${LOGFILE}"
echo "SSH port          : ${SSH_PORT}"
echo "Allowed LAN CIDRs : ${LAN_CIDRS}"
echo "OpenClaw port     : ${OPENCLAW_PORT}"
echo "OpenClaw bind     : ${OPENCLAW_BIND}"
echo
echo "OpenClaw token is stored here (root/openclaw-readable only):"
echo "  ${OC_ENV}"
echo "To view it:"
echo "  sudo cat ${OC_ENV}"
echo
echo "Quick checks:"
echo "  systemctl status openclaw-gateway --no-pager"
echo "  ufw status verbose"
if [[ "${INSTALL_FAIL2BAN}" == "1" ]]; then
  echo "  fail2ban-client status"
  echo "  fail2ban-client status sshd"
fi
echo "=========================================================="
