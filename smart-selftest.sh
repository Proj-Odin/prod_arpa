#!/usr/bin/env bash
# smart-selftest.sh - non-destructive SMART self-tests for Linux.
# Supports ATA/SATA, SAS/SCSI, NVMe, and SAT-capable USB bridges.
set -uo pipefail
umask 077

usage() {
  cat <<'HELP'
Usage:
  smart-selftest.sh list
  sudo smart-selftest.sh short  DEVICE [--type TYPE]
  sudo smart-selftest.sh long   DEVICE [--type TYPE]
  sudo smart-selftest.sh status DEVICE [--type TYPE]
  sudo smart-selftest.sh report DEVICE [--type TYPE]

Examples:
  sudo ./smart-selftest.sh short /dev/sdb
  sudo ./smart-selftest.sh long /dev/disk/by-id/ata-TOSHIBA_...
  sudo ./smart-selftest.sh long /dev/sdb --type sat  # USB SATA bridge
  sudo ./smart-selftest.sh status /dev/sdb --type sat

TYPE is a smartctl -d device type (e.g. sat, scsi, nvme).
Tests run inside drive firmware; closing the terminal does not stop them.
No destructive write/surface test is performed.
HELP
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
ACTION="${1:-list}"
if [[ "$ACTION" == help || "$ACTION" == -h || "$ACTION" == --help ]]; then
  usage; exit 0
fi
command -v lsblk >/dev/null || die 'lsblk is missing'
command -v smartctl >/dev/null || die 'Install smartmontools: sudo apt install smartmontools'

if [[ "$ACTION" == list ]]; then
  [[ $# == 0 || $# == 1 ]] || die 'list does not take a device'
  lsblk -d -o NAME,SIZE,MODEL,SERIAL,TRAN,TYPE
  printf '\nSMART device scan (may show USB bridge types):\n'
  smartctl --scan-open || true
  exit 0
fi

case "$ACTION" in short|long|status|report) ;; *) usage; exit 2;; esac
[[ $# == 2 || $# == 4 ]] || { usage; exit 2; }
INPUT="$2"
TYPE=''
if (( $# == 4 )); then
  [[ "$3" == --type ]] || die 'Expected --type TYPE after device'
  [[ "$4" =~ ^[a-zA-Z0-9,+-]+$ ]] || die 'Invalid smartctl device type'
  TYPE="$4"
fi
[[ "$INPUT" == /dev/* ]] || die 'Specify a /dev/ disk or /dev/disk/by-id/ path'
DEVICE="$(readlink -f -- "$INPUT")"
[[ -b "$DEVICE" ]] || die "Not a block device: $INPUT"
[[ "$(lsblk -dn -o TYPE "$DEVICE" 2>/dev/null)" == disk ]] || die 'Specify a whole drive, not a partition'
if [[ "$EUID" -ne 0 ]]; then die 'Run this command with sudo'; fi

SMART_ARGS=()
[[ -n "$TYPE" ]] && SMART_ARGS=(-d "$TYPE")
smart() { smartctl "${SMART_ARGS[@]}" "$@" "$DEVICE"; }

# smartctl exit bits 0-2 indicate CLI/open/device-command failures.
# Bits 3-7 describe health/history findings, not necessarily a failed command.
command_failed() { (( ($1 & 7) != 0 )); }

INFO_RC=0
INFO="$(smart -i 2>&1)" || INFO_RC=$?
if command_failed "$INFO_RC"; then
  printf '%s\n' "$INFO" >&2
  die "Cannot talk to $DEVICE. For a USB SATA adapter, try: --type sat"
fi
if grep -Eqi 'SMART support is:[[:space:]]+Disabled' <<< "$INFO"; then
  die 'SMART is disabled on this drive; not enabling it automatically'
fi

printf '\nTarget: %s -> %s\n' "$INPUT" "$DEVICE"
lsblk -dn -o NAME,SIZE,MODEL,SERIAL,TRAN "$DEVICE"
printf '\n'

if [[ "$ACTION" == status || "$ACTION" == report ]]; then
  printf '%s\n' '--- Overall SMART health ---'
  smart -H || true
  printf '\n%s\n' '--- Self-test capability / current progress ---'
  smart -c || true
  printf '\n%s\n' '--- Self-test history ---'
  smart -l selftest || true
  if [[ "$ACTION" == report ]]; then
    printf '\n%s\n' '--- Full SMART report ---'
    smart -x || true
  fi
  exit 0
fi

# Avoid starting a second test when an existing test is reported active.
CAPS_RC=0
CAPS="$(smart -c 2>&1)" || CAPS_RC=$?
if command_failed "$CAPS_RC"; then
  printf '%s\n' "$CAPS" >&2
  die 'Could not determine self-test status; refusing to start another test'
fi
# smartctl can wrap the "Self-test ... in progress" statement over lines.
CAPS_ONE_LINE="$(tr '\n' ' ' <<< "$CAPS")"
if grep -Eiq '(self[- ]test|selftest).{0,180}(in progress|currently running|is running)' <<< "$CAPS_ONE_LINE"; then
  printf '%s\n' "$CAPS" >&2
  die 'A SMART self-test appears to be running already'
fi

LOGDIR="${SMART_LOG_DIR:-/var/log/smart-selftest}"
mkdir -p -- "$LOGDIR" || die "Cannot create log directory: $LOGDIR"
TS="$(date +%Y%m%d_%H%M%S)"
LOGFILE="$LOGDIR/${TS}_$(basename "$DEVICE")_${ACTION}.log"
{
  printf 'Started: %s\nDevice: %s\nRequested: %s\nType: %s\n\n' "$(date -Is)" "$INPUT" "$ACTION" "${TYPE:-auto}"
  printf '%s\n\n' "$INFO"
  printf '%s\n' '--- Before test ---'
  smart -H || true
  smart -l selftest || true
  printf '\n%s\n' '--- Start request ---'
} > "$LOGFILE"

RC=0
smart -t "$ACTION" >> "$LOGFILE" 2>&1 || RC=$?
tail -n 25 "$LOGFILE"
printf '\nLog: %s\n' "$LOGFILE"
if command_failed "$RC"; then
  die "SMART start command failed (smartctl exit bitmask: $RC)"
fi
if (( RC != 0 )); then
  printf 'WARNING: smartctl returned bitmask %d; inspect the pre-existing health errors.\n' "$RC" >&2
fi
printf '\nSMART %s start request sent. This does NOT mean the test passed.\n' "$ACTION"
printf 'Check later: sudo %s status %q' "$0" "$INPUT"
[[ -n "$TYPE" ]] && printf ' --type %q' "$TYPE"
printf '\n'