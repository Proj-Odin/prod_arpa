#!/usr/bin/env bash
# conkey_setup_v1.9_fixed.sh
# Fixes applied to v1.9:
# - Changed bash -lc to bash -c (faster, no login shell needed)
# - Added timeout fallback for systems without timeout command
# - Added validation that helper scripts were created successfully
# - Added trailing newlines to heredocs (POSIX compliance)
# - Added error checking for sed replacements
# - Added SKIP_SENSORS_DETECT option

set -euo pipefail
export LC_ALL=C

BURNIN_GROUP="${BURNIN_GROUP:-burnin}"
ENABLE_CONKY_SMART_SUDO="${ENABLE_CONKY_SMART_SUDO:-1}"
CUR_JSON="/var/lib/hdd_burnin/current_run.json"
SENSORS_TIMEOUT="${SENSORS_TIMEOUT:-60}"  # seconds
SKIP_SENSORS_DETECT="${SKIP_SENSORS_DETECT:-0}"

# ---------- helpers ----------
die(){ echo "[FATAL] $*" >&2; exit 1; }

if [[ $EUID -ne 0 ]]; then
  die "Run as root: sudo $0 [nic]"
fi

TARGET_USER="${SUDO_USER:-}"
if [[ -z "$TARGET_USER" || "$TARGET_USER" == "root" ]]; then
  die "Run via sudo from a normal user (so we can configure their autostart)."
fi

USER_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
if [[ -z "$USER_HOME" || ! -d "$USER_HOME" ]]; then
  die "Could not determine home directory for user: $TARGET_USER"
fi

if [[ ! "$SENSORS_TIMEOUT" =~ ^[0-9]+$ ]] || [[ "$SENSORS_TIMEOUT" -lt 1 ]]; then
  die "SENSORS_TIMEOUT must be a positive integer seconds (got: $SENSORS_TIMEOUT)"
fi

echo "[INFO] Installing Conky + sensors..."
apt-get update -y
if ! apt-get install -y --no-install-recommends conky-all; then
  echo "[WARN] conky-all not available; installing conky instead..."
  apt-get install -y --no-install-recommends conky
fi
apt-get install -y --no-install-recommends lm-sensors smartmontools iproute2 coreutils sed gawk

# Run sensors-detect with timeout (or skip if requested)
if [[ "$SKIP_SENSORS_DETECT" == "1" ]]; then
  echo "[INFO] Skipping sensors-detect (SKIP_SENSORS_DETECT=1)"
else
  echo "[INFO] Running sensors-detect (auto, timeout=${SENSORS_TIMEOUT}s)..."
  if command -v timeout >/dev/null 2>&1; then
    timeout "${SENSORS_TIMEOUT}s" bash -c 'yes | sensors-detect --auto' >/dev/null 2>&1 || true
  else
    echo "[WARN] timeout command not found, using background fallback..."
    (yes | sensors-detect --auto >/dev/null 2>&1) &
    DETECT_PID=$!
    sleep "$SENSORS_TIMEOUT"
    kill -9 "$DETECT_PID" 2>/dev/null || true
    wait "$DETECT_PID" 2>/dev/null || true
  fi
fi

# Ensure burnin group exists
if ! getent group "$BURNIN_GROUP" >/dev/null 2>&1; then
  echo "[INFO] Creating group: $BURNIN_GROUP"
  groupadd --system "$BURNIN_GROUP"
fi

# Ensure user in burnin group
if ! id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx "$BURNIN_GROUP"; then
  echo "[INFO] Adding user to group: $TARGET_USER -> $BURNIN_GROUP"
  usermod -aG "$BURNIN_GROUP" "$TARGET_USER"
  echo "[WARN] You must log out/in (or reboot) for group membership to take effect."
fi

# NIC arg (safe under set -u)
NIC="${1:-}"

# Autodetect NIC if not provided
if [[ -z "$NIC" ]]; then
  NIC="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
fi
if [[ -z "$NIC" ]]; then
  NIC="$(ip -br link 2>/dev/null | awk '$1!="lo"{print $1; exit}')"
fi
NIC="${NIC:-enp34s0}"

echo "[INFO] Using NIC: $NIC"

