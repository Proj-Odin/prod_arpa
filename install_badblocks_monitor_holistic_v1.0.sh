#!/usr/bin/env bash
# install_badblocks_monitor_holistic.sh
# Installs:
# - /usr/local/bin/badblocks_state_update.sh
# - systemd oneshot service + timer (runs every N seconds)
# - hdd-burnin system group/user + permissions model
# - node_exporter textfile collector linkage (symlink .prom into textfile dir)
#
# Idempotent and safe to re-run.

set -euo pipefail

SERVICE_NAME="badblocks-monitor"
BIN_DST="/usr/local/bin/badblocks_state_update.sh"
ENV_FILE="/etc/default/${SERVICE_NAME}"
UNIT_DIR="/etc/systemd/system"

STATE_ROOT="/var/lib/hdd_burnin"
STATE_DIR="${STATE_ROOT}/badblocks"
ARCHIVE_DIR="${STATE_DIR}/archive"
DEDUPE_DIR="${STATE_DIR}/.dedupe"
LOG_FILE="/var/log/badblocks_state_update.log"
ORCH_STATE="${STATE_ROOT}/orchestrator_state.json"

# Node exporter
NODE_TEXTFILE_LINK_NAME="badblocks_state.prom"
NODE_TEXTFILE_DIR=""
NODE_EXPORTER_USER=""
AUTO_CONFIG_NODE_EXPORTER=1

# Security model
BURNIN_GROUP="hdd-burnin"
BURNIN_USER="hdd-burnin"
CREATE_USER_GROUP=1

# Timer interval
INTERVAL_SECONDS=60

# Source script to install
SCRIPT_SRC="./badblocks_state_update.sh"

DO_ENABLE=1
DO_START=1

usage() {
  cat <<EOF
Usage:
  sudo $0 install [--script /path/to/badblocks_state_update.sh] [--interval 60]
                  [--no-enable] [--no-start]
                  [--no-node-exporter]
                  [--no-user-group]
                  [--textfile-dir /path/to/textfile_collector]

  sudo $0 uninstall [--yes]
  sudo $0 status
  sudo $0 run-now

Notes:
- Default script source: ./badblocks_state_update.sh
- Installs: ${SERVICE_NAME}.service + ${SERVICE_NAME}.timer
- State root: ${STATE_ROOT}
EOF
}

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "ERROR: must run as root (use sudo)." >&2
    exit 1
  fi
}

have_cmd(){ command -v "$1" >/dev/null 2>&1; }

ensure_group_user(){
  [[ "$CREATE_USER_GROUP" -eq 1 ]] || return 0

  if ! getent group "$BURNIN_GROUP" >/dev/null; then
    groupadd --system "$BURNIN_GROUP"
    echo "Created group: $BURNIN_GROUP"
  fi

  if ! id -u "$BURNIN_USER" >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin --gid "$BURNIN_GROUP" "$BURNIN_USER"
    echo "Created user: $BURNIN_USER"
  fi
}

create_dirs_and_perms(){
  mkdir -p "$STATE_DIR" "$ARCHIVE_DIR" "$DEDUPE_DIR"
  touch "$LOG_FILE" 2>/dev/null || true

  # Root owns; group can read. No non-root writes. This prevents symlink / state poisoning attacks.
  chown -R root:"$BURNIN_GROUP" "$STATE_ROOT" 2>/dev/null || true
  chmod 0750 "$STATE_ROOT" "$STATE_DIR" "$ARCHIVE_DIR" "$DEDUPE_DIR" 2>/dev/null || true

  chown root:"$BURNIN_GROUP" "$LOG_FILE" 2>/dev/null || true
  chmod 0640 "$LOG_FILE" 2>/dev/null || true

  # Orchestrator state file should be group-readable too (when created by orchestrator)
  if [[ -f "$ORCH_STATE" ]]; then
    chown root:"$BURNIN_GROUP" "$ORCH_STATE" 2>/dev/null || true
    chmod 0640 "$ORCH_STATE" 2>/dev/null || true
  fi
}

install_monitor_script(){
  if [[ ! -f "$SCRIPT_SRC" ]]; then
    echo "ERROR: monitor script not found at: $SCRIPT_SRC" >&2
    echo "Use: --script /path/to/badblocks_state_update.sh" >&2
    exit 1
  fi

  head -n1 "$SCRIPT_SRC" | grep -qE '^#!' || {
    echo "ERROR: $SCRIPT_SRC missing shebang; doesn’t look like a script." >&2
    exit 1
  }

  install -m 0755 "$SCRIPT_SRC" "$BIN_DST"
  echo "Installed monitor script -> $BIN_DST"
}

