#!/usr/bin/env bash
# prep_master.sh - "any box" Linux prep script (Debian/Ubuntu first, best-effort RHEL-like)
#
# Quick start examples:
#   # Interactive server setup
#   sudo bash prep_master.sh --profile server
#
#   # Noninteractive dev setup with explicit users
#   sudo bash prep_master.sh --noninteractive \
#     --profile dev \
#     --ssh-user deploybot \
#     --admin-user sysadmin \
#     --enable-docker
#
# Idempotency:
#   Safe to re-run. Uses drop-ins (sshd_config.d, jail.d, systemd overrides),
#   creates users only if missing, and applies firewall rules predictably.
#
# Security model (recommended):
#   - SSH_USER: non-sudo SSH login user for remote access
#   - ADMIN_USER: sudo-capable admin user, denied SSH by default
#   - Elevation pattern: SSH in as SSH_USER -> su - ADMIN_USER -> sudo ...
#
set -euo pipefail
IFS=$'\n\t'
umask 027

readonly VERSION="1.4.0"

# ---------------------------
# Constants (paths; tweak here if your distro differs)
# ---------------------------
readonly SSH_CONFIG_DIR="/etc/ssh/sshd_config.d"
readonly SSH_HARDEN_DROPIN="${SSH_CONFIG_DIR}/99-prep-master-hardening.conf"

readonly FAIL2BAN_JAIL_DIR="/etc/fail2ban/jail.d"
readonly FAIL2BAN_SSHD_JAIL="${FAIL2BAN_JAIL_DIR}/sshd-prep-master.local"

readonly NODE_EXPORTER_TEXTFILE_DIR="/var/lib/node_exporter/textfile_collector"
readonly NODE_EXPORTER_SVC="prometheus-node-exporter"
readonly NODE_EXPORTER_OVERRIDE_DIR="/etc/systemd/system/${NODE_EXPORTER_SVC}.service.d"
readonly NODE_EXPORTER_OVERRIDE_FILE="${NODE_EXPORTER_OVERRIDE_DIR}/override.conf"

readonly LOG_FILE="/var/log/prep_master.log"

# ---------------------------
# Logging / helpers
# ---------------------------
ts() { date +"%Y-%m-%d %H:%M:%S%z"; }
log() { echo "[$(ts)] $*" | tee -a "$LOG_FILE" >&2; }
die() { log "ERROR: $*"; exit 1; }

need_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    die "Run as root (use sudo)."
  fi
}

have() { command -v "$1" >/dev/null 2>&1; }

prompt() {
  local q="$1"; local def="${2:-}"
  local ans=""
  if [[ "${NONINTERACTIVE}" == "1" ]]; then
    echo "$def"
    return 0
  fi
  if [[ -n "$def" ]]; then
    read -r -p "$q [$def]: " ans
    echo "${ans:-$def}"
  else
    read -r -p "$q: " ans
    echo "$ans"
  fi
}

prompt_yn() {
  local q="$1"; local def="${2:-y}"
  local ans=""
  if [[ "${NONINTERACTIVE}" == "1" ]]; then
    [[ "$def" =~ ^[Yy]$ ]]
    return $?
  fi
  read -r -p "$q [${def}/$( [[ "$def" == "y" ]] && echo "n" || echo "y" )]: " ans
  ans="${ans:-$def}"
  [[ "$ans" =~ ^[Yy]$ ]]
}

append_if_missing() {
  local file="$1" line="$2"
  mkdir -p "$(dirname "$file")"
  touch "$file"
  grep -Fqx "$line" "$file" || echo "$line" >> "$file"
}

# ---------------------------
# systemctl helpers
# ---------------------------
systemctl_unit_exists() {
  have systemctl || return 1
  systemctl list-unit-files --type=service 2>/dev/null | awk '{print $1}' | grep -Fxq "$1"
}

warn_if_multiple_ssh_units() {
  # Edge case: both ssh.service and sshd.service exist. Not fatal, but suspicious.
  if have systemctl; then
    if systemctl_unit_exists "ssh.service" && systemctl_unit_exists "sshd.service"; then
      log "WARNING: Both ssh.service and sshd.service are present. This is unusual; ensure only one is active/configured."
    fi
  fi
}

svc_enable_restart() {
  # Important but recoverable
  local svc="$1"
  if have systemctl; then
    systemctl daemon-reload || true
    systemctl enable "$svc" >/dev/null 2>&1 || true
    systemctl restart "$svc" >/dev/null 2>&1 || true
  else
    service "$svc" restart >/dev/null 2>&1 || true
  fi
}

