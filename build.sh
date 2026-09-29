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

# Build for Apple Silicon and Intel, then join them into one app that runs on both.
BUILD="$(mktemp -d)"
for ARCH in arm64 x86_64; do
  swiftc -O -swift-version 5 -parse-as-library \
    -target "$ARCH-apple-macos13.0" \
    -framework SwiftUI -framework GameController -framework AppKit -framework IOKit \
    Sources/*.swift \
    -o "$BUILD/TriggerLab-$ARCH"
done
lipo -create "$BUILD/TriggerLab-arm64" "$BUILD/TriggerLab-x86_64" -output "$APP/Contents/MacOS/TriggerLab"
rm -rf "$BUILD"

cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "Done. Open it with:  open \"$APP\""
echo "Tip: drag \"$APP\" into your Applications folder to keep it."
