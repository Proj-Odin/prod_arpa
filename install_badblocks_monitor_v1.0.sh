#!/usr/bin/env bash
# install_badblocks_monitor.sh
# Idempotent installer for a oneshot systemd service + timer that runs badblocks_state_update.sh every N seconds.

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

INTERVAL_SECONDS=60
SCRIPT_SRC="./badblocks_state_update.sh"
DO_ENABLE=1
DO_START=1

usage() {
  cat <<EOF
Usage:
  sudo $0 install [--script /path/to/badblocks_state_update.sh] [--interval 60] [--no-enable] [--no-start]
  sudo $0 uninstall [--yes]
  sudo $0 status
  sudo $0 run-now

Notes:
- Default script source is ./badblocks_state_update.sh
- Installs service/timer as: ${SERVICE_NAME}.service / ${SERVICE_NAME}.timer
EOF
}

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "ERROR: must run as root (use sudo)." >&2
    exit 1
  fi
}

write_unit_files() {
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
Group=root

# Optional hardening (safe defaults; still allows /proc and /dev reads)
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
MemoryDenyWriteExecute=true

# Needs write access here:
ReadWritePaths=${STATE_ROOT} /var/log /run

# Optional config
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
}

maybe_write_env_file() {
  if [[ -f "$ENV_FILE" ]]; then
    echo "Keeping existing $ENV_FILE"
    return 0
  fi

  cat >"$ENV_FILE" <<'EOF'
# /etc/default/badblocks-monitor
# Optional runtime config for badblocks_state_update.sh

# Alerts
#ALERT_EMAIL="you@example.com"
#ALERT_WEBHOOK="https://your.webhook/endpoint"

# Feature flags (script must read these vars)
#ENABLE_ALERTS=1
#ENABLE_PROMETHEUS=1
#ROTATE_STATE_FILES=1
EOF

  chmod 0644 "$ENV_FILE"
}

create_dirs() {
  mkdir -p "$STATE_DIR" "$ARCHIVE_DIR" "$DEDUPE_DIR"
  chmod 0750 "$STATE_ROOT" "$STATE_DIR" "$ARCHIVE_DIR" "$DEDUPE_DIR" 2>/dev/null || true
  touch "$LOG_FILE" 2>/dev/null || true
  chmod 0640 "$LOG_FILE" 2>/dev/null || true
}

install_script() {
  if [[ ! -f "$SCRIPT_SRC" ]]; then
    echo "ERROR: script not found at: $SCRIPT_SRC" >&2
    echo "Provide it with: --script /path/to/badblocks_state_update.sh" >&2
    exit 1
  fi

  # Basic sanity check: has shebang and is executable-ish content
  head -n1 "$SCRIPT_SRC" | grep -qE '^#!' || {
    echo "ERROR: $SCRIPT_SRC does not look like a script (missing shebang)." >&2
    exit 1
  }

  install -m 0755 "$SCRIPT_SRC" "$BIN_DST"
}

systemd_reload_and_enable() {
  systemctl daemon-reload

  if [[ "$DO_ENABLE" -eq 1 ]]; then
    systemctl enable "${SERVICE_NAME}.timer" >/dev/null
  fi

  if [[ "$DO_START" -eq 1 ]]; then
    systemctl start "${SERVICE_NAME}.timer"
  fi
}

run_now() {
  systemctl start "${SERVICE_NAME}.service"
}

status() {
  echo "== Timer status =="
  systemctl status "${SERVICE_NAME}.timer" --no-pager -l || true
  echo
  echo "== Last service runs =="
  systemctl status "${SERVICE_NAME}.service" --no-pager -l || true
  echo
  echo "== Recent log tail =="
  tail -n 50 "$LOG_FILE" 2>/dev/null || true
  echo
  echo "== State files =="
  ls -la "$STATE_DIR" 2>/dev/null || true
}

uninstall() {
  local yes=0
  if [[ "${1:-}" == "--yes" ]]; then yes=1; fi

  if [[ "$yes" -ne 1 ]]; then
    read -r -p "This will disable/remove ${SERVICE_NAME}.service/.timer (state files kept). Continue? [y/N] " ans
    [[ "$ans" == "y" || "$ans" == "Y" ]] || exit 0
  fi

  systemctl disable --now "${SERVICE_NAME}.timer" 2>/dev/null || true
  rm -f "${UNIT_DIR}/${SERVICE_NAME}.service" "${UNIT_DIR}/${SERVICE_NAME}.timer"
  systemctl daemon-reload
  echo "Uninstalled systemd units. Kept: $BIN_DST, $ENV_FILE, and $STATE_ROOT"
}

# ----------------- arg parsing -----------------
cmd="${1:-}"
shift || true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --script) SCRIPT_SRC="${2:-}"; shift 2 ;;
    --interval) INTERVAL_SECONDS="${2:-60}"; shift 2 ;;
    --no-enable) DO_ENABLE=0; shift ;;
    --no-start) DO_START=0; shift ;;
    --yes) # only used by uninstall
      # pass through
      break ;;
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
    create_dirs
    install_script
    write_unit_files
    maybe_write_env_file
    systemd_reload_and_enable
    echo "Installed ${SERVICE_NAME} timer (${INTERVAL_SECONDS}s)."
    echo "Running once now to validate..."
    run_now || true
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
