#!/bin/bash
# Installs NotchFaceID + pam_notchfaceid.so for `sudo` via /etc/pam.d/sudo_local.
#
# Modes:
#   ./Scripts/install-sudo.sh          # Production: root-owned /Applications/NotchFaceID.app + pinned cert + protected templates
#   ./Scripts/install-sudo.sh --dev    # Dev test: allows running from build/NotchFaceID.app (adds `allow_dev` PAM option)
#
# Always keeps password authentication (`pam_opendirectory.so`) right after `sudo_local`.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEV_MODE=0
CERT_NAME="${CERT_NAME:-NotchFaceID Local Signing}"
TIMEOUT="${TIMEOUT:-5}"

for arg in "$@"; do
    case "$arg" in
        --dev) DEV_MODE=1 ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

APP_SRC="$ROOT/build/NotchFaceID.app"
PAM_SRC="$ROOT/build/pam_notchfaceid.so"
PAM_DST="/usr/local/lib/pam/pam_notchfaceid.so"
APP_DST="/Applications/NotchFaceID.app"
SYS_SUPPORT="/Library/Application Support/NotchFaceID"
REQ_FILE="$SYS_SUPPORT/code_requirement"
USER_TEMPLATE="$HOME/Library/Application Support/NotchFaceID/faces"
SUDO_LOCAL="/etc/pam.d/sudo_local"
AGENT_PLIST="$HOME/Library/LaunchAgents/local.notchfaceid.plist"

if [ ! -d "$APP_SRC" ] || [ ! -f "$PAM_SRC" ]; then
    echo "error: build artifacts missing. Run ./build.sh first." >&2
    exit 1
fi

echo "==> Installing PAM module -> $PAM_DST"
sudo mkdir -p /usr/local/lib/pam
sudo install -m 0644 -o root -g wheel "$PAM_SRC" "$PAM_DST"

if [ "$DEV_MODE" -eq 0 ]; then
    echo "==> Installing app -> $APP_DST (root:wheel, tamper-protected)"
    sudo rm -rf "$APP_DST"
    sudo ditto "$APP_SRC" "$APP_DST"
    sudo chown -R root:wheel "$APP_DST"
    sudo chmod -R go-w "$APP_DST"

    echo "==> Setting up root-owned support dir -> $SYS_SUPPORT"
    sudo mkdir -p "$SYS_SUPPORT"
    sudo chown root:wheel "$SYS_SUPPORT"
    sudo chmod 0755 "$SYS_SUPPORT"

    if security find-identity -v -p codesigning | grep -Fq "\"$CERT_NAME\""; then
        printf 'identifier "local.notchfaceid" and certificate leaf[subject.CN] = "%s"\n' "$CERT_NAME" \
            | sudo tee "$REQ_FILE" >/dev/null
        sudo chown root:wheel "$REQ_FILE"
        sudo chmod 0644 "$REQ_FILE"
        echo "    Pinned code requirement written to $REQ_FILE"
    else
        echo "    Note: \"$CERT_NAME\" cert not found; using default identifier check."
        echo "    Run ./Scripts/setup-codesign.sh for stronger certificate pinning."
    fi

    if [ -f "$USER_TEMPLATE" ]; then
        echo "==> Promoting enrolled face template -> $SYS_SUPPORT/faces (root:staff 0640)"
        sudo install -m 0640 -o root -g staff "$USER_TEMPLATE" "$SYS_SUPPORT/faces"
    else
        echo "    Note: no enrolled template found yet at $USER_TEMPLATE."
        echo "    Enroll in NotchFaceID first, then re-run to promote to $SYS_SUPPORT/faces."
    fi

    echo "==> Installing LaunchAgent -> $AGENT_PLIST"
    mkdir -p "$HOME/Library/LaunchAgents"
    cat > "$AGENT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>local.notchfaceid</string>
	<key>ProgramArguments</key>
	<array>
		<string>/Applications/NotchFaceID.app/Contents/MacOS/NotchFaceID</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
</dict>
</plist>
EOF
    launchctl bootout "gui/$(id -u)" "$AGENT_PLIST" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST"
fi

echo "==> Configuring $SUDO_LOCAL (backing up existing file if present)"
if [ -f "$SUDO_LOCAL" ] && [ ! -f "$SUDO_LOCAL.notchfaceid.bak" ]; then
    sudo cp "$SUDO_LOCAL" "$SUDO_LOCAL.notchfaceid.bak"
fi

PAM_OPTS="timeout=$TIMEOUT"
if [ "$DEV_MODE" -eq 1 ]; then
    PAM_OPTS="$PAM_OPTS allow_dev debug"
fi

{
    printf '# NotchFaceID PAM config (rollback: ./Scripts/uninstall-sudo.sh)\n'
    printf 'auth       sufficient     %s %s\n' "$PAM_DST" "$PAM_OPTS"
    if [ -f "$SUDO_LOCAL.notchfaceid.bak" ]; then
        grep -v 'pam_notchfaceid.so' "$SUDO_LOCAL.notchfaceid.bak" || true
    fi
} | sudo tee "$SUDO_LOCAL" >/dev/null

echo ""
echo "Installation complete!"
echo "Test in a NEW terminal (keep this terminal open as backup):"
echo "  sudo -k && sudo true"
echo "Rollback anytime:"
echo "  $ROOT/Scripts/uninstall-sudo.sh"
