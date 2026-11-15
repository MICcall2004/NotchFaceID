#!/bin/bash
# Builds NotchFaceID.app next to this script, then runs its self-check.
set -euo pipefail
cd "$(dirname "$0")"
APP=NotchFaceID.app
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/"
swiftc -O main.swift -o "$APP/Contents/MacOS/NotchFaceID"
# Ad-hoc signature: macOS ties the camera permission to it, so a rebuild can ask again.
codesign --force -s - "$APP"
"$APP/Contents/MacOS/NotchFaceID" --selftest
