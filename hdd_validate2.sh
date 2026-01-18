#!/bin/bash
# hdd_validate.sh - Interactive HDD validation with persistent history
#
# OVERVIEW:
# This script provides comprehensive hard drive testing with two distinct phases:
#   - Phase 0: Non-destructive SMART diagnostics (short, conveyance, long tests + logs)
#   - Phase B: DESTRUCTIVE surface testing (badblocks write test) + temperature monitoring
#
# All test history is persisted in /var/lib/hdd_burnin/ as TSV files, allowing tracking
# of drive health over time and across multiple test runs.
#
# SAFETY FEATURES:
#   - Persistent drive registry with serial numbers and WWN identifiers
#   - Temperature monitoring with configurable emergency shutoff
#   - Mount detection to prevent testing drives in use
#   - Root disk protection to prevent OS drive testing
#   - Confirmation prompts for destructive operations
#   - Signal handling for clean termination
#
# REQUIREMENTS:
#   - Must run as root (needs direct disk access)
#   - Requires: smartctl, badblocks, lsblk, udevadm, findmnt, standard POSIX tools
#
# WARNING: Phase B is DESTRUCTIVE and will completely erase all data on selected drives.

set -euo pipefail

# =============================================================================
# CONFIGURATION VARIABLES
# =============================================================================

# Temperature threshold in Celsius - tests will emergency-abort if any drive exceeds this
MAX_TEMP="${MAX_TEMP:-45}"

# Maximum number of drives allowed in a single Phase B batch
# (Phase B runs badblocks in parallel, which can be I/O intensive)
MAX_BATCH="${MAX_BATCH:-4}"

# Block size for badblocks testing - 4096 is safe for modern HDDs with 4K sectors
BLOCK_SIZE="${BLOCK_SIZE:-4096}"

# Badblocks test chunk size - number of blocks tested at once
# Larger values = faster but more memory usage. 65536 blocks = 256MB chunks at 4K block size
BADBLOCKS_CHUNK="${BADBLOCKS_CHUNK:-65536}"

# Root directory for test run logs (each run gets a timestamped subdirectory)
LOG_ROOT="${LOG_ROOT:-/var/log}"

# Directory for persistent state (drive registry + test history)
STATE_DIR="${STATE_DIR:-/var/lib/hdd_burnin}"

# TSV file tracking all known drives (serial, WWN, model, size, first/last seen)
DRIVES_DB="$STATE_DIR/drives.tsv"

# TSV file tracking all test runs (phase, outcome, SMART stats, temperatures, etc.)
RUNS_DB="$STATE_DIR/runs.tsv"

# Generate unique run identifier from current timestamp
RUN_ID="$(date +%Y%m%d_%H%M%S)"

# Create log directory for this specific run
LOG_DIR="$LOG_ROOT/hdd_validate_$RUN_ID"
mkdir -p "$LOG_DIR"

# Summary file for this run (human-readable results)
SUMMARY="$LOG_DIR/SUMMARY.txt"

# =============================================================================
# GLOBAL STATE TRACKING
# =============================================================================

# Array of currently selected drives (by-id paths preferred for stability)
declare -a SELECTED=()

# Associative array tracking maximum temperature seen for each drive during current operation
# Key: drive path (e.g., /dev/disk/by-id/ata-...), Value: max temp in Celsius
declare -A TEMP_MAX=()

# Array tracking background process IDs for Phase B badblocks runs
# Used for both monitoring and emergency termination
declare -a BACKGROUND_PIDS=()

# Flag indicating whether we're currently running tests (used by signal handler)
TESTS_RUNNING=0

# =============================================================================
# DEPENDENCY CHECKING
# =============================================================================

# Check for required external commands
# Dies immediately if any dependency is missing to prevent confusing errors later
need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "[FATAL] Missing required dependency: $1"
    echo "Install it with your package manager and try again."
    exit 1
  fi
}

# Core dependencies required for operation
need smartctl   # For SMART diagnostics
need badblocks  # For surface testing
need lsblk      # For disk enumeration
need udevadm    # For stable device identifiers
need findmnt    # For mount detection
need awk        # For text processing
need sed        # For pattern manipulation
need sort       # For inventory sorting
need readlink   # For symlink resolution
need grep       # For pattern matching
need date       # For timestamps

# Verify we're running as root (needed for direct disk I/O)
if [[ $EUID -ne 0 ]]; then
  echo "[FATAL] This script must be run as root (use sudo)."
  echo "Reason: Direct disk access and SMART commands require root privileges."
  exit 1
fi

# =============================================================================
# SIGNAL HANDLING & CLEANUP
# =============================================================================

# Cleanup handler for graceful shutdown on SIGINT (Ctrl+C) or SIGTERM
# Ensures background badblocks processes are terminated to prevent orphaned I/O operations
cleanup_handler() {
  echo
  echo "[INTERRUPT] Received termination signal - cleaning up..."
  
  # If tests are actively running, kill background processes
  if [[ $TESTS_RUNNING -eq 1 ]]; then
    echo "[INFO] Terminating background test processes..."
    
    # Kill all tracked background PIDs
    for pid in "${BACKGROUND_PIDS[@]}"; do
      if kill -0 "$pid" 2>/dev/null; then
        echo "[INFO] Killing PID $pid..."
        kill -TERM "$pid" 2>/dev/null || true
      fi
    done
    
    # Also kill any orphaned job processes
    # shellcheck disable=SC2046
    kill $(jobs -p) 2>/dev/null || true
    
    echo "[INFO] Waiting for processes to terminate..."
    sleep 2
  fi
  
  echo "[INFO] Cleanup complete. Summary available at: $SUMMARY"
  exit 130  # Standard exit code for SIGINT termination
}

# Register the cleanup handler for interruption signals
trap cleanup_handler INT TERM

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

# Fatal error handler - logs message and exits
# Usage: die "error message"
die() {
  echo "[FATAL] $*" | tee -a "$SUMMARY"
  exit 1
}

# Generate ISO 8601 timestamp
# Returns: YYYY-MM-DDTHH:MM:SS±HH:MM
ts_now() {
  date -Is
}

# Sanitize field for TSV storage
# Removes tabs, newlines, carriage returns, and pipes (which could break parsing)
# Collapses multiple spaces, trims leading/trailing whitespace
# Usage: clean_field "raw string"
clean_field() {
  # Replace tab, CR, LF, and pipe with spaces
  # Collapse multiple spaces into one
  # Trim leading and trailing spaces
  echo "${1:-}" | tr '\t\r\n|' '    ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//'
}

