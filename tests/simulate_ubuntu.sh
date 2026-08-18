#!/usr/bin/env bash
# Run update-clean.sh as Ubuntu 22.04, Ubuntu 24.04, and Debian 12 by
# bind-mounting a fake /etc/os-release inside a private mount namespace.
# No container daemon required.
#
# Usage: ./tests/simulate_ubuntu.sh
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
UC="$ROOT/update-clean.sh"
SIM=$(mktemp -d "${TMPDIR:-/tmp}/ubuntu-sim.XXXXXX")
PASS=0
FAIL=0
# shellcheck disable=SC2064
trap 'rm -rf "$SIM"' EXIT

if [ ! -x "$UC" ]; then
    printf 'missing %s\n' "$UC" >&2
    exit 1
fi
if [ "$EUID" -ne 0 ]; then
    printf 'this harness needs root (unshare --mount + dry-run)\n' >&2
    exit 1
fi
if ! unshare --mount true 2>/dev/null; then
    printf 'unshare --mount is not available\n' >&2
    exit 1
fi

mkdir -p "$SIM/logs" "$SIM/state"

cat >"$SIM/os-ubuntu-2204" <<'EOF'
PRETTY_NAME="Ubuntu 22.04.5 LTS"
NAME="Ubuntu"
VERSION_ID="22.04"
VERSION="22.04.5 LTS (Jammy Jellyfish)"
ID=ubuntu
ID_LIKE=debian
VERSION_CODENAME=jammy
UBUNTU_CODENAME=jammy
EOF

cat >"$SIM/os-ubuntu-2404" <<'EOF'
PRETTY_NAME="Ubuntu 24.04.2 LTS"
NAME="Ubuntu"
VERSION_ID="24.04"
VERSION="24.04.2 LTS (Noble Numbat)"
ID=ubuntu
ID_LIKE=debian
VERSION_CODENAME=noble
UBUNTU_CODENAME=noble
EOF

cat >"$SIM/os-debian-12" <<'EOF'
PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"
NAME="Debian GNU/Linux"
VERSION_ID="12"
VERSION="12 (bookworm)"
ID=debian
VERSION_CODENAME=bookworm
EOF

run_as() {
    local osfile="$1" out="$2"
    shift 2
    local envfile="$SIM/env.sh"
    cat >"$envfile" <<ENV
export LOG_DIR="$SIM/logs"
export LAST_RUN_DIR="$SIM/state"
export LOCKFILE="$SIM/update-clean.lock"
ENV
    unshare --mount bash -c "
        set -euo pipefail
        mount --bind $(printf '%q' "$osfile") /etc/os-release
        mount -t tmpfs -o mode=0755 tmpfs /var/run
        if [ -f $(printf '%q' "$SIM/reboot-required") ]; then
            cp $(printf '%q' "$SIM/reboot-required") /var/run/reboot-required
        fi
        # shellcheck disable=SC1091
        . $(printf '%q' "$envfile")
        $(printf '%q' "$UC") $(printf '%q ' "$@")
    " >"$out" 2>&1
}

expect_rc() {
    local name="$1" got="$2" want="$3"
    if [ "$got" -eq "$want" ]; then
        printf '  PASS  %s (exit %s)\n' "$name" "$got"
        PASS=$((PASS + 1))
    else
        printf '  FAIL  %s (exit %s, want %s)\n' "$name" "$got" "$want"
        FAIL=$((FAIL + 1))
    fi
}

expect_grep() {
    local name="$1" file="$2" pat="$3"
    if grep -Eq -- "$pat" "$file"; then
        printf '  PASS  %s\n' "$name"
        PASS=$((PASS + 1))
    else
        printf '  FAIL  %s (missing /%s/)\n' "$name" "$pat"
        FAIL=$((FAIL + 1))
    fi
}

expect_no_grep() {
    local name="$1" file="$2" pat="$3"
    if grep -Eq -- "$pat" "$file"; then
        printf '  FAIL  %s (unexpected /%s/)\n' "$name" "$pat"
        FAIL=$((FAIL + 1))
    else
        printf '  PASS  %s\n' "$name"
        PASS=$((PASS + 1))
    fi
}

