# Changelog

All notable changes to this project are documented here.

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