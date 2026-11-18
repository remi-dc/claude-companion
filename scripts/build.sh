#!/bin/sh
# Builds build/Claude Companion.app.
#   --install     copy it to /Applications and launch it
#   --universal   build for Apple Silicon and Intel (used for releases)
#   --zip         also write build/ClaudeCompanion.zip (used for releases)
set -e
cd "$(dirname "$0")/.."

INSTALL=0; UNIVERSAL=0; ZIP=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --universal) UNIVERSAL=1 ;;
    --zip) ZIP=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

swift build -c release
BIN="$(swift build -c release --show-bin-path)/ClaudeCompanion"
if [ "$UNIVERSAL" = 1 ]; then
  # Build Intel separately and merge (a one-step universal build needs full Xcode).
  swift build -c release --triple x86_64-apple-macosx14.0 --scratch-path .build/intel
  INTEL="$(swift build -c release --triple x86_64-apple-macosx14.0 --scratch-path .build/intel --show-bin-path)/ClaudeCompanion"
  mkdir -p build
  lipo -create "$BIN" "$INTEL" -output build/ClaudeCompanion-universal
  BIN_OUT=build/ClaudeCompanion-universal
else
  BIN_OUT="$BIN"
fi

APP="build/Claude Companion.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_OUT" "$APP/Contents/MacOS/ClaudeCompanion"
cp Resources/Info.plist "$APP/Contents/Info.plist"
rm -rf build/AppIcon.iconset
"$BIN" render-icon build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
xattr -cr "$APP"
codesign --force --deep --sign - "$APP"
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/ClaudeCompanion"))"

if [ "$ZIP" = 1 ]; then
  rm -f build/ClaudeCompanion.zip
  ditto -c -k --keepParent "$APP" build/ClaudeCompanion.zip
  echo "Wrote build/ClaudeCompanion.zip"
fi

if [ "$INSTALL" = 1 ]; then
  pkill -x ClaudeCompanion 2>/dev/null && sleep 1 || true
  rm -rf "/Applications/Claude Companion.app"
  cp -R "$APP" /Applications/
  open "/Applications/Claude Companion.app"
  echo "Installed to /Applications and launched."
fi
