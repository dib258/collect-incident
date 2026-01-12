#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Collect an "incident bundle" for debugging reboots/outages on Ubuntu (systemd/journald).

You typically run this on the server (as root via sudo), then download the .tgz.

Examples:
  sudo ./collect-incident.sh --center "2026-01-12 09:33:00 UTC" --before 30m --after 30m
  sudo ./collect-incident.sh --since "2026-01-12 09:00:00 UTC" --until "2026-01-12 10:00:00 UTC"
  sudo ./collect-incident.sh --center "2026-01-12 09:33:00 UTC" --out-dir .

Options:
  --center "<date>"   Center time (UTC recommended)
  --before 30m        How far back from center (default 30m)
  --after  30m        How far forward from center (default 30m)
  --since "<date>"    Explicit since time (overrides --center)
  --until "<date>"    Explicit until time (overrides --center)
  --out-dir <dir>     Output directory (auto-named incident-<timestamp>.tgz)
  --out  <path.tgz>   Output tarball path (default /tmp/incident-<timestamp>.tgz)
  --include-gz        Also include *.gz rotated logs under /var/log (bigger bundle)
EOF
}

run_id="$(date -u +%Y%m%dT%H%M%SZ)"

center=""
before="30m"
after="30m"
since=""
until=""
out="/tmp/incident-$run_id.tgz"
out_dir=""
out_user_set="0"
include_gz="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --center) center="${2:-}"; shift 2 ;;
    --before) before="${2:-}"; shift 2 ;;
    --after) after="${2:-}"; shift 2 ;;
    --since) since="${2:-}"; shift 2 ;;
    --until) until="${2:-}"; shift 2 ;;
    --out-dir) out_dir="${2:-}"; shift 2 ;;
    --out) out="${2:-}"; out_user_set="1"; shift 2 ;;
    --include-gz) include_gz="1"; shift 1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -n "$out_dir" && "$out_user_set" == "0" ]]; then
  mkdir -p "$out_dir"
  out="$out_dir/incident-$run_id.tgz"
fi

if [[ -z "$since" || -z "$until" ]]; then
  if [[ -z "$center" ]]; then
    echo "Provide --since/--until or --center." >&2
    usage
    exit 2
  fi

  # Use TZ=UTC so the arithmetic is deterministic.
  since="$(TZ=UTC date -d "$center - $before" '+%F %T UTC')"
  until="$(TZ=UTC date -d "$center + $after" '+%F %T UTC')"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

meta() { printf '[%s] %s\n' "$(date -u '+%F %T UTC')" "$*" >>"$tmp/METADATA.txt"; }
run() {
  meta "RUN: $*"
  ( "$@" ) >>"$tmp/METADATA.txt" 2>&1 || true
}

meta "Incident window: SINCE=$since  UNTIL=$until"
run uname -a
run cat /etc/os-release
run timedatectl
run uptime
run who -b
run last -x -n 50

# Boot inventory + previous boot are usually the best sources for "why did it reboot?"
journalctl --list-boots >"$tmp/journal-boots.txt" || true
journalctl -b -1 -o short-iso >"$tmp/journal-boot--1.txt" || true
journalctl -b -1 -k -o short-iso >"$tmp/journal-boot--1-kernel.txt" || true

# Full window journal + kernel window.
journalctl -o short-iso --since "$since" --until "$until" >"$tmp/journal-window.txt" || true
journalctl -k -o short-iso --since "$since" --until "$until" >"$tmp/journal-window-kernel.txt" || true

# Key services (add/remove to match your server).
units=(
  systemd-logind
  nginx
  php8.3-fpm
  mariadb
  redis-server
  unattended-upgrades
  apt-daily
  apt-daily-upgrade
  cron
  ssh
  sshd
  ufw
  do-agent
  droplet-agent
)

for unit in "${units[@]}"; do
  journalctl -u "$unit" -o short-iso --since "$since" --until "$until" >"$tmp/journal-unit-$unit.txt" 2>/dev/null || true
  systemctl status --no-pager "$unit" >"$tmp/systemctl-status-$unit.txt" 2>/dev/null || true
done

mkdir -p "$tmp/var-log"

copy_glob() {
  local pattern="$1"
  shopt -s nullglob
  for file in $pattern; do
    if [[ "$include_gz" == "0" && "$file" == *.gz ]]; then
      continue
    fi
    cp -a "$file" "$tmp/var-log/" 2>/dev/null || true
  done
  shopt -u nullglob
}

copy_glob "/var/log/syslog*"
copy_glob "/var/log/auth.log*"
copy_glob "/var/log/kern.log*"
copy_glob "/var/log/daemon.log*"
copy_glob "/var/log/ufw.log*"
copy_glob "/var/log/nginx/error.log*"
copy_glob "/var/log/nginx/access.log*"
copy_glob "/var/log/redis/*"
copy_glob "/var/log/mysql/*"
copy_glob "/var/log/unattended-upgrades/*"
copy_glob "/var/log/apt/history.log*"
copy_glob "/var/log/dpkg.log*"

tar -C "$tmp" -czf "$out" .
echo "$out"
