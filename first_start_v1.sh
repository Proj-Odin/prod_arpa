#!/usr/bin/env bash
# check_badblocks_deps.sh

echo "Checking dependencies for badblocks_state_update.sh v1.5..."
echo

MISSING=0

check_cmd() {
  local cmd="$1" pkg="$2" required="$3"
  if command -v "$cmd" >/dev/null 2>&1; then
    echo "✅ $cmd (found)"
  else
    if [[ "$required" == "required" ]]; then
      echo "❌ $cmd (MISSING - install: $pkg)"
      MISSING=1
    else
      echo "⚠️  $cmd (optional - install: $pkg)"
    fi
  fi
}

echo "=== REQUIRED ==="
check_cmd jq "jq" required
check_cmd blockdev "util-linux" required
check_cmd date "coreutils" required
check_cmd awk "gawk" required
check_cmd sed "sed" required
check_cmd pgrep "procps-ng" required
check_cmd flock "util-linux" required
check_cmd readlink "coreutils" required
check_cmd badblocks "e2fsprogs" required

echo
echo "=== HIGHLY RECOMMENDED ==="
check_cmd udevadm "systemd/udev" recommended

echo
echo "=== OPTIONAL (for alerts) ==="
check_cmd mail "mailutils" optional
check_cmd curl "curl" optional

echo
if [[ $MISSING -eq 0 ]]; then
  echo "✅ All required dependencies are installed!"
  exit 0
else
  echo "❌ Missing required dependencies. Install them before running."
  exit 1
fi

: <<'COMMENT'
# Install on Debian/Ubuntu:
apt-get update
apt-get install -y \
  jq \
  util-linux \
  coreutils \
  gawk \
  sed \
  grep \
  procps \
  e2fsprogs

# Install on RHEL/CentOS/Rocky/Alma:
yum install -y \
  jq \
  util-linux \
  coreutils \
  gawk \
  sed \
  grep \
  procps-ng \
  e2fsprogs

# Install on Arch:
pacman -S \
  jq \
  util-linux \
  coreutils \
  gawk \
  sed \
  grep \
  procps-ng \
  e2fsprogs
 FROM debian:bookworm-slim

# Install all dependencies
RUN apt-get update && apt-get install -y \
    jq \
    util-linux \
    coreutils \
    gawk \
    sed \
    procps \
    e2fsprogs \
    systemd \
    curl \
    mailutils \
    && rm -rf /var/lib/apt/lists/*

# Copy script
COPY badblocks_state_update.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/badblocks_state_update.sh
    
  COMMENT
  
