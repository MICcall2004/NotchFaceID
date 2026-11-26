#!/bin/bash
# Builds build/NotchFaceID.app and PAM modules (build/pam_test.so, build/pam_notchfaceid.so),
# then runs the self-check.
#
# Optional signing:
#   SIGN_IDENTITY="NotchFaceID Local Signing" ./build.sh
# Signs the app with Hardened Runtime + camera entitlement so TCC camera permissions persist
# across rebuilds and pam_notchfaceid.so can verify the app's code signature.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/NotchFaceID.app
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
PAM_ARCH="${PAM_ARCH:-arm64}"

# Resolve toolchain cleanly (works with Xcode or CommandLineTools even when xcrun link is restricted).
if [ -x /Library/Developer/CommandLineTools/usr/bin/swiftc ] && [ -d /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk ]; then
    SWIFTC="${SWIFTC:-/Library/Developer/CommandLineTools/usr/bin/swiftc}"
    CLANG="${CLANG:-/Library/Developer/CommandLineTools/usr/bin/clang}"
    SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk}"
else
    SWIFTC="${SWIFTC:-swiftc}"
    CLANG="${CLANG:-clang}"
    SDK="${SDKROOT:-$(xcrun --show-sdk-path)}"
fi

mkdir -p "$APP/Contents/MacOS" build
cp Resources/Info.plist "$APP/Contents/"
if [ -d Resources/Models ]; then
    rm -rf "$APP/Contents/Resources" && mkdir -p "$APP/Contents/Resources" && cp -R Resources/Models "$APP/Contents/Resources/"
fi

MODULE_CACHE="${CLANG_MODULE_CACHE_PATH:-/tmp/notchfaceid-module-cache}"
mkdir -p "$MODULE_CACHE"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"

"$SWIFTC" -O -sdk "$SDK" -module-cache-path "$MODULE_CACHE" Sources/*.swift -o "$APP/Contents/MacOS/NotchFaceID"

# Build PAM PoC and production PAM module (arm64: macOS rejects non-Apple arm64e binaries unless SIP is disabled).
if [ -f PAM/pam_test.c ]; then
    "$CLANG" -O2 -Wall -Wextra -arch "$PAM_ARCH" -isysroot "$SDK" -fmodules-cache-path="$MODULE_CACHE" -dynamiclib \
        PAM/pam_test.c -lpam -o build/pam_test.so
fi

if [ -f PAM/pam_notchfaceid.c ]; then
    "$CLANG" -O2 -Wall -Wextra -arch "$PAM_ARCH" -isysroot "$SDK" -fmodules-cache-path="$MODULE_CACHE" -dynamiclib \
        PAM/pam_notchfaceid.c -lpam \
        -framework CoreFoundation -framework Security -framework IOKit -framework ApplicationServices \
        -o build/pam_notchfaceid.so
fi

# Code signing
if [ "$SIGN_IDENTITY" = "-" ]; then
    # Ad-hoc signature: macOS ties camera permission to it, so a rebuild can ask again.
    codesign --force -s - "$APP"
    [ -f build/pam_test.so ] && codesign --force -s - build/pam_test.so
    [ -f build/pam_notchfaceid.so ] && codesign --force -s - build/pam_notchfaceid.so
else
    codesign --force --options runtime --entitlements Resources/NotchFaceID.entitlements -s "$SIGN_IDENTITY" "$APP"
    [ -f build/pam_test.so ] && codesign --force -s "$SIGN_IDENTITY" build/pam_test.so
    [ -f build/pam_notchfaceid.so ] && codesign --force -s "$SIGN_IDENTITY" build/pam_notchfaceid.so
fi

"$APP/Contents/MacOS/NotchFaceID" --selftest