restart_ssh_service_safe() {
  # Critical: avoid lockout by validating config first.
  log "Testing SSH configuration before applying..."
  if have sshd; then
    sshd -t 2>&1 | tee -a "$LOG_FILE" || die "SSH config test failed. NOT reloading/restarting (prevents lockout)."
  elif have /usr/sbin/sshd; then
    /usr/sbin/sshd -t 2>&1 | tee -a "$LOG_FILE" || die "SSH config test failed. NOT reloading/restarting (prevents lockout)."
  else
    log "WARNING: sshd binary not found; cannot test config. Proceeding cautiously."
  fi

  log "SSH config valid. Applying via reload-or-restart..."
  if have systemctl; then
    if systemctl_unit_exists "ssh.service"; then
      systemctl reload-or-restart ssh 2>&1 | tee -a "$LOG_FILE"
      return 0
    fi
    if systemctl_unit_exists "sshd.service"; then
      systemctl reload-or-restart sshd 2>&1 | tee -a "$LOG_FILE"
      return 0
    fi
  fi

  # Fallback if no systemd
  service ssh restart 2>&1 | tee -a "$LOG_FILE" && return 0
  service sshd restart 2>&1 | tee -a "$LOG_FILE" && return 0

  die "Failed to apply SSH service changes (reload/restart)."
}

ensure_ssh_running() {
  # Best-effort: start the SSH service if present and not active.
  if have systemctl; then
    if systemctl_unit_exists "ssh.service"; then
      systemctl is-active ssh >/dev/null 2>&1 || { log "Attempting to start ssh.service..."; systemctl start ssh || true; }
      return 0
    fi
    if systemctl_unit_exists "sshd.service"; then
      systemctl is-active sshd >/dev/null 2>&1 || { log "Attempting to start sshd.service..."; systemctl start sshd || true; }
      return 0
    fi
  fi
  service ssh start >/dev/null 2>&1 || true
  service sshd start >/dev/null 2>&1 || true
}

# ---------------------------
# CLI args / toggles
# ---------------------------
NONINTERACTIVE=0
PROFILE=""

# Users
SSH_USER=""           # non-sudo SSH login user
ADMIN_USER=""         # sudo-capable admin user (optional)
ALLOW_ADMIN_SSH="0"   # safer default: deny admin SSH

# SSH
SET_TZ=""
SSH_PORT="22"
ENABLE_SSH_HARDEN=""
ALLOW_PASSWORD_AUTH=""     # yes/no
ALLOW_TCP_FORWARDING=""    # yes/no

# Optional components
ENABLE_UFW=""
ENABLE_FAIL2BAN=""
ENABLE_DOCKER=""
ENABLE_NODE_EXPORTER=""
ENABLE_CHECKMK=""
ENABLE_QEMU_GUEST_AGENT=""

usage() {
  cat <<EOF
prep_master.sh v$VERSION

Usage:
  sudo bash prep_master.sh [options]

User options:
  --ssh-user <name>          Create/ensure NON-sudo SSH login user exists.
  --admin-user <name>        Create/ensure sudo-enabled admin user exists.
  --allow-admin-ssh          Allow admin user to SSH (default: off).
  --deny-admin-ssh           Deny admin user SSH (default).

General:
  --profile <minimal|server|dev>     Choose install profile.
  --noninteractive                   Run with defaults (no prompts).
  --tz <Area/City>                   Set timezone (default: America/New_York)
  --ssh-port <port>                  SSH port to allow in firewall (default: 22)

Feature toggles:
  --enable-ssh-hardening | --disable-ssh-hardening
  --enable-ufw          | --disable-ufw
  --enable-fail2ban     | --disable-fail2ban
  --enable-docker       | --disable-docker
  --enable-node-exporter| --disable-node-exporter
  --enable-checkmk      | --disable-checkmk
  --enable-qemu-guest-agent | --disable-qemu-guest-agent
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="${2:-}"; shift 2 ;;
    --noninteractive) NONINTERACTIVE=1; shift ;;
    --ssh-user) SSH_USER="${2:-}"; shift 2 ;;
    --admin-user) ADMIN_USER="${2:-}"; shift 2 ;;
    --allow-admin-ssh) ALLOW_ADMIN_SSH="1"; shift ;;
    --deny-admin-ssh) ALLOW_ADMIN_SSH="0"; shift ;;
    --tz) SET_TZ="${2:-}"; shift 2 ;;
    --ssh-port) SSH_PORT="${2:-22}"; shift 2 ;;

    --enable-ssh-hardening) ENABLE_SSH_HARDEN="1"; shift ;;
    --disable-ssh-hardening) ENABLE_SSH_HARDEN="0"; shift ;;
    --enable-ufw) ENABLE_UFW="1"; shift ;;
    --disable-ufw) ENABLE_UFW="0"; shift ;;
    --enable-fail2ban) ENABLE_FAIL2BAN="1"; shift ;;
    --disable-fail2ban) ENABLE_FAIL2BAN="0"; shift ;;
    --enable-docker) ENABLE_DOCKER="1"; shift ;;
    --disable-docker) ENABLE_DOCKER="0"; shift ;;
    --enable-node-exporter) ENABLE_NODE_EXPORTER="1"; shift ;;
    --disable-node-exporter) ENABLE_NODE_EXPORTER="0"; shift ;;
    --enable-checkmk) ENABLE_CHECKMK="1"; shift ;;
    --disable-checkmk) ENABLE_CHECKMK="0"; shift ;;
    --enable-qemu-guest-agent) ENABLE_QEMU_GUEST_AGENT="1"; shift ;;
    --disable-qemu-guest-agent) ENABLE_QEMU_GUEST_AGENT="0"; shift ;;

    -h|--help) usage; exit 0 ;;
    *) die "Unknown arg: $1 (use --help)" ;;
  esac
