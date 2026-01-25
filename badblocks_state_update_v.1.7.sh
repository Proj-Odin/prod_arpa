#!/usr/bin/env bash
# badblocks_state_update.sh v1.7 - PRODUCTION READY (FINAL)
# 
# Changelog v1.7:
# - Added phase_num safety normalization
# - Added phase transition logging to main log
# - Improved archive error handling with retry logic
# - All v1.6 critical fixes included
#
# Requires: jq, bash 4.0+

set -euo pipefail
export LC_ALL=C
umask 027

VERSION="1.7"
SCHEMA_VERSION="5"

STATE_DIR="/var/lib/hdd_burnin/badblocks"
ARCHIVE_DIR="/var/lib/hdd_burnin/badblocks/archive"
DEDUPE_DIR="/var/lib/hdd_burnin/badblocks/.dedupe"
LOCK="/run/badblocks_state_update.lock"
LOG_FILE="/var/log/badblocks_state_update.log"
METRICS_FILE="/var/lib/hdd_burnin/badblocks/metrics.prom"

STALE_THRESHOLD=3600
CRITICAL_STALE_THRESHOLD=7200
ERROR_WARN_THRESHOLD=10
ERROR_CRITICAL_THRESHOLD=100
RETRY_DELAY=1
MAX_RETRIES=2
ALERT_DEDUPE_INTERVAL=1800
INACTIVE_GRACE_SECONDS=300

ALERT_EMAIL="${ALERT_EMAIL:-}"
ALERT_WEBHOOK="${ALERT_WEBHOOK:-}"
ENABLE_PROMETHEUS=1
ENABLE_ALERTS=1
ROTATE_STATE_FILES=1

mkdir -p "$STATE_DIR" "$ARCHIVE_DIR" "$DEDUPE_DIR"
chmod 0750 /var/lib/hdd_burnin "$STATE_DIR" "$ARCHIVE_DIR" "$DEDUPE_DIR" 2>/dev/null || true
command -v jq >/dev/null || { echo "ERROR: jq required" >&2; exit 1; }
printf '%s\n' "$VERSION" > "$STATE_DIR/VERSION" 2>/dev/null || true

exec 9>"$LOCK"
flock -n 9 || exit 0

log_msg(){ printf '[%s] [%s] %s\n' "$(date --iso-8601=s)" "${1:-INFO}" "${@:2}" >>"$LOG_FILE" 2>&1 || true; }
log_info(){ log_msg INFO "$@"; }
log_warn(){ log_msg WARN "$@"; }
log_error(){ log_msg ERROR "$@"; }
log_debug(){ log_msg DEBUG "$@"; }
now_iso(){ date --iso-8601=s; }
now_epoch(){ date +%s; }

retry(){
  local n=1 m="$1"; shift
  while (( n <= m )); do
    "$@" && return 0
    (( n < m )) && sleep "$RETRY_DELAY"
    ((n++))
  done
  return 1
}

sanitize_id(){ echo -n "$1" | tr ':/' '--' | tr -c 'A-Za-z0-9._-' '_' | cut -c1-200; }
norm_int(){ [[ "${1:-}" =~ ^[0-9]+$ ]] && echo "$1" || echo "${2:-0}"; }
norm_num(){ [[ "${1:-}" =~ ^-?[0-9]+(\.[0-9]+)?$ ]] && echo "$1" || echo "${2:-0}"; }

dev_size_bytes(){ [[ -b "$1" ]] && retry "$MAX_RETRIES" blockdev --getsize64 "$1" 2>/dev/null || echo 0; }

pid_io_bytes(){
  local pid="$1" key="$2"
  [[ -f "/proc/$pid/io" ]] || { echo 0; return; }
  retry "$MAX_RETRIES" awk -v k="$key" '
    $1==k {print $2; found=1}
    END {if(!found) print 0}
  ' "/proc/$pid/io" 2>/dev/null || echo 0
}

jget(){ [[ -f "$1" ]] && jq -r "$2 // empty" "$1" 2>/dev/null || echo ""; }