# Sanitize string for use in filenames
# Replaces any non-alphanumeric characters (except . - _) with underscores
# Usage: sanitize "Serial Number ABC-123"
sanitize() {
  echo "${1:-}" | tr -c 'A-Za-z0-9._-' '_'
}

# Extract first integer from string, or return 0 if no integer found
# Usage: echo "foo123bar456" | first_int_or_zero  # Returns: 123
first_int_or_zero() {
  sed -E 's/[^0-9]*([0-9]+).*/\1/; t; s/.*/0/'
}

# =============================================================================
# DATABASE INITIALIZATION
# =============================================================================

# Initialize persistent database files if they don't exist
# Creates STATE_DIR and two TSV files: drives.tsv and runs.tsv
init_db() {
  # Create state directory with restrictive permissions (only root can access)
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"

  # Initialize drives registry if it doesn't exist
  # Tracks: serial number, WWN, model, size in bytes, first seen timestamp, last seen timestamp, notes
  if [[ ! -f "$DRIVES_DB" ]]; then
    printf "sn\twwn\tmodel\tsize_bytes\tfirst_seen\tlast_seen\tnotes\n" > "$DRIVES_DB"
    chmod 600 "$DRIVES_DB"  # Protect potentially sensitive drive info
  fi

  # Initialize test runs history if it doesn't exist
  # Tracks: run_id, timestamp, phase, outcome, drive identifiers, SMART stats, max temp, log location
  if [[ ! -f "$RUNS_DB" ]]; then
    printf "run_id\tts\tphase\toutcome\tsn\twwn\tmodel\tsize_bytes\tpoh\trealloc\tpending\toffline_unc\tudma_crc\ttemp_max\tlog_dir\n" > "$RUNS_DB"
    chmod 600 "$RUNS_DB"
  fi
}

# =============================================================================
# DISK IDENTIFICATION FUNCTIONS
# =============================================================================

# Determine the base disk device for the root filesystem
# Returns: /dev/sdX path or empty string if cannot determine
# Used to prevent accidentally testing the OS drive
root_base_disk() {
  local root_src base
  
  # Find the source device for root mount
  root_src="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
  
  # If root is on a partition, get the parent disk name
  base="$(lsblk -no PKNAME "$root_src" 2>/dev/null || true)"
  
  # Return full path if we found a parent, otherwise empty
  [[ -n "$base" ]] && echo "/dev/$base" || echo ""
}

# Resolve a device path to its canonical form
# Follows symlinks to get actual device path
# Usage: resolve_dev "/dev/disk/by-id/ata-..."
resolve_dev() {
  readlink -f "$1" 2>/dev/null || echo "$1"
}

# Check if device is a whole disk (not a partition)
# Returns: 0 if whole disk, 1 otherwise
is_whole_disk() {
  [[ "$(lsblk -no TYPE "$1" 2>/dev/null || true)" == "disk" ]]
}

# Check if device or any of its partitions are currently mounted
# Returns: 0 if mounted somewhere, 1 if not mounted
is_mounted_somewhere() {
  # Check device and all partitions (e.g., /dev/sda, /dev/sda1, /dev/sda2)
  lsblk -no MOUNTPOINT "${1}"* 2>/dev/null | grep -qE '\S'
}

# Get serial number for a device
# Tries smartctl first (most reliable), falls back to udevadm
# Returns: Serial number string or "UNKNOWN_SN" if not found
get_serial() {
  local d="$1"
  local out sn
  
  # Try smartctl -i first (most comprehensive for SMART devices)
  out="$(smartctl -i "$d" 2>/dev/null || true)"
  sn="$(echo "$out" | awk -F: '/Serial Number/ {gsub(/^[ \t]+/,"",$2); print $2; exit}' || true)"
  
  # Fall back to udevadm if smartctl didn't find it
  if [[ -z "${sn:-}" ]]; then
    sn="$(udevadm info --query=property --name="$d" 2>/dev/null | awk -F= '/^ID_SERIAL_SHORT=/ {print $2; exit}' || true)"
  fi
  
  # Return what we found, or a placeholder
  [[ -n "${sn:-}" ]] && echo "$sn" || echo "UNKNOWN_SN"
}

# Get WWN (World Wide Name) identifier for a device
# WWN is a globally unique identifier, more stable than serial numbers
# Returns: WWN string (e.g., 0x5000c500a1b2c3d4) or empty string
get_wwn() {
  local dev="$1"
  local wwn=""
  
  # Try udevadm first (fastest)
  wwn="$(udevadm info --query=property --name="$dev" 2>/dev/null | awk -F= '/^ID_WWN=/{print $2; exit}' || true)"
  
  # Fall back to smartctl if udevadm didn't find it
  if [[ -z "${wwn:-}" ]]; then
    local out
    out="$(smartctl -i "$dev" 2>/dev/null || true)"
    # Try multiple possible field names (varies by drive type)
    wwn="$(echo "$out" | awk -F: '/WWN|World Wide Name|LU WWN Device Id/ {gsub(/^[ \t]+/,"",$2); print $2; exit}' || true)"
  fi
  
  echo "${wwn:-}"
}

# Find the most stable /dev/disk/by-id/ path for a device
# Prefers WWN > ATA > SCSI identifiers, avoids partition links
# Returns: by-id path or fails with exit code 1
# Usage: best_by_id /dev/sda
best_by_id() {
  local dev="$1" p
  
  # Check WWN paths first (most stable)
  for p in /dev/disk/by-id/wwn-*; do
    [[ -e "$p" ]] || continue
    [[ "$p" == *-part* ]] && continue  # Skip partition links
    if [[ "$(readlink -f "$p")" == "$dev" ]]; then
      echo "$p"
      return 0
    fi
  done
  
  # Fall back to ATA paths
  for p in /dev/disk/by-id/ata-*; do
    [[ -e "$p" ]] || continue
    [[ "$p" == *-part* ]] && continue
    if [[ "$(readlink -f "$p")" == "$dev" ]]; then
      echo "$p"
      return 0
    fi
  done
  
  # Fall back to SCSI paths
  for p in /dev/disk/by-id/scsi-*; do
    [[ -e "$p" ]] || continue
    [[ "$p" == *-part* ]] && continue
    if [[ "$(readlink -f "$p")" == "$dev" ]]; then
      echo "$p"
      return 0
    fi
  done
  
  # No stable identifier found
  return 1
}

# =============================================================================
# SMART ATTRIBUTE EXTRACTION
# =============================================================================