done

# ---------------------------
# OS / package manager detection
# ---------------------------
OS_FAMILY="unknown"
PKG_MGR=""

detect_os() {
  if have apt-get; then
    OS_FAMILY="debian"
    PKG_MGR="apt"
  elif have dnf; then
    OS_FAMILY="rhel"
    PKG_MGR="dnf"
  elif have yum; then
    OS_FAMILY="rhel"
    PKG_MGR="yum"
  else
    die "Unsupported OS/package manager (need apt/dnf/yum)."
  fi
  log "Detected OS_FAMILY=$OS_FAMILY PKG_MGR=$PKG_MGR"
}

pkg_update() {
  case "$PKG_MGR" in
    apt) export DEBIAN_FRONTEND=noninteractive; apt-get update -y ;;
    dnf) dnf -y makecache ;;
    yum) yum -y makecache fast || yum -y makecache ;;
  esac
}

pkg_upgrade() {
  case "$PKG_MGR" in
    apt) export DEBIAN_FRONTEND=noninteractive; apt-get upgrade -y ;;
    dnf) dnf -y upgrade ;;
    yum) yum -y update ;;
  esac
}

pkg_install() {
  local pkgs=("$@")
  case "$PKG_MGR" in
    apt) export DEBIAN_FRONTEND=noninteractive; apt-get install -y "${pkgs[@]}" ;;
    dnf) dnf -y install "${pkgs[@]}" ;;
    yum) yum -y install "${pkgs[@]}" ;;
  esac
}

# ---------------------------
# Profiles / defaults
# ---------------------------
choose_profile_defaults() {
  if [[ -z "$PROFILE" ]]; then
    PROFILE="$(prompt "Choose profile (minimal/server/dev)" "server")"
  fi

  case "$PROFILE" in
    minimal)
      : "${ENABLE_SSH_HARDEN:=0}"
      : "${ENABLE_UFW:=0}"
      : "${ENABLE_FAIL2BAN:=0}"
      : "${ENABLE_DOCKER:=0}"
      : "${ENABLE_NODE_EXPORTER:=0}"
      : "${ENABLE_CHECKMK:=0}"
      : "${ENABLE_QEMU_GUEST_AGENT:=0}"
      ;;
    server)
      : "${ENABLE_SSH_HARDEN:=1}"
      : "${ENABLE_UFW:=1}"
      : "${ENABLE_FAIL2BAN:=1}"
      : "${ENABLE_DOCKER:=0}"
      : "${ENABLE_NODE_EXPORTER:=1}"
      : "${ENABLE_CHECKMK:=0}"
      : "${ENABLE_QEMU_GUEST_AGENT:=1}"
      ;;
    dev)
      : "${ENABLE_SSH_HARDEN:=1}"
      : "${ENABLE_UFW:=1}"
      : "${ENABLE_FAIL2BAN:=1}"
      : "${ENABLE_DOCKER:=1}"
      : "${ENABLE_NODE_EXPORTER:=1}"
      : "${ENABLE_CHECKMK:=0}"
      : "${ENABLE_QEMU_GUEST_AGENT:=1}"
      ;;
    *) die "Unknown profile: $PROFILE" ;;
  esac

  : "${SET_TZ:=America/New_York}"
  : "${SSH_PORT:=22}"

  if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || (( SSH_PORT < 1 || SSH_PORT > 65535 )); then
    die "Invalid --ssh-port: $SSH_PORT"
  fi

  if [[ -z "$SSH_USER" ]]; then
    SSH_USER="$(prompt "Create/ensure SSH login user (non-sudo). Blank to skip" "ops")"
    [[ -z "$SSH_USER" ]] && SSH_USER=""
  fi

  if [[ -z "$ADMIN_USER" ]]; then
    ADMIN_USER="$(prompt "Create/ensure admin user (sudo). Blank to skip" "admin")"
    [[ -z "$ADMIN_USER" ]] && ADMIN_USER=""
  fi

  if [[ "$NONINTERACTIVE" == "0" && -n "$ADMIN_USER" ]]; then
    if prompt_yn "Allow admin user to SSH? (safer: no)" "n"; then
      ALLOW_ADMIN_SSH="1"
    else
      ALLOW_ADMIN_SSH="0"
    fi
  fi
}

