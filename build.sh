#!/bin/bash
# Builds "Trigger Lab.app" next to this script. Run with:  bash build.sh
set -euo pipefail
cd "$(dirname "$0")"

APP="Trigger Lab.app"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "Swift isn't installed yet. Run this first, then try again:"
  echo "  xcode-select --install"
  exit 1
fi

echo "Building Trigger Lab..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 -parse-as-library \
  -target arm64-apple-macos13.0 \
  -framework SwiftUI -framework GameController -framework AppKit -framework IOKit \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/TriggerLab"

cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "Done. Open it with:  open \"$APP\""
echo "Tip: drag \"$APP\" into your Applications folder to keep it."