# Extract a SMART attribute's raw value as an integer
# Usage: smart_attr /dev/sda Reallocated_Sector_Ct
# Returns: Integer value or 0 if attribute not found
smart_attr() {
  local dev="$1" name="$2" out val
  
  # Get SMART attributes table
  out="$(smartctl -A "$dev" 2>/dev/null || true)"
  
  # Extract the raw value (column 10) for the matching attribute name
  # first_int_or_zero ensures we always get a valid integer
  val="$(echo "$out" | awk -v n="$name" '$1==n {print $10; exit}' | first_int_or_zero)"
  
  echo "${val:-0}"
}

# Get key SMART health indicators as a formatted string
# Usage: smart_keyvals /dev/sda
# Returns: "POH=123 Realloc=0 Pending=0 OfflineUnc=0 UDMA_CRC=0"
smart_keyvals() {
  local d="$1"
  local realloc pending offline hours crc
  
  # Extract critical SMART attributes
  realloc="$(smart_attr "$d" Reallocated_Sector_Ct)"      # Sectors remapped due to errors
  pending="$(smart_attr "$d" Current_Pending_Sector)"     # Sectors waiting to be remapped
  offline="$(smart_attr "$d" Offline_Uncorrectable)"      # Uncorrectable errors found offline
  hours="$(smart_attr "$d" Power_On_Hours)"               # Total powered-on time
  crc="$(smart_attr "$d" UDMA_CRC_Error_Count)"          # Interface CRC errors
  
  echo "POH=$hours Realloc=$realloc Pending=$pending OfflineUnc=$offline UDMA_CRC=$crc"
}

# Check if a SMART self-test is currently running
# Returns: 0 if test in progress, 1 otherwise
selftest_in_progress() {
  local out
  out="$(smartctl -c "$1" 2>/dev/null || true)"
  echo "$out" | grep -qi "Self-test execution status:.*in progress"
}

# =============================================================================
# TEMPERATURE MONITORING
# =============================================================================

# Extract current temperature from SMART data
# Tries multiple possible attribute names (varies by drive manufacturer)
# Returns: Temperature in Celsius or empty string if not found
temp_of() {
  local d="$1"
  local out t
  
  # Get SMART attributes
  out="$(smartctl -A "$d" 2>/dev/null || true)"
  
  # Try multiple possible temperature attribute names
  # Different manufacturers use different names
  t="$(echo "$out" | awk '
    /Temperature_Celsius|Temperature_Internal|Airflow_Temperature_Cel/ {print $10; exit}
    /Current Drive Temperature/ {print $4; exit}
    /^Temperature:/ {print $2; exit}
  ' | sed -E 's/[^0-9].*//' || true)"
  
  echo "${t:-}"
}

# Monitor temperatures of all selected drives and emergency-abort if threshold exceeded
# Optionally terminates provided background PIDs if temperature emergency occurs
# Usage: check_temps_or_kill [pid1 pid2 ...]
# 
# NOTE: For Phase 0, we cannot kill SMART self-tests (they're firmware operations),
#       so we pass no PIDs and rely on natural test completion.
check_temps_or_kill() {
  local -a pids=("$@")
  local d dev t key
  
  # Skip if no drives are being monitored
  [[ "${#SELECTED[@]}" -eq 0 ]] && return 0
  
  # Check temperature of each selected drive
  for d in "${SELECTED[@]}"; do
    dev="$(resolve_dev "$d")"
    t="$(temp_of "$dev")"
    key="$d"
    
    # Update maximum temperature tracking if we got a valid reading
    if [[ -n "${t:-}" && "$t" =~ ^[0-9]+$ ]]; then
      # Track highest temperature seen for this drive during current operation
      if [[ -z "${TEMP_MAX[$key]:-}" || "$t" -gt "${TEMP_MAX[$key]}" ]]; then
        TEMP_MAX[$key]="$t"
      fi
      
      # EMERGENCY SHUTDOWN: Temperature exceeded safe threshold
      if [[ "$t" -ge "$MAX_TEMP" ]]; then
        echo
        echo "========================================" | tee -a "$SUMMARY"
        echo "[EMERGENCY] $d reached ${t}°C >= ${MAX_TEMP}°C threshold!" | tee -a "$SUMMARY"
        echo "[EMERGENCY] Aborting tests to prevent drive damage." | tee -a "$SUMMARY"
        echo "========================================" | tee -a "$SUMMARY"
        echo
        
        # Kill all provided background processes
        for pid in "${pids[@]}"; do
          if kill -0 "$pid" 2>/dev/null; then
            echo "[INFO] Terminating PID $pid..." | tee -a "$SUMMARY"
            kill -TERM "$pid" 2>/dev/null || true
          fi
        done
        
        # Exit immediately with failure code
        exit 1
      fi
    fi
  done
}

# =============================================================================
# DATABASE ACCESS FUNCTIONS
# =============================================================================

# Check if a drive exists in the registry (by serial number)
# Returns: 0 if found, 1 if not found
db_drive_exists() {
  local sn="$1"
  awk -F'\t' -v sn="$sn" 'NR>1 && $1==sn {found=1} END{exit(found?0:1)}' "$DRIVES_DB"
}

# Insert or update drive in registry
# Updates last_seen timestamp and fills in missing WWN if provided
# Usage: db_upsert_drive "serial" "wwn" "model" "size_bytes"
db_upsert_drive() {
  local sn="$1" wwn="$2" model="$3" sizeb="$4"
  local now; now="$(ts_now)"
  
  # Sanitize all fields for TSV storage
  sn="$(clean_field "$sn")"
  wwn="$(clean_field "$wwn")"
  model="$(clean_field "$model")"
  sizeb="$(clean_field "$sizeb")"
  
  # Skip if no valid serial number
  [[ -z "$sn" || "$sn" == "UNKNOWN_SN" ]] && return 0
  
  if db_drive_exists "$sn"; then
    # Update existing entry: refresh last_seen, fill in WWN if missing
    awk -F'\t' -v OFS='\t' -v sn="$sn" -v now="$now" -v wwn="$wwn" '
      NR==1 {print; next}
      $1==sn {
        $6=now                         # Update last_seen
        if ($2=="" && wwn!="") $2=wwn  # Fill in WWN if we have it and field is empty
      }
      {print}
    ' "$DRIVES_DB" > "$DRIVES_DB.tmp" && mv "$DRIVES_DB.tmp" "$DRIVES_DB"
  else
    # Insert new entry
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
      "$sn" "$wwn" "$model" "$sizeb" "$now" "$now" "" >> "$DRIVES_DB"
  fi
}