# ---------------------------
# Packages (critical vs optional)
# ---------------------------
install_base_packages() {
  log "Installing critical packages (fail-fast)..."
  local critical_pkgs=(ca-certificates curl sudo openssh-server)
  pkg_install "${critical_pkgs[@]}" || die "Critical packages failed: ${critical_pkgs[*]}"

  log "Installing optional packages (best-effort)..."
  local optional_pkgs=(
    wget gnupg
    git vim nano
    jq tmux
    unzip zip
    rsync
    lsof psmisc
    htop iotop iftop
    tree
    netcat-openbsd
    dnsutils
    traceroute
    tcpdump
    ethtool
    iperf3
    python3 python3-pip python3-venv
    iproute2   # provides ss (usually present, but harmless to include)
    net-tools  # provides netstat (fallback)
  )

  if [[ "$OS_FAMILY" == "debian" ]]; then
    optional_pkgs+=(apt-transport-https software-properties-common)
    optional_pkgs+=(build-essential pkg-config)
    optional_pkgs+=(chrony)
  fi

  pkg_install "${optional_pkgs[@]}" || log "Some optional packages failed (non-fatal)."

  # Ensure host keys exist
  if have ssh-keygen; then
    ssh-keygen -A || true
  fi

  # Ensure privilege separation dir exists
  mkdir -p /run/sshd || true
  chmod 755 /run/sshd || true
}

# ---------------------------
# Timezone / time sync
# ---------------------------
configure_time() {
  log "Configuring timezone: $SET_TZ"
  if have timedatectl; then
    timedatectl set-timezone "$SET_TZ" || log "timedatectl failed (non-fatal)."
  elif [[ -e "/usr/share/zoneinfo/$SET_TZ" ]]; then
    ln -sf "/usr/share/zoneinfo/$SET_TZ" /etc/localtime
    echo "$SET_TZ" >/etc/timezone || true
  fi

  # Safer with set -e: explicit if-blocks (no accidental exit paths)
  if have systemctl; then
    if systemctl_unit_exists "chrony.service"; then
      svc_enable_restart chrony || true
    fi
    if systemctl_unit_exists "chronyd.service"; then
      svc_enable_restart chronyd || true
    fi
    if systemctl_unit_exists "systemd-timesyncd.service"; then
      svc_enable_restart systemd-timesyncd || true
    fi
  fi
}

# ---------------------------
# User management
# ---------------------------
default_shell() {
  [[ -x /bin/bash ]] && echo "/bin/bash" || echo "/bin/sh"
}

create_user_if_missing() {
  local u="$1" sh="${2:-/bin/bash}"
  if id "$u" >/dev/null 2>&1; then
    log "User exists: $u"
  else
    log "Creating user: $u"
    useradd -m -s "$sh" "$u"
  fi
}

set_user_password_optional() {
  local u="$1"
  if [[ "$NONINTERACTIVE" == "1" ]]; then
    log "Noninteractive: not setting password for $u. Set manually: passwd $u"
    return 0
  fi
  log "Password guidance for '$u': use a STRONG password (12+ chars; mix case, numbers, symbols)."
  if prompt_yn "Set password for $u now? (recommended if you'll use su)" "y"; then
    passwd "$u"
  fi
}

install_authorized_key_optional() {
  local u="$1"
  if [[ "$NONINTERACTIVE" == "1" ]]; then
    log "Noninteractive: skipping SSH key prompt for $u."
    return 0
  fi

  if prompt_yn "Add an SSH public key to $u authorized_keys?" "y"; then
    echo "Paste the SSH public key (single line), then Enter:"
    local key=""
    read -r key
    [[ -n "$key" ]] || { log "No key provided; skipping."; return 0; }

    local home_dir
    home_dir="$(getent passwd "$u" | cut -d: -f6)"
    [[ -n "$home_dir" && -d "$home_dir" ]] || die "Could not determine home directory for $u"

    mkdir -p "$home_dir/.ssh"
    chmod 700 "$home_dir/.ssh"
    touch "$home_dir/.ssh/authorized_keys"
    chmod 600 "$home_dir/.ssh/authorized_keys"
    chown -R "$u:$u" "$home_dir/.ssh"
    append_if_missing "$home_dir/.ssh/authorized_keys" "$key"
    chown "$u:$u" "$home_dir/.ssh/authorized_keys"
    log "SSH key added for $u"
  fi
}

ensure_users() {
  local sh
  sh="$(default_shell)"

  if [[ -n "$SSH_USER" ]]; then
    create_user_if_missing "$SSH_USER" "$sh"
    set_user_password_optional "$SSH_USER"
    install_authorized_key_optional "$SSH_USER"
  else
    log "Skipping SSH user creation."
  fi

  if [[ -n "$ADMIN_USER" ]]; then
    create_user_if_missing "$ADMIN_USER" "$sh"
    set_user_password_optional "$ADMIN_USER"
    install_authorized_key_optional "$ADMIN_USER"

    if getent group sudo >/dev/null 2>&1; then
      usermod -aG sudo "$ADMIN_USER"
    elif getent group wheel >/dev/null 2>&1; then
      usermod -aG wheel "$ADMIN_USER"
    else
      log "WARNING: No sudo/wheel group found; sudo elevation may need manual setup."
    fi
  else
    log "Skipping admin user creation."
  fi
}

