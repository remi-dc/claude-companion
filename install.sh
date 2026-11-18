#!/bin/sh
# Claude Companion installer.
#   curl -fsSL https://raw.githubusercontent.com/remi-dc/claude-companion/main/install.sh | sh
#
# Downloads the latest release, installs it in /Applications (or ~/Applications) and launches it.
# If no release can be downloaded, it builds from source instead (needs Xcode Command Line Tools).
set -e

REPO="remi-dc/claude-companion"
APP_NAME="Claude Companion.app"
ZIP_URL="${CLAUDE_COMPANION_ZIP_URL:-https://github.com/$REPO/releases/latest/download/ClaudeCompanion.zip}"
NO_LAUNCH="${CLAUDE_COMPANION_NO_LAUNCH:-}"   # for testing: don't quit or launch anything

say()  { printf '\033[1;38;5;209m▸\033[0m %s\n' "$1"; }
fail() { printf '\033[1;31m✗\033[0m %s\n' "$1" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "Claude Companion runs on macOS only."
MAJOR=$(sw_vers -productVersion | cut -d. -f1)
[ "$MAJOR" -ge 14 ] || fail "Claude Companion needs macOS 14 (Sonoma) or later. You have $(sw_vers -productVersion)."

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

say "Downloading Claude Companion…"
if curl -fsSL "$ZIP_URL" -o "$TMP/app.zip" && ditto -x -k "$TMP/app.zip" "$TMP/unzipped" 2>/dev/null \
   && [ -d "$TMP/unzipped/$APP_NAME" ]; then
  SRC="$TMP/unzipped/$APP_NAME"
else
  say "No release download available, building from source instead…"
  command -v git >/dev/null 2>&1 && xcrun --find swift >/dev/null 2>&1 \
    || fail "Building needs the Xcode Command Line Tools. Run: xcode-select --install, then run this installer again."
  git clone --depth 1 -q "https://github.com/$REPO.git" "$TMP/src"
  (cd "$TMP/src" && ./scripts/build.sh >/dev/null)
  SRC="$TMP/src/build/$APP_NAME"
fi

# /Applications if writable, otherwise ~/Applications (no sudo needed).
DEST="${CLAUDE_COMPANION_DEST:-/Applications}"
if [ ! -w "$DEST" ]; then DEST="$HOME/Applications"; mkdir -p "$DEST"; fi

if [ -z "$NO_LAUNCH" ] && pgrep -x ClaudeCompanion >/dev/null 2>&1; then
  say "Quitting the running version…"
  pkill -x ClaudeCompanion || true
  sleep 1
fi

say "Installing to ${DEST}…"
rm -rf "$DEST/$APP_NAME"
ditto "$SRC" "$DEST/$APP_NAME"
# The app is not notarized; downloads made with curl aren't quarantined, but clear it just in case.
xattr -dr com.apple.quarantine "$DEST/$APP_NAME" 2>/dev/null || true

[ -n "$NO_LAUNCH" ] || open "$DEST/$APP_NAME"

say "Done! Look for the chat-bubble icon in your menu bar."
cat <<'EOF'

  Next steps (about a minute):
   1. Allow notifications when macOS asks.
   2. Click the menu bar icon, then "Install" in the orange banner.
   3. Start a new Claude Code session. That's it.

  Optional, in Settings › Setup: account switching for the `claude` command and VS Code.

EOF
