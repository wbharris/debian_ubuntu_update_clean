#!/usr/bin/env bash
# Debian / Ubuntu - Complete Update & Cleanup Script
# Full system update + thorough cleanup for Debian-based systems
#
# Requirements: Bash 4+, run as root (sudo), apt-based system
# Config: /etc/update-clean.conf, root or SUDO_USER home configs (see README)
# Logs: /var/log/update-clean/ (retention via LOG_RETENTION)
# Exit codes: 0 = success; 1 = one or more failures (count in FAILURES / EXIT_CODE)
#
# Usage: sudo ./update-clean.sh [--dry-run] [--no-kernel] [--help] [--version]
# Recommended: run weekly

set -euo pipefail
set -o errtrace

# Require Bash 4+ (mapfile, array sorting)
if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    printf '%s\n' "This script requires Bash 4+. Found: ${BASH_VERSION:-unknown}" >&2
    exit 1
fi

umask 022

PATH="/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
export PATH

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
SKIP_CONNECTIVITY=false
LOG_RETENTION=${LOG_RETENTION:-3}
KERNEL_KEEP=${KERNEL_KEEP:-2}
KERNEL_KEEP_MAX=${KERNEL_KEEP_MAX:-10}
BACKUP_MODE=${BACKUP_MODE:-false}
REBOOT_IF_REQUIRED=${REBOOT_IF_REQUIRED:-false}
LOG_DIR="${LOG_DIR:-/var/log/update-clean}"
LOCKFILE="${LOCKFILE:-/run/update-clean.lock}"
LAST_RUN_DIR="${LAST_RUN_DIR:-/var/lib/update-clean}"
CRITICAL_PACKAGES=(base-files base-passwd bash coreutils util-linux)
readonly SCRIPT_NAME="update-clean"
SCRIPT_VERSION=$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null || echo "unknown")
readonly SCRIPT_DIR
EXIT_CODE=0
KERNELS_REMOVED=false

# Thresholds and retry limits (override via env if needed)
readonly MIN_DISK_KB=${MIN_DISK_KB:-2097152}       # 2 GB
readonly MIN_LOG_DIR_KB=${MIN_LOG_DIR_KB:-1024}    # 1 MB
readonly BOOT_MIN_KB=${BOOT_MIN_KB:-10240}         # 10 MB — skip kernel removal
readonly BOOT_LOW_KB=${BOOT_LOW_KB:-51200}         # 50 MB — low /boot warning
readonly APT_UPDATE_MAX_RETRIES=${APT_UPDATE_MAX_RETRIES:-3}

# CLI override markers (explicit flags win over config file)
CLI_KERNEL_KEEP=""
CLI_DRY_RUN=false
CLI_SKIP_KERNEL=false
CLI_SKIP_CONNECTIVITY=false
CLI_REBOOT_IF_REQUIRED=false
CLI_DEBUG=false

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

require_cmds() {
    local -a cmds=(apt-get dpkg awk sed grep tar mktemp flock)
    local cmd
    for cmd in "${cmds[@]}"; do
        if ! has_cmd "$cmd"; then
            error "Required command missing: $cmd"
            exit 1
        fi
    done
}

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
            owner=$(stat -c %u "$conf" 2>/dev/null || echo "invalid")
            if ! [[ "$owner" =~ ^[0-9]+$ ]] || [ "$owner" != "0" ]; then
                warn "Config $conf not owned by root (uid=$owner); skipping"
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

validate_config_values() {
    if ! [[ "$LOG_RETENTION" =~ ^[0-9]+$ ]] || [ "$LOG_RETENTION" -lt 0 ]; then
        warn "Invalid LOG_RETENTION='$LOG_RETENTION', using default 3"
        LOG_RETENTION=3
    fi
    if ! [[ "$KERNEL_KEEP" =~ ^[0-9]+$ ]] || [ "$KERNEL_KEEP" -lt 0 ]; then
        warn "Invalid KERNEL_KEEP='$KERNEL_KEEP', using default 2"
        KERNEL_KEEP=2
    elif [ "$KERNEL_KEEP" -gt "$KERNEL_KEEP_MAX" ]; then
        warn "KERNEL_KEEP=$KERNEL_KEEP exceeds max $KERNEL_KEEP_MAX, using $KERNEL_KEEP_MAX"
        KERNEL_KEEP=$KERNEL_KEEP_MAX
    fi
}