# Get summary of last test run for a drive
# Returns: "PHASE OUTCOME YYYY-MM-DD..." or empty string if no runs found
# Usage: db_last_run_summary "WD-ABC123"
db_last_run_summary() {
  local sn="$1"
  
  # Skip if no valid serial
  [[ -z "${sn:-}" || "$sn" == "UNKNOWN_SN" ]] && return 0
  
  # Find most recent run for this serial number
  # Returns format: "PHASE0 PASS 2025-01-15T10:30:00-05:00"
  awk -F'\t' -v sn="$sn" '
    NR>1 && $5==sn { last=$3" "$4" "$2 }
    END{ if(last!="") print last }
  ' "$RUNS_DB"
}

# Append a test run record to the history
# Usage: db_append_run phase outcome sn wwn model sizeb poh realloc pending offline crc tempmax logdir
db_append_run() {
  local phase="$1" outcome="$2" sn="$3" wwn="$4" model="$5" sizeb="$6"
  local poh="$7" realloc="$8" pending="$9" offline="${10}" crc="${11}"
  local tempmax="${12}" logdir="${13}"
  local now; now="$(ts_now)"
  
  # Append sanitized record to runs database
  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "$(clean_field "$RUN_ID")" "$now" "$(clean_field "$phase")" "$(clean_field "$outcome")" \
    "$(clean_field "$sn")" "$(clean_field "$wwn")" "$(clean_field "$model")" "$(clean_field "$sizeb")" \
    "$(clean_field "$poh")" "$(clean_field "$realloc")" "$(clean_field "$pending")" "$(clean_field "$offline")" \
    "$(clean_field "$crc")" "$(clean_field "$tempmax")" "$(clean_field "$logdir")" \
    >> "$RUNS_DB"
}

# =============================================================================
# DISK INVENTORY MANAGEMENT
# =============================================================================

# Arrays for disk inventory
# These parallel arrays store information indexed by a numeric key
declare -a IDX           # Numeric indices (1, 2, 3, ...)
declare -A DEV           # /dev/sdX device paths
declare -A SIZEB         # Size in bytes (for sorting)
declare -A SIZEH         # Human-readable size (e.g., "2.7T")
declare -A MODEL         # Drive model string
declare -A SERIAL        # Serial number
declare -A BYID          # Stable by-id path
declare -A WWN           # World Wide Name identifier

# Build or rebuild the disk inventory
# Populates the global arrays IDX, DEV, SIZEB, SIZEH, MODEL, SERIAL, BYID, WWN
# Also updates the persistent drive registry
build_inventory() {
  # Reset arrays
  IDX=()
  DEV=(); SIZEB=(); SIZEH=(); MODEL=(); SERIAL=(); BYID=(); WWN=()
  
  # Get all block devices of type "disk", sorted by size then name
  # Format: "sda 1000000000000"
  mapfile -t lines < <(
    lsblk -b -dn -o NAME,TYPE,SIZE | \
    awk '$2=="disk"{print $1" "$3}' | \
    sort -k2,2n -k1,1
  )
  
  local i=0 name bytes dev sizeh model sn byid wwn
  
  # Process each disk
  for line in "${lines[@]}"; do
    name="$(awk '{print $1}' <<<"$line")"
    bytes="$(awk '{print $2}' <<<"$line")"
    dev="/dev/$name"
    
    # Extract metadata for this disk
    sizeh="$(lsblk -dn -o SIZE "$dev" 2>/dev/null || echo "?")"
    model="$(lsblk -dn -o MODEL "$dev" 2>/dev/null | sed 's/[[:space:]]\+/ /g' || echo "?")"
    sn="$(get_serial "$dev")"
    wwn="$(get_wwn "$dev")"
    byid="$(best_by_id "$dev" 2>/dev/null || echo "$dev")"
    
    # Store in parallel arrays with numeric index
    i=$((i+1))
    IDX+=("$i")
    DEV["$i"]="$dev"
    SIZEB["$i"]="$bytes"
    SIZEH["$i"]="$sizeh"
    MODEL["$i"]="$model"
    SERIAL["$i"]="$sn"
    WWN["$i"]="$wwn"
    BYID["$i"]="$byid"
    
    # Update persistent registry with this drive's info
    db_upsert_drive "$sn" "$wwn" "$model" "$bytes"
  done
}

# Display the current disk inventory with test history
# Shows: Number, Device, Size, Model, Serial, Last Test Run, Stable Path
print_inventory() {
  echo
  echo "============================================================================"
  echo "Available disks (sorted by size):"
  echo "============================================================================"
  
  # Print header
  printf "%-4s %-12s %-8s %-24s %-22s %-26s %s\n" \
    "No." "Device" "Size" "Model" "Serial" "Last Run" "Stable by-id"
  printf "%-4s %-12s %-8s %-24s %-22s %-26s %s\n" \
    "----" "------------" "--------" "------------------------" \
    "----------------------" "--------------------------" "---------------------------"
  
  # Print each disk
  local i last
  for i in "${IDX[@]}"; do
    # Get last test run summary from history
    last="$(db_last_run_summary "${SERIAL[$i]}")"
    
    printf "%-4s %-12s %-8s %-24.24s %-22.22s %-26.26s %s\n" \
      "$i" "${DEV[$i]}" "${SIZEH[$i]}" "${MODEL[$i]}" "${SERIAL[$i]}" \
      "${last:-never tested}" "${BYID[$i]}"
  done
  
  echo
  echo "Persistent tracking:"
  echo "  Drives registry: $DRIVES_DB"
  echo "  Run history:     $RUNS_DB"
  echo "============================================================================"
  echo
}

# =============================================================================
# USER DRIVE SELECTION
# =============================================================================

