#!/usr/bin/env bash
set -e

REPO=/home/iceroot/Projects/debian_ubuntu_update_clean

git config --global --add safe.directory "$REPO"
cd "$REPO"
git add -A
git commit -m "feat: v1.2.0 robustness, failure tracking, and repo consolidation" || true
git push origin main
git log -1 --oneline
./update-clean.sh --version