# Incident log bundle script

This folder includes `collect-incident.sh`, a small helper to collect the most useful logs for investigating short outages on an Ubuntu 24.04 droplet (reboots, service restarts, network issues).

## What it collects

The script creates a single `.tgz` “incident bundle” containing:

- **journald boot inventory** (`journalctl --list-boots`)
- **previous boot journal** (`journalctl -b -1`) and **previous boot kernel log** (`journalctl -b -1 -k`)
- **all journald entries** for the incident time window (`--since` → `--until`) + the **kernel log for that window**
- **per-service journald slices** for common services:
  - `systemd-logind` (power/reboot events)
  - `nginx`, `php8.3-fpm`, `mariadb`, `redis-server`
  - `unattended-upgrades`, `apt-daily`, `apt-daily-upgrade`
  - `cron`, `ssh`/`sshd`, `ufw`
  - DigitalOcean agents: `do-agent`, `droplet-agent`
- **traditional log files** (copied as-is if present):
  - `/var/log/syslog*`, `/var/log/auth.log*`, `/var/log/kern.log*`, `/var/log/daemon.log*`
  - `/var/log/nginx/error.log*`, `/var/log/nginx/access.log*`
  - `/var/log/redis/*`
  - `/var/log/mysql/*` (works for MariaDB installs too)
  - `/var/log/unattended-upgrades/*`, `/var/log/apt/history.log*`, `/var/log/dpkg.log*`

By default it **does not** include rotated `*.gz` logs (to keep the bundle small), but you can opt-in.

## Why this helps

For outages caused by reboots or host maintenance, the most important evidence is often in:

- `journalctl -b -1` (the boot *before* the reboot)
- `systemd-logind` messages (power key, shutdown requests)
- the service unit logs for nginx/php-fpm/redis/mariadb during the outage window

This bundle collects those automatically so you don’t have to “hunt” across many files.

## How to use

1) Copy `collect-incident.sh` to your server (or keep it in a tools directory).

2) Make it executable:

`chmod +x collect-incident.sh`

3) Run it with `sudo` (recommended) so it can read logs:

Note: don’t run it via `sh ./collect-incident.sh ...` (that uses `dash` on Ubuntu and will fail). Use `./collect-incident.sh ...` or `bash ./collect-incident.sh ...`.

### Option A: center time (recommended)

Provide a “center” time when you noticed the outage, and a window before/after:

`sudo ./collect-incident.sh --center "2026-01-12 09:33:00 UTC" --before 30m --after 30m`

This computes `--since` and `--until` automatically using UTC.

`--before` / `--after` accept compact durations like `30m`, `2h`, `7d` (or strings like `30 minutes`).

### Option B: explicit window

`sudo ./collect-incident.sh --since "2026-01-12 09:00:00 UTC" --until "2026-01-12 10:00:00 UTC"`

### Choose output directory (recommended)

`sudo ./collect-incident.sh --center "2026-01-12 09:33:00 UTC" --out-dir /home/forge/incidents`

The script will create the directory if needed and write `incident-<timestamp>.tgz` inside it.

### Include rotated `.gz` logs (bigger bundle)

`sudo ./collect-incident.sh --center "2026-01-12 09:33:00 UTC" --before 2h --after 2h --include-gz`

## Output

The script prints the path to the resulting `.tgz` (default: `/tmp/incident-<timestamp>.tgz`).

You can choose a custom output path:

`sudo ./collect-incident.sh --center "2026-01-12 09:33:00 UTC" --out /tmp/hollow-lake-incident.tgz`

Or choose an output directory and let the script auto-name the tarball:

`sudo ./collect-incident.sh --center "2026-01-12 09:33:00 UTC" --out-dir .`

## Notes / cautions

- The bundle can contain sensitive data (IP addresses, usernames, request paths). Treat it like production data.
- If `/var/log/mysql/error.log` isn’t where your MariaDB errors are, that’s okay: journald unit logs (`journalctl -u mariadb`) are still captured.
- If your PHP-FPM unit is not `php8.3-fpm` (e.g. `php8.2-fpm`), update the `units=(...)` list in `collect-incident.sh`.