# Prompt user to select drives from inventory
# Populates global SELECTED array with stable by-id paths
# Usage: select_drives "prompt text" max_count
#        max_count=0 means no limit
select_drives() {
  local prompt="$1"
  local max_allowed="${2:-0}"   # 0 = unlimited
  local input=()
  
  # Clear previous selection
  SELECTED=()
  
  echo
  echo "$prompt"
  echo "Enter disk numbers separated by spaces (e.g., 1 3 5)."
  echo "Press Enter with no input to skip."
  echo -n "> "
  
  # Read user input (won't fail on empty input)
  read -r -a input || true
  
  # Empty input = user skipped
  [[ "${#input[@]}" -eq 0 ]] && return 0
  
  # Validate selections and remove duplicates
  local seen=" "  # Space-separated list of seen numbers
  local n
  
  for n in "${input[@]}"; do
    # Ensure input is a number
    [[ "$n" =~ ^[0-9]+$ ]] || die "Invalid selection: '$n' is not a number"
    
    # Ensure number corresponds to a disk
    [[ -n "${DEV[$n]:-}" ]] || die "No such disk number: $n"
    
    # Skip duplicates
    [[ "$seen" == *" $n "* ]] && continue
    
    # Mark as seen
    seen+=" $n "
  done
  
  # Build SELECTED array from validated unique selections
  # Use stable by-id paths for resilience across reboots
  for n in "${input[@]}"; do
    # Only add if still in seen list (duplicates removed)
    [[ "$seen" != *" $n "* ]] && continue
    
    SELECTED+=("${BYID[$n]}")
    
    # Remove from seen to prevent duplicate additions
    seen="${seen/ $n / }"
  done
  
  # Check maximum count constraint
  if [[ "$max_allowed" -gt 0 && "${#SELECTED[@]}" -gt "$max_allowed" ]]; then
    die "Selected ${#SELECTED[@]} drives, but maximum allowed is $max_allowed."
  fi
  
  # Report selection
  if [[ "${#SELECTED[@]}" -gt 0 ]]; then
    echo "[INFO] Selected ${#SELECTED[@]} drive(s):"
    for d in "${SELECTED[@]}"; do
      echo "  - $d"
    done
  fi
}

# =============================================================================
# PHASE 0: NON-DESTRUCTIVE SMART TESTING
# =============================================================================

# Run comprehensive SMART diagnostics on selected drives
# Phases: Short test → Conveyance test → Long test
# All tests run in drive firmware - cannot be killed, only monitored
# Usage: phase0 /dev/disk/by-id/... [more drives...]
phase0() {
  local -a drives=("$@")
  
  # Skip if no drives selected
  [[ "${#drives[@]}" -gt 0 ]] || {
    echo "[INFO] Phase 0 skipped - no drives selected."
    return 0
  }
  
  echo
  echo "============================================================================"
  echo "[PHASE 0] Starting non-destructive SMART diagnostics..."
  echo "============================================================================"
  echo "Selected drives: ${#drives[@]}"
  echo "Tests: Short → Conveyance → Long (may take many hours)"
  echo "Temperature monitoring enabled (emergency abort at ${MAX_TEMP}°C)"
  echo
  
  # Set up temperature tracking for these drives
  SELECTED=("${drives[@]}")
  TEMP_MAX=()
  
  local d dev sn s wwn model sizeb
  
  # ===========================================================================
  # Step 1: Capture baseline SMART data and initiate short+conveyance tests
  # ===========================================================================
  
  echo "[PHASE 0] Step 1/4: Capturing baseline SMART data and starting short tests..."
  
  for d in "${drives[@]}"; do
    dev="$(resolve_dev "$d")"
    sn="$(get_serial "$dev")"
    s="$(sanitize "$sn")"
    
    echo "[INFO] Processing: $d (SN=$sn)"
    
    # Capture full SMART report (baseline before tests)
    smartctl -x "$dev" > "$LOG_DIR/phase0_smart_pre_${s}.log" 2>/dev/null || true
    
    # Initiate short self-test (~1-2 minutes)
    echo "  - Starting short self-test..."
    smartctl -t short "$dev" >/dev/null 2>&1 || true
    
    # Initiate conveyance test if supported (~5 minutes, tests for transport damage)
    # Not all drives support this - failure is expected and ignored
    echo "  - Starting conveyance self-test (if supported)..."
    smartctl -t conveyance "$dev" >/dev/null 2>&1 || true
  done
  
  # ===========================================================================
  # Step 2: Wait for short/conveyance tests to complete
  # ===========================================================================
  
  echo
  echo "[PHASE 0] Step 2/4: Waiting for short/conveyance tests to complete (~5 minutes)..."
  echo "[INFO] Monitoring temperatures every 60 seconds..."
  
  # Note: We cannot kill SMART self-tests (they're firmware operations)
  # Temperature monitoring here is informational + will abort script if needed
  # but cannot stop the tests themselves
  for i in {1..5}; do
    echo "[INFO] Wait cycle $i/5 - checking temperatures..."
    check_temps_or_kill  # No PIDs to kill - will only abort script on emergency
    sleep 60
  done
  
  # ===========================================================================
  # Step 3: Capture short/conveyance test results and start long test
  # ===========================================================================
  
  echo
  echo "[PHASE 0] Step 3/4: Capturing short/conveyance results and starting long tests..."
  
  for d in "${drives[@]}"; do
    dev="$(resolve_dev "$d")"
    sn="$(get_serial "$dev")"
    s="$(sanitize "$sn")"
    
    echo "[INFO] Processing: $d (SN=$sn)"
    
    # Capture self-test results log (contains short + conveyance results)
    smartctl -l selftest "$dev" > "$LOG_DIR/phase0_selftest_after_short_${s}.log" 2>/dev/null || true
    
    # Capture error log (shows any errors detected during tests)
    smartctl -l error "$dev" > "$LOG_DIR/phase0_errorlog_after_short_${s}.log" 2>/dev/null || true
    
    # Initiate long self-test (can take 4-12+ hours depending on drive size)
    echo "  - Starting long self-test (this will take several hours)..."
    smartctl -t long "$dev" >/dev/null 2>&1 || true
  done
  
  # ===========================================================================
  # Step 4: Poll for long test completion
  # ===========================================================================
  
  echo
  echo "[PHASE 0] Step 4/4: Polling for long test completion..."
  echo "[INFO] This may take 4-12+ hours depending on drive size and health."
  echo "[INFO] Checking every 5 minutes for completion + temperature monitoring..."
  echo
  
  local poll_count=0
  
  while :; do
    poll_count=$((poll_count + 1))
    
    # Check temperatures (no PIDs to kill, but will abort script if needed)
    check_temps_or_kill
    
    # Check if any tests are still running
    local any_running=0
    local status_msg=""
    
    for d in "${drives[@]}"; do
      dev="$(resolve_dev "$d")"
      
      if selftest_in_progress "$dev"; then
        any_running=1
        
        # Try to get estimated completion time
        local eta
        eta="$(smartctl -c "$dev" 2>/dev/null | grep -i "please wait" | head -1 || true)"
        
        if [[ -n "$eta" ]]; then
          status_msg="${status_msg}  - $d: ${eta}\n"
        else
          status_msg="${status_msg}  - $d: test in progress\n"
        fi
      fi
    done
    
    # If no tests running, we're done
    [[ "$any_running" -eq 0 ]] && break
    
    # Show status
    echo "[INFO] Poll #${poll_count} - Tests still running:"
    echo -e "$status_msg"
    
    # Wait 5 minutes before next check
    sleep 300
  done
  
  echo
  echo "[PHASE 0] All long tests complete! Capturing final results..."
  echo
  
  # ===========================================================================
  # Step 5: Capture final SMART data and generate verdicts
  # ===========================================================================
  
  local poh realloc pending offline crc outcome tempmax
  
  for d in "${drives[@]}"; do
    dev="$(resolve_dev "$d")"
    sn="$(get_serial "$dev")"
    s="$(sanitize "$sn")"
    wwn="$(get_wwn "$dev")"
    model="$(lsblk -dn -o MODEL "$dev" 2>/dev/null | sed 's/[[:space:]]\+/ /g' || echo "?")"
    sizeb="$(lsblk -b -dn -o SIZE "$dev" 2>/dev/null || echo "")"
    
    echo "[INFO] Finalizing: $d (SN=$sn)"
    
    # Capture post-test SMART data
    smartctl -x "$dev" > "$LOG_DIR/phase0_smart_post_${s}.log" 2>/dev/null || true
    smartctl -l selftest "$dev" > "$LOG_DIR/phase0_selftest_after_long_${s}.log" 2>/dev/null || true
    smartctl -l error "$dev" > "$LOG_DIR/phase0_errorlog_after_long_${s}.log" 2>/dev/null || true
    
    # Extract critical SMART attributes
    poh="$(smart_attr "$dev" Power_On_Hours)"
    realloc="$(smart_attr "$dev" Reallocated_Sector_Ct)"
    pending="$(smart_attr "$dev" Current_Pending_Sector)"
    offline="$(smart_attr "$dev" Offline_Uncorrectable)"
    crc="$(smart_attr "$dev" UDMA_CRC_Error_Count)"
    
    # Determine outcome: FAIL if any bad sector counts are non-zero
    outcome="PASS"
    if [[ "$realloc" -gt 0 || "$pending" -gt 0 || "$offline" -gt 0 ]]; then
      outcome="FAIL"
    fi
    
    # Get maximum temperature seen during testing
    tempmax="${TEMP_MAX[$d]:-NA}"
    
    # Display result
    echo "  ----------------------------------------"
    echo "  [RESULT] $outcome"
    echo "  $(smart_keyvals "$dev")"
    echo "  TempMax=${tempmax}°C"
    echo "  ----------------------------------------"
    echo
    
    # Log to summary
    echo "[PHASE 0 RESULT] $d : $(smart_keyvals "$dev") Outcome=$outcome TempMax=${tempmax}" | tee -a "$SUMMARY"
    
    # Record in persistent database
    db_append_run "PHASE0" "$outcome" "$sn" "$wwn" "$model" "$sizeb" \
      "$poh" "$realloc" "$pending" "$offline" "$crc" "$tempmax" "$LOG_DIR"
  done
  
  echo
  echo "============================================================================"
  echo "[PHASE 0] Complete!"
  echo "============================================================================"
  echo "Logs saved to: $LOG_DIR/phase0_*"
  echo "Summary: $SUMMARY"
  echo
}

