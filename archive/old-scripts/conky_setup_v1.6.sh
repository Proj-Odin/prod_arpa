#!/usr/bin/env bash
# conkey_setup_v1.6.sh
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