# ---------------------------
# SSH lockout preflight validation
# ---------------------------
validate_ssh_access() {
  local -a allowed=("$@")

  [[ "$ENABLE_SSH_HARDEN" == "1" ]] || return 0
  [[ "${ALLOW_PASSWORD_AUTH:-}" == "no" ]] || return 0

  if [[ ${#allowed[@]} -eq 0 ]]; then
    log "WARNING: PasswordAuthentication=no but no AllowUsers enforced. Ensure your SSH user has keys."
    return 0
  fi

  local has_keys=0 u home_dir
  for u in "${allowed[@]}"; do
    home_dir="$(getent passwd "$u" | cut -d: -f6 || true)"
    if [[ -n "$home_dir" && -f "$home_dir/.ssh/authorized_keys" && -s "$home_dir/.ssh/authorized_keys" ]]; then
      has_keys=1
      break
    fi
  done

  if [[ $has_keys -eq 0 ]]; then
    log "WARNING: PasswordAuthentication=no AND no non-empty authorized_keys found for allowed SSH users: ${allowed[*]}"
    log "You may be locked out after applying SSH config/firewall."
    if [[ "$NONINTERACTIVE" == "0" ]]; then
      prompt_yn "Continue anyway? (risky!)" "n" || die "Aborted to prevent lockout."
    else
      log "Noninteractive: continuing despite risk (verify console access)."
    fi
  fi
}

# ---------------------------
# SSH hardening (drop-in)
# ---------------------------
harden_ssh() {
  [[ "$ENABLE_SSH_HARDEN" == "1" ]] || { log "SSH hardening disabled."; return 0; }

  log "Configuring SSH hardening..."
  mkdir -p "$SSH_CONFIG_DIR"

  if [[ -z "$ALLOW_PASSWORD_AUTH" ]]; then
    if prompt_yn "Allow SSH password authentication temporarily?" "n"; then
      ALLOW_PASSWORD_AUTH="yes"
    else
      ALLOW_PASSWORD_AUTH="no"
    fi
  fi

  if [[ -z "$ALLOW_TCP_FORWARDING" ]]; then
    if prompt_yn "Allow SSH TCP forwarding (tunnels)?" "n"; then
      ALLOW_TCP_FORWARDING="yes"
    else
      ALLOW_TCP_FORWARDING="no"
    fi
  fi

  local -a allow_users_list=()
  [[ -n "$SSH_USER" ]] && allow_users_list+=("$SSH_USER")
  [[ -n "$ADMIN_USER" && "$ALLOW_ADMIN_SSH" == "1" ]] && allow_users_list+=("$ADMIN_USER")

  cat >"$SSH_HARDEN_DROPIN" <<EOF
# Managed by prep_master.sh v$VERSION
# NOTE: Correct directive is "AllowUsers" (not "AllowedUsers")

Protocol 2
PermitRootLogin no

# Authentication
PasswordAuthentication $ALLOW_PASSWORD_AUTH
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no

# Reduce attack surface
X11Forwarding no
AllowAgentForwarding no
PermitTunnel no
PermitUserEnvironment no
AllowTcpForwarding $ALLOW_TCP_FORWARDING

# Connection behavior
LoginGraceTime 30
MaxAuthTries 4
MaxSessions 10
ClientAliveInterval 300
ClientAliveCountMax 2

# Logging
LogLevel VERBOSE
EOF

  if [[ ${#allow_users_list[@]} -gt 0 ]]; then
    printf "AllowUsers %s\n" "${allow_users_list[*]}" >>"$SSH_HARDEN_DROPIN"
  fi

  chmod 644 "$SSH_HARDEN_DROPIN" || true

  validate_ssh_access "${allow_users_list[@]}"

  restart_ssh_service_safe
  ensure_ssh_running  # extra safety for fresh installs

  log "SSH hardening applied: $SSH_HARDEN_DROPIN"
}

# ---------------------------
# UFW helpers
# ---------------------------
detect_sshd_config_ports() {
  local ports=""
  if have sshd; then
    ports="$(sshd -T 2>/dev/null | awk '$1=="port"{print $2}' | xargs || true)"
  elif have /usr/sbin/sshd; then
    ports="$(/usr/sbin/sshd -T 2>/dev/null | awk '$1=="port"{print $2}' | xargs || true)"
  fi
  echo "$ports"
}

is_port_listening_tcp() {
  # Modern ss -ltn shows both IPv4 and IPv6 listeners.
  # Avoid ss -H for compatibility; just skip the header line.
  local port="$1"

  if have ss; then
    ss -ltn 2>/dev/null | tail -n +2 | awk '{print $4}' | grep -Eq "(:|\\])${port}\$" && return 0
  elif have netstat; then
    netstat -ltn 2>/dev/null | tail -n +3 | awk '{print $4}' | grep -Eq "(:|\\])${port}\$" && return 0
  fi

  return 1
}

ufw_is_active() {
  have ufw || return 1
  ufw status 2>/dev/null | grep -q "Status: active"
}

# ---------------------------
# UFW firewall (Debian/Ubuntu focused)
# ---------------------------
setup_ufw() {
  [[ "$ENABLE_UFW" == "1" ]] || { log "UFW disabled."; return 0; }
  if [[ "$OS_FAMILY" != "debian" ]]; then
    log "UFW setup is Debian/Ubuntu-focused; skipping on this OS."
    return 0
  fi

  log "Installing and configuring UFW..."
  pkg_install ufw || die "UFW requested but failed to install."

  # Warn if UFW is already active (reset will wipe existing rules)
  if ufw_is_active; then
    log "WARNING: UFW is already active. Resetting will delete existing rules."
    if [[ "$NONINTERACTIVE" == "0" ]]; then
      prompt_yn "Continue with UFW reset and reconfigure?" "y" || { log "Skipping UFW configuration by user choice."; return 0; }
    fi
  fi

  # Detect all configured sshd ports (multi-port safe)
  local -a actual_ports=()
  local ports_str=""
  ports_str="$(detect_sshd_config_ports)"
  if [[ -n "$ports_str" ]]; then
    read -r -a actual_ports <<<"$ports_str"
  fi

  if [[ ${#actual_ports[@]} -gt 0 ]]; then
    local p
    for p in "${actual_ports[@]}"; do
      if [[ "$p" != "$SSH_PORT" ]]; then
        log "WARNING: sshd configured to listen on port $p, but SSH_PORT for firewall is $SSH_PORT"
      fi
    done
  fi

  # Reset to known state
  ufw --force reset

  ufw default deny incoming
  ufw default allow outgoing

  # Always allow the requested SSH_PORT
  ufw allow "${SSH_PORT}/tcp" || die "Failed to allow SSH_PORT ${SSH_PORT}/tcp in UFW"

  # Allow ALL sshd-configured ports; if allowing fails, treat as lockout-risk.
  if [[ ${#actual_ports[@]} -gt 0 ]]; then
    local p
    for p in "${actual_ports[@]}"; do
      [[ "$p" == "$SSH_PORT" ]] && continue
      if ! ufw allow "${p}/tcp"; then
        log "ERROR: Failed to allow sshd-configured port ${p}/tcp in UFW"
        if [[ "$NONINTERACTIVE" == "1" ]]; then
          die "CRITICAL: Cannot proceed without allowing sshd port ${p}/tcp in noninteractive mode (lockout risk)."
        else
          prompt_yn "Continue anyway? (risky - sshd may use this port!)" "n" || die "Aborted to prevent lockout."
        fi
      fi
    done
  fi

  # Ensure SSH is running before we decide it's "not listening"
  ensure_ssh_running

  # Check listening for SSH_PORT specifically (the port you expect to use)
  if ! is_port_listening_tcp "$SSH_PORT"; then
    log "WARNING: Nothing appears to be listening on TCP port $SSH_PORT right now."

    # Try one more time to start SSH (fresh installs / race)
    ensure_ssh_running

    if ! is_port_listening_tcp "$SSH_PORT"; then
      log "ERROR: Still not listening on $SSH_PORT after attempting to start SSH."
      if [[ "$NONINTERACTIVE" == "0" ]]; then
        prompt_yn "Continue enabling UFW anyway? (very risky!)" "n" || die "Aborted to prevent likely lockout."
      else
        die "Noninteractive: refusing to enable UFW when SSH_PORT is not listening (prevents lockout)."
      fi
    fi
  fi

  if [[ "$NONINTERACTIVE" == "0" ]]; then
    local extra
    extra="$(prompt "Extra ports to allow (comma-separated, e.g. 80/tcp,443/tcp). Blank to skip" "")"
    if [[ -n "$extra" ]]; then
      IFS=',' read -r -a parts <<<"$extra"
      for p in "${parts[@]}"; do
        p="$(echo "$p" | xargs)"
        [[ -n "$p" ]] || continue
        ufw allow "$p" || log "Failed to allow $p (non-fatal)."
      done
    fi
  fi

  if ! ufw --force enable; then
    log "ERROR: Failed to enable UFW. Firewall is now in reset state."
    log "Manual intervention required. Check: ufw status"
    die "UFW enable failed"
  fi

  ufw status verbose | tee -a "$LOG_FILE" >/dev/null
  log "UFW enabled."
}

# ---------------------------
# Fail2Ban
# ---------------------------
setup_fail2ban() {
  [[ "$ENABLE_FAIL2BAN" == "1" ]] || { log "Fail2Ban disabled."; return 0; }

  log "Installing and configuring Fail2Ban..."
  pkg_install fail2ban || die "Fail2Ban requested but failed to install."

  mkdir -p "$FAIL2BAN_JAIL_DIR"

  cat >"$FAIL2BAN_SSHD_JAIL" <<EOF
[sshd]
enabled = true
backend = systemd
mode = normal
maxretry = 5
findtime = 10m
bantime  = 1h
EOF

  if have ufw; then
    append_if_missing "$FAIL2BAN_SSHD_JAIL" "banaction = ufw"
  fi

  svc_enable_restart fail2ban || log "Fail2Ban service failed to start (check manually)."
  log "Fail2Ban enabled for sshd."
}

# ---------------------------
# Docker (simple via distro packages)
# ---------------------------
setup_docker() {
  [[ "$ENABLE_DOCKER" == "1" ]] || { log "Docker disabled."; return 0; }

  log "Installing Docker (distro packages)..."
  if [[ "$OS_FAMILY" == "debian" ]]; then
    pkg_install docker.io docker-compose-plugin || die "Docker requested but failed to install."
    svc_enable_restart docker || log "Docker service failed to start (check manually)."
  else
    pkg_install docker docker-compose || log "Docker install failed on this OS (non-fatal)."
    svc_enable_restart docker || log "Docker service failed to start (check manually)."
  fi

  if [[ -n "$ADMIN_USER" ]] && id "$ADMIN_USER" >/dev/null 2>&1; then
    getent group docker >/dev/null 2>&1 || groupadd docker || true
    usermod -aG docker "$ADMIN_USER" || true
    log "Added $ADMIN_USER to docker group (re-login needed)."
    log "WARNING: Docker group grants root-equivalent access. Use with caution."
  fi
}

# ---------------------------
# node_exporter + textfile collector (Debian/Ubuntu focused)
# ---------------------------
setup_node_exporter() {
  [[ "$ENABLE_NODE_EXPORTER" == "1" ]] || { log "node_exporter disabled."; return 0; }
  if [[ "$OS_FAMILY" != "debian" ]]; then
    log "node_exporter setup is Debian/Ubuntu-focused; skipping on this OS."
    return 0
  fi

  log "Installing node_exporter..."
  pkg_install prometheus-node-exporter || die "node_exporter requested but failed to install."

  mkdir -p "$NODE_EXPORTER_TEXTFILE_DIR"
  chmod 755 "$NODE_EXPORTER_TEXTFILE_DIR" || true

  mkdir -p "$NODE_EXPORTER_OVERRIDE_DIR"

  local bin=""
  bin="$(command -v prometheus-node-exporter || true)"
  [[ -n "$bin" ]] || bin="$(command -v node_exporter || true)"
  [[ -n "$bin" ]] || die "node_exporter binary not found after install."

  cat >"$NODE_EXPORTER_OVERRIDE_FILE" <<EOF
# Managed by prep_master.sh v$VERSION
[Service]
ExecStart=
ExecStart=$bin --collector.textfile.directory=$NODE_EXPORTER_TEXTFILE_DIR
EOF

  cat >"${NODE_EXPORTER_TEXTFILE_DIR}/metrics.prom" <<EOF
# Example textfile collector metrics
prep_master_build_info{version="$VERSION"} 1
EOF
  chmod 644 "${NODE_EXPORTER_TEXTFILE_DIR}/metrics.prom" || true

  svc_enable_restart "$NODE_EXPORTER_SVC" || log "node_exporter service failed to start (check manually)."
  log "node_exporter running with textfile collector at: $NODE_EXPORTER_TEXTFILE_DIR"
}

# ---------------------------
# Checkmk agent (optional; needs package URL)
# ---------------------------
setup_checkmk_agent() {
  [[ "$ENABLE_CHECKMK" == "1" ]] || { log "Checkmk disabled."; return 0; }

  log "Checkmk agent setup..."
  local default_base="http://checkmk.prod.home.arpa/monitoring/"
  local base_url
  base_url="$(prompt "Checkmk server base URL (for your reference)" "$default_base")"
  log "Checkmk base URL noted: $base_url"

  local agent_url
  agent_url="$(prompt "Direct Checkmk agent package URL (.deb/.rpm). Blank to skip" "")"
  if [[ -z "$agent_url" ]]; then
    log "Skipping Checkmk agent install."
    return 0
  fi

  local tmp="/tmp/checkmk-agent.$$"
  mkdir -p "$tmp"
  local pkg="$tmp/agent_pkg"
  log "Downloading agent from: $agent_url"
  curl -fsSL "$agent_url" -o "$pkg" || die "Failed to download agent package."

  local ext=""
  [[ "$agent_url" =~ \.deb($|\?) ]] && ext="deb"
  [[ "$agent_url" =~ \.rpm($|\?) ]] && ext="rpm"

  if [[ -z "$ext" ]]; then
    file "$pkg" | grep -qi 'debian binary package' && ext="deb"
    file "$pkg" | grep -qi 'rpm' && ext="rpm"
  fi

  case "$ext" in
    deb)
      if ! dpkg -i "$pkg"; then
        log "dpkg failed, attempting to fix dependencies..."
        apt-get -f install -y || die "Failed to fix Checkmk dependencies"
        dpkg -i "$pkg" || die "Checkmk .deb install failed after dependency fix"
      fi
      ;;
    rpm)
      have rpm || die "rpm not found; cannot install .rpm"
      rpm -Uvh "$pkg" || die "Checkmk .rpm install failed."
      ;;
    *)
      die "Could not determine agent package type (.deb/.rpm)."
      ;;
  esac

  rm -rf "$tmp"
  log "Checkmk agent install completed."
}

# ---------------------------
# Proxmox qemu-guest-agent
# ---------------------------
setup_qemu_guest_agent() {
  [[ "$ENABLE_QEMU_GUEST_AGENT" == "1" ]] || { log "qemu-guest-agent disabled."; return 0; }

  log "Installing qemu-guest-agent..."
  pkg_install qemu-guest-agent || log "qemu-guest-agent install failed (non-fatal)."
  svc_enable_restart qemu-guest-agent || log "qemu-guest-agent service failed (check manually)."
}

# ---------------------------
# QoL defaults (safe)
# ---------------------------
configure_shell_defaults() {
  log "Configuring small QoL defaults..."
  local skel="/etc/skel/.tmux.conf"
  cat >"$skel" <<'EOF'
# Basic tmux defaults
set -g mouse on
setw -g mode-keys vi
set -g history-limit 20000
EOF

  for u in "$SSH_USER" "$ADMIN_USER"; do
    [[ -n "$u" ]] || continue
    if id "$u" >/dev/null 2>&1; then
      local home_dir
      home_dir="$(getent passwd "$u" | cut -d: -f6)"
      [[ -n "$home_dir" && -d "$home_dir" ]] || continue
      [[ -f "$home_dir/.tmux.conf" ]] || cp -f "$skel" "$home_dir/.tmux.conf"
      chown "$u:$u" "$home_dir/.tmux.conf" || true
    fi
  done
}

# ---------------------------
# Log file permissions
# ---------------------------
secure_logfile() {
  touch "$LOG_FILE" || die "Cannot write log file: $LOG_FILE"
  chmod 0640 "$LOG_FILE" || true
  if getent group adm >/dev/null 2>&1; then
    chown root:adm "$LOG_FILE" || true
  else
    chown root:root "$LOG_FILE" || true
  fi
}

# ---------------------------
# Main
# ---------------------------
main() {
  need_root
  secure_logfile

  log "==== prep_master.sh v$VERSION starting ===="
  detect_os
  warn_if_multiple_ssh_units
  choose_profile_defaults

  log "Profile=$PROFILE | SSH_HARDEN=$ENABLE_SSH_HARDEN UFW=$ENABLE_UFW FAIL2BAN=$ENABLE_FAIL2BAN DOCKER=$ENABLE_DOCKER NODE_EXPORTER=$ENABLE_NODE_EXPORTER CHECKMK=$ENABLE_CHECKMK QEMU_GUEST_AGENT=$ENABLE_QEMU_GUEST_AGENT"
  log "Users: SSH_USER='${SSH_USER:-}' (non-sudo), ADMIN_USER='${ADMIN_USER:-}' (sudo), ALLOW_ADMIN_SSH=$ALLOW_ADMIN_SSH"

  if [[ "$NONINTERACTIVE" == "0" ]]; then
    if prompt_yn "Run full OS upgrade (apt upgrade/dnf upgrade)?" "y"; then
      pkg_update
      pkg_upgrade
    else
      pkg_update
    fi
  else
    pkg_update
    pkg_upgrade || true
  fi

  install_base_packages
  configure_time

  ensure_users
  configure_shell_defaults

  # Apply SSH hardening before firewall so UFW can reflect sshd config.
  harden_ssh
  setup_ufw

  setup_fail2ban
  setup_docker
  setup_node_exporter
  setup_qemu_guest_agent
  setup_checkmk_agent

  log "==== Completed prep_master.sh v$VERSION ===="
  log "Log file: $LOG_FILE"

  if [[ -n "$SSH_USER" && -n "$ADMIN_USER" && "$ALLOW_ADMIN_SSH" == "0" ]]; then
    log "Elevation pattern: SSH in as '$SSH_USER' then run: su - $ADMIN_USER (then sudo ...)"
  fi

  if [[ "${ALLOW_PASSWORD_AUTH:-}" == "yes" ]]; then
    log "Reminder: You enabled SSH password auth. Disable it after key login is verified."
  fi
}

main "$@"
