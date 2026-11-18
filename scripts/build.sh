#!/bin/sh
# Builds build/Claude Companion.app. Pass --install to copy it to /Applications and launch it.
set -e
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/ClaudeCompanion"
APP="build/Claude Companion.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ClaudeCompanion"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"
echo "Built $APP"

if [ "$1" = "--install" ]; then
  pkill -x ClaudeCompanion 2>/dev/null || true
  rm -rf "/Applications/Claude Companion.app"
  cp -R "$APP" /Applications/
  open "/Applications/Claude Companion.app"
  echo "Installed to /Applications and launched."
fi
