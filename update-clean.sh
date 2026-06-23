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
if [ ! -d "$SCRIPT_DIR" ] || [ ! -r "$SCRIPT_DIR" ]; then
    printf '%s\n' "Error: Cannot access script directory: $SCRIPT_DIR" >&2
    exit 1
fi

# ────────────────────────────────────────────────────────────────
# Defaults & Config
# ────────────────────────────────────────────────────────────────
DRY_RUN=false
SKIP_KERNEL=false
DEBUG=false
LOG_RETENTION=${LOG_RETENTION:-3}
KERNEL_KEEP=${KERNEL_KEEP:-2}
BACKUP_MODE=${BACKUP_MODE:-false}
CRITICAL_PACKAGES=(base-files base-passwd bash coreutils util-linux)
SCRIPT_NAME="update-clean"
SCRIPT_VERSION=$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null || echo "unknown")
EXIT_CODE=0
KERNELS_REMOVED=false

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

has_cmd() { command -v "$1" >/dev/null 2>&1; }

load_config_files() {
    local conf owner
    local -a confs=(/etc/update-clean.conf)

    if [ "$EUID" -eq 0 ]; then
        confs+=("/root/.config/update-clean.conf" "/root/.update-clean.conf")
        if [ -n "${SUDO_USER:-}" ] && [ -d "/home/$SUDO_USER" ]; then
            confs+=(
                "/home/$SUDO_USER/.config/update-clean.conf"
                "/home/$SUDO_USER/.update-clean.conf"
            )
        fi
    else
        confs+=("$HOME/.config/update-clean.conf" "$HOME/.update-clean.conf")
    fi

    for conf in "${confs[@]}"; do
        [ -f "$conf" ] || continue
        if [[ "$conf" == /etc/* ]]; then
            owner=$(stat -c %u "$conf" 2>/dev/null || echo "")
            if [ "$owner" != "0" ]; then
                warn "Config $conf not owned by root; skipping"
                continue
            fi
        fi
        if [ ! -r "$conf" ]; then
            warn "Config $conf is not readable; skipping"
            continue
        fi
        # shellcheck source=/dev/null
        source "$conf"
    done
}

load_config_files

if ! [[ "$LOG_RETENTION" =~ ^[0-9]+$ ]] || [ "$LOG_RETENTION" -lt 0 ]; then
    warn "Invalid LOG_RETENTION='$LOG_RETENTION', using default 3"
    LOG_RETENTION=3
fi

if ! [[ "$KERNEL_KEEP" =~ ^[0-9]+$ ]] || [ "$KERNEL_KEEP" -lt 1 ]; then
    warn "Invalid KERNEL_KEEP='$KERNEL_KEEP', using default 2"
    KERNEL_KEEP=2
fi

export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none

# ────────────────────────────────────────────────────────────────
# Helpers
# ────────────────────────────────────────────────────────────────
get_avail_kb() {
    local part="$1"
    local val
    val=$(df --output=avail "$part" 2>/dev/null | awk 'NR==2 {print $1+0}')
    printf '%d' "${val:-0}"
}

check_partition_space() {
    local part="$1" min_kb="${2:-2097152}"
    local avail_kb

    [ -d "$part" ] || return 0
    avail_kb=$(get_avail_kb "$part")
    if [ "$avail_kb" -lt "$min_kb" ]; then
        if [ "$min_kb" -ge 1048576 ]; then
            error "Less than $((min_kb / 1024 / 1024)) GB free on $part"
        else
            error "Less than $((min_kb / 1024)) MB free on $part"
        fi
        return 1
    fi
    return 0
}

warn_low_partition_space() {
    local part="$1" min_kb="$2"
    local avail_kb

    [ -d "$part" ] || return 0
    avail_kb=$(get_avail_kb "$part")
    if [ "$avail_kb" -lt "$min_kb" ]; then
        warn "Very low space on $part (< $((min_kb / 1024)) MB). Kernel updates may fail."
    fi
}

report_partition_space() {
    local part="$1" min_kb="${2:-2097152}"
    local avail_kb

    [ -d "$part" ] || return 0
    avail_kb=$(get_avail_kb "$part")
    printf 'Disk space on %s: ' "$part"
    if [ "$avail_kb" -ge "$min_kb" ]; then
        printf 'OK (%s MB free)\n' "$((avail_kb / 1024))"
    else
        printf 'LOW (%s MB free)\n' "$((avail_kb / 1024))"
    fi
}

calc_disk_freed_mb() {
    local before="$1" after="$2"
    local freed_kb=$((before - after))
    awk "BEGIN {printf \"%.2f\", $freed_kb / 1024 }"
}

log_to_syslog() {
    if has_cmd logger; then
        logger -t "$SCRIPT_NAME" -p user.info -- "$1"
    fi
}

format_cmd_args() {
    local -a args=("$@")
    local out="" arg
    for arg in "${args[@]}"; do
        out+="$(printf '%q' "$arg") "
    done
    printf '%s' "${out%" "}"
}

is_apt_locked() {
    has_cmd fuser && fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1
}

list_installed_kernel_images() {
    dpkg-query -W -f='${Status}\t${Package}\n' 'linux-image-[0-9]*' 2>/dev/null \
        | awk -F'\t' '$1 ~ /^install ok installed/ {print $2}' \
        | grep -Ev '(-meta|-rt|linux-image-amd64|linux-image-generic)$' \
        | sort -V
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
        kali)
            ARCHIVE_HOST="archive.kali.org"
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
        debian|ubuntu|kali|linuxmint|pop|elementary|zorin|kubuntu|xubuntu|lubuntu|mint)
            return 0
            ;;
        *)
            warn "Unsupported or unknown distro '$DISTRO_ID'. Proceeding anyway (apt-based assumed)."
            ;;
    esac
}

check_connectivity() {
    local host="${ARCHIVE_HOST:-deb.debian.org}"

    if has_cmd curl; then
        if curl -sSf --connect-timeout 5 "https://${host}/" >/dev/null 2>&1; then
            return 0
        fi
    elif has_cmd wget; then
        if wget -q --timeout=5 --spider "https://${host}/" >/dev/null 2>&1; then
            return 0
        fi
    fi

    if has_cmd getent && getent hosts "$host" >/dev/null 2>&1; then
        warn "HTTPS check failed but DNS resolves for $host; proceeding."
        return 0
    fi

    if has_cmd ping; then
        if ping -c 1 -W 3 "$host" >/dev/null 2>&1; then
            warn "Could not reach https://${host} but host responds to ping; proceeding."
            return 0
        fi
        if ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
            warn "Could not reach $host but internet ping (8.8.8.8) succeeded; proceeding."
            return 0
        fi
    fi

    return 1
}

find_running_kernel_pkg() {
    local running_ver="$1"
    local pkg vmlinuz

    [ -z "$running_ver" ] && return 1

    vmlinuz="/boot/vmlinuz-${running_ver}"
    if [ -f "$vmlinuz" ]; then
        pkg=$(dpkg-query -S "$vmlinuz" 2>/dev/null | awk -F: '{print $1}' | head -n1)
        if [ -n "$pkg" ]; then
            printf '%s' "$pkg"
            return 0
        fi
    fi

    while IFS= read -r pkg; do
        [ -z "$pkg" ] && continue
        if [[ "$pkg" == *"$running_ver"* ]]; then
            printf '%s' "$pkg"
            return 0
        fi
    done < <(list_installed_kernel_images)

    return 1
}

purge_kernel_related() {
    local pkg="$1"
    local ver suffix candidate related

    if [[ "$pkg" =~ ^linux-image-(.+)$ ]]; then
        ver="${BASH_REMATCH[1]}"
        for suffix in headers modules-extra modules modules-unsigned; do
            candidate="linux-${suffix}-${ver}"
            if dpkg-query -W -f='${Status}' "$candidate" 2>/dev/null | grep -q 'install ok installed'; then
                apt_run purge "$candidate" || true
            fi
        done
        while IFS= read -r related; do
            [ -z "$related" ] || [ "$related" = "$pkg" ] && continue
            apt_run purge "$related" || true
        done < <(
            dpkg-query -W -f='${Package}\n' 2>/dev/null \
                | grep -E '^linux-(headers|modules)' \
                | grep -F -- "$ver" || true
        )
    fi
}

apt_run() {
    local -a args=("$@")
    local apt_log="${APT_LOG:-/dev/null}"

    if $DRY_RUN; then
        info "DRY-RUN: would run: apt-get -y $(format_cmd_args "${args[@]}")"
        return 0
    fi

    local -a cmd=(
        apt-get
        -o Dpkg::Options::="--force-confdef"
        -o Dpkg::Options::="--force-confold"
        -y
        "${args[@]}"
    )

    if ! DEBIAN_FRONTEND=noninteractive "${cmd[@]}" 2>&1 | tee -a "$apt_log"; then
        _record_failure
        return 1
    fi
}

remove_old_kernels() {
    local -a kernels=()
    local -a to_remove=()
    local running_pkg running_ver pkg i delcount

    running_ver=$(uname -r 2>/dev/null || true)
    running_pkg=$(find_running_kernel_pkg "$running_ver" || true)

    if [ -n "$running_pkg" ]; then
        info "Running kernel package: $running_pkg ($running_ver)"
    elif [ -n "$running_ver" ]; then
        warn "Could not match installed package for running kernel $running_ver; skipping kernel removal"
        return 0
    fi

    mapfile -t kernels < <(list_installed_kernel_images)

    if [ "${#kernels[@]}" -eq 0 ]; then
        info "No linux-image packages found."
        return 0
    fi

    for pkg in "${kernels[@]}"; do
        if [ -n "$running_pkg" ] && [ "$pkg" = "$running_pkg" ]; then
            continue
        fi
        if [ -n "$running_ver" ] && [[ "$pkg" == *"$running_ver"* ]]; then
            continue
        fi
        to_remove+=("$pkg")
    done

    if [ "${#to_remove[@]}" -le "$KERNEL_KEEP" ]; then
        info "No old kernels to remove (keeping $KERNEL_KEEP beside running kernel)."
        return 0
    fi

    delcount=$(( ${#to_remove[@]} - KERNEL_KEEP ))
    KERNELS_REMOVED=true

    for ((i = 0; i < delcount; i++)); do
        pkg="${to_remove[i]}"
        if $DRY_RUN; then
            info "DRY-RUN: Would purge old kernel: $pkg"
            continue
        fi
        info "Purging old kernel: $pkg"
        apt_run purge "$pkg" || warn "Failed to purge $pkg"
        purge_kernel_related "$pkg"
    done
}

show_dry_run_preview() {
    local apt_log="${APT_LOG:-/dev/null}"

    info "DRY-RUN preview: upgradable packages (read-only)"
    apt list --upgradable 2>/dev/null | sed -n '1,40p' || true
    info "DRY-RUN preview: autoremove simulation (read-only)"
    apt-get -s --purge autoremove 2>&1 | sed -n '1,40p' | tee -a "$apt_log" || true
}

rotate_old_logs() {
    local keep="$1"
    local -a files=()
    local i

    [ "$keep" -le 0 ] && return
    [ -d "$LOG_DIR" ] || return

    if find "$LOG_DIR" -maxdepth 0 -printf '%T@\n' >/dev/null 2>&1; then
        mapfile -t files < <(
            find "$LOG_DIR" -maxdepth 1 -type f -name 'update-clean-*.log' -printf '%T@ %p\n' 2>/dev/null \
                | sort -nr | awk '{print $2}'
        )
    else
        while IFS= read -r file; do
            [ -z "$file" ] && continue
            files+=("$file")
        done < <(ls -1t "$LOG_DIR"/update-clean-*.log 2>/dev/null || true)
    fi

    for ((i = keep; i < ${#files[@]}; i++)); do
        rm -f "${files[i]}" || warn "Failed to remove old log ${files[i]}"
    done
}

flatpak_update() {
    if flatpak update --help 2>&1 | grep -q assumeyes; then
        flatpak update --assumeyes "$@"
    else
        flatpak update -y "$@"
    fi
}

flatpak_uninstall_unused() {
    if flatpak uninstall --help 2>&1 | grep -q assumeyes; then
        flatpak uninstall --unused --assumeyes "$@"
    else
        flatpak uninstall --unused -y "$@"
    fi
}

remove_disabled_snaps() {
    local name rev

    if command -v jq >/dev/null 2>&1; then
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            name="${line%% *}"
            rev="${line##* }"
            snap remove "$name" --revision="$rev" 2>/dev/null || true
        done < <(
            snap list --all --format=json 2>/dev/null \
                | jq -r '.[] | select(.notes[]? == "disabled") | "\(.name) \(.revision)"' 2>/dev/null || true
        )
        return
    fi

    while IFS= read -r name rev; do
        [ -z "$name" ] && continue
        snap remove "$name" --revision="$rev" 2>/dev/null || true
    done < <(snap list --all 2>/dev/null | awk '$NF == "disabled" {print $1, $3}' || true)
}

hold_critical_packages() {
    local curpkg
    local -a to_hold=()

    curpkg=$(find_running_kernel_pkg "$(uname -r)" || true)
    to_hold=("${CRITICAL_PACKAGES[@]}")
    [ -n "$curpkg" ] && to_hold+=("$curpkg")
    [ "${#to_hold[@]}" -eq 0 ] && return 0
    apt-mark hold "${to_hold[@]}" 2>/dev/null || true
}

send_completion_notification() {
    local msg="$1"

    if command -v notify-send >/dev/null 2>&1 && [ -n "${DISPLAY:-}" ]; then
        notify-send "Update & Cleanup" "$msg" 2>/dev/null || true
    fi

    if [ -n "${ADMIN_EMAIL:-}" ] && command -v mail >/dev/null 2>&1; then
        printf '%s\n' "$msg" | mail -s "$SCRIPT_NAME completion" "$ADMIN_EMAIL" 2>/dev/null || true
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
  --keep-kernels N  Keep N kernels besides running (default: 2)
  --last, --status  Show information from the last run
  --check, --doctor Run pre-flight checks only (no updates)
  --debug           Enable shell trace (set -x) for troubleshooting
  --help, -h        Show this help
  --version, -v     Show version information

Environment / Config:
  LOG_RETENTION     Number of logs to keep (default: 3)
  KERNEL_KEEP       Kernels to keep besides running (default: 2)
  BACKUP_MODE       Backup /etc before purging configs (default: false)
  ADMIN_EMAIL       Optional email address for completion notification
  CRITICAL_PACKAGES Array of packages to hold during cleanup
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
    local log_path

    if [ -f "$last_file" ]; then
        printf '%s\n' "Last run information:"
        cat "$last_file"
        log_path=$(awk -F= '/^LOG_FILE=/ {print $2}' "$last_file" 2>/dev/null | tail -n1)
        if [ -n "$log_path" ] && [ -f "$log_path" ]; then
            printf '\nTail of log file (%s):\n' "$log_path"
            tail -n 80 "$log_path" 2>/dev/null || true
        fi
    else
        printf '%s\n' "No last-run record found."
    fi
}

run_preflight_checks() {
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
        report_partition_space "$part" 2097152
    done

    printf 'APT lock free: '
    if ! has_cmd fuser; then
        printf '%s\n' "UNKNOWN (fuser not installed)"
    elif is_apt_locked; then
        printf '%s\n' "LOCKED"
    else
        printf '%s\n' "OK"
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
        --keep-kernels)
            shift
            if [ $# -eq 0 ]; then
                error "--keep-kernels requires a number"
                exit 1
            fi
            KERNEL_KEEP="$1"
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
        --debug)
            DEBUG=true
            shift
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

if $DEBUG; then
    set -x
    info "Debug mode enabled (set -x)"
fi

if $DRY_RUN; then
    info "DRY RUN MODE ENABLED - No changes will be made"
    info "DRY-RUN may still use the network to list upgradable packages"
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
log_to_syslog "Running $SCRIPT_NAME version: $SCRIPT_VERSION on $DISTRO_NAME"

log "Cleaning up old logs (keeping last $LOG_RETENTION)..."
rotate_old_logs "${LOG_RETENTION:-0}"

SCRIPT_START=$(date +%s)

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
    check_partition_space "$partition" 2097152 || exit 1
done

warn_low_partition_space "/boot" 51200

if has_cmd fuser && is_apt_locked; then
    warn "APT is locked by another process. Waiting up to 60s..."
    for _ in {1..12}; do
        if ! is_apt_locked; then
            break
        fi
        sleep 5
    done
    if is_apt_locked; then
        error "APT still locked after waiting. Please resolve and try again."
        exit 1
    fi
elif ! has_cmd fuser; then
    warn "fuser not available; skipping APT lock check"
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
trap '_record_failure; error "Unhandled error on line $LINENO in ${FUNCNAME[0]:-main}"' ERR

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
    info "DRY-RUN: Would run apt-get update (skipped)"
else
    if ! apt-get update 2>&1 | tee -a "${APT_LOG:-/dev/null}"; then
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
else
    info "Removing unnecessary packages (autoremove --purge)..."
    apt_run --purge autoremove || warn "autoremove had issues"

    info "Cleaning package cache (autoclean + clean)..."
    apt-get autoclean 2>&1 | tee -a "${APT_LOG:-/dev/null}" || _record_failure
    apt-get clean 2>&1 | tee -a "${APT_LOG:-/dev/null}" || _record_failure

    if [ "${BACKUP_MODE}" = true ]; then
        info "BACKUP_MODE: Creating backup of /etc before purging configs"
        mkdir -p /var/backups
        tar -czf "/var/backups/etc-before-cleanup-$(date +%Y%m%d-%H%M%S).tar.gz" /etc/ 2>/dev/null \
            || warn "Backup of /etc failed"
    fi

    info "Purging residual configuration files..."
    apt_run purge '~c' || warn "Purging residual configs had issues"
fi

if $SKIP_KERNEL; then
    info "Skipping old kernel removal (--no-kernel)."
else
    info "Removing old kernels (keeping current + previous)..."
    remove_old_kernels
fi

if $KERNELS_REMOVED; then
    if ! $DRY_RUN; then
        info "Old kernels were removed. To recover: boot GRUB menu and select a previous kernel entry."
    else
        info "DRY-RUN: Would remove old kernels. Recovery: boot GRUB menu and select a previous kernel."
    fi
fi

if $KERNELS_REMOVED && command -v update-grub >/dev/null 2>&1 && ! $DRY_RUN; then
    safe_run "Updating GRUB bootloader" update-grub
fi

if command -v flatpak >/dev/null 2>&1; then
    if $DRY_RUN; then
        info "DRY-RUN: Would update Flatpaks and remove unused"
    else
        safe_run "Updating Flatpaks" flatpak_update
        safe_run "Removing unused Flatpaks" flatpak_uninstall_unused
    fi
fi

if command -v snap >/dev/null 2>&1; then
    if $DRY_RUN; then
        info "DRY-RUN: Would refresh Snaps and remove old revisions"
    else
        safe_run "Refreshing Snaps" snap refresh
        remove_disabled_snaps
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
    if [ -d /var/lib/apt/lists/partial ]; then
        rm -rf -- /var/lib/apt/lists/partial/* || warn "Failed to clean partial apt lists"
    fi

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
FREED_MB=$(calc_disk_freed_mb "$BEFORE" "$AFTER")

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

MSG="System update completed. Freed ${FREED_MB} MB."
if [ "$REBOOT_DURING_RUN" = true ]; then
    MSG="$MSG Reboot recommended."
fi
if [ "$EXIT_CODE" -ne 0 ]; then
    MSG="$MSG Some steps reported failures."
fi
send_completion_notification "$MSG"
log_to_syslog "$MSG (failures=$EXIT_CODE)"

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