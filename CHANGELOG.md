# Changelog

All notable changes to this project are documented here.

## [1.4.7] - 2026-06-22

### Added
- Configurable `LOG_DIR`, `LOCKFILE`, and `LAST_RUN_DIR` (env overrides)
- `KERNEL_KEEP_MAX` (default: 10) with validation on CLI and config

### Changed
- Kernel removal uses safe array slices (`"${to_remove[@]:0:delcount}"`)
- ERR trap registered before EXIT trap; `err_trap` exits explicitly to run `cleanup`
- Meta kernel filter matches `-generic-hwe` and similar variants
- `detect_distro()` defaults `ARCHIVE_HOST` to `deb.debian.org`
- `has_cmd` used consistently instead of raw `command -v`
- `cleanup()` calls `sync` to flush log pipeline output

### Fixed
- `KERNEL_KEEP` comparisons use explicit defaults and bounds checks
- Kernel `delcount` validated before array access

## [1.4.6] - 2026-06-22

### Added
- `require_cmds()` early check for apt-get, dpkg, awk, sed, grep, tar, mktemp, flock
- `get_used_kb_for_paths()` and `df_supports_output()` for portable disk usage
- `err_trap()` with failing command and call stack on ERR

### Changed
- APT lock wait uses `is_apt_locked()` unconditionally (fuser, lsof, or fallback)
- `get_avail_kb()` falls back to `df -k` when `--output` is unavailable

### Fixed
- APT lock check skipped when `fuser` missing but `lsof` was available

## [1.4.5] - 2026-06-22

### Added
- `--offline` flag to skip internet connectivity checks
- `apt_get_update_with_retries()` with exponential backoff (3 attempts)
- `last-run.json` written when `jq` is available
- Kernel removal skipped when `/boot` has less than 10 MB free

### Changed
- `dump_debug_state()` uses safe defaults for unset variables
- ERR trap reports captured exit code (`rc=$?`)
- Normalized `PATH` to system directories first
- `readonly` on `SCRIPT_NAME` and `SCRIPT_DIR`
- `apt_run()` documents pipefail exit-code preservation

## [1.4.4] - 2026-06-22

### Added
- Header documentation for requirements, config paths, logs, and exit codes
- `dump_debug_state()` when `--debug` is enabled
- Comment documenting `is_apt_locked` return semantics and `~c` purge selection

### Changed
- Log files created atomically via `mktemp` in `LOG_DIR` (timestamp + random suffix)
- Broader kernel package name regex (dots, dashes, `+` in version strings)
- `/etc` backup excludes `/etc/ssl/private` and uses `--one-file-system`
- ShellCheck CI fails on `error` severity

## [1.4.3] - 2026-06-22

### Added
- `validate_config_values()` re-run after CLI parsing
- `--reboot-if-required` flag and `REBOOT_IF_REQUIRED` config option
- `create_etc_backup()` with restrictive umask and `chmod 600` archives
- Kernel removal preview list before purging

### Changed
- `cleanup()` clears traps first to prevent EXIT trap recursion
- `is_apt_locked()` checks all common apt/dpkg lock files (fuser/lsof fallback)
- `list_installed_kernel_images()` includes `linux-image-unsigned` variants
- Log directory validated for writability and minimum free space before `exec`
- `--keep-kernels` rejects non-numeric values at parse time

### Fixed
- `KERNEL_KEEP` from `--keep-kernels` could bypass post-config validation

## [1.4.2] - 2026-06-22

### Added
- `has_cmd()`, `is_apt_locked()`, `format_cmd_args()`, and `list_installed_kernel_images()` helpers
- `--debug` flag for shell trace (`set -x`) troubleshooting
- `--last` / `--status` now includes tail of the last log file
- Sudo-aware config loading (`/etc`, root, and `SUDO_USER` home configs)

### Changed
- `apt_run()` and tee targets default `APT_LOG` to `/dev/null` when unset
- `find_running_kernel_pkg()` prefers `/boot/vmlinuz-*` package ownership
- Kernel listing filters to `install ok installed` packages only
- Log rotation uses `find` + mtime sort (falls back to `ls` on non-GNU find)
- `fuser` and `ping` guarded when tools are missing
- `DEBIAN_FRONTEND=noninteractive` exported before any apt operations
- Safer partial apt list cleanup with directory check

## [1.4.1] - 2026-06-22

### Added
- `check_partition_space()`, `warn_low_partition_space()`, and `report_partition_space()` helpers
- `calc_disk_freed_mb()` for consistent disk-freed calculations
- `log_to_syslog()` for optional syslog integration via `logger`
- `send_completion_notification()` with desktop notify and optional `ADMIN_EMAIL` mail
- Configurable `CRITICAL_PACKAGES` array for `hold_critical_packages()`
- `BACKUP_MODE` option to tar `/etc` before purging residual configs
- Kernel recovery hint when old kernels are removed

### Changed
- `apt_run()` uses explicit `local -a` arrays for arguments
- ERR trap includes function name for better diagnostics
- Script directory validated for readability at startup

## [1.4.0] - 2026-06-22

### Added
- `--keep-kernels N` CLI flag to override `KERNEL_KEEP` at runtime
- `show_dry_run_preview()` with read-only `apt list --upgradable` and autoremove simulation
- Kali Linux in supported distro list with `archive.kali.org` connectivity checks
- `flatpak_update()` / `flatpak_uninstall_unused()` with `--assumeyes` fallback
- Snap cleanup via `snap list --all --format=json` when `jq` is available

### Changed
- `apt_run()` dry-run logs planned commands only (no `apt-get -s` simulation)
- `purge_kernel_related()` also searches dpkg for packages sharing the kernel version string
- `purge_kernel_related()` handles `modules-unsigned` suffix variant
- Log rotation uses portable shell loop instead of `xargs -r`

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