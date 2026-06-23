# update-clean

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
sudo ./update-clean.sh --check
sudo ./update-clean.sh --last
```

Run periodically (recommended weekly).

### Configuration

Optional config files (sourced in order if present):

- `/etc/update-clean.conf`
- `~/.config/update-clean.conf`
- `~/.update-clean.conf`

Example:

```bash
LOG_RETENTION=5
```

### Logging & Records

- Detailed logs: `/var/log/update-clean/`
- Only the most recent 3 logs are kept automatically
- Last run record: `/var/lib/update-clean/last-run`

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

Or use a systemd timer for more control.

### Supported systems

- Debian (stable, testing, unstable)
- Ubuntu (LTS and interim releases)
- Other apt-based derivatives may work but are not explicitly tested

### Versioning

- Version is in the `VERSION` file
- Script supports `--version`
- See `CHANGELOG.md` for history