# =============================================================================
# PHASE B: DESTRUCTIVE SURFACE TESTING
# =============================================================================

# Run destructive badblocks write test on selected drives
# WARNING: This ERASES ALL DATA on selected drives
# Tests: 4-pass write pattern + full surface scan
# Usage: phaseB /dev/disk/by-id/... [more drives...]
# Returns: 0 if all drives pass, 1 if any drive fails
phaseB() {
  local -a drives=("$@")
  
  # Skip if no drives selected
  [[ "${#drives[@]}" -gt 0 ]] || {
    echo "[INFO] Phase B skipped - no drives selected."
    return 0
  }
  
  # Enforce batch size limit
  [[ "${#drives[@]}" -le "$MAX_BATCH" ]] || \
    die "Phase B maximum is $MAX_BATCH drives at once (selected ${#drives[@]})"
  
  echo
  echo "============================================================================"
  echo "[PHASE B] DESTRUCTIVE surface test with badblocks"
  echo "============================================================================"
  echo "WARNING: This will COMPLETELY ERASE all data on selected drives!"
  echo "Selected drives: ${#drives[@]}"
  echo "Block size: $BLOCK_SIZE bytes"
  echo "Chunk size: $BADBLOCKS_CHUNK blocks ($(( BLOCK_SIZE * BADBLOCKS_CHUNK / 1024 / 1024 ))MB)"
  echo "Temperature monitoring enabled (emergency abort at ${MAX_TEMP}°C)"
  echo
  
  # ===========================================================================
  # Safety checks
  # ===========================================================================
  
  echo "[SAFETY] Performing pre-flight safety checks..."
  
  local root_disk; root_disk="$(root_base_disk)"
  local d dev
  
  for d in "${drives[@]}"; do
    dev="$(resolve_dev "$d")"
    
    # Ensure it's a block device
    [[ -b "$dev" ]] || die "Not a block device: $dev"
    
    # Ensure it's a whole disk, not a partition
    is_whole_disk "$dev" || die "Not a whole disk: $dev (must be sda not sda1)"
    
    # Prevent testing the OS disk
    if [[ -n "$root_disk" && "$dev" == "$root_disk" ]]; then
      die "SAFETY ABORT: Refusing to test OS disk: $dev"
    fi
    
    # Prevent testing mounted drives
    if is_mounted_somewhere "$dev"; then
      die "SAFETY ABORT: $dev (or a partition) is currently mounted"
    fi
  done
  
  echo "[SAFETY] All checks passed."
  echo
  
  # ===========================================================================
  # Confirmation prompt
  # ===========================================================================
  
  echo "The following drives will be COMPLETELY ERASED:"
  for d in "${drives[@]}"; do
    dev="$(resolve_dev "$d")"
    echo "  - $d"
    echo "      Device:  $dev"
    echo "      Serial:  $(get_serial "$dev")"
    echo "      Size:    $(lsblk -dn -o SIZE "$dev")"
    echo "      Model:   $(lsblk -dn -o MODEL "$dev")"
  done
  echo
  echo "This operation will take many hours (typically 1+ hours per TB)."
  echo
  echo "Type exactly: ERASE"
  echo "to proceed, or anything else to cancel."
  echo -n "> "
  
  read -r confirm
  
  if [[ "$confirm" != "ERASE" ]]; then
    echo "[INFO] User cancelled - no changes made."
    return 0
  fi
  
  echo
  echo "[INFO] Confirmed - proceeding with destructive testing..."
  echo
  
  # ===========================================================================
  # Initialize testing state
  # ===========================================================================
  
  # Set up temperature tracking for these drives
  SELECTED=("${drives[@]}")
  TEMP_MAX=()
  
  # Clear background PID tracking array
  BACKGROUND_PIDS=()
  
  # Associative array to map drive paths to their badblocks PIDs
  declare -A PIDS
  
  # Mark that tests are now running (for signal handler)
  TESTS_RUNNING=1
  
  # ===========================================================================
  # Start badblocks on all drives in parallel
  # ===========================================================================
  
  echo "[PHASE B] Starting badblocks processes..."
  echo
  
  local sn s bb_log bb_bad
  
  for d in "${drives[@]}"; do
    dev="$(resolve_dev "$d")"
    sn="$(get_serial "$dev")"
    s="$(sanitize "$sn")"
    
    echo "[INFO] Initializing: $d (SN=$sn)"
    
    # Capture pre-test SMART baseline
    smartctl -x "$dev" > "$LOG_DIR/phaseB_smart_pre_${s}.log" 2>/dev/null || true
    
    # Set up log files
    bb_log="$LOG_DIR/phaseB_badblocks_${s}.log"
    bb_bad="$LOG_DIR/phaseB_badblocks_${s}.bad"
    
    # Start badblocks in background
    # -b: block size
    # -w: destructive write test (4 passes with different patterns)
    # -s: show progress
    # -v: verbose
    # -c: chunk size (blocks tested at once)
    # -o: output file for bad blocks found
    echo "  - Starting badblocks: $bb_log"
    badblocks -b "$BLOCK_SIZE" -wsv -c "$BADBLOCKS_CHUNK" -o "$bb_bad" "$dev" \
      > "$bb_log" 2>&1 &
    
    # Track this PID
    PIDS["$d"]=$!
    BACKGROUND_PIDS+=("${PIDS[$d]}")
    
    echo "  - PID: ${PIDS[$d]}"
    echo
  done
  
  echo "[PHASE B] All badblocks processes started. Monitoring progress..."
  echo "[INFO] Progress can be viewed in log files or with: tail -f $LOG_DIR/phaseB_badblocks_*.log"
  echo
  
  # ===========================================================================
  # Monitor badblocks processes until completion
  # ===========================================================================
  
  local check_count=0
  
  while :; do
    check_count=$((check_count + 1))
    
    # Temperature check with emergency kill capability
    # Pass all PIDs so check_temps_or_kill can terminate them if needed
    check_temps_or_kill "${BACKGROUND_PIDS[@]}"
    
    # Check if any badblocks processes are still running
    local any_running=0
    
    for d in "${drives[@]}"; do
      if kill -0 "${PIDS[$d]}" 2>/dev/null; then
        any_running=1
      fi
    done
    
    # All done?
    [[ "$any_running" -eq 0 ]] && break
    
    # Status update every 10 checks (10 minutes)
    if [[ $((check_count % 10)) -eq 0 ]]; then
      echo "[INFO] Check #${check_count} - badblocks still running on:"
      for d in "${drives[@]}"; do
        if kill -0 "${PIDS[$d]}" 2>/dev/null; then
          dev="$(resolve_dev "$d")"
          local temp; temp="$(temp_of "$dev")"
          echo "  - $d (temp: ${temp:-?}°C)"
        fi
      done
      echo
    fi
    
    # Wait 60 seconds before next check
    sleep 60
  done
  
  # Tests are no longer running (for signal handler)
  TESTS_RUNNING=0
  
  echo
  echo "[PHASE B] All badblocks processes have completed."
  echo
  
  # ===========================================================================
  # Check exit codes and collect badblocks results
  # ===========================================================================
  
  echo "[PHASE B] Checking badblocks exit codes..."
  
  local bb_failed=0  # Track if any drive failed
  
  for d in "${drives[@]}"; do
    echo -n "[INFO] $d: "
    
    # Wait for process and check exit code
    # Note: badblocks exit codes:
    #   0 = success (no bad blocks found)
    #   non-zero = errors occurred or bad blocks found
    if wait "${PIDS[$d]}"; then
      echo "exit code 0 (OK)"
    else
      echo "exit code $? (FAILED)"
      bb_failed=1
    fi
  done
  
  echo
  
  # ===========================================================================
  # Capture post-test SMART data and generate verdicts
  # ===========================================================================
  
  echo "[PHASE B] Capturing post-test SMART data and generating verdicts..."
  echo
  
  local wwn model sizeb poh realloc pending offline crc outcome tempmax
  
  for d in "${drives[@]}"; do
    dev="$(resolve_dev "$d")"
    sn="$(get_serial "$dev")"
    s="$(sanitize "$sn")"
    wwn="$(get_wwn "$dev")"
    model="$(lsblk -dn -o MODEL "$dev" 2>/dev/null | sed 's/[[:space:]]\+/ /g' || echo "?")"
    sizeb="$(lsblk -b -dn -o SIZE "$dev" 2>/dev/null || echo "")"
    
    bb_bad="$LOG_DIR/phaseB_badblocks_${s}.bad"
    
    echo "[INFO] Finalizing: $d (SN=$sn)"
    
    # Capture post-test SMART data
    smartctl -x "$dev" > "$LOG_DIR/phaseB_smart_post_${s}.log" 2>/dev/null || true
    
    # Extract critical SMART attributes
    poh="$(smart_attr "$dev" Power_On_Hours)"
    realloc="$(smart_attr "$dev" Reallocated_Sector_Ct)"
    pending="$(smart_attr "$dev" Current_Pending_Sector)"
    offline="$(smart_attr "$dev" Offline_Uncorrectable)"
    crc="$(smart_attr "$dev" UDMA_CRC_Error_Count)"
    
    # Determine outcome
    outcome="PASS"
    
    # FAIL if any bad sector indicators are non-zero
    if [[ "$realloc" -gt 0 || "$pending" -gt 0 || "$offline" -gt 0 ]]; then
      outcome="FAIL"
    fi
    
    # FAIL if badblocks found bad blocks
    if [[ -s "$bb_bad" ]]; then
      outcome="FAIL"
      bb_failed=1
    fi
    
    # Get maximum temperature
    tempmax="${TEMP_MAX[$d]:-NA}"
    
    # Display detailed result
    echo "  ========================================"
    echo "  Drive: $d"
    echo "  Serial: $sn"
    echo "  ----------------------------------------"
    echo "  Outcome: $outcome"
    echo "  ----------------------------------------"
    echo "  SMART Stats:"
    echo "    $(smart_keyvals "$dev")"
    echo "  ----------------------------------------"
    echo "  Temperature:"
    echo "    Max: ${tempmax}°C"
    echo "  ----------------------------------------"
    echo "  Surface Test:"
    
    if [[ -s "$bb_bad" ]]; then
      local bad_count
      bad_count="$(wc -l < "$bb_bad")"
      echo "    ❌ FAILED - Found ${bad_count} bad blocks"
      echo "    Bad blocks list: $bb_bad"
    else
      echo "    ✓ PASSED - No bad blocks found"
    fi
    
    echo "  ========================================"
    echo
    
    # Log to summary
    {
      echo "---- PHASE B RESULT: $d (SN=$sn) ----"
      echo "Outcome: $outcome"
      echo "$(smart_keyvals "$dev")"
      echo "TempMax: ${tempmax}°C"
      if [[ -s "$bb_bad" ]]; then
        echo "Badblocks: FAILED (see $bb_bad)"
      else
        echo "Badblocks: PASSED"
      fi
      echo "----------------------------------------"
      echo
    } | tee -a "$SUMMARY"
    
    # Record in persistent database
    db_append_run "PHASEB" "$outcome" "$sn" "$wwn" "$model" "$sizeb" \
      "$poh" "$realloc" "$pending" "$offline" "$crc" "$tempmax" "$LOG_DIR"
  done
  
  # ===========================================================================
  # Final summary
  # ===========================================================================
  
  echo "============================================================================"
  echo "[PHASE B] Complete!"
  echo "============================================================================"
  echo "Logs saved to: $LOG_DIR/phaseB_*"
  echo "Summary: $SUMMARY"
  
  if [[ "$bb_failed" -eq 0 ]]; then
    echo "Result: ALL DRIVES PASSED ✓"
    echo "============================================================================"
    echo
    return 0
  else
    echo "Result: ONE OR MORE DRIVES FAILED ✗"
    echo "Review badblocks logs and SMART data for details."
    echo "============================================================================"
    echo
    return 1
  fi
}