write_units(){
  local svc="${UNIT_DIR}/${SERVICE_NAME}.service"
  local tmr="${UNIT_DIR}/${SERVICE_NAME}.timer"

  cat >"$svc" <<EOF
[Unit]
Description=Badblocks monitoring state + Prometheus metrics updater
After=local-fs.target
ConditionPathExists=${BIN_DST}

[Service]
Type=oneshot
ExecStart=${BIN_DST}
User=root
Group=${BURNIN_GROUP}
UMask=0027

# Hardening (safe defaults; still allows /proc + /dev reads)
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
MemoryDenyWriteExecute=true

# Needs write access:
ReadWritePaths=${STATE_ROOT} /var/log /run

EnvironmentFile=-${ENV_FILE}
EOF

  cat >"$tmr" <<EOF
[Unit]
Description=Run badblocks monitoring every ${INTERVAL_SECONDS} seconds

[Timer]
OnBootSec=30s
OnUnitActiveSec=${INTERVAL_SECONDS}s
AccuracySec=10s
Persistent=true

[Install]
WantedBy=timers.target
EOF

  chmod 0644 "$svc" "$tmr"
  echo "Wrote systemd units -> ${svc}, ${tmr}"
}

write_env_file(){
  if [[ -f "$ENV_FILE" ]]; then
    echo "Keeping existing $ENV_FILE"
    return 0
  fi

  cat >"$ENV_FILE" <<EOF
# /etc/default/${SERVICE_NAME}
# Optional runtime config for badblocks_state_update.sh

# Alerts
#ALERT_EMAIL="you@example.com"
#ALERT_WEBHOOK="https://your.webhook/endpoint"

# Feature flags (monitor script must read these vars)
#ENABLE_ALERTS=1
#ENABLE_PROMETHEUS=1
#ROTATE_STATE_FILES=1
EOF

  chmod 0644 "$ENV_FILE"
  echo "Wrote defaults -> $ENV_FILE"
}

systemd_reload_enable_start(){
  systemctl daemon-reload

  if [[ "$DO_ENABLE" -eq 1 ]]; then
    systemctl enable "${SERVICE_NAME}.timer" >/dev/null
    echo "Enabled timer: ${SERVICE_NAME}.timer"
  fi

  if [[ "$DO_START" -eq 1 ]]; then
    systemctl start "${SERVICE_NAME}.timer"
    echo "Started timer: ${SERVICE_NAME}.timer"
  fi
}

# -------- Node exporter integration --------

detect_node_exporter_pid(){
  pidof node_exporter 2>/dev/null || true
}

detect_node_exporter_service_name(){
  # Common unit names
  if systemctl list-unit-files --type=service 2>/dev/null | awk '{print $1}' | grep -qx "node_exporter.service"; then
    echo "node_exporter.service"
    return 0
  fi
  if systemctl list-unit-files --type=service 2>/dev/null | awk '{print $1}' | grep -qx "prometheus-node-exporter.service"; then
    echo "prometheus-node-exporter.service"
    return 0
  fi
  echo ""
}

detect_textfile_dir_from_cmdline(){
  local pid="$1"
  [[ -n "$pid" && -r "/proc/$pid/cmdline" ]] || return 0

  local cmd
  cmd="$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true)"

  # Newer flag form
  if grep -q -- '--collector.textfile.directory=' <<<"$cmd"; then
    sed -n 's/.*--collector\.textfile\.directory=\([^ ]*\).*/\1/p' <<<"$cmd" | head -n1
    return 0
  fi

  # Alternate naming (rare)
  if grep -q -- '--collector.textfile-dir=' <<<"$cmd"; then
    sed -n 's/.*--collector\.textfile-dir=\([^ ]*\).*/\1/p' <<<"$cmd" | head -n1
    return 0
  fi

  echo ""
}

detect_node_exporter_user(){
  local pid="$1"
  local svc="$2"

  # Prefer systemd config if available
  if [[ -n "$svc" ]]; then
    local u
    u="$(systemctl show -p User --value "$svc" 2>/dev/null || true)"
    [[ -n "$u" ]] && { echo "$u"; return 0; }
  fi

  # Fall back to process owner
  if [[ -n "$pid" ]]; then
    ps -o user= -p "$pid" 2>/dev/null | awk '{print $1}' || true
    return 0
  fi

  echo ""
}

