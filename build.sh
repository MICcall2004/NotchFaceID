#!/bin/bash
# Builds build/NotchFaceID.app, then runs its self-check.
set -euo pipefail
cd "$(dirname "$0")"
APP=build/NotchFaceID.app
mkdir -p "$APP/Contents/MacOS"
cp Resources/Info.plist "$APP/Contents/"
swiftc -O Sources/*.swift -o "$APP/Contents/MacOS/NotchFaceID"
# Ad-hoc signature: macOS ties the camera permission to it, so a rebuild can ask again.
codesign --force -s - "$APP"
"$APP/Contents/MacOS/NotchFaceID" --selftest
