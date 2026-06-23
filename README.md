# debian_ubuntu_update_clean

One clean update and cleanup script for **Debian** and **Ubuntu** (and other apt-based derivatives).

**Version:** See the `VERSION` file (or run `./update-clean.sh --version`)

## Main Script

**`update-clean.sh`** — Complete system update and cleanup.

### What it does

**Update:**
- Fixes interrupted installs and broken packages
- `apt update`
- Package cache check (`apt-get check`)
- `apt upgrade`
- `apt full-upgrade`

**Cleanup:**
- `apt --purge autoremove`
- `apt autoclean` + `apt clean`
- Purge residual config files (`apt purge '~c'`)
- Remove old kernels (keeps current + previous for safety)
- Remove old snap revisions
- Update + remove unused Flatpaks
- Firmware updates (`fwupdmgr`)
- Vacuum journal logs (last 30 days)
- Clean partial apt lists
- Update locate database (if present)
- Rebuild man database
- Update GRUB after kernel changes

**Other:**
- Detects Debian vs Ubuntu for connectivity checks
- Tracks disk usage before/after (across `/`, `/var`, `/boot`)
- Keeps only the last **3** log files
- Color output + clear logging
- Records last run details in `/var/lib/update-clean/last-run`
- Safety checks (root, internet, disk space, APT lock)

### Usage

```bash
sudo ./update-clean.sh
```

Options:

```bash
sudo ./update-clean.sh --dry-run
sudo ./update-clean.sh --no-kernel
sudo ./update-clean.sh --keep-kernels 3
sudo ./update-clean.sh --reboot-if-required
sudo ./update-clean.sh --offline
sudo ./update-clean.sh --check
sudo ./update-clean.sh --last
sudo ./update-clean.sh --debug
```

**Dry-run:** skips `apt-get update` and logs planned `apt-get` commands instead of simulating them. It may still use the network for read-only listings (`apt list --upgradable`, autoremove preview).

Run periodically (recommended weekly).

### Configuration

Optional config files (sourced in order if present):

- `/etc/update-clean.conf` (must be root-owned)
- When run as root: `/root/.config/update-clean.conf`, `/root/.update-clean.conf`
- When run via `sudo`: also the invoking user's `~/.config/update-clean.conf` and `~/.update-clean.conf`
- When run as a normal user: `$HOME/.config/update-clean.conf`, `$HOME/.update-clean.conf`

Example:

```bash
LOG_RETENTION=5
KERNEL_KEEP=2
BACKUP_MODE=true
ADMIN_EMAIL=admin@example.com
CRITICAL_PACKAGES=(base-files base-passwd bash coreutils util-linux)
```

**Config security:** `/etc/update-clean.conf` must be owned by root (non-root-owned system config is skipped). User-level configs are sourced without ownership checks — only use configs you trust.

**KERNEL_KEEP:** number of installed kernel packages to retain *besides* the running kernel (default: 2; `0` keeps only the running kernel). Override with `--keep-kernels N` or `KERNEL_KEEP=N` in config.

**BACKUP_MODE:** when `true`, creates a `/var/backups/etc-before-cleanup-*.tar.gz` archive before purging residual config packages (excludes `/etc/ssl/private`, stays on local filesystem).

### Logging & Records

- Detailed logs: `/var/log/update-clean/`
- Only the most recent 3 logs are kept automatically
- Last run record: `/var/lib/update-clean/last-run` (includes `STATUS`, `FAILURES`, and `LOG_FILE`)
- Machine-readable summary: `/var/lib/update-clean/last-run.json` (when `jq` is installed)
- `sudo ./update-clean.sh --last` shows the record plus the last 80 lines of the log

### Safety

- Must run as root
- Requires at least 2 GB free disk space
- Keeps current + one previous kernel as fallback
- Non-critical steps won't stop the script

### Scheduling

**Cron example (weekly):**

```bash
0 4 * * 0 /path/to/update-clean.sh
```

Or use the included systemd timer:

```bash
sudo cp systemd/update-clean.service systemd/update-clean.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now update-clean.timer
```

### Supported systems

- Debian (stable, testing, unstable)
- Ubuntu (LTS and interim releases)
- Kali Linux and other apt-based derivatives (Mint, Pop!_OS, etc.) — may work but are not all explicitly tested

### Versioning

- Version is in the `VERSION` file
- Script supports `--version`
- See `CHANGELOG.md` for history

### Repository layout

```
update-clean.sh          # main script
VERSION                  # release version
CHANGELOG.md             # change history
README.md                # documentation
update-clean.conf.example
.github/workflows/       # CI (ShellCheck)
systemd/                 # optional weekly timer
```