json_write(){
  local f="$1" c="$2" t="${f}.tmp.$$"
  printf '%s\n' "$c" >"$t"
  jq empty "$t" >/dev/null || { rm -f "$t"; return 1; }
  mv "$t" "$f" || { rm -f "$t"; return 1; }
  chmod 0640 "$f" 2>/dev/null || true
  return 0
}

dedupe_path(){ printf '%s/%s.%s\n' "$DEDUPE_DIR" "$1" "$2"; }

should_alert(){
  [[ $ENABLE_ALERTS -eq 1 && -n "$1" ]] || return 1
  local f; f="$(dedupe_path "$1" "$2")"
  local e=0
  [[ -f "$f" ]] && read -r e <"$f" || true
  [[ "$e" =~ ^[0-9]+$ ]] || e=0
  local n; n="$(now_epoch)"
  (( e == 0 || n - e >= ALERT_DEDUPE_INTERVAL ))
}

record_alert(){ [[ -n "$1" ]] && printf '%s\n' "$(now_epoch)" >"$(dedupe_path "$1" "$2")" || true; }

send_alert(){
  local sev="$1" subj="$2" msg="$3" uid="$4" type="${5:-gen}"
  should_alert "$uid" "$type" || { log_debug "Alert suppressed: $type for $uid"; return 0; }
  log_warn "ALERT [$sev] $subj: $msg"

  [[ -n "$ALERT_EMAIL" ]] && command -v mail >/dev/null && echo "$msg" | mail -s "[Badblocks $sev] $subj" "$ALERT_EMAIL" 2>/dev/null || true

  if [[ -n "$ALERT_WEBHOOK" && "$ALERT_WEBHOOK" =~ ^https:// ]] && command -v curl >/dev/null; then
    local p
    p="$(jq -n --arg s "$sev" --arg su "$subj" --arg m "$msg" --arg t "$(now_iso)" --arg h "$(hostname -f 2>/dev/null || hostname)" --arg d "$uid" \
      '{severity:$s,subject:$su,message:$m,timestamp:$t,hostname:$h,device:$d}')"
    curl --fail -sSm5 --connect-timeout 3 --proto '=https' --tlsv1.2 \
      -H 'Content-Type: application/json' -d "$p" "$ALERT_WEBHOOK" >/dev/null 2>&1 || true
  fi

  record_alert "$uid" "$type"
}

drive_ids(){
  local d="$1" dr p w="" is="" iss="" m="" v="" ip="" bi="" bp=""
  dr="$(readlink -f "$d" 2>/dev/null || echo "$d")"

  if command -v udevadm >/dev/null; then
    p="$(udevadm info -q property -n "$d" 2>/dev/null || true)"
    w="$(awk -F= '$1=="ID_WWN_WITH_EXTENSION"{print $2;exit}$1=="ID_WWN"{print $2;exit}' <<<"$p")"
    # Accept 0x... or naa.... formats
    if [[ -n "$w" && ! "$w" =~ ^(0x[0-9a-fA-F]+|naa\.[0-9a-fA-F]+)$ ]]; then
      log_warn "Invalid WWN format (will ignore): $w"
      w=""
    fi
    iss="$(awk -F= '$1=="ID_SERIAL_SHORT"{print $2;exit}' <<<"$p")"
    is="$(awk -F= '$1=="ID_SERIAL"{print $2;exit}' <<<"$p")"
    m="$(awk -F= '$1=="ID_MODEL"{print $2;exit}' <<<"$p")"
    v="$(awk -F= '$1=="ID_VENDOR"{print $2;exit}' <<<"$p")"
    ip="$(awk -F= '$1=="ID_PATH"{print $2;exit}' <<<"$p")"
  fi

  local l
  for l in /dev/disk/by-id/*; do
    [[ -e "$l" && "$(readlink -f "$l" 2>/dev/null)" == "$dr" ]] && { bi="$l"; break; }
  done
  for l in /dev/disk/by-path/*; do
    [[ -e "$l" && "$(readlink -f "$l" 2>/dev/null)" == "$dr" ]] && { bp="$l"; break; }
  done

  local u=""
  if [[ -n "$w" ]]; then
    u="wwn:$w"
  elif [[ -n "$iss" ]]; then
    u="serial:$iss"
  elif [[ -n "$is" ]]; then
    u="serial:$is"
  else
    u="dev:$dr"
  fi

  echo "$u|$w|$is|$iss|$m|$v|$ip|$bi|$bp"
}

parse_cmd(){
  local p="$1" d="" pt="" o="" ph="" s=""
  [[ -f "/proc/$p/cmdline" ]] || { echo "||||"; return; }

  local -a a=()
  mapfile -d '' -t a <"/proc/$p/cmdline" 2>/dev/null || { echo "||||"; return; }

  local i
  for ((i=0;i<${#a[@]};i++)); do
    case "${a[i]}" in
      -o|--output) ((i+1<${#a[@]})) && o="${a[i+1]}" ;;
      -o*)         o="${a[i]#-o}" ;;
      -t)          ((i+1<${#a[@]})) && pt="${a[i+1]}" ;;
      -t*)         pt="${a[i]#-t}" ;;
    esac
  done

  ((${#a[@]} > 0)) && d="${a[-1]}"

  if [[ -n "$o" ]]; then
    ph="$(sed -n 's#.*/phase\([A-Za-z]\)_badblocks_.*#\1#p' <<<"$o")"
    s="$(sed -n 's#.*/phase[A-Za-z]_badblocks_\([^_]*\)_\.bad\.tmp#\1#p' <<<"$o")"
  fi

  echo "$d|$pt|$o|$ph|$s"
}

phase_num(){
  local p="${1:-}"
  [[ "$p" =~ ^[A-Za-z]$ ]] && awk -v c="$(tr '[:lower:]' '[:upper:]' <<<"$p")" 'BEGIN{print index("ABCD",c)}' || echo 0
}

archive(){
  local f="$1" u; u="$(basename "$f" .json)"
  local t; t="$(date +%Y%m%d_%H%M%S)"
  local a="${ARCHIVE_DIR}/${u}_${t}.json"
  
  if cp "$f" "$a" 2>/dev/null; then
    if gzip -f "$a" 2>/dev/null; then
      log_info "Archived $u -> ${a}.gz"
      return 0
    else
      log_warn "Archive gzip failed for $u, keeping uncompressed"
      return 0
    fi
  else
    log_error "Archive copy failed for $u"
    return 1
  fi
}

write_metrics(){
  local t="${METRICS_FILE}.tmp.$$" j u ph pc er sp et ss st av
  {
    echo "# HELP badblocks_scan_progress_pct Progress %"
    echo "# TYPE badblocks_scan_progress_pct gauge"
    echo "# HELP badblocks_errors_found Bad blocks"
    echo "# TYPE badblocks_errors_found gauge"
    echo "# HELP badblocks_speed_mbps Speed MB/s"
    echo "# TYPE badblocks_speed_mbps gauge"
    echo "# HELP badblocks_eta_seconds ETA"
    echo "# TYPE badblocks_eta_seconds gauge"
    echo "# HELP badblocks_stalled Stalled"
    echo "# TYPE badblocks_stalled gauge"
    echo "# HELP badblocks_active Active"
    echo "# TYPE badblocks_active gauge"

    shopt -s nullglob
    for j in "$STATE_DIR"/*.json; do
      u="$(basename "$j" .json)"
      ph="$(jget "$j" .phase_letter)"
      pc="$(jget "$j" .progress_pct)"
      er="$(jget "$j" .errors)"
      sp="$(jget "$j" .speed_mbps)"
      et="$(jget "$j" .eta_seconds)"
      ss="$(jget "$j" .seconds_since_progress_change)"
      av="$(jget "$j" .active)"; av="${av:-1}"

      st=0
      [[ "$ss" =~ ^[0-9]+$ && "$ss" -gt "$STALE_THRESHOLD" ]] && st=1

      [[ -n "$pc" ]] && echo "badblocks_scan_progress_pct{device=\"$u\",phase=\"$ph\"} $pc"
      [[ -n "$er" ]] && echo "badblocks_errors_found{device=\"$u\",phase=\"$ph\"} $er"
      [[ -n "$sp" ]] && echo "badblocks_speed_mbps{device=\"$u\",phase=\"$ph\"} $sp"
      [[ -n "$et" ]] && echo "badblocks_eta_seconds{device=\"$u\",phase=\"$ph\"} $et"
      echo "badblocks_stalled{device=\"$u\",phase=\"$ph\"} $st"
      echo "badblocks_active{device=\"$u\",phase=\"$ph\"} $av"
    done
  } >"$t"

  mv "$t" "$METRICS_FILE" 2>/dev/null || rm -f "$t"
  chmod 0640 "$METRICS_FILE" 2>/dev/null || true
}

log_info "Starting badblocks_state_update v${VERSION} (schema=${SCHEMA_VERSION})"
mapfile -t pids < <(pgrep -x badblocks 2>/dev/null || true)
log_info "Found ${#pids[@]} badblocks processes"

declare -A active_uids=()

for pid in "${pids[@]}"; do
  [[ -d "/proc/$pid" ]] || { log_warn "PID $pid vanished"; continue; }

  IFS='|' read -r dev pat out phl sh < <(parse_cmd "$pid")
  [[ -b "${dev:-}" ]] || { log_warn "PID $pid: invalid dev"; continue; }

  short="${dev#/dev/}"

  IFS='|' read -r uid wwn ids idss mod ven idp bid bpth < <(drive_ids "$dev")
  us="$(sanitize_id "$uid")"

  [[ -n "${active_uids[$us]:-}" ]] && { log_warn "Duplicate PID for $us"; continue; }
  active_uids["$us"]="$pid"

  sf="${STATE_DIR}/${us}.json"

  sb="$(norm_int "$(dev_size_bytes "$dev")")"
  wb="$(norm_int "$(pid_io_bytes "$pid" "write_bytes:")")"
  rb="$(norm_int "$(pid_io_bytes "$pid" "read_bytes:")")"
  db="$wb"; [[ "$db" -le 0 ]] && db="$rb"

  pc="0.0"
  (( sb > 0 && db > 0 )) && pc="$(awk -v d="$db" -v s="$sb" 'BEGIN{p=(d/s)*100;if(p>99.9)p=99.9;printf "%.1f",p}')"

  er=0
  [[ -n "$out" && -f "$out" ]] && er="$(wc -l <"$out" 2>/dev/null || echo 0)"
  er="$(norm_int "$er")"

  # Load prior state
  ppid="$(norm_int "$(jget "$sf" .pid)")"
  pph="$(jget "$sf" .phase_letter)"
  pps="$(jget "$sf" .phase_started_at)"
  pdb="$(norm_int "$(jget "$sf" .done_bytes)")"
  ppe="$(norm_int "$(jget "$sf" .progress_updated_epoch)")"
  ppc="$(norm_num "$(jget "$sf" .progress_pct)" "0.0")"
  lce="$(norm_int "$(jget "$sf" .last_change_epoch)")"

  # PATCH v1.7: Phase start detection with transition logging
  ps="$pps"
  if [[ "$ppid" != "$pid" || "$pph" != "$phl" || -z "$ps" ]]; then
    ps="$(now_iso)"
    
    # Log phase transitions to main log
    if [[ -n "$phl" && -n "$pph" && "$pph" != "$phl" ]]; then
      log_info "Phase transition for $us: $pph → $phl"
    fi
    
    [[ -n "$phl" ]] && send_alert INFO "Phase $phl started" "Dev:$short Pat:$pat" "$us" "ph_${phl}"
  fi

  ne="$(now_epoch)"
  ni="$(now_iso)"
  sp="0.0"
  eta=0

  if (( ppe > 0 )); then
    dt=$(( ne - ppe ))
    if (( dt > 0 )); then
      ddb=$(( db - pdb ))
      if (( ddb > 0 )); then
        sp="$(awk -v d="$ddb" -v t="$dt" 'BEGIN{printf "%.1f",(d/t)/1048576.0}')"
        if (( sb > 0 && db > 0 && db < sb )); then
          rem=$(( sb - db ))
          eta="$(awk -v r="$rem" -v d="$ddb" -v t="$dt" 'BEGIN{s=d/t;printf "%.0f",s>0?r/s:0}')"
        fi
      fi
    fi
  fi

  # Correct change detection (v1.6 fix)
  ch=1
  if [[ -f "$sf" ]]; then
    ch=0
    awk -v a="$pc" -v b="$ppc" 'BEGIN{exit !((a-b>=0.1)||(b-a>=0.1))}' && ch=1
    (( db > pdb )) && ch=1
  fi
  (( ch == 1 )) && lce="$ne"

  ssc=0
  (( lce > 0 )) && ssc=$(( ne - lce ))

  # Alerts
  (( er >= ERROR_CRITICAL_THRESHOLD )) && send_alert CRITICAL "High errors on $us" "$er bad blocks" "$us" "err_crit"
  (( er >= ERROR_WARN_THRESHOLD && er < ERROR_CRITICAL_THRESHOLD )) && send_alert WARNING "Elevated errors on $us" "$er bad blocks" "$us" "err_warn"
  (( ssc > CRITICAL_STALE_THRESHOLD )) && send_alert CRITICAL "Scan stalled on $us" "No progress ${ssc}s. Phase $phl ${pc}%" "$us" "stall_crit"
  (( ssc > STALE_THRESHOLD && ssc <= CRITICAL_STALE_THRESHOLD )) && send_alert WARNING "Scan may be stalled on $us" "No progress ${ssc}s. Phase $phl ${pc}%" "$us" "stall_warn"

  # PATCH v1.7: Add phase_num safety normalization
  pn="$(norm_int "$(phase_num "$phl")" "0")"

  # Base new JSON
  c="$(jq -n \
    --arg sv "$VERSION" \
    --arg scv "$SCHEMA_VERSION" \
    --arg d "$dev" \
    --arg s "$short" \
    --arg u "$uid" \
    --arg w "$wwn" \
    --arg ids "$ids" \
    --arg idss "$idss" \
    --arg m "$mod" \
    --arg v "$ven" \
    --arg ip "$idp" \
    --arg bi "$bid" \
    --arg bp "$bpth" \
    --arg sh "$sh" \
    --argjson p "$pid" \
    --arg pt "$pat" \
    --arg pl "$phl" \
    --argjson pn "$pn" \
    --arg psa "$ps" \
    --argjson dsb "$sb" \
    --argjson dob "$db" \
    --argjson ppc "$(norm_num "$pc" "0.0")" \
    --arg pua "$ni" \
    --argjson pue "$ne" \
    --argjson lce "$lce" \
    --argjson ssc "$ssc" \
    --argjson spm "$(norm_num "$sp" "0.0")" \
    --argjson ets "$(norm_int "$eta" "0")" \
    --arg bo "$out" \
    --argjson e "$er" \
    '{
      suite_version:$sv,
      schema_version:$scv,

      dev:$d,
      short:$s,

      unique_id:$u,
      wwn:$w,
      id_serial:$ids,
      id_serial_short:$idss,
      model:$m,
      vendor:$v,
      id_path:$ip,
      by_id:$bi,
      by_path:$bp,
      serial_hint:$sh,

      pid:$p,
      pattern:$pt,

      phase_letter:$pl,
      phase:$pn,
      phase_started_at:$psa,

      device_size_bytes:$dsb,
      done_bytes:$dob,
      progress_pct:$ppc,
      progress_updated_at:$pua,
      progress_updated_epoch:$pue,

      last_change_epoch:$lce,
      seconds_since_progress_change:$ssc,

      speed_mbps:$spm,
      eta_seconds:$ets,

      badblocks_out:$bo,
      errors:$e,

      active:1,
      ended_at:"",
      inactive_since:"",
      status:"running",

      phase_history:{"A":{},"B":{},"C":{},"D":{}}
    }'
  )"

  # Merge with existing + update phase_history (v1.6 fix)
  if [[ -f "$sf" ]]; then
    c="$(jq -s \
      --arg old_phase "$pph" \
      --arg new_phase "$phl" \
      --arg now "$ni" '
      .[0] as $old
      | .[1] as $new
      | ($old * $new) as $m
      | $m
      | .phase_history = ($old.phase_history // {"A":{},"B":{},"C":{},"D":{}})

      # If phase changed, set end on old phase
      | if (($old_phase|length)==1 and ($new_phase|length)==1 and ($old_phase != $new_phase)) then
          .phase_history[$old_phase].end = (.phase_history[$old_phase].end // "" | if .=="" then $now else . end)
        else .
        end

      # Update current phase stats
      | if (($new_phase|length)==1) then
          .phase_history[$new_phase].start = (.phase_history[$new_phase].start // "" | if .=="" then $new.phase_started_at else . end)
          | .phase_history[$new_phase].last_update = $new.progress_updated_at
          | .phase_history[$new_phase].errors = $new.errors
          | .phase_history[$new_phase].speed_mbps = $new.speed_mbps
          | .phase_history[$new_phase].pattern = $new.pattern
        else .
        end
      ' "$sf" <(printf '%s\n' "$c"))"
  else
    c="$(jq '
      .phase_history = (.phase_history // {"A":{},"B":{},"C":{},"D":{}})
      | if (.phase_letter|length)==1 then
          .phase_history[.phase_letter].start = (.phase_history[.phase_letter].start // "" | if .=="" then .phase_started_at else . end)
          | .phase_history[.phase_letter].last_update = .progress_updated_at
          | .phase_history[.phase_letter].errors = .errors
          | .phase_history[.phase_letter].speed_mbps = .speed_mbps
          | .phase_history[.phase_letter].pattern = .pattern
        else .
        end
    ' <(printf '%s\n' "$c"))"
  fi

  json_write "$sf" "$c" && log_info "Updated $us: ${pc}% ${er}err ${sp}MB/s" || log_error "Write failed: $us"
done

log_info "Checking inactive drives"
shopt -s nullglob
for f in "$STATE_DIR"/*.json; do
  u="$(basename "$f" .json)"
  [[ -z "${active_uids[$u]:-}" ]] || continue

  pa="$(norm_int "$(jget "$f" .active)" "0")"
  is="$(jget "$f" .inactive_since)"

  if (( pa == 1 )); then
    ni="$(now_iso)"
    pl="$(jget "$f" .phase_letter)"

    # Mark inactive (v1.6 fix)
    c="$(jq --arg t "$ni" --arg p "$pl" '
      .active=0
      | .ended_at=(.ended_at//"" | if .=="" then $t else . end)
      | .inactive_since=(.inactive_since//"" | if .=="" then $t else . end)
      | .status="completed"
      | .phase_history=(.phase_history//{"A":{},"B":{},"C":{},"D":{}})
      | if (($p|length)==1) then
          .phase_history[$p].end=(.phase_history[$p].end//"" | if .=="" then $t else . end)
        else .
        end
    ' "$f")"

    json_write "$f" "$c"

    er="$(jget "$f" .errors)"
    pc="$(jget "$f" .progress_pct)"
    send_alert INFO "Scan completed on $u" "Phase $pl ${pc}% ${er}err" "$u" "scan_end"
    log_info "Marked inactive $u phase=$pl"
    
  elif [[ -n "$is" ]]; then
    ie="$(date -d "$is" +%s 2>/dev/null || echo 0)"
    ne="$(now_epoch)"
    el=$(( ne - ie ))
    
    if (( el >= INACTIVE_GRACE_SECONDS )); then
      # PATCH v1.7: Improved archive error handling
      if [[ $ROTATE_STATE_FILES -eq 1 ]]; then
        if archive "$f"; then
          rm -f "$f"
          log_info "Removed archived state for $u"
        else
          log_error "Archive failed for $u, will retry next run"
        fi
      else
        rm -f "$f"
        log_info "Removed state for $u (archival disabled)"
      fi
    fi
  fi
done

[[ $ENABLE_PROMETHEUS -eq 1 ]] && write_metrics
log_info "Scan complete (${#pids[@]} active drives)"
exit 0