detect_textfile_dir_fallback(){
  # Common distro/package defaults
  local candidates=(
    "/var/lib/node_exporter/textfile_collector"
    "/var/lib/prometheus/node-exporter"
    "/var/lib/prometheus/node_exporter"
    "/var/lib/node_exporter"
  )

  for d in "${candidates[@]}"; do
    if [[ -d "$d" ]]; then
      echo "$d"
      return 0
    fi
  done

  # Create a sane default if none exist
  echo "/var/lib/node_exporter/textfile_collector"
}

ensure_node_exporter_textfile_link(){
  [[ "$AUTO_CONFIG_NODE_EXPORTER" -eq 1 ]] || return 0

  local pid svc tdir user

  pid="$(detect_node_exporter_pid)"
  svc="$(detect_node_exporter_service_name)"

  # Allow override by flag
  if [[ -n "$NODE_TEXTFILE_DIR" ]]; then
    tdir="$NODE_TEXTFILE_DIR"
  else
    tdir="$(detect_textfile_dir_from_cmdline "$pid")"
    [[ -z "$tdir" ]] && tdir="$(detect_textfile_dir_fallback)"
  fi

  mkdir -p "$tdir"
  chmod 0755 "$tdir" 2>/dev/null || true

  user="$(detect_node_exporter_user "$pid" "$svc")"
  NODE_EXPORTER_USER="$user"

  # Symlink a .prom into textfile dir; node_exporter reads *.prom
  local link="${tdir}/${NODE_TEXTFILE_LINK_NAME}"
  ln -sf "${STATE_DIR}/metrics.prom" "$link"

  # Ensure node_exporter can read the target file:
  # - target is root:hdd-burnin 0640, so node_exporter user must be in hdd-burnin group
  if [[ -n "$NODE_EXPORTER_USER" && "$NODE_EXPORTER_USER" != "root" ]]; then
    if id -u "$NODE_EXPORTER_USER" >/dev/null 2>&1; then
      usermod -a -G "$BURNIN_GROUP" "$NODE_EXPORTER_USER" || true
      echo "Added ${NODE_EXPORTER_USER} to group ${BURNIN_GROUP} (to read metrics)."
    fi
  fi

  echo "node_exporter textfile dir: $tdir"
  echo "Symlinked: $link -> ${STATE_DIR}/metrics.prom"
  echo "node_exporter user: ${NODE_EXPORTER_USER:-unknown}"
}

run_now(){
  systemctl start "${SERVICE_NAME}.service" || true
}

status(){
  echo "== Timer status =="
  systemctl status "${SERVICE_NAME}.timer" --no-pager -l || true
  echo
  echo "== Service status =="
  systemctl status "${SERVICE_NAME}.service" --no-pager -l || true
  echo
  echo "== Recent log tail =="
  tail -n 60 "$LOG_FILE" 2>/dev/null || true
  echo
  echo "== State dir =="
  ls -la "$STATE_DIR" 2>/dev/null || true
}

uninstall(){
  local yes=0
  [[ "${1:-}" == "--yes" ]] && yes=1

  if [[ "$yes" -ne 1 ]]; then
    read -r -p "Remove ${SERVICE_NAME}.service/.timer (keep state + scripts)? [y/N] " ans
    [[ "$ans" == "y" || "$ans" == "Y" ]] || exit 0
  fi

  systemctl disable --now "${SERVICE_NAME}.timer" 2>/dev/null || true
  rm -f "${UNIT_DIR}/${SERVICE_NAME}.service" "${UNIT_DIR}/${SERVICE_NAME}.timer"
  systemctl daemon-reload
  echo "Uninstalled units. Kept: $BIN_DST, $ENV_FILE, $STATE_ROOT"
}

# ------------- args -------------
cmd="${1:-}"; shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --script) SCRIPT_SRC="${2:-}"; shift 2 ;;
    --interval) INTERVAL_SECONDS="${2:-60}"; shift 2 ;;
    --no-enable) DO_ENABLE=0; shift ;;
    --no-start) DO_START=0; shift ;;
    --no-node-exporter) AUTO_CONFIG_NODE_EXPORTER=0; shift ;;
    --no-user-group) CREATE_USER_GROUP=0; shift ;;
    --textfile-dir) NODE_TEXTFILE_DIR="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 2
      ;;
  esac
done

need_root

case "$cmd" in
  install)
    ensure_group_user
    create_dirs_and_perms
    install_monitor_script
    write_units
    write_env_file
    systemd_reload_enable_start
    ensure_node_exporter_textfile_link
    echo "Running once now to validate..."
    run_now
    status
    ;;
  uninstall)
    uninstall "${1:-}"
    ;;
  status)
    status
    ;;
  run-now)
    run_now
    status
    ;;
  *)
    usage
    exit 2
    ;;
esac
