#!/usr/bin/env bash
# Debian / Ubuntu - Complete Update & Cleanup Script
# Full system update + thorough cleanup for Debian-based systems
# Usage: sudo ./update-clean.sh [--dry-run] [--no-kernel] [--help] [--version]
# Recommended: run weekly
# Configurable via env or /etc/update-clean.conf

set -euo pipefail

# ────────────────────────────────────────────────────────────────
# Defaults & Config
# ────────────────────────────────────────────────────────────────
DRY_RUN=false
SKIP_KERNEL=false
LOG_RETENTION=${LOG_RETENTION:-3}
SCRIPT_NAME="update-clean"
SCRIPT_VERSION=$(cat VERSION 2>/dev/null || echo "unknown")

# Load config file if present
for conf in /etc/update-clean.conf "$HOME/.config/update-clean.conf" "$HOME/.update-clean.conf"; do
    [ -f "$conf" ] && source "$conf"
done

# ────────────────────────────────────────────────────────────────
# Colors (define early)
# ────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()      { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }
info()     { echo -e "${BLUE}[INFO]${NC} $1"; }
success()  { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
warn()     { echo -e "${YELLOW}[WARNING]${NC} $1"; }
error()    { echo -e "${RED}[ERROR]${NC} $1"; }

# ────────────────────────────────────────────────────────────────
# Distro detection
# ────────────────────────────────────────────────────────────────
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
    local label host

    if [ -n "$ARCHIVE_HOST" ]; then
        label="$ARCHIVE_HOST"
        host="$ARCHIVE_HOST"
    else
        label="network"
        host="1.1.1.1"
    fi

    if timeout 5 bash -c "echo > /dev/tcp/${host}/443" 2>/dev/null; then
        return 0
    fi

    if ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
        warn "Could not reach $label on port 443; fallback ping to 8.8.8.8 succeeded."
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
    echo "$SCRIPT_NAME $SCRIPT_VERSION"
    echo "Distro: $DISTRO_NAME"

    if [ -d .git ]; then
        local commit
        commit=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
        echo "Commit: $commit"
    fi

    local last_file="/var/lib/update-clean/last-run"
    if [ -f "$last_file" ]; then
        echo ""
        echo "Last run:"
        sed 's/^/  /' "$last_file"
    fi
}

show_last_run() {
    local last_file="/var/lib/update-clean/last-run"
    if [ -f "$last_file" ]; then
        echo "Last run information:"
        cat "$last_file"
    else
        echo "No last-run record found."
    fi
}

