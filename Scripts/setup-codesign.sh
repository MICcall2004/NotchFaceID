#!/bin/bash
# Creates a self-signed local Code Signing certificate ("NotchFaceID Local Signing")
# and imports it into the login Keychain so:
#   1. Rebuilds keep macOS TCC camera & Accessibility permissions intact.
#   2. pam_notchfaceid.so can pin the exact signing certificate via SecRequirement.
#
# After running this script, rebuild with:
#   SIGN_IDENTITY="NotchFaceID Local Signing" ./build.sh
set -euo pipefail

CERT_NAME="${CERT_NAME:-NotchFaceID Local Signing}"
TMPDIR_CERT="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_CERT"' EXIT

if security find-identity -v -p codesigning | grep -Fq "\"$CERT_NAME\""; then
    echo "Certificate \"$CERT_NAME\" already exists in Keychain."
    exit 0
fi

cat > "$TMPDIR_CERT/cert.cfg" <<EOF
[ req ]
distinguished_name = dn
x509_extensions    = codesign_ext
prompt             = no

[ dn ]
CN = $CERT_NAME

[ codesign_ext ]
basicConstraints = CA:FALSE
keyUsage         = digitalSignature
extendedKeyUsage = codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMPDIR_CERT/key.pem" \
    -out "$TMPDIR_CERT/cert.pem" \
    -days 1825 \
    -config "$TMPDIR_CERT/cert.cfg" 2>/dev/null

P12_PASS="$(openssl rand -hex 16)"
openssl pkcs12 -export \
    -inkey "$TMPDIR_CERT/key.pem" \
    -in "$TMPDIR_CERT/cert.pem" \
    -out "$TMPDIR_CERT/cert.p12" \
    -passout "pass:$P12_PASS"

LOGIN_KC="$(security default-keychain -d user | tr -d '" ')"
security import "$TMPDIR_CERT/cert.p12" -k "$LOGIN_KC" -P "$P12_PASS" -T /usr/bin/codesign

echo "==> Trusting \"$CERT_NAME\" for code signing (may prompt for Keychain/admin password)..."
security add-trusted-cert -p codeSign -k "$LOGIN_KC" "$TMPDIR_CERT/cert.pem"

echo ""
echo "Done! Verify with:"
echo "  security find-identity -v -p codesigning"
echo "Then build with:"
echo "  SIGN_IDENTITY=\"$CERT_NAME\" ./build.sh"