# Optional: allow conky (user) to read SMART temps without password prompts
if [[ "$ENABLE_CONKY_SMART_SUDO" == "1" ]]; then
  echo "[INFO] Enabling NOPASSWD sudo for smartctl for user: $TARGET_USER"
  cat > /etc/sudoers.d/conky-smartctl <<EOF
# Managed by conkey_setup_v1.9_fixed.sh
${TARGET_USER} ALL=(root) NOPASSWD: /usr/sbin/smartctl
EOF
  chmod 0440 /etc/sudoers.d/conky-smartctl
fi

# ---------- helper: temps ----------
echo "[INFO] Installing helper script: /usr/local/bin/conky-get-temps.sh"
cat > /usr/local/bin/conky-get-temps.sh <<'HELPER_EOF'
#!/usr/bin/env bash
# conky-get-temps.sh v1.9.0
# Created by conkey_setup_v1.9_fixed.sh

set -euo pipefail
export LC_ALL=C

JSON_FILE="${1:-/var/lib/hdd_burnin/current_run.json}"
[[ -r "$JSON_FILE" ]] || exit 0

j="$(tr -d '\n' < "$JSON_FILE")"
drives="$(echo "$j" | sed -n 's/.*"drives_dev_text"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
[[ -n "${drives:-}" ]] || exit 0

for dv in $drives; do
  temp="$(sudo /usr/sbin/smartctl -A "$dv" 2>/dev/null | awk '
    /Temperature_Celsius|Airflow_Temperature_Cel|Temperature_Internal/ {
      for(i=1; i<=NF; i++) if($i ~ /^[0-9]+$/) {print $i; exit}
    }
    /^Temperature:/ {
      for(i=1; i<=NF; i++) if($i ~ /^[0-9]+$/) {print $i; exit}
    }
    /Current Drive Temperature/ {
      for(i=1; i<=NF; i++) if($i ~ /^[0-9]+$/) {print $i; exit}
    }
  ' | head -n 1 | sed -E 's/[^0-9].*//')"

  echo "$dv temp: ${temp:-NA}C"
done
exit 0

HELPER_EOF

chmod 0755 /usr/local/bin/conky-get-temps.sh
chown root:root /usr/local/bin/conky-get-temps.sh

# Validate helper was created successfully
if [[ ! -x /usr/local/bin/conky-get-temps.sh ]]; then
  die "Failed to create helper script: /usr/local/bin/conky-get-temps.sh"
fi

# ---------- helper: status + last line ----------
echo "[INFO] Installing helper script: /usr/local/bin/conky-burnin-status.sh"
cat > /usr/local/bin/conky-burnin-status.sh <<'HELPER2_EOF'
#!/usr/bin/env bash
# conky-burnin-status.sh v1.9.0
# Created by conkey_setup_v1.9_fixed.sh

set -euo pipefail
export LC_ALL=C

JSON_FILE="${1:-/var/lib/hdd_burnin/current_run.json}"
[[ -r "$JSON_FILE" ]] || { echo "burnin: current_run.json unreadable"; exit 0; }

j="$(tr -d '\n' < "$JSON_FILE")"

# Extract string field from simple JSON (no escaping support, good enough for our generated file)
jget() {
  local key="$1"
  echo "$j" | sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p"
}

status="$(jget status)"
phase="$(jget phase)"
drives="$(jget drives_dev_text)"
abort_reason="$(jget abort_reason)"
summary_path="$(jget summary_path)"

echo "Status: ${status:-?}  Phase: ${phase:-?}"
echo "Drives: ${drives:-}"

if [[ -n "${abort_reason:-}" ]]; then
  echo "Abort: ${abort_reason}"
fi

if [[ -n "${summary_path:-}" && -r "${summary_path:-}" ]]; then
  last="$(tail -n 1 -- "$summary_path" 2>/dev/null || true)"
  [[ -n "$last" ]] && echo "Last: $last"
fi

exit 0

HELPER2_EOF

chmod 0755 /usr/local/bin/conky-burnin-status.sh
chown root:root /usr/local/bin/conky-burnin-status.sh

# Validate helper was created successfully
if [[ ! -x /usr/local/bin/conky-burnin-status.sh ]]; then
  die "Failed to create helper script: /usr/local/bin/conky-burnin-status.sh"
fi

