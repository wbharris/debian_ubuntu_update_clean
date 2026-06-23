#!/usr/bin/env bash
# Debian / Ubuntu - Complete Update & Cleanup Script
# Full system update + thorough cleanup for Debian-based systems
# Usage: sudo ./update-clean.sh [--dry-run] [--no-kernel] [--help] [--version]
# Recommended: run weekly
# Configurable via env or /etc/update-clean.conf

set -euo pipefail
set -o errtrace

# Require Bash 4+ (mapfile, array sorting)
if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    printf '%s\n' "This script requires Bash 4+. Found: ${BASH_VERSION:-unknown}" >&2
    exit 1
fi

umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# ────────────────────────────────────────────────────────────────
# Defaults & Config
# ────────────────────────────────────────────────────────────────
DRY_RUN=false
SKIP_KERNEL=false
LOG_RETENTION=${LOG_RETENTION:-3}
SCRIPT_NAME="update-clean"
SCRIPT_VERSION=$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null || echo "unknown")
EXIT_CODE=0
KERNELS_REMOVED=false

# Load config file if present
for conf in /etc/update-clean.conf "$HOME/.config/update-clean.conf" "$HOME/.update-clean.conf"; do
    [ -f "$conf" ] && source "$conf"
done

# ────────────────────────────────────────────────────────────────
# Colors (TTY-aware)
# ────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
fi

log()     { printf '%b\n' "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }
info()    { printf '%b\n' "${BLUE}[INFO]${NC} $1"; }
success() { printf '%b\n' "${GREEN}[SUCCESS]${NC} $1"; }
warn()    { printf '%b\n' "${YELLOW}[WARNING]${NC} $1"; }
error()   { printf '%b\n' "${RED}[ERROR]${NC} $1"; }

_record_failure() { EXIT_CODE=$((EXIT_CODE + 1)); }

if ! [[ "$LOG_RETENTION" =~ ^[0-9]+$ ]] || [ "$LOG_RETENTION" -lt 0 ]; then
    warn "Invalid LOG_RETENTION='$LOG_RETENTION', using default 3"
    LOG_RETENTION=3
fi

# ────────────────────────────────────────────────────────────────
# Helpers
# ────────────────────────────────────────────────────────────────
get_avail_kb() {
    local part="$1"
    local val
    val=$(df --output=avail "$part" 2>/dev/null | awk 'NR==2 {print $1+0}')
    printf '%d' "${val:-0}"
}

detect_distro() {
    if [ -f /etc/os-release ]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        DISTRO_ID="${ID:-unknown}"
        DISTRO_NAME="${PRETTY_NAME:-$DISTRO_ID}"
        DISTRO_VERSION="${VERSION_ID:-}"
    else
        DISTRO_ID="unknown"
        DISTRO_NAME="Unknown"
        DISTRO_VERSION=""
    fi

    case "$DISTRO_ID" in
        debian)
            ARCHIVE_HOST="deb.debian.org"
            ;;
        ubuntu)
            ARCHIVE_HOST="archive.ubuntu.com"
            ;;
        *)
            ARCHIVE_HOST=""
            ;;
    esac
}

check_debian_based() {
    if ! command -v apt >/dev/null 2>&1; then
        error "This script requires apt and is intended for Debian-based systems."
        exit 1
    fi

    case "$DISTRO_ID" in
        debian|ubuntu|linuxmint|pop|elementary|zorin|kubuntu|xubuntu|lubuntu|mint)
            return 0
            ;;
        *)
            warn "Unsupported or unknown distro '$DISTRO_ID'. Proceeding anyway (apt-based assumed)."
            ;;
    esac
}

check_connectivity() {
    local host="${ARCHIVE_HOST:-1.1.1.1}"

    if command -v curl >/dev/null 2>&1; then
        if curl -sSf --connect-timeout 5 "https://${host}/" >/dev/null 2>&1; then
            return 0
        fi
    elif command -v wget >/dev/null 2>&1; then
        if wget -q --timeout=5 --spider "https://${host}/" >/dev/null 2>&1; then
            return 0
        fi
    fi

    if ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
        warn "Cannot reach https://${host}. Ping to 8.8.8.8 succeeded; proceeding."
        return 0
    fi

    return 1
}

