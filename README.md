# debian_ubuntu_update_clean

One **update and cleanup** script for **Debian** and **Ubuntu** (and other apt-based derivatives).

**Version:** `VERSION` file, or `./update-clean.sh --version`. See `CHANGELOG.md` for history.

For Ubuntu AI / GPU compute blades, see [`ai_blade_ubuntu_update_clean`](https://github.com/wbharris/ai_blade_ubuntu_update_clean).

## What it does

**Update:** fix interrupted installs, then `apt-get update` / `upgrade` / `full-upgrade` and `apt-get check`. Mutating work uses **`apt-get`**, not `apt(8)`.

**Cleanup:** purge autoremove, autoclean, residual configs, old kernels (running + the `KERNEL_KEEP` newest extras), Snap/Flatpak when present, `fwupd` when installed, journal vacuum, partial apt lists, man/locate DBs, GRUB after kernel changes.

**Also:** Debian vs Ubuntu archive host for connectivity, disk change on `/` `/var` `/boot`, log rotation, last-run record, root / disk / APT-lock checks.

## Usage

```bash
sudo ./update-clean.sh
```

```bash
sudo ./update-clean.sh --dry-run
sudo ./update-clean.sh --check
sudo ./update-clean.sh --last
sudo ./update-clean.sh --no-kernel
sudo ./update-clean.sh --reboot-if-required
sudo ./update-clean.sh --offline
```

`--dry-run` skips `apt-get update` and logs planned apt commands. It may still use the network for read-only listings.

Kernel keep count, log retention, and similar knobs live in the config file, not as extra flags. See `update-clean.conf.example`.

Requires **Bash 4+** (`#!/usr/bin/env bash`). Do not run under `/bin/sh`.

Run weekly. Prefer a maintenance window if you use `--reboot-if-required`.

## Configuration

Sourced in order if present:

- `/etc/update-clean.conf` (must be root-owned)
- As root: `/root/.config/update-clean.conf`, `/root/.update-clean.conf`
- Via `sudo`: also the invoking user's `~/.config/update-clean.conf` and `~/.update-clean.conf`
- As a normal user: `$HOME/.config/update-clean.conf`, `$HOME/.update-clean.conf`

```bash
KERNEL_KEEP=2
BACKUP_MODE=false
REBOOT_IF_REQUIRED=false
```

`/etc/update-clean.conf` must be owned by root. User-level configs are sourced without ownership checks — only use files you trust.

Config loads after CLI parsing; explicit flags win.

| Variable | Default | Meaning |
|----------|---------|---------|
| `KERNEL_KEEP` | `2` | Newest extra kernels besides the running one (oldest extras are purged) |
| `BACKUP_MODE` | `false` | Tar `/etc` before purging residual configs (excludes `/etc/ssl/private`) |
| `REBOOT_IF_REQUIRED` | `false` | Auto-reboot when `/var/run/reboot-required` is set |
| `LOG_RETENTION` | `3` | Log files to keep under `/var/log/update-clean` |

Further keys (`LOG_DIR`, `LOCKFILE`, `ADMIN_EMAIL`, `CRITICAL_PACKAGES`, …) are in `update-clean.conf.example`.

## Logging

- Logs: `/var/log/update-clean/` (retention via `LOG_RETENTION`)
- Last run: `/var/lib/update-clean/last-run`
- JSON (when `jq` is installed): `/var/lib/update-clean/last-run.json`
- `sudo ./update-clean.sh --last` prints the record and the last 80 log lines
- Disk-freed figure is `df` on `/`, `/var`, `/boot` only

## Safety

- Root required except `--check` / `--version` / `--last` / `--help`
- Needs at least 2 GB free on `/`, `/var`, and `/boot` when those paths exist
- Keeps the running kernel plus the `KERNEL_KEEP` newest other images
- Non-critical steps do not abort the run
- The bundled timer does **not** pass `--reboot-if-required`

## Scheduling

Weekly, Sunday 04:00:

```bash
0 4 * * 0 /usr/local/sbin/update-clean.sh
```

Or the bundled timer:

```bash
sudo install -m 755 update-clean.sh /usr/local/sbin/update-clean.sh
sudo cp systemd/update-clean.service systemd/update-clean.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now update-clean.timer
```

## Supported systems

Debian (stable, testing, unstable), Ubuntu (LTS and interim), and other apt-based derivatives (Kali, Mint, Pop!_OS, …). Not all derivatives are tested.

| Repo | Focus |
|------|--------|
| `update_clean` | Kali |
| **`debian_ubuntu_update_clean`** | General Debian/Ubuntu |
| `ai_blade_ubuntu_update_clean` | Ubuntu AI / GPU blades |

```
update-clean.sh
VERSION / CHANGELOG.md / README.md / LICENSE
update-clean.conf.example
systemd/                 # optional weekly timer
.github/workflows/       # ShellCheck
```

## License

Copyright (C) 2026 wbharris

[GNU General Public License v3.0 or later](LICENSE) (GPL-3.0-or-later).