apply_cli_config_overrides() {
    # Explicit CLI flags override values loaded from config files
    [ -n "$CLI_KERNEL_KEEP" ] && KERNEL_KEEP="$CLI_KERNEL_KEEP"
    $CLI_DRY_RUN && DRY_RUN=true
    $CLI_SKIP_KERNEL && SKIP_KERNEL=true
    $CLI_SKIP_CONNECTIVITY && SKIP_CONNECTIVITY=true
    $CLI_REBOOT_IF_REQUIRED && REBOOT_IF_REQUIRED=true
    $CLI_DEBUG && DEBUG=true
}

# ────────────────────────────────────────────────────────────────
# Helpers
# ────────────────────────────────────────────────────────────────
get_avail_kb() {
    local part="$1"
    local val

    val=$(df -B 1K "$part" 2>/dev/null | awk 'NR==2 {print $4+0}')
    printf '%d' "${val:-0}"
}

get_used_kb_for_paths() {
    local sum

    sum=$(df -B 1K "$@" 2>/dev/null | awk 'NR>1 {s+=$3} END {print s+0}')
    printf '%d' "${sum:-0}"
}

check_partition_space() {
    local part="$1" min_kb="${2:-$MIN_DISK_KB}"
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
    local part="$1" min_kb="${2:-$MIN_DISK_KB}"
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

dump_debug_state() {
    $DEBUG || return
    printf 'DEBUG STATE:\n'
    printf '  KERNEL_KEEP=%s SKIP_KERNEL=%s DRY_RUN=%s DEBUG=%s\n' \
        "${KERNEL_KEEP:-}" "${SKIP_KERNEL:-}" "${DRY_RUN:-}" "${DEBUG:-}"
    printf '  LOG_DIR=%s\n  LOG_FILE=%s\n  APT_LOG=%s\n' \
        "${LOG_DIR:-<unset>}" "${LOG_FILE:-<unset>}" "${APT_LOG:-<unset>}"
    printf '  DISTRO=%s ARCHIVE_HOST=%s SKIP_CONNECTIVITY=%s\n' \
        "${DISTRO_NAME:-<unset>}" "${ARCHIVE_HOST:-<unset>}" "${SKIP_CONNECTIVITY:-}"
}

format_cmd_args() {
    local -a args=("$@")
    local out="" arg
    for arg in "${args[@]}"; do
        out+="$(printf '%q' "$arg") "
    done
    printf '%s' "${out%" "}"
}

# is_apt_locked: returns 0 if an apt/dpkg lock is held, 1 if unlocked.
# (Return 0 means "locked" — inverted from typical "success = free" wording.)
is_apt_locked() {
    local locks=(
        /var/lib/dpkg/lock-frontend
        /var/lib/dpkg/lock
        /var/lib/apt/lists/lock
        /var/cache/apt/archives/lock
    )
    local lock

    if has_cmd fuser; then
        for lock in "${locks[@]}"; do
            if [ -e "$lock" ] && fuser "$lock" >/dev/null 2>&1; then
                return 0
            fi
        done
        return 1
    fi

    if has_cmd lsof; then
        for lock in "${locks[@]}"; do
            if [ -e "$lock" ] && lsof "$lock" >/dev/null 2>&1; then
                return 0
            fi
        done
        return 1
    fi

    for lock in "${locks[@]}"; do
        if [ -e "$lock" ]; then
            return 0
        fi
    done
    return 1
}

list_installed_kernel_images() {
    dpkg-query -W -f='${Status}\t${Package}\n' 'linux-image-*' 2>/dev/null \
        | awk -F'\t' '$1 ~ /^install ok installed/ {print $2}' \
        | grep -E '^linux-image(-unsigned)?-[0-9][0-9a-zA-Z.\-+]*' \
        | grep -Ev -- '-(meta|dbg|dbgsym|rt|cloud|kvm|virtual)$' \
        | grep -Ev 'linux-image-(generic|generic-hwe|amd64)(-lts|-hwe)?$' \
        | sort -V
}

create_etc_backup() {
    local backup_file old_umask

    info "BACKUP_MODE: Creating backup of /etc before purging configs"
    if ! mkdir -p /var/backups; then
        warn "Cannot create /var/backups"
        return 1
    fi

    backup_file="/var/backups/etc-before-cleanup-$(date +%Y%m%d-%H%M%S).tar.gz"
    old_umask=$(umask)
    umask 077
    if tar --one-file-system \
        --exclude='/etc/ssl/private' \
        -czf "$backup_file" /etc/ 2>/dev/null; then
        chmod 600 "$backup_file"
        info "Backup saved to $backup_file"
    else
        warn "Backup of /etc failed"
        umask "$old_umask"
        return 1
    fi
    umask "$old_umask"
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

    ARCHIVE_HOST="${ARCHIVE_HOST:-deb.debian.org}"
}

check_debian_based() {
    if ! has_cmd apt; then
        error "This script requires apt and is intended for Debian-based systems."
        exit 1
    fi

    case "$DISTRO_ID" in
        debian*|ubuntu|kali*|linuxmint|pop|elementary|zorin|kubuntu|xubuntu|lubuntu|mint|*ubuntu*)
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
    shift
    local pkg vmlinuz
    local -a candidates=("$@")

    [ -z "$running_ver" ] && return 1

    vmlinuz="/boot/vmlinuz-${running_ver}"
    if [ -f "$vmlinuz" ]; then
        pkg=$(dpkg-query -S "$vmlinuz" 2>/dev/null | awk -F: '{print $1}' | head -n1)
        if [ -n "$pkg" ]; then
            printf '%s' "$pkg"
            return 0
        fi
    fi

    if [ "${#candidates[@]}" -eq 0 ]; then
        mapfile -t candidates < <(list_installed_kernel_images)
    fi

    for pkg in "${candidates[@]}"; do
        if [[ "$pkg" == *"$running_ver"* ]]; then
            printf '%s' "$pkg"
            return 0
        fi
    done

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

    # pipefail ensures apt-get exit code is preserved through tee
    if ! DEBIAN_FRONTEND=noninteractive "${cmd[@]}" 2>&1 | tee -a "$apt_log"; then
        _record_failure
        return 1
    fi
    return 0
}

