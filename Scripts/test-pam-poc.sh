#!/bin/bash
# Safe PoC runner for build/pam_test.so on macOS sudo_local.
# Installs pam_test.so (which only logs and returns PAM_IGNORE), tests `sudo true`,
# prints unified log verification + `/usr/bin/sudo` architecture, and ALWAYS rolls back on exit.
set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
    echo "error: run this as your normal user, not with sudo/root." >&2
    exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PAM_SO="$ROOT/build/pam_test.so"
DST="/usr/local/lib/pam/pam_test.so"
SUDO_LOCAL="/etc/pam.d/sudo_local"
BACKUP=""

if [ ! -f "$PAM_SO" ] || [ -L "$PAM_SO" ]; then
    echo "error: $PAM_SO not found (or is a symlink). Run ./build.sh first." >&2
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
# Read as the user, write as root, so root never opens a user-controlled path.
sudo sh -c 'umask 022; cat > "$1"' _ "$DST" < "$PAM_SO"
sudo chown root:wheel "$DST"
sudo chmod 0644 "$DST"

if [ -f "$SUDO_LOCAL" ]; then
    # Keep the backup in root-owned /etc/pam.d: cleanup moves it back as root, so a user-writable
    # copy (in /tmp or $TMPDIR) would let any user process rewrite sudo's PAM config.
    BACKUP="$SUDO_LOCAL.notchfaceid-poc.bak"
    sudo cp -p "$SUDO_LOCAL" "$BACKUP"
fi

printf 'auth       optional       %s\n' "$DST" | sudo tee "$SUDO_LOCAL" >/dev/null

echo "==> Running 'sudo -k && sudo true' (enter your password to test normal fallback)..."
sudo -k && sudo true

echo "==> Checking macOS unified logs for pam_test invocation:"
log show --last 1m --predicate 'subsystem == "local.notchfaceid.pam"' --info || true
