#!/bin/bash
# Installs NotchFaceID + pam_notchfaceid.so for `sudo` via /etc/pam.d/sudo_local.
#
# Security requirements (enforced strictly — no ad-hoc/dev bypass):
#   1. A trusted local Code Signing certificate ("NotchFaceID Local Signing" by default).
#      Create once with: ./Scripts/setup-codesign.sh
#   2. build/NotchFaceID.app signed with that certificate (NOT ad-hoc):
#      SIGN_IDENTITY="NotchFaceID Local Signing" ./build.sh
#   3. Pins exact leaf certificate SHA-1 hash (`certificate leaf = H"<SHA-1>"`) in
#      /Library/Application Support/NotchFaceID/code_requirement (root:wheel 0644)
#      and verifies the installed /Applications/NotchFaceID.app against it before enabling PAM.
#
# Always keeps password authentication (`pam_opendirectory.so`) right after `sudo_local`.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CERT_NAME="${CERT_NAME:-NotchFaceID Local Signing}"
TIMEOUT="${TIMEOUT:-10}"

if [ $# -ne 0 ]; then
    echo "Usage: $0 (no flags; production hardened install only)" >&2
    exit 1
fi

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
    echo "error: build artifacts missing. Run SIGN_IDENTITY=\"$CERT_NAME\" ./build.sh first." >&2
    exit 1
fi

# Reject ad-hoc signed app builds: PAM requires a pinned certificate hash.
if codesign -dv "$APP_SRC" 2>&1 | grep -q '^Signature=adhoc$'; then
    echo "error: $APP_SRC is ad-hoc signed." >&2
    echo "Run ./Scripts/setup-codesign.sh once, then rebuild with:" >&2
    echo "  SIGN_IDENTITY=\"$CERT_NAME\" ./build.sh" >&2
    exit 1
fi

# Resolve exact 40-char SHA-1 fingerprint of the signing certificate leaf.
CERT_HASH="$(security find-identity -v -p codesigning | awk -v name="\"$CERT_NAME\"" 'index($0, name) { print $2; exit }')"
if ! [[ "$CERT_HASH" =~ ^[0-9A-Fa-f]{40}$ ]]; then
    echo "error: valid code-signing certificate \"$CERT_NAME\" not found in Keychain." >&2
    echo "Run ./Scripts/setup-codesign.sh first." >&2
    exit 1
fi

REQ_STR="identifier \"local.notchfaceid\" and certificate leaf = H\"$CERT_HASH\""

echo "==> Verifying $APP_SRC against pinned requirement:"
echo "    $REQ_STR"
codesign --verify --strict -R "=$REQ_STR" "$APP_SRC"

echo "==> Installing PAM module -> $PAM_DST"
sudo mkdir -p /usr/local/lib/pam
sudo install -m 0644 -o root -g wheel "$PAM_SRC" "$PAM_DST"

echo "==> Installing app -> $APP_DST (root:wheel, tamper-protected)"
sudo rm -rf "$APP_DST"
sudo ditto "$APP_SRC" "$APP_DST"
sudo chown -R root:wheel "$APP_DST"
sudo chmod -R go-w "$APP_DST"
codesign --verify --strict -R "=$REQ_STR" "$APP_DST"

echo "==> Writing root-owned pinned requirement -> $REQ_FILE"
sudo mkdir -p "$SYS_SUPPORT"
sudo chown root:wheel "$SYS_SUPPORT"
sudo chmod 0755 "$SYS_SUPPORT"
printf '%s\n' "$REQ_STR" | sudo tee "$REQ_FILE" >/dev/null
sudo chown root:wheel "$REQ_FILE"
sudo chmod 0644 "$REQ_FILE"

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

echo "==> Configuring $SUDO_LOCAL (backing up existing file if present)"
if [ -f "$SUDO_LOCAL" ] && [ ! -f "$SUDO_LOCAL.notchfaceid.bak" ]; then
    sudo cp "$SUDO_LOCAL" "$SUDO_LOCAL.notchfaceid.bak"
fi

{
    printf '# NotchFaceID PAM config (rollback: ./Scripts/uninstall-sudo.sh)\n'
    printf 'auth       sufficient     %s timeout=%s\n' "$PAM_DST" "$TIMEOUT"
    if [ -f "$SUDO_LOCAL.notchfaceid.bak" ]; then
        grep -v 'pam_notchfaceid.so' "$SUDO_LOCAL.notchfaceid.bak" || true
    fi
} | sudo tee "$SUDO_LOCAL" >/dev/null

echo ""
echo "Installation complete!"
echo "Test in a NEW terminal (keep this terminal open as backup):"
echo "  sudo -k && sudo true"
echo "When prompted, click the notch ('클릭해서 승인') to start face recognition."
echo "Rollback anytime:"
echo "  $ROOT/Scripts/uninstall-sudo.sh"