apt_get_update_with_retries() {
    local attempt=0
    local apt_log="${APT_LOG:-/dev/null}"

    while :; do
        if apt-get update 2>&1 | tee -a "$apt_log"; then
            return 0
        fi
        attempt=$((attempt + 1))
        if [ "$attempt" -ge "$APT_UPDATE_MAX_RETRIES" ]; then
            return 1
        fi
        warn "apt-get update failed, retrying (attempt $((attempt + 1))/$APT_UPDATE_MAX_RETRIES)..."
        sleep $((attempt * 2))
    done
}

remove_old_kernels() {
    local -a kernels=()
    local -a to_remove=()
    local running_pkg running_ver pkg delcount boot_kb keep

    if [ -d /boot ]; then
        boot_kb=$(get_avail_kb /boot)
        if [ "$boot_kb" -lt "$BOOT_MIN_KB" ]; then
            warn "Skipping kernel removal: /boot has less than $((BOOT_MIN_KB / 1024)) MB free"
            return 0
        fi
    fi

    mapfile -t kernels < <(list_installed_kernel_images)

    running_ver=$(uname -r 2>/dev/null || true)
    running_pkg=$(find_running_kernel_pkg "$running_ver" "${kernels[@]}" || true)

    if [ -n "$running_pkg" ]; then
        info "Running kernel package: $running_pkg ($running_ver)"
    elif [ -n "$running_ver" ]; then
        warn "Could not match installed package for running kernel $running_ver; skipping kernel removal"
        return 0
    fi

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

    keep="${KERNEL_KEEP:-2}"

    if [ "${#to_remove[@]}" -le "$keep" ]; then
        info "No old kernels to remove (keeping $keep beside running kernel)."
        return 0
    fi

    delcount=$(( ${#to_remove[@]} - keep ))
    if [ "$delcount" -lt 1 ] || [ "$delcount" -gt "${#to_remove[@]}" ]; then
        warn "Kernel removal count out of range; skipping removal"
        return 0
    fi
    KERNELS_REMOVED=true

    info "Kernels scheduled for removal ($delcount):"
    for pkg in "${to_remove[@]:0:delcount}"; do
        info "  $pkg"
    done

    for pkg in "${to_remove[@]:0:delcount}"; do
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

    if has_cmd jq; then
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

    if has_cmd notify-send && [ -n "${DISPLAY:-}" ]; then
        notify-send "Update & Cleanup" "$msg" 2>/dev/null || true
    fi

    if [ -n "${ADMIN_EMAIL:-}" ] && has_cmd mail; then
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
    if has_cmd systemctl && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
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
  --keep-kernels N  Keep N kernels besides running (default: 2; 0 = only running)
  --reboot-if-required  Reboot automatically when required
  --offline         Skip internet connectivity checks
  --last, --status  Show information from the last run
  --check, --doctor Run pre-flight checks only (no updates)
  --debug           Enable shell trace (set -x) for troubleshooting
  --help, -h        Show this help
  --version, -v     Show version information

Environment / Config:
  LOG_RETENTION     Number of logs to keep (default: 3)
  KERNEL_KEEP       Kernels to keep besides running (default: 2, max 10)
  LOG_DIR           Log directory (default: /var/log/update-clean)
  LOCKFILE          Instance lock file (default: /run/update-clean.lock)
  LAST_RUN_DIR      Last-run record directory (default: /var/lib/update-clean)
  BACKUP_MODE       Backup /etc before purging configs (default: false)
  REBOOT_IF_REQUIRED Reboot automatically if required (default: false)
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
    if $SKIP_CONNECTIVITY; then
        printf '%s\n' "SKIPPED (--offline)"
    elif check_connectivity; then
        printf '%s\n' "OK"
    else
        printf '%s\n' "FAIL"
    fi

    for part in / /var /boot; do
        report_partition_space "$part" "$MIN_DISK_KB"
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
        if ! has_cmd "$tool"; then
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
            CLI_DRY_RUN=true
            shift
            ;;
        --no-kernel)
            SKIP_KERNEL=true
            CLI_SKIP_KERNEL=true
            shift
            ;;
        --keep-kernels)
            shift
            if [ $# -eq 0 ]; then
                error "--keep-kernels requires a number"
                exit 1
            fi
            if ! [[ "$1" =~ ^[0-9]+$ ]]; then
                error "--keep-kernels requires a numeric value"
                exit 1
            fi
            if [ "$1" -gt "$KERNEL_KEEP_MAX" ]; then
                error "--keep-kernels cannot exceed $KERNEL_KEEP_MAX"
                exit 1
            fi
            CLI_KERNEL_KEEP="$1"
            KERNEL_KEEP="$1"
            shift
            ;;
        --reboot-if-required)
            REBOOT_IF_REQUIRED=true
            CLI_REBOOT_IF_REQUIRED=true
            shift
            ;;
        --offline)
            SKIP_CONNECTIVITY=true
            CLI_SKIP_CONNECTIVITY=true
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
            CLI_DEBUG=true
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

load_config_files
apply_cli_config_overrides
validate_config_values
require_cmds

export DEBIAN_FRONTEND=noninteractive
export APT_LISTCHANGES_FRONTEND=none

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

if ! mkdir -p "$LOG_DIR"; then
    printf '%s\n' "Failed to create log directory $LOG_DIR" >&2
    exit 1
fi
chmod 755 "$LOG_DIR"

if [ ! -w "$LOG_DIR" ]; then
    printf '%s\n' "Log directory $LOG_DIR is not writable" >&2
    exit 1
fi

if [ "$(get_avail_kb "$LOG_DIR")" -lt "$MIN_LOG_DIR_KB" ]; then
    printf '%s\n' "Insufficient space in $LOG_DIR for logs (< 1 MB free)" >&2
    exit 1
fi

LOG_FILE=$(mktemp --tmpdir="$LOG_DIR" "update-clean-$(date +%Y%m%d-%H%M%S)-XXXXXX.log") \
    || { printf '%s\n' "Cannot create log file in $LOG_DIR" >&2; exit 1; }
APT_LOG="${LOG_FILE}.apt-warnings"

exec > >(tee >(sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE")) 2>&1

log "Running $SCRIPT_NAME version: $SCRIPT_VERSION on $DISTRO_NAME"
log_to_syslog "Running $SCRIPT_NAME version: $SCRIPT_VERSION on $DISTRO_NAME"
dump_debug_state

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

if $SKIP_CONNECTIVITY; then
    warn "Skipping internet connectivity check (--offline)"
else
    info "Checking internet connectivity..."
    if ! check_connectivity; then
        error "No internet connection detected."
        exit 1
    fi
fi

for partition in "/" "/var" "/boot"; do
    check_partition_space "$partition" "$MIN_DISK_KB" || exit 1
done

warn_low_partition_space "/boot" "$BOOT_LOW_KB"

if is_apt_locked; then
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
fi

if ! check_systemd_resolved; then
    warn "systemd-resolved is not active. DNS resolution may be affected."
fi

BEFORE=$(get_used_kb_for_paths / /var /boot)

# ────────────────────────────────────────────────────────────────
# File lock + trap
# ────────────────────────────────────────────────────────────────
exec 200>"$LOCKFILE" || { error "Cannot open lockfile $LOCKFILE"; exit 1; }
if ! flock -n 200; then
    error "Another instance of $SCRIPT_NAME is already running."
    exit 1
fi

err_trap() {
    local rc=$?
    local cmd=${BASH_COMMAND:-}
    local lineno=${BASH_LINENO[0]:-?}
    local i

    _record_failure
    error "Unhandled error (rc=$rc) while running: '$cmd' at or near line $lineno"
    if [ "${#BASH_SOURCE[@]}" -gt 1 ]; then
        error "Call stack (most recent call last):"
        for ((i = 1; i < ${#BASH_SOURCE[@]}; i++)); do
            error "  ${BASH_SOURCE[i]}:${BASH_LINENO[i - 1]} ${FUNCNAME[i]:-main}"
        done
    fi
    exit "$rc"
}

cleanup() {
    trap - INT TERM EXIT ERR

    local rc=${1:-$?}
    sync 2>/dev/null || true
    flock -u 200 2>/dev/null || true
    exec 200>&- 2>/dev/null || true
    rm -f "$LOCKFILE" 2>/dev/null || true
    if [ "$rc" -ne 0 ]; then
        error "Script exited with status $rc"
    fi
    exit "$rc"
}

trap 'err_trap' ERR
trap 'cleanup $?' INT TERM EXIT

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
    if ! apt_get_update_with_retries; then
        warn "apt-get update had issues after retries"
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
        create_etc_backup || true
    fi

    # '~c' is an apt/dpkg selection: packages in "rc" state (removed, config remains)
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

if $KERNELS_REMOVED && has_cmd update-grub && ! $DRY_RUN; then
    safe_run "Updating GRUB bootloader" update-grub
fi

if has_cmd flatpak; then
    if $DRY_RUN; then
        info "DRY-RUN: Would update Flatpaks and remove unused"
    else
        safe_run "Updating Flatpaks" flatpak_update
        safe_run "Removing unused Flatpaks" flatpak_uninstall_unused
    fi
fi

if has_cmd snap; then
    if $DRY_RUN; then
        info "DRY-RUN: Would refresh Snaps and remove old revisions"
    else
        safe_run "Refreshing Snaps" snap refresh
        remove_disabled_snaps
    fi
fi

if has_cmd fwupdmgr; then
    if $DRY_RUN; then
        info "DRY-RUN: Would update firmware"
    else
        safe_run "Refreshing firmware metadata" fwupdmgr refresh --force
        safe_run "Applying firmware updates" fwupdmgr update -y || true
    fi
fi

if has_cmd journalctl; then
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

    if has_cmd updatedb; then
        safe_run "Updating locate database" updatedb
    fi

    if has_cmd mandb; then
        safe_run "Rebuilding man page database" mandb -q
    fi
else
    info "DRY-RUN: Would perform final cleanups"
fi

# ────────────────────────────────────────────────────────────────
# Final status & summary
# ────────────────────────────────────────────────────────────────
AFTER=$(get_used_kb_for_paths / /var /boot)
FREED_MB=$(calc_disk_freed_mb "$BEFORE" "$AFTER")

REBOOT_DURING_RUN=false
if [ -f /var/run/reboot-required ]; then
    if [ "$(stat -c %Y /var/run/reboot-required 2>/dev/null || echo 0)" -gt "$SCRIPT_START" ]; then
        REBOOT_DURING_RUN=true
    fi
fi

if [ "$REBOOT_DURING_RUN" = true ]; then
    warn "Reboot is required to complete some updates."
    if [ "${REBOOT_IF_REQUIRED}" = true ] && ! $DRY_RUN; then
        info "REBOOT_IF_REQUIRED set; rebooting now"
        log_to_syslog "Rebooting after $SCRIPT_NAME run"
        reboot
    else
        warn "Run: sudo reboot (or use --reboot-if-required)"
    fi
else
    success "No reboot required from this run."
fi

LAST_RUN_FILE="$LAST_RUN_DIR/last-run"
RUN_STATUS=success
[ "$EXIT_CODE" -ne 0 ] && RUN_STATUS=failure

if ! $DRY_RUN; then
    mkdir -p "$LAST_RUN_DIR"
    RUN_TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    REBOOT_FLAG=$([ "$REBOOT_DURING_RUN" = true ] && echo "yes" || echo "no")
    cat > "$LAST_RUN_FILE" << LAST
VERSION=$SCRIPT_VERSION
DISTRO=$DISTRO_NAME
TIMESTAMP=$RUN_TIMESTAMP
STATUS=$RUN_STATUS
FAILURES=$EXIT_CODE
DISK_FREED_MB=$FREED_MB
REBOOT_REQUIRED=$REBOOT_FLAG
LOG_FILE=$LOG_FILE
LAST
    if has_cmd jq; then
        jq -n \
            --arg v "$SCRIPT_VERSION" \
            --arg d "$DISTRO_NAME" \
            --arg t "$RUN_TIMESTAMP" \
            --arg status "$RUN_STATUS" \
            --argjson failures "$EXIT_CODE" \
            --arg freed "$FREED_MB" \
            --arg reboot "$REBOOT_FLAG" \
            --arg log "$LOG_FILE" \
            '{version:$v,distro:$d,timestamp:$t,status:$status,failures:$failures,disk_freed_mb:$freed,reboot_required:$reboot,log_file:$log}' \
            >"$LAST_RUN_DIR/last-run.json" 2>/dev/null \
            || warn "Failed to write $LAST_RUN_DIR/last-run.json"
    fi
    info "Last run record written to $LAST_RUN_FILE"
else
    info "DRY-RUN: Would write last-run record"
fi

if has_cmd needrestart && ! $DRY_RUN; then
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