# =============================================================================
# MAIN PROGRAM
# =============================================================================

# Initialize persistent database
init_db

# Write run header to summary file
{
  echo "=========================================================================="
  echo "HDD Validation Run: $RUN_ID"
  echo "=========================================================================="
  echo "Started: $(ts_now)"
  echo "Log directory: $LOG_DIR"
  echo "State directory: $STATE_DIR"
  echo ""
  echo "Configuration:"
  echo "  MAX_TEMP = ${MAX_TEMP}°C (emergency abort threshold)"
  echo "  MAX_BATCH = $MAX_BATCH drives (Phase B parallel limit)"
  echo "  BLOCK_SIZE = $BLOCK_SIZE bytes"
  echo "  BADBLOCKS_CHUNK = $BADBLOCKS_CHUNK blocks"
  echo "=========================================================================="
  echo
} > "$SUMMARY"

# Build initial disk inventory
build_inventory

# Sanity check: ensure we found at least one disk
[[ "${#IDX[@]}" -gt 0 ]] || die "No disks found on system. Nothing to test."

# =============================================================================
# Interactive menu loop
# =============================================================================

echo
echo "=========================================================================="
echo "HDD VALIDATION TOOL"
echo "=========================================================================="
echo "This tool provides comprehensive hard drive testing:"
echo "  • Phase 0: Non-destructive SMART diagnostics"
echo "  • Phase B: DESTRUCTIVE surface testing (erases data)"
echo
echo "All test results are saved to persistent database for historical tracking."
echo "=========================================================================="
echo