printf '=== Simulated Ubuntu/Debian systems (real update-clean.sh) ===\n'
printf 'script: %s\nwork:   %s\n\n' "$UC" "$SIM"

# 1) Ubuntu 22.04 identity
out="$SIM/01-jammy-version.txt"
rc=0
run_as "$SIM/os-ubuntu-2204" "$out" --version || rc=$?
expect_rc "jammy --version exit" "$rc" 0
expect_grep "jammy pretty name" "$out" "Ubuntu 22.04"
expect_grep "jammy version id" "$out" "update-clean 1\.5"

# 2) Ubuntu 24.04 --check
out="$SIM/02-noble-check.txt"
rc=0
run_as "$SIM/os-ubuntu-2404" "$out" --check --offline || rc=$?
expect_rc "noble --check exit" "$rc" 0
expect_grep "noble distro" "$out" "Ubuntu 24.04"
expect_grep "noble archive" "$out" "archive.ubuntu.com"
expect_grep "noble tools" "$out" "Required tools: OK"

# 3) Debian 12 --check
out="$SIM/03-bookworm-check.txt"
rc=0
run_as "$SIM/os-debian-12" "$out" --check --offline || rc=$?
expect_rc "bookworm --check exit" "$rc" 0
expect_grep "bookworm distro" "$out" "Debian GNU/Linux 12"
expect_grep "bookworm archive" "$out" "deb.debian.org"

# 4) Ubuntu 22.04 dry-run (no kernel touch)
out="$SIM/04-jammy-dryrun.txt"
rc=0
run_as "$SIM/os-ubuntu-2204" "$out" --dry-run --offline --no-kernel || rc=$?
expect_rc "jammy dry-run exit" "$rc" 0
expect_grep "jammy dry-run banner" "$out" "DRY RUN MODE ENABLED"
expect_grep "jammy skip kernel" "$out" "Skipping old kernel removal"
expect_grep "jammy would upgrade" "$out" "DRY-RUN: would run: apt-get -y upgrade|Would run: apt-get"
expect_grep "jammy preview note" "$out" "first 40 lines|DRY-RUN preview"

# 5) --check --offline either order on noble
out="$SIM/05-order.txt"
rc=0
run_as "$SIM/os-ubuntu-2404" "$out" --offline --check || rc=$?
expect_rc "offline then check" "$rc" 0
expect_grep "offline skipped" "$out" "SKIPPED \\(--offline\\)"

# 6) hidden --keep-kernels still works
out="$SIM/06-keep.txt"
rc=0
run_as "$SIM/os-ubuntu-2204" "$out" --keep-kernels 2 --check --offline || rc=$?
expect_rc "keep-kernels compat" "$rc" 0

# 7) --last
out="$SIM/07-last.txt"
rc=0
run_as "$SIM/os-ubuntu-2204" "$out" --last || rc=$?
expect_rc "last exit" "$rc" 0

# 8) reboot-required already present (dry-run must not reboot)
: >"$SIM/reboot-required"
out="$SIM/08-reboot.txt"
rc=0
run_as "$SIM/os-ubuntu-2404" "$out" --dry-run --offline --no-kernel || rc=$?
rm -f "$SIM/reboot-required"
expect_rc "reboot-required dry-run exit" "$rc" 0
expect_grep "pre-existing reboot flag" "$out" "already present before this run"
expect_grep "reboot required warning" "$out" "Reboot is required"
expect_no_grep "did not reboot" "$out" "rebooting now"

# 9) instance lock
out="$SIM/09-lock.txt"
exec 9>"$SIM/update-clean.lock"
if flock -n 9; then
    rc=0
    run_as "$SIM/os-ubuntu-2204" "$out" --dry-run --offline --no-kernel || rc=$?
    flock -u 9 || true
    exec 9>&- || true
    expect_rc "lock conflict exit" "$rc" 1
    expect_grep "already running" "$out" "already running"
else
    printf '  FAIL  could not take test lock\n'
    FAIL=$((FAIL + 1))
fi

printf '\n=== %s passed, %s failed ===\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
    printf '\n--- artifacts in %s ---\n' "$SIM"
    exit 1
fi
exit 0
