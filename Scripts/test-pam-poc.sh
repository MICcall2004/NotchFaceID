#!/bin/bash
# Safe PoC runner for build/pam_test.so on macOS sudo_local.
# Installs pam_test.so (which only logs and returns PAM_IGNORE), tests `sudo true`,
# prints unified log verification + `/usr/bin/sudo` architecture, and ALWAYS rolls back on exit.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PAM_SO="$ROOT/build/pam_test.so"
DST="/usr/local/lib/pam/pam_test.so"
SUDO_LOCAL="/etc/pam.d/sudo_local"
BACKUP=""

if [ ! -f "$PAM_SO" ]; then
    echo "error: $PAM_SO not found. Run ./build.sh first." >&2
    exit 1
fi

cleanup() {
    echo ""
    echo "==> Rolling back PoC changes..."
    sudo rm -f "$DST"
    if [ -n "$BACKUP" ] && [ -f "$BACKUP" ]; then
        sudo mv "$BACKUP" "$SUDO_LOCAL"
    else
        sudo rm -f "$SUDO_LOCAL"
    fi
    echo "==> Rollback complete."
}
trap cleanup EXIT

echo "==> Checking /usr/bin/sudo architecture:"
sudo file /usr/bin/sudo

echo "==> Installing $PAM_SO -> $DST"
sudo mkdir -p /usr/local/lib/pam
sudo install -m 0644 -o root -g wheel "$PAM_SO" "$DST"

if [ -f "$SUDO_LOCAL" ]; then
    BACKUP="/tmp/sudo_local.poc.$$.bak"
    sudo cp "$SUDO_LOCAL" "$BACKUP"
fi

printf 'auth       optional       %s\n' "$DST" | sudo tee "$SUDO_LOCAL" >/dev/null

echo "==> Running 'sudo -k && sudo true' (enter your password to test normal fallback)..."
sudo -k && sudo true

echo "==> Checking macOS unified logs for pam_test invocation:"
log show --last 1m --predicate 'subsystem == "local.notchfaceid.pam"' --info || true