# ---------- write conky config ----------
echo "[INFO] Writing Conky config..."
install -d -m 0755 "${USER_HOME}/.config/conky"

cat > "${USER_HOME}/.config/conky/conky.conf" <<'EOF'
conky.config = {
  background = true,
  update_interval = 1,
  cpu_avg_samples = 2,
  net_avg_samples = 2,
  double_buffer = true,

  own_window = true,
  own_window_type = 'override',
  own_window_transparent = true,
  own_window_hints = 'undecorated,below,sticky,skip_taskbar,skip_pager',
  draw_shades = false,
  draw_outline = false,
  draw_borders = false,

  alignment = 'top_right',
  gap_x = 20,
  gap_y = 20,

  minimum_width = 520,
  maximum_width = 620,

  use_xft = true,
  font = 'DejaVu Sans Mono:size=10',
};

conky.text = [[
${time %Y-%m-%d %H:%M:%S}

CPU: ${cpu cpu0}%  ${cpubar 8}
Load: ${loadavg}

RAM: ${mem} / ${memmax} (${memperc}%)
${membar 8}

Disk /: ${fs_used /} / ${fs_size /}
${fs_bar 8 /}

Net (__NIC__): D ${downspeedf __NIC__} KiB/s  U ${upspeedf __NIC__} KiB/s

${hr}
BURN-IN (from __CUR_JSON__):

${execi 3 /usr/local/bin/conky-burnin-status.sh __CUR_JSON__}

${execi 10 /usr/local/bin/conky-get-temps.sh __CUR_JSON__}

${hr}
Top CPU: ${top name 1} ${top cpu 1}%
Top MEM: ${top_mem name 1} ${top_mem mem 1}%
]];
EOF

chmod 0644 "${USER_HOME}/.config/conky/conky.conf"

# Replace placeholders with error checking
if ! sed -i "s|__NIC__|${NIC}|g" "${USER_HOME}/.config/conky/conky.conf"; then
  die "Failed to replace __NIC__ placeholder in conky config"
fi
if ! sed -i "s|__CUR_JSON__|${CUR_JSON}|g" "${USER_HOME}/.config/conky/conky.conf"; then
  die "Failed to replace __CUR_JSON__ placeholder in conky config"
fi

chown -R "${TARGET_USER}:${TARGET_USER}" "${USER_HOME}/.config/conky"

# ---------- autostart ----------
echo "[INFO] Adding XFCE autostart entry (with delay)..."
install -d -m 0755 "${USER_HOME}/.config/autostart"

cat > "${USER_HOME}/.config/autostart/conky.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Conky Overlay
Exec=sh -c "sleep 2; conky -c ${USER_HOME}/.config/conky/conky.conf"
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
EOF

chmod 0644 "${USER_HOME}/.config/autostart/conky.desktop"
chown -R "${TARGET_USER}:${TARGET_USER}" "${USER_HOME}/.config/autostart"

# ---------- self-checks ----------
echo ""
echo "[INFO] Quick self-checks:"
echo "  - Script syntax: $(bash -n "$0" >/dev/null 2>&1 && echo OK || echo FAIL)"
echo "  - Config exists: $(test -f "${USER_HOME}/.config/conky/conky.conf" && echo OK || echo FAIL)"
echo "  - Helper status: $(test -x /usr/local/bin/conky-burnin-status.sh && echo OK || echo FAIL)"
echo "  - Helper temps: $(test -x /usr/local/bin/conky-get-temps.sh && echo OK || echo FAIL)"
echo "  - Placeholders replaced: $(grep -q '__NIC__\|__CUR_JSON__' "${USER_HOME}/.config/conky/conky.conf" && echo FAIL || echo OK)"
echo "  - NIC ${NIC} MAC: $(cat "/sys/class/net/${NIC}/address" 2>/dev/null || echo '?')"

echo ""
echo "[DONE] Conky overlay installed for user: ${TARGET_USER}"
echo "Start now: conky -c ~/.config/conky/conky.conf"
echo "[NOTE] If Conky can't read current_run.json yet, log out/in (or reboot) for burnin group to apply."
echo ""
echo "Optional testing:"
echo "  sudo /usr/local/bin/conky-burnin-status.sh ${CUR_JSON}"
echo "  sudo /usr/local/bin/conky-get-temps.sh ${CUR_JSON}"
