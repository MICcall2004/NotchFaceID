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

if [ "$(id -u)" -eq 0 ]; then
    echo "error: run this as your normal user, not with sudo/root." >&2
    echo "       The script calls sudo itself and installs into your \$HOME." >&2
    exit 1
fi

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
# Root reads these paths during install; never let a planted symlink redirect that read.
if [ -L "$APP_SRC" ] || [ -L "$PAM_SRC" ]; then
    echo "error: build artifacts must be real files/directories, not symlinks." >&2
    exit 1
fi

# Refuse to install through a symlink planted in a path root will write.
for path in "$APP_DST" "$SYS_SUPPORT" "$REQ_FILE" "$PAM_DST" "$AGENT_PLIST"; do
    if [ -L "$path" ]; then
        echo "error: $path is a symlink; refusing to install through it." >&2
        exit 1
    fi
done

# Validate the user's enrollment before any sudo call. Root must never open a user-controlled
# path: a symlink to a root-only file (e.g. a password hash plist) would otherwise be copied
# to a staff-readable location. Read as the user; hand root only the validated bytes.
check_user_template() {
    local path="$1"
    [ -e "$path" ] || [ -L "$path" ] || return 0  # not enrolled yet: allowed
    if [ -L "$path" ]; then
        echo "error: $path is a symlink; refusing to use it." >&2
        return 1
    fi
    if [ ! -f "$path" ]; then
        echo "error: $path is not a regular file." >&2
        return 1
    fi
    if [ "$(stat -f '%u' "$path")" != "$(id -u)" ]; then
        echo "error: $path is not owned by $(id -un)." >&2
        return 1
    fi
    local mode
    mode="$(stat -f '%Mp%Lp' "$path")"
    if [ $((8#$mode & 8#022)) -ne 0 ]; then
        echo "error: $path is group/world-writable ($mode)." >&2
        return 1
    fi
    if ! plutil -extract model raw -o - "$path" 2>/dev/null | grep -qx 'SFace-2021dec'; then
        echo "error: $path is not a current SFace template. Enroll again in NotchFaceID first." >&2
        return 1
    fi
    if ! plutil -extract embeddings json -o - "$path" 2>/dev/null | python3 -c '
import json, math, sys
e = json.load(sys.stdin)
assert isinstance(e, list) and e
assert all(isinstance(v, list) and len(v) == 128 for v in e)
assert all(all(isinstance(x, (int, float)) and math.isfinite(x) for x in v) for v in e)
assert all(0.5 <= math.sqrt(sum(x * x for x in v)) <= 2 for v in e)
'; then
        echo "error: $path contains invalid embeddings." >&2
        return 1
    fi
}

check_user_template "$USER_TEMPLATE" || exit 1

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
# Read as the user, write as root (same reason as the template below).
sudo sh -c 'umask 022; cat > "$1"' _ "$PAM_DST" < "$PAM_SRC"
sudo chown root:wheel "$PAM_DST"
sudo chmod 0644 "$PAM_DST"

echo "==> Installing app -> $APP_DST (root:wheel, tamper-protected)"
# Stage under a fresh path so root's ditto never writes through a planted symlink at the destination.
sudo rm -rf "$APP_DST.new"
sudo ditto "$APP_SRC" "$APP_DST.new"
sudo chown -R root:wheel "$APP_DST.new"
sudo chmod -R go-w "$APP_DST.new"
sudo rm -rf "$APP_DST"
sudo mv "$APP_DST.new" "$APP_DST"
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
    # Read as the user, write as root: root never opens the user-controlled source path.
    sudo sh -c 'umask 077; cat > "$1"' _ "$SYS_SUPPORT/faces.tmp" < "$USER_TEMPLATE"
    sudo chown root:staff "$SYS_SUPPORT/faces.tmp"
    sudo chmod 0640 "$SYS_SUPPORT/faces.tmp"
    sudo mv -f "$SYS_SUPPORT/faces.tmp" "$SYS_SUPPORT/faces"
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
