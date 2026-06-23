# Changelog

All notable changes to this project are documented here.

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