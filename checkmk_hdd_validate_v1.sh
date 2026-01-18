#!/bin/bash
# Checkmk local check: HDD burn-in status from hdd_validate.sh history DB
# Outputs one service per drive serial, based on latest run outcome.
#
# Expects:
#   /var/lib/hdd_burnin/runs.tsv   (created by hdd_validate.sh)
#
# Local check format:
#   <state> <service_name> <perfdata> <text>
# states: 0=OK, 1=WARN, 2=CRIT, 3=UNKNOWN
# Chatgpt v1

set -euo pipefail

STATE_DIR="${STATE_DIR:-/var/lib/hdd_burnin}"
RUNS_DB="${RUNS_DB:-$STATE_DIR/runs.tsv}"

# Helper: map outcome to Checkmk state
state_from_outcome() {
  case "${1:-}" in
    PASS) echo 0 ;;
    WARN) echo 1 ;;
    FAIL) echo 2 ;;
    *)    echo 3 ;;
  esac
}

# If DB missing, report UNKNOWN once
if [[ ! -r "$RUNS_DB" ]]; then
  echo "3 HDD Burnin DB - runs.tsv not found at $RUNS_DB"
  exit 0
fi

# Gather last record per SN (field 5) from runs.tsv
# runs.tsv columns (from our script):
# run_id ts phase outcome sn wwn model size_bytes poh realloc pending offline_unc udma_crc temp_max log_dir
awk -F'\t' '
  NR==1 { next }               # skip header
  $5 != "" && $5 != "UNKNOWN_SN" { last[$5] = $0 }
  END {
    for (sn in last) print last[sn]
  }
' "$RUNS_DB" | while IFS=$'\t' read -r run_id ts phase outcome sn wwn model size_bytes poh realloc pending offline_unc udma_crc temp_max log_dir; do
  state="$(state_from_outcome "$outcome")"

  # Make a safe-ish service name (no tabs/newlines; keep it simple)
  svc_sn="${sn//[^A-Za-z0-9._-]/_}"
  svc="HDD Burnin ${svc_sn}"

  # perfdata: expose key values so you can graph/filter
  # (thresholds optional; you can set rules instead)
  perf="poh=${poh:-0} realloc=${realloc:-0} pending=${pending:-0} offline_unc=${offline_unc:-0} udma_crc=${udma_crc:-0} temp_max=${temp_max:-0}"

  # human text
  text="Phase=${phase:-?} Outcome=${outcome:-?} Model=${model:-?} SizeBytes=${size_bytes:-?} LastTS=${ts:-?} Logs=${log_dir:-?}"

  echo "${state} ${svc} ${perf} ${text}"
done

# Optional: show a single summary service if badblocks is running
if pgrep -x badblocks >/dev/null 2>&1; then
  # 1=warning (informational: destructive test running)
  echo "1 HDD Burnin Running - badblocks currently running | jobs=$(pgrep -xc badblocks)"
else
  echo "0 HDD Burnin Running - no badblocks running | jobs=0"
fi
