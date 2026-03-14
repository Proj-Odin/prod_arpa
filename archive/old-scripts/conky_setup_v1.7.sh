#!/usr/bin/env bash
# conkey_setup_v1.6_fixed.sh
# Fixes: set -u positional expansion inside heredocs (e.g., awk $2/$10)
# Optional arg: NIC name (e.g., enp34s0). If omitted, autodetects.

set -euo pipefail
export LC_ALL=C

BURNIN_GROUP="${BURNIN_GROUP:-burnin}"
ENABLE_CONKY_SMART_SUDO="${ENABLE_CONKY_SMART_SUDO:-1}"
CUR_JSON="/var/lib/hdd_burnin/current_run.json"

if [[ $EUID -ne 0 ]]; then
  echo "[FATAL] Run as root: sudo $0 [nic]" >&2
  exit 1
fi

TARGET_USER="${SUDO_USER:-}"
if [[ -z "$TARGET_USER" || "$TARGET_USER" == "root" ]]; then
  echo "[FATAL] Run via sudo from a normal user (so we can configure their autostart)." >&2
  exit 1
fi

USER_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

echo "[INFO] Installing Conky + sensors..."
apt-get update -y
if ! apt-get install -y --no-install-recommends conky-all; then
  echo "[WARN] conky-all not available; installing conky instead..."
  apt-get install -y --no-install-recommends conky
fi
apt-get install -y --no-install-recommends lm-sensors smartmontools iproute2

echo "[INFO] Running sensors-detect (auto)..."
yes | sensors-detect --auto >/dev/null 2>&1 || true

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

# Optional: allow conky to read SMART temps without password prompts
if [[ "$ENABLE_CONKY_SMART_SUDO" == "1" ]]; then
  echo "[INFO] Enabling NOPASSWD sudo for smartctl for user: $TARGET_USER"
  cat > /etc/sudoers.d/conky-smartctl <<EOF
# Managed by conkey_setup_v1.6.sh
${TARGET_USER} ALL=(root) NOPASSWD: /usr/sbin/smartctl
EOF
  chmod 0440 /etc/sudoers.d/conky-smartctl
fi

echo "[INFO] Writing Conky config..."
install -d -m 0755 "${USER_HOME}/.config/conky"

# IMPORTANT:
# Use a single-quoted heredoc so $2/$10 inside awk are NOT expanded by bash (set -u safe).
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

${execi 3 bash -lc '
  f="__CUR_JSON__";
  if [[ -r "$f" ]]; then
    j=$(tr -d "\n" < "$f");
    s=$(echo "$j" | sed -n "s/.*\"status\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p");
    p=$(echo "$j" | sed -n "s/.*\"phase\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p");
    d=$(echo "$j" | sed -n "s/.*\"drives_dev_text\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p");
    a=$(echo "$j" | sed -n "s/.*\"abort_reason\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p");
    echo "Status: ${s:-?}  Phase: ${p:-?}";
    echo "Drives: ${d:-}";
    [[ -n "$a" ]] && echo "Abort: $a";
  else
    echo "current_run.json not readable yet (log out/in so burnin group applies).";
  fi
'}

${execi 5 bash -lc '
  f="__CUR_JSON__";
  if [[ -r "$f" ]]; then
    j=$(tr -d "\n" < "$f");
    sum=$(echo "$j" | sed -n "s/.*\"summary_path\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p");
    if [[ -n "$sum" && -r "$sum" ]]; then
      echo "Last: $(tail -n 1 "$sum" 2>/dev/null)";
    fi
  fi
'}

${execi 10 bash -lc '
  f="__CUR_JSON__";
  if [[ -r "$f" ]]; then
    j=$(tr -d "\n" < "$f");
    drives=$(echo "$j" | sed -n "s/.*\"drives_dev_text\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p");
    if [[ -n "$drives" ]]; then
      for dv in $drives; do
        t=$(sudo /usr/sbin/smartctl -A "$dv" 2>/dev/null | awk '\''
          /Temperature_Celsius|Airflow_Temperature_Cel|Temperature_Internal/ {print $10; exit}
          /^Temperature:/ {print $2; exit}
          /Current Drive Temperature/ {print $4; exit}
        '\'' | sed -E "s/[^0-9].*//");
        echo "$dv temp: ${t:-NA}C";
      done
    fi
  fi
'}

${hr}
Top CPU: ${top name 1} ${top cpu 1}%
Top MEM: ${top_mem name 1} ${top_mem mem 1}%
]];
EOF

# Replace placeholders safely
sed -i "s|__NIC__|${NIC}|g" "${USER_HOME}/.config/conky/conky.conf"
sed -i "s|__CUR_JSON__|${CUR_JSON}|g" "${USER_HOME}/.config/conky/conky.conf"

chown -R "${TARGET_USER}:${TARGET_USER}" "${USER_HOME}/.config/conky"

echo "[INFO] Adding XFCE autostart entry..."
install -d -m 0755 "${USER_HOME}/.config/autostart"
cat > "${USER_HOME}/.config/autostart/conky.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Conky Overlay
Exec=conky -c ${USER_HOME}/.config/conky/conky.conf
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
EOF

chown -R "${TARGET_USER}:${TARGET_USER}" "${USER_HOME}/.config/autostart"

echo "[DONE] Conky overlay installed for user: ${TARGET_USER}"
echo "Start now: conky -c ~/.config/conky/conky.conf"
echo "[NOTE] If Conky can't read current_run.json yet, log out/in (or reboot) for burnin group to apply."