apt_run() {
    local args=("$@")

    if $DRY_RUN; then
        info "DRY-RUN: apt-get ${args[*]}"
        apt-get -s "${args[@]}" 2>&1 | tee -a "$APT_LOG" || true
        return 0
    fi

    local cmd=(
        apt-get
        -o Dpkg::Options::="--force-confdef"
        -o Dpkg::Options::="--force-confold"
        -y
    )
    cmd+=("${args[@]}")

    if ! DEBIAN_FRONTEND=noninteractive "${cmd[@]}" 2>&1 | tee -a "$APT_LOG"; then
        _record_failure
        return 1
    fi
}

remove_old_kernels() {
    local -a kernels=()
    local -a to_remove=()
    local keep=2
    local running_pkg running_ver pkg i delcount

    running_ver=$(uname -r 2>/dev/null || true)
    running_pkg=$(dpkg-query -W -f='${Package}\n' "linux-image-${running_ver}" 2>/dev/null || true)

    mapfile -t kernels < <(
        dpkg-query -W -f='${Package}\n' 'linux-image-[0-9]*' 2>/dev/null \
            | grep -Ev '(-meta|-rt|linux-image-amd64|linux-image-generic)$' \
            | sort -V
    )

    if [ "${#kernels[@]}" -eq 0 ]; then
        info "No linux-image packages found."
        return 0
    fi

    for pkg in "${kernels[@]}"; do
        if [ -n "$running_pkg" ] && [ "$pkg" = "$running_pkg" ]; then
            continue
        fi
        to_remove+=("$pkg")
    done

    if [ "${#to_remove[@]}" -le "$keep" ]; then
        info "No old kernels to remove."
        return 0
    fi

    delcount=$(( ${#to_remove[@]} - keep ))
    KERNELS_REMOVED=true

    for ((i = 0; i < delcount; i++)); do
        pkg="${to_remove[i]}"
        if $DRY_RUN; then
            info "DRY-RUN: Would purge old kernel: $pkg"
            continue
        fi
        info "Purging old kernel: $pkg"
        apt_run purge "$pkg" || warn "Failed to purge $pkg"
        apt_run purge "${pkg/linux-image/linux-headers}" || true
        apt_run purge "${pkg/linux-image/linux-modules}" || true
    done
}

show_dry_run_preview() {
    info "DRY-RUN preview: upgradable packages"
    apt list --upgradable 2>/dev/null | sed -n '1,40p' || true
    info "DRY-RUN preview: autoremove simulation"
    apt-get -s autoremove 2>&1 | sed -n '1,40p' | tee -a "$APT_LOG" || true
}

hold_critical_packages() {
    local curpkg
    curpkg=$(dpkg-query -W -f='${Package}\n' "linux-image-$(uname -r)" 2>/dev/null || true)
    if [ -n "$curpkg" ]; then
        apt-mark hold base-files base-passwd bash coreutils util-linux "$curpkg" 2>/dev/null || true
    else
        apt-mark hold base-files base-passwd bash coreutils util-linux 2>/dev/null || true
    fi
}

safe_run() {
    local desc="$1"
    shift
    info "$desc"
    if ! "$@"; then
        warn "$desc failed — continuing"
        _record_failure
    fi
}

check_systemd_resolved() {
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        return 0
    fi
    return 1
}

# ────────────────────────────────────────────────────────────────
# CLI Parsing (do this very early, before logging or heavy work)
# ────────────────────────────────────────────────────────────────
usage() {
    cat << USAGE
Usage: sudo $0 [options]

Options:
  --dry-run         Simulate actions without making changes
  --no-kernel       Skip old kernel removal
  --last, --status  Show information from the last run
  --check, --doctor Run pre-flight checks only (no updates)
  --help, -h        Show this help
  --version, -v     Show version information

Environment / Config:
  LOG_RETENTION     Number of logs to keep (default: 3)
USAGE
}

show_version() {
    detect_distro
    printf '%s %s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
    printf 'Distro: %s\n' "$DISTRO_NAME"

    if [ -d "$SCRIPT_DIR/.git" ]; then
        local commit
        commit=$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
        printf 'Commit: %s\n' "$commit"
    fi

    local last_file="/var/lib/update-clean/last-run"
    if [ -f "$last_file" ]; then
        printf '\nLast run:\n'
        sed 's/^/  /' "$last_file"
    fi
}

show_last_run() {
    local last_file="/var/lib/update-clean/last-run"
    if [ -f "$last_file" ]; then
        printf '%s\n' "Last run information:"
        cat "$last_file"
    else
        printf '%s\n' "No last-run record found."
    fi
}

run_preflight_checks() {
    local avail_kb
    detect_distro
    check_debian_based

    printf '%s\n' "=== Pre-flight Checks ==="
    printf 'Distro: %s\n' "$DISTRO_NAME"

    printf 'Running as root: '
    if [ "$EUID" -eq 0 ]; then printf '%s\n' "OK"; else printf '%s\n' "FAIL (must be root)"; fi

    printf 'Internet'
    if [ -n "$ARCHIVE_HOST" ]; then
        printf ' (%s)' "$ARCHIVE_HOST"
    fi
    printf ': '
    if check_connectivity; then
        printf '%s\n' "OK"
    else
        printf '%s\n' "FAIL"
    fi

    for part in / /var /boot; do
        if [ -d "$part" ]; then
            avail_kb=$(get_avail_kb "$part")
            printf 'Disk space on %s: ' "$part"
            if [ "$avail_kb" -ge 2097152 ]; then
                printf 'OK (%s MB free)\n' "$((avail_kb / 1024))"
            else
                printf 'LOW (%s MB free)\n' "$((avail_kb / 1024))"
            fi
        fi
    done

    printf 'APT lock free: '
    if ! fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
        printf '%s\n' "OK"
    else
        printf '%s\n' "LOCKED"
    fi

    printf 'systemd-resolved active: '
    if check_systemd_resolved; then
        printf '%s\n' "OK"
    else
        printf '%s\n' "INACTIVE or systemctl not available"
    fi

    printf 'Required tools: '
    local missing=""
    for tool in apt dpkg; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing="$missing $tool"
        fi
    done
    if [ -z "$missing" ]; then
        printf '%s\n' "OK"
    else
        printf 'MISSING:%s\n' "$missing"
    fi

    printf '%s\n' "=== Checks complete ==="
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --no-kernel)
            SKIP_KERNEL=true
            shift
            ;;
        --last|--status)
            show_last_run
            exit 0
            ;;
        --check|--doctor)
            run_preflight_checks
            exit 0
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        --version|-v)
            show_version
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