run_preflight_checks() {
    detect_distro
    check_debian_based

    echo "=== Pre-flight Checks ==="
    echo "Distro: $DISTRO_NAME"

    echo -n "Running as root: "
    if [ "$EUID" -eq 0 ]; then echo "OK"; else echo "FAIL (must be root)"; fi

    echo -n "Internet"
    if [ -n "$ARCHIVE_HOST" ]; then
        echo -n " ($ARCHIVE_HOST)"
    fi
    echo -n ": "
    if check_connectivity; then
        echo "OK"
    else
        echo "FAIL"
    fi

    for part in / /var /boot; do
        if [ -d "$part" ]; then
            local avail
            avail=$(df "$part" --output=avail | tail -n 1)
            echo -n "Disk space on $part: "
            if [ "$avail" -ge 2097152 ]; then
                echo "OK ($(($avail / 1024)) MB free)"
            else
                echo "LOW ($(($avail / 1024)) MB free)"
            fi
        fi
    done

    echo -n "APT lock free: "
    if ! fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
        echo "OK"
    else
        echo "LOCKED"
    fi

    echo -n "systemd-resolved active: "
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        echo "OK"
    else
        echo "INACTIVE"
    fi

    echo -n "Required tools: "
    local missing=""
    for tool in apt dpkg; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing="$missing $tool"
        fi
    done
    if [ -z "$missing" ]; then
        echo "OK"
    else
        echo "MISSING:$missing"
    fi

    echo "=== Checks complete ==="
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
find "$LOG_DIR" -name "update-clean-*.log" -type f -printf '%T@ %p\0' | \
    sort -z -n | head -zn "-$LOG_RETENTION" | cut -zd' ' -f2- | xargs -0r rm -f

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
        avail_kb=$(df "$partition" --output=avail | tail -n 1)
        if [ "$avail_kb" -lt 2097152 ]; then
            error "Less than 2 GB free on $partition"
            exit 1
        fi
    fi
done

if [ -d /boot ]; then
    boot_kb=$(df /boot --output=avail | tail -n 1)
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

if ! systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    warn "systemd-resolved is not active. DNS resolution may be affected."
fi

BEFORE=$(df / /var /boot --output=used 2>/dev/null | awk 'NR>1 {s+=$1} END {print s}')

# ────────────────────────────────────────────────────────────────
# Simple file lock + trap
# ────────────────────────────────────────────────────────────────
LOCKFILE="/var/run/update-clean.lock"
exec 200>"$LOCKFILE"
if ! flock -n 200; then
    error "Another instance of $SCRIPT_NAME is already running."
    exit 1
fi
trap 'rm -f "$LOCKFILE"' EXIT

safe_run() {
    local desc="$1"
    shift
    info "$desc"
    if ! "$@"; then
        warn "$desc failed — continuing"
    fi
}

# ────────────────────────────────────────────────────────────────
# Core update
# ────────────────────────────────────────────────────────────────
info "Configuring any interrupted package installations..."
dpkg --configure -a || warn "dpkg --configure -a had issues"

info "Fixing broken dependencies..."
apt install -f -y || warn "apt install -f had issues"

info "Updating package lists..."
apt update

info "Checking package cache integrity (apt-get check)..."
apt-get check || warn "Package cache check reported issues"

APT_OPTS="-y"
if $DRY_RUN; then
    APT_OPTS="-s"
    info "DRY-RUN: Using simulation mode for APT commands"
fi

info "Upgrading packages..."
apt upgrade $APT_OPTS 2>&1 | tee -a "$APT_LOG" || warn "apt upgrade had issues"

info "Listing upgradable packages after initial upgrade:"
apt list --upgradable 2>/dev/null || true

info "Performing full system upgrade..."
apt full-upgrade $APT_OPTS 2>&1 | tee -a "$APT_LOG" || warn "full-upgrade had issues"

# ────────────────────────────────────────────────────────────────
# Complete cleanup
# ────────────────────────────────────────────────────────────────
info "Holding critical packages to prevent accidental removal..."
apt-mark hold base-files base-passwd bash coreutils util-linux "linux-image-$(uname -r)" 2>/dev/null || true

if $DRY_RUN; then
    info "DRY-RUN: Would run autoremove, clean, purge configs, kernel removal, etc."
else
    info "Removing unnecessary packages (autoremove --purge)..."
    apt --purge autoremove -y 2>&1 | tee -a "$APT_LOG" || warn "autoremove had issues"

    info "Cleaning package cache (autoclean + clean)..."
    apt autoclean
    apt clean

    info "Purging residual configuration files..."
    apt purge '~c' -y 2>&1 | tee -a "$APT_LOG" || warn "Purging residual configs had issues"
fi

KERNELS_REMOVED=false
if $SKIP_KERNEL; then
    info "Skipping old kernel removal (--no-kernel)."
elif $DRY_RUN; then
    info "DRY-RUN: Would remove old kernels (keeping current + previous)."
else
    info "Removing old kernels (keeping current + previous)..."
    CURRENT=$(uname -r)
    KERNELS=$(dpkg -l 'linux-image-*' 2>/dev/null | awk '/^ii/ {print $2}' | grep -v "$CURRENT" | sort -V | head -n -1 || true)
    if [ -n "$KERNELS" ]; then
        KERNELS_REMOVED=true
        while read -r k; do
            [ -z "$k" ] && continue
            apt purge -y "$k" 2>&1 | tee -a "$APT_LOG" || warn "Failed to purge $k"
            echo "$k" | sed 's/linux-image/linux-headers/' | xargs -r apt purge -y 2>/dev/null || true
            echo "$k" | sed 's/linux-image/linux-modules/'  | xargs -r apt purge -y 2>/dev/null || true
        done <<< "$KERNELS"
    else
        info "No old kernels to remove."
    fi
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
AFTER=$(df / /var /boot --output=used 2>/dev/null | awk 'NR>1 {s+=$1} END {print s}')
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

if ! $DRY_RUN; then
    mkdir -p "$LAST_RUN_DIR"
    cat > "$LAST_RUN_FILE" << LAST
VERSION=$SCRIPT_VERSION
DISTRO=$DISTRO_NAME
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
STATUS=success
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
    notify-send "Update & Cleanup" "$MSG" 2>/dev/null || true
fi

success "Update and cleanup completed successfully!"
log "=== Update Summary ==="
log "Distro: $DISTRO_NAME"
log "Disk space freed (/, /var, /boot): ${FREED_MB} MB"
log "Full log saved to: $LOG_FILE"
log "APT warnings logged to: $APT_LOG"
exit 0