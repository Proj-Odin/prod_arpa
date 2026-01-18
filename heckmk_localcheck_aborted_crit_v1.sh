#!/usr/bin/env bash
# update_checkmk_localcheck_aborted_crit.sh
# Sets ABORTED -> CRIT (2) in the Checkmk local check used by our setup.sh

set -euo pipefail

LC_PATH="/usr/lib/check_mk_agent/local/hdd_burnin_status"

if [[ $EUID -ne 0 ]]; then
  echo "[FATAL] Run as root: sudo $0" >&2
  exit 1
fi

if [[ ! -f "$LC_PATH" ]]; then
  echo "[FATAL] Local check not found at: $LC_PATH" >&2
  echo "       Did you run setup.sh on this host?" >&2
  exit 1
fi

# Safety backup
backup="${LC_PATH}.bak.$(date +%Y%m%d_%H%M%S)"
cp -a "$LC_PATH" "$backup"
echo "[INFO] Backup saved: $backup"

# Ensure ABORTED maps to CRIT (2). If state_of() exists, replace it; otherwise, insert it.
if grep -qE '^[[:space:]]*state_of\(\)[[:space:]]*\{' "$LC_PATH"; then
  # Replace the whole state_of() block (best-effort, assumes function is contiguous).
  perl -0777 -pe 's/state_of\(\)\s*\{\s*.*?\s*\}\s*/state_of() {\n  case "$1" in\n    PASS)    echo 0 ;;\n    WARN)    echo 1 ;;\n    FAIL)    echo 2 ;;\n    ABORTED) echo 2 ;;  # burn-in interrupted\n    *)       echo 3 ;;\n  esac\n}\n\n/sms' -i "$LC_PATH"
  echo "[INFO] Updated existing state_of() mapping."
else
  # Insert state_of() near top after RUNS=... line
  awk '
    BEGIN{inserted=0}
    {print}
    !inserted && $0 ~ /^RUNS=/ {
      print ""
      print "state_of() {"
      print "  case \"$1\" in"
      print "    PASS)    echo 0 ;;"
      print "    WARN)    echo 1 ;;"
      print "    FAIL)    echo 2 ;;"
      print "    ABORTED) echo 2 ;;  # burn-in interrupted"
      print "    *)       echo 3 ;;"
      print "  esac"
      print "}"
      print ""
      inserted=1
    }
  ' "$LC_PATH" > "${LC_PATH}.tmp"
  mv "${LC_PATH}.tmp" "$LC_PATH"
  chmod 0755 "$LC_PATH"
  echo "[INFO] Inserted state_of() mapping."
fi

# Optional: make ABORTED text explicit (idempotent-ish)
if ! grep -q 'ABORTED: run interrupted' "$LC_PATH"; then
  # Insert after txt= line (first occurrence)
  perl -pe 'if (!$done && /^(\s*txt=)/) { $done=1; $_ .= "  if [[ \"\\$outcome\" == \"ABORTED\" ]]; then\n    txt=\"ABORTED: run interrupted (Ctrl-C/TERM or temp kill) \\$txt\"\n  fi\n"; }' -i "$LC_PATH"
  echo "[INFO] Added ABORTED text annotation."
fi

echo "[INFO] Final local-check preview:"
check_mk_agent | sed -n '/<<<local>>>/,$p' | head -n 80 || true

echo "[DONE] ABORTED now maps to CRIT (2)."