while :; do
  # Refresh inventory (in case drives were added/removed, or after tests completed)
  build_inventory
  
  # Display current disk inventory with test history
  print_inventory
  
  # Show menu
  echo "Actions:"
  echo "  1) Run Phase 0 (SMART diagnostics) on selected drives"
  echo "  2) Run Phase B (DESTRUCTIVE badblocks) on selected drives (max $MAX_BATCH)"
  echo "  3) Run BOTH phases on selected drives (Phase 0 → Phase B)"
  echo "  4) View current summary"
  echo "  5) Exit"
  echo
  echo -n "Select action [1-5]: "
  
  read -r choice
  
  case "$choice" in
    1)
      # Phase 0 only
      echo
      select_drives "Select drives for Phase 0 (SMART diagnostics):" 0
      
      if [[ "${#SELECTED[@]}" -gt 0 ]]; then
        phase0 "${SELECTED[@]}"
      else
        echo "[INFO] No drives selected - skipping Phase 0."
      fi
      ;;
      
    2)
      # Phase B only
      echo
      select_drives "Select drives for Phase B (DESTRUCTIVE - max $MAX_BATCH):" "$MAX_BATCH"
      
      if [[ "${#SELECTED[@]}" -gt 0 ]]; then
        # Note: We don't exit on Phase B failure - let user continue with menu
        phaseB "${SELECTED[@]}" || echo "[INFO] Phase B completed with failures (see above)"
      else
        echo "[INFO] No drives selected - skipping Phase B."
      fi
      ;;
      
    3)
      # Both phases
      echo
      select_drives "Select drives for BOTH phases (Phase B max $MAX_BATCH):" "$MAX_BATCH"
      
      if [[ "${#SELECTED[@]}" -gt 0 ]]; then
        # Run Phase 0 first (non-destructive)
        phase0 "${SELECTED[@]}"
        
        # Then run Phase B (destructive)
        # Don't exit on failure - let user continue
        phaseB "${SELECTED[@]}" || echo "[INFO] Phase B completed with failures (see above)"
      else
        echo "[INFO] No drives selected - skipping both phases."
      fi
      ;;
      
    4)
      # Display current summary
      echo
      echo "=========================================================================="
      echo "CURRENT RUN SUMMARY"
      echo "=========================================================================="
      if [[ -f "$SUMMARY" ]]; then
        cat "$SUMMARY"
      else
        echo "[INFO] No summary available yet."
      fi
      echo "=========================================================================="
      echo
      ;;
      
    5)
      # Exit
      echo
      echo "=========================================================================="
      echo "Exiting HDD Validation Tool"
      echo "=========================================================================="
      echo "Run ID: $RUN_ID"
      echo "Summary: $SUMMARY"
      echo "Logs: $LOG_DIR"
      echo
      echo "Historical data:"
      echo "  Drives: $DRIVES_DB"
      echo "  Runs:   $RUNS_DB"
      echo "=========================================================================="
      echo
      exit 0
      ;;
      
    *)
      echo
      echo "[ERROR] Invalid selection. Please choose 1-5."
      echo
      ;;
  esac
  
  # Show summary location after each operation
  echo
  echo "Current run summary: $SUMMARY"
  echo
  echo "Press Enter to continue..."
  read -r
done
