#!/bin/bash
# Clean rollback for NotchFaceID sudo PAM integration.
# Restores /etc/pam.d/sudo_local, removes PAM .so files, and unloads LaunchAgent.
# Pass `--purge` to also remove /Applications/NotchFaceID.app and /Library/Application Support/NotchFaceID.
set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
    echo "error: run this as your normal user, not with sudo/root." >&2
    exit 1
fi

PURGE=0
for arg in "$@"; do
    case "$arg" in
        --purge) PURGE=1 ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

SUDO_LOCAL="/etc/pam.d/sudo_local"
AGENT_PLIST="$HOME/Library/LaunchAgents/local.notchfaceid.plist"

echo "==> Restoring $SUDO_LOCAL"
if [ -f "$SUDO_LOCAL.notchfaceid.bak" ]; then
    sudo mv "$SUDO_LOCAL.notchfaceid.bak" "$SUDO_LOCAL"
else
    sudo rm -f "$SUDO_LOCAL"
fi

echo "==> Removing PAM modules"
sudo rm -f /usr/local/lib/pam/pam_notchfaceid.so /usr/local/lib/pam/pam_test.so

if [ -f "$AGENT_PLIST" ]; then
    echo "==> Unloading and removing LaunchAgent"
    launchctl bootout "gui/$(id -u)" "$AGENT_PLIST" 2>/dev/null || true
    rm -f "$AGENT_PLIST"
fi

if [ "$PURGE" -eq 1 ]; then
    echo "==> Purging /Applications/NotchFaceID.app and /Library/Application Support/NotchFaceID"
    sudo rm -rf /Applications/NotchFaceID.app "/Library/Application Support/NotchFaceID"
fi

echo "Rollback complete. Verify with: sudo -k && sudo true"
