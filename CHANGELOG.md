# Changelog

All notable changes to this project are documented here.

## [1.3.0] - 2026-06-23

### Added
- `find_running_kernel_pkg()` for reliable running-kernel package detection
- `purge_kernel_related()` for headers/modules package cleanup
- `KERNEL_KEEP` config option (default: 2)
- Config ownership check for `/etc/update-clean.conf` (must be root-owned)
- DNS resolution fallback (`getent`) in connectivity checks

### Changed
- Kernel removal skips when running kernel package cannot be matched
- Dry-run skips `apt-get update` simulation; documents network use for listings
- Connectivity check pings archive host before generic 8.8.8.8 fallback

### Fixed
- Running kernel no longer at risk when package name differs from `linux-image-$(uname -r)`
- Header/modules purge handles `linux-headers-*`, `linux-modules-*` naming variants

## [1.2.1] - 2026-06-23

### Removed
- Temporary `push.sh` helper script from the repository

### Changed
- `.gitignore` now excludes local helper scripts and backup files

## [1.2.0] - 2026-06-23

### Added
- Bash 4+ version check and `umask 022`
- `get_avail_kb()` for robust disk-space parsing
- `EXIT_CODE` / `_record_failure()` tracking with `FAILURES` in last-run record
- `wget` fallback in connectivity checks
- `check_systemd_resolved()` guard before `systemctl` calls
- ERR trap for unhandled errors

### Changed
- `apt_run()` uses `apt-get` with `--force-confdef` / `--force-confold`
- `remove_old_kernels()` excludes running kernel and meta packages; keeps 2 newest
- Last-run `STATUS` reflects success or failure instead of always `success`
- Logging uses `printf` instead of `echo -e`
- Script exits non-zero when failures were recorded

### Fixed
- Cleanup trap releases flock and preserves exit code reliably

## [1.1.1] - 2026-06-23

### Changed
- Renamed repository to `debian_ubuntu_update_clean` (consolidated from separate Debian/Ubuntu repos)

## [1.1.0] - 2026-06-23

### Added
- `apt_run()` helper for consistent dry-run and noninteractive apt behavior
- `remove_old_kernels()` using versioned `linux-image-[0-9]*` packages only
- `hold_critical_packages()` with installed kernel package detection
- TTY-aware color output
- `LOG_RETENTION` validation at startup
- Dry-run preview of upgradable and autoremovable packages
- Optional systemd service and timer unit files
- GitHub Actions ShellCheck workflow

### Changed
- Log rotation uses portable `ls -1t` instead of `find -printf`
- Lock file moved to `/run/update-clean.lock` with proper flock release on exit
- Connectivity check prefers `curl` over `/dev/tcp`
- `SCRIPT_VERSION` reads from script directory; `set -o errtrace` enabled

### Fixed
- Kernel removal no longer targets meta-packages like `linux-image-generic`
- Trap handler releases file descriptor and preserves exit code

## [1.0.0] - 2026-06-22

### Added
- Initial Debian/Ubuntu release derived from the Kali `update_clean` project
- Distro detection for Debian and Ubuntu (with generic fallback)
- Connectivity checks against distro-appropriate archive hosts
- `--dry-run`, `--no-kernel`, `--check`, `--last`, and `--version` options
- Logging to `/var/log/update-clean/`
- Last-run record at `/var/lib/update-clean/last-run`

### Removed
- Kali archive keyring download and verification
- All Kali-specific naming, paths, and messaging

### Fixed
- `--no-kernel` flag is now honored
- Stray `done <<< "$KERNELS"` artifacts from the prior script revision