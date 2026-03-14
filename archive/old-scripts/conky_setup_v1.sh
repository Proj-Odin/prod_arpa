#!/bin/bash
# setup_conky_overlay.sh
# One-click Conky overlay for Xubuntu/XFCE:
# - Installs conky-all + lm-sensors (+ optional xfce panel plugins)
# - Runs sensors-detect non-interactively (safe default suggestions)
# - Creates a Conky config that shows CPU/RAM/Disk/Net + per-drive temps
#   (tries sensors first; falls back to smartctl via sudo NOPASSWD if enabled)
# - Adds XFCE autostart entry so it launches on login
#
# Usage:
#   chmod +x setup_conky_overlay.sh
#   sudo ./setup_conky_overlay.sh
#
# Optional env vars:
#   ENABLE_SMARTCTL_OVERLAY=true   # enables sudoers NOPASSWD for smartctl (default true)
#   SMARTCTL_DRIVES="/dev/sda /dev/sdb"  # drives to show temps for (default auto-detect disks)
#   INSTALL_XFCE_PANEL_PLUGINS=true      # installs XFCE panel plugins (default true)

set -euo pipefail

ENABLE_SMARTCTL_OVERLAY="${ENABLE_SMARTCTL_OVERLAY:-true}"
INSTALL_XFCE_PANEL_PLUGINS="${INSTALL_XFCE_PANEL_PLUGINS:-true}"
SMARTCTL_DRIVES="${SMARTCTL_DRIVES:-}"   # optional override

if [[ $EUID -ne 0 ]]; then echo "Run as root (sudo)."; exit 1; fi

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
[[ -n "$REAL_HOME" && -d "$REAL_HOME" ]] || { echo "Could not determine user home for $REAL_USER"; exit 1; }

echo "[1/7] Installing packages..."
apt-get update
apt-get install -y conky-all lm-sensors smartmontools

if [[ "$INSTALL_XFCE_PANEL_PLUGINS" == "true" ]]; then
  apt-get install -y xfce4-sensors-plugin xfce4-systemload-plugin xfce4-netload-plugin || true
fi

echo "[2/7] Running sensors-detect (non-interactive)..."
# This uses safe defaults; it may not load every module on every system, but it won't break anything.
yes | sensors-detect --auto >/dev/null 2>&1 || true
systemctl restart kmod || true

echo "[3/7] Detecting primary network interface..."
# Pick first "UP" non-loopback interface
NET_IF="$(ip -o link show up | awk -F': ' '$2!="lo"{print $2; exit}')"
NET_IF="${NET_IF:-eth0}"

echo "[4/7] Selecting drives for temp display..."
if [[ -z "$SMARTCTL_DRIVES" ]]; then
  # auto-detect whole disks (excluding loop/ram)
  SMARTCTL_DRIVES="$(lsblk -dn -o NAME,TYPE | awk '$2=="disk"{print "/dev/"$1}' | tr '\n' ' ')"
fi
SMARTCTL_DRIVES="$(echo "$SMARTCTL_DRIVES" | xargs || true)"
echo "  Net IF: $NET_IF"
echo "  Drives: $SMARTCTL_DRIVES"

echo "[5/7] (Optional) Allow smartctl without password for overlay..."
SUDOERS_FILE="/etc/sudoers.d/conky-smartctl"
if [[ "$ENABLE_SMARTCTL_OVERLAY" == "true" ]]; then
  cat > "$SUDOERS_FILE" <<EOF
# Allow $REAL_USER to run smartctl without a password for Conky overlay
$REAL_USER ALL=(root) NOPASSWD: /usr/sbin/smartctl
EOF
  chmod 440 "$SUDOERS_FILE"
else
  rm -f "$SUDOERS_FILE" || true
fi

echo "[6/7] Writing Conky config + helper script..."
CONKY_DIR="$REAL_HOME/.config/conky"
CONKY_CONF="$CONKY_DIR/conky.conf"
HELPER="$CONKY_DIR/drive_temps.sh"

mkdir -p "$CONKY_DIR"
chown -R "$REAL_USER:$REAL_USER" "$CONKY_DIR"

# Helper script: prints per-drive temps. Prefer sensors if it clearly has drive temps, otherwise use smartctl.
cat > "$HELPER" <<'EOF'
#!/bin/bash
set -euo pipefail

DRIVES="${DRIVES:-}"
ENABLE_SMARTCTL="${ENABLE_SMARTCTL:-true}"

# Normalize drive list
if [[ -z "$DRIVES" ]]; then
  DRIVES="$(lsblk -dn -o NAME,TYPE | awk '$2=="disk"{print "/dev/"$1}' | tr '\n' ' ')"
fi
DRIVES="$(echo "$DRIVES" | xargs || true)"

# Try to pull temps from sensors output (works on some HBAs / some setups)
SENS="$(sensors 2>/dev/null || true)"
has_any_temp=false

# Print a compact header
echo "Drive Temps"

# For each drive, attempt:
#  1) smartctl (best per-drive, if permitted)
#  2) fallback: print "NA"
for d in $DRIVES; do
  base="$(basename "$d")"

  # smartctl path
  temp=""
  if [[ "$ENABLE_SMARTCTL" == "true" ]]; then
    # try without sudo first, then sudo
    temp="$(/usr/sbin/smartctl -A "$d" 2>/dev/null | awk '
      /Temperature_Celsius|Temperature_Internal|Airflow_Temperature_Cel/ {print $10; exit}
      /Current Drive Temperature/ {print $4; exit}
      /^Temperature:/ {print $2; exit}
    ' | sed -E 's/[^0-9].*//' || true)"

    if [[ -z "$temp" ]]; then
      temp="$(sudo /usr/sbin/smartctl -A "$d" 2>/dev/null | awk '
        /Temperature_Celsius|Temperature_Internal|Airflow_Temperature_Cel/ {print $10; exit}
        /Current Drive Temperature/ {print $4; exit}
        /^Temperature:/ {print $2; exit}
      ' | sed -E 's/[^0-9].*//' || true)"
    fi
  fi

  if [[ -n "${temp:-}" && "$temp" =~ ^[0-9]+$ ]]; then
    has_any_temp=true
    printf "%-6s : %sC\n" "$base" "$temp"
  else
    printf "%-6s : NA\n" "$base"
  fi
done

# If nothing reported temps, give a hint
if [[ "$has_any_temp" == "false" ]]; then
  echo "Tip: enable smartctl sudoers or ensure drive temps are exposed."
fi
EOF

chmod +x "$HELPER"
chown "$REAL_USER:$REAL_USER" "$HELPER"

# Conky config
cat > "$CONKY_CONF" <<EOF
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

  minimum_width = 360,
  maximum_width = 480,

  use_xft = true,
  font = 'DejaVu Sans Mono:size=10',
};

conky.text = [[
\${time %Y-%m-%d %H:%M:%S}

CPU: \${cpu cpu0}%  \${cpubar 8}
Load: \${loadavg}

RAM: \$mem / \$memmax  (\$memperc%)
\${membar 8}

Disk /: \${fs_used /} / \${fs_size /}
\${fs_bar 8 /}

IO: R \${diskio_read}  W \${diskio_write}

Net ($NET_IF): D \${downspeedf $NET_IF} KiB/s  U \${upspeedf $NET_IF} KiB/s
\${downspeedgraph $NET_IF 20,200} \${upspeedgraph $NET_IF 20,200}

\${hr}
\${execi 5 bash -lc "DRIVES='$SMARTCTL_DRIVES' ENABLE_SMARTCTL='$ENABLE_SMARTCTL_OVERLAY' '$HELPER'"}

\${hr}
Top CPU: \${top name 1} \${top cpu 1}%
Top MEM: \${top_mem name 1} \${top_mem mem 1}%
]];
EOF

chown "$REAL_USER:$REAL_USER" "$CONKY_CONF"

echo "[7/7] Adding XFCE autostart entry..."
AUTOSTART_DIR="$REAL_HOME/.config/autostart"
AUTOSTART_FILE="$AUTOSTART_DIR/conky.desktop"

mkdir -p "$AUTOSTART_DIR"
chown -R "$REAL_USER:$REAL_USER" "$AUTOSTART_DIR"

cat > "$AUTOSTART_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=Conky Overlay
Exec=conky -c $CONKY_CONF
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
Comment=Real-time overlay HUD
EOF

chown "$REAL_USER:$REAL_USER" "$AUTOSTART_FILE"

echo
echo "Done."
echo "Conky config: $CONKY_CONF"
echo "Drive temp helper: $HELPER"
echo "Autostart: $AUTOSTART_FILE"
echo
echo "Start now (as your user):"
echo "  sudo -u $REAL_USER conky -c $CONKY_CONF"
echo
echo "If the overlay doesn't appear on XFCE, try:"
echo "  xfconf-query -c xfce4-desktop -p /desktop-icons/style -s 0 >/dev/null 2>&1 || true"