detect_distro
check_debian_based

if $DRY_RUN; then
    info "DRY RUN MODE ENABLED - No changes will be made"
fi

# ────────────────────────────────────────────────────────────────
# Logging (with color stripping for file)
# ────────────────────────────────────────────────────────────────
LOG_DIR="/var/log/update-clean"
LOG_FILE="$LOG_DIR/update-clean-$(date +%Y%m%d-%H%M%S).log"
APT_LOG="$LOG_FILE.apt-warnings"

mkdir -p "$LOG_DIR"
chmod 755 "$LOG_DIR"

exec > >(tee >(sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE")) 2>&1

log "Running $SCRIPT_NAME version: $SCRIPT_VERSION on $DISTRO_NAME"

log "Cleaning up old logs (keeping last $LOG_RETENTION)..."
if [ "${LOG_RETENTION:-0}" -gt 0 ]; then
    ls -1t "$LOG_DIR"/update-clean-*.log 2>/dev/null | tail -n +"$((LOG_RETENTION + 1))" | xargs -r rm -f --
fi

SCRIPT_START=$(date +%s)

# ────────────────────────────────────────────────────────────────
# Environment
# ────────────────────────────────────────────────────────────────
export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none

# ────────────────────────────────────────────────────────────────
# Pre-flight checks
# ────────────────────────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
    error "This script must be run as root (use sudo)."
    exit 1
fi

info "Checking internet connectivity..."
if ! check_connectivity; then
    error "No internet connection detected."
    exit 1
fi

for partition in "/" "/var" "/boot"; do
    if [ -d "$partition" ]; then
        avail_kb=$(get_avail_kb "$partition")
        if [ "$avail_kb" -lt 2097152 ]; then
            error "Less than 2 GB free on $partition"
            exit 1
        fi
    fi
done

if [ -d /boot ]; then
    boot_kb=$(get_avail_kb /boot)
    if [ "$boot_kb" -lt 51200 ]; then
        warn "Very low space on /boot (< 50 MB). Kernel updates may fail."
    fi
fi

if fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
    warn "APT is locked by another process. Waiting up to 60s..."
    for _ in {1..12}; do
        if ! fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
            break
        fi
        sleep 5
    done
    if fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
        error "APT still locked after waiting. Please resolve and try again."
        exit 1
    fi
fi

if ! check_systemd_resolved; then
    warn "systemd-resolved is not active. DNS resolution may be affected."
fi

BEFORE=$(df / /var /boot --output=used 2>/dev/null | awk 'NR>1 {s+=$1} END {print s+0}')

# ────────────────────────────────────────────────────────────────
# File lock + trap
# ────────────────────────────────────────────────────────────────
LOCKFILE="/run/update-clean.lock"
exec 200>"$LOCKFILE" || { error "Cannot open lockfile $LOCKFILE"; exit 1; }
if ! flock -n 200; then
    error "Another instance of $SCRIPT_NAME is already running."
    exit 1
fi

cleanup() {
    local rc=$?
    flock -u 200 2>/dev/null || true
    exec 200>&- 2>/dev/null || true
    rm -f "$LOCKFILE" 2>/dev/null || true
    if [ "$rc" -ne 0 ]; then
        error "Script exited with status $rc"
    fi
    exit "$rc"
}

trap cleanup INT TERM EXIT
trap '_record_failure; error "Unhandled error on line $LINENO"' ERR

# ────────────────────────────────────────────────────────────────
# Core update
# ────────────────────────────────────────────────────────────────
info "Configuring any interrupted package installations..."
if ! dpkg --configure -a; then
    warn "dpkg --configure -a had issues"
    _record_failure
fi

info "Fixing broken dependencies..."
apt_run install -f || warn "apt install -f had issues"

info "Updating package lists..."
if $DRY_RUN; then
    info "DRY-RUN: apt-get update"
    apt-get -s update 2>&1 | tee -a "$APT_LOG" || true
else
    if ! apt-get update 2>&1 | tee -a "$APT_LOG"; then
        warn "apt-get update had issues"
        _record_failure
    fi
fi

info "Checking package cache integrity (apt-get check)..."
if ! apt-get check; then
    warn "Package cache check reported issues"
    _record_failure
fi

info "Upgrading packages..."
apt_run upgrade || warn "apt upgrade had issues"

info "Listing upgradable packages after initial upgrade:"
apt list --upgradable 2>/dev/null || true

if $DRY_RUN; then
    show_dry_run_preview
fi

info "Performing full system upgrade..."
apt_run full-upgrade || warn "full-upgrade had issues"

# ────────────────────────────────────────────────────────────────
# Complete cleanup
# ────────────────────────────────────────────────────────────────
info "Holding critical packages to prevent accidental removal..."
hold_critical_packages

if $DRY_RUN; then
    info "DRY-RUN: Would run autoremove, clean, purge configs, kernel removal, etc."
    apt-get -s --purge autoremove 2>&1 | sed -n '1,40p' | tee -a "$APT_LOG" || true
else
    info "Removing unnecessary packages (autoremove --purge)..."
    apt_run --purge autoremove || warn "autoremove had issues"

    info "Cleaning package cache (autoclean + clean)..."
    apt-get autoclean 2>&1 | tee -a "$APT_LOG" || _record_failure
    apt-get clean 2>&1 | tee -a "$APT_LOG" || _record_failure

    info "Purging residual configuration files..."
    apt_run purge '~c' || warn "Purging residual configs had issues"
fi

if $SKIP_KERNEL; then
    info "Skipping old kernel removal (--no-kernel)."
else
    info "Removing old kernels (keeping current + previous)..."
    remove_old_kernels
fi

if $KERNELS_REMOVED && command -v update-grub >/dev/null 2>&1 && ! $DRY_RUN; then
    safe_run "Updating GRUB bootloader" update-grub
fi

if command -v flatpak >/dev/null 2>&1; then
    if $DRY_RUN; then
        info "DRY-RUN: Would update Flatpaks and remove unused"
    else
        safe_run "Updating Flatpaks" flatpak update -y
        safe_run "Removing unused Flatpaks" flatpak uninstall --unused -y
    fi
fi

if command -v snap >/dev/null 2>&1; then
    if $DRY_RUN; then
        info "DRY-RUN: Would refresh Snaps and remove old revisions"
    else
        safe_run "Refreshing Snaps" snap refresh
        snap list --all 2>/dev/null | awk '/disabled/ {print $1, $3}' | while read -r snapname revision; do
            [ -z "$snapname" ] && continue
            snap remove "$snapname" --revision="$revision" 2>/dev/null || true
        done
    fi
fi

if command -v fwupdmgr >/dev/null 2>&1; then
    if $DRY_RUN; then
        info "DRY-RUN: Would update firmware"
    else
        safe_run "Refreshing firmware metadata" fwupdmgr refresh --force
        safe_run "Applying firmware updates" fwupdmgr update -y || true
    fi
fi

if command -v journalctl >/dev/null 2>&1; then
    if $DRY_RUN; then
        info "DRY-RUN: Would vacuum journal logs"
    else
        safe_run "Vacuuming journal logs (last 30 days)" journalctl --vacuum-time=30d
    fi
fi

if ! $DRY_RUN; then
    info "Cleaning partial package lists..."
    rm -rf /var/lib/apt/lists/partial/*

    if command -v updatedb >/dev/null 2>&1; then
        safe_run "Updating locate database" updatedb
    fi

    if command -v mandb >/dev/null 2>&1; then
        safe_run "Rebuilding man page database" mandb -q
    fi
else
    info "DRY-RUN: Would perform final cleanups"
fi

# ────────────────────────────────────────────────────────────────
# Final status & summary
# ────────────────────────────────────────────────────────────────
AFTER=$(df / /var /boot --output=used 2>/dev/null | awk 'NR>1 {s+=$1} END {print s+0}')
FREED_KB=$(( BEFORE - AFTER ))
FREED_MB=$(awk "BEGIN {printf \"%.2f\", $FREED_KB / 1024 }")

REBOOT_DURING_RUN=false
if [ -f /var/run/reboot-required ]; then
    if [ "$(stat -c %Y /var/run/reboot-required 2>/dev/null || echo 0)" -gt "$SCRIPT_START" ]; then
        REBOOT_DURING_RUN=true
    fi
fi

if [ "$REBOOT_DURING_RUN" = true ]; then
    warn "Reboot is required to complete some updates."
    warn "Run: sudo reboot"
else
    success "No reboot required from this run."
fi

LAST_RUN_DIR="/var/lib/update-clean"
LAST_RUN_FILE="$LAST_RUN_DIR/last-run"
RUN_STATUS=success
[ "$EXIT_CODE" -ne 0 ] && RUN_STATUS=failure

if ! $DRY_RUN; then
    mkdir -p "$LAST_RUN_DIR"
    cat > "$LAST_RUN_FILE" << LAST
VERSION=$SCRIPT_VERSION
DISTRO=$DISTRO_NAME
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
STATUS=$RUN_STATUS
FAILURES=$EXIT_CODE
DISK_FREED_MB=$FREED_MB
REBOOT_REQUIRED=$([ "$REBOOT_DURING_RUN" = true ] && echo "yes" || echo "no")
LOG_FILE=$LOG_FILE
LAST
    info "Last run record written to $LAST_RUN_FILE"
else
    info "DRY-RUN: Would write last-run record"
fi

if command -v needrestart >/dev/null 2>&1 && ! $DRY_RUN; then
    info "Checking services that need restart..."
    needrestart -r a -l 2>/dev/null || true
elif $DRY_RUN; then
    info "DRY-RUN: Would check for services needing restart"
fi

if command -v notify-send >/dev/null 2>&1 && [ -n "${DISPLAY:-}" ]; then
    MSG="System update completed. Freed ${FREED_MB} MB."
    if [ "$REBOOT_DURING_RUN" = true ]; then
        MSG="$MSG Reboot recommended."
    fi
    if [ "$EXIT_CODE" -ne 0 ]; then
        MSG="$MSG Some steps reported failures."
    fi
    notify-send "Update & Cleanup" "$MSG" 2>/dev/null || true
fi

log "=== Update Summary ==="
log "Distro: $DISTRO_NAME"
log "Disk space freed (/, /var, /boot): ${FREED_MB} MB"
log "Failures recorded: $EXIT_CODE"
log "Full log saved to: $LOG_FILE"
log "APT warnings logged to: $APT_LOG"

if [ "$EXIT_CODE" -eq 0 ]; then
    success "Update and cleanup completed successfully!"
    exit 0
else
    warn "Update and cleanup finished with $EXIT_CODE failure(s)."
    exit 1
fi