#!/bin/zsh
# Build ClaudeVoice.app from source, assemble the bundle, and ad-hoc sign it
# (ad-hoc signing gives a stable code identity so macOS TCC remembers the
# Microphone / Speech / Accessibility grants between launches).
set -euo pipefail

APP="ClaudeVoice"
DIR="${0:A:h}"                 # this script's directory
BUILD="$DIR/build"
APPDIR="$BUILD/$APP.app"

echo "→ cleaning"
rm -rf "$APPDIR"
mkdir -p "$APPDIR/Contents/MacOS" "$APPDIR/Contents/Resources"

echo "→ Info.plist"
cp "$DIR/Info.plist" "$APPDIR/Contents/Info.plist"

echo "→ compiling (swiftc)"
swiftc \
  -O \
  -swift-version 5 \
  -target arm64-apple-macos26.0 \
  -framework AppKit -framework AVFoundation -framework Speech -framework ApplicationServices -framework SwiftUI \
  -o "$APPDIR/Contents/MacOS/$APP" \
  "$DIR/Sources/main.swift"

echo "→ ad-hoc codesign"
codesign --force --deep --sign - "$APPDIR"

echo "✓ built: $APPDIR"
