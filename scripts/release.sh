#!/bin/sh
# Publishes a new version: everyone running Claude Companion is offered the update in the app.
#   ./scripts/release.sh 1.1.0 "What's new, in one line"
# Sets the version, builds the universal app, commits, pushes and creates the GitHub release.
set -e
cd "$(dirname "$0")/.."

V="$1"; NOTES="$2"
echo "$V" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || { echo "Usage: $0 X.Y.Z [\"release notes\"]" >&2; exit 2; }
command -v gh >/dev/null 2>&1 || { echo "Needs the GitHub CLI (brew install gh), logged in with: gh auth login" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "Commit or stash your changes first." >&2; exit 1; }

git fetch -q origin
if [ -n "$(git rev-list HEAD..origin/main)" ]; then echo "origin/main has commits you don't have: pull first." >&2; exit 1; fi
if gh release view "v$V" >/dev/null 2>&1; then echo "Release v$V already exists." >&2; exit 1; fi

CUR=$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)
if [ "$CUR" = "$V" ] || [ "$(printf '%s\n%s\n' "$CUR" "$V" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)" != "$V" ]; then
  echo "New version must be higher than the current $CUR." >&2; exit 1
fi
BUILD=$(( $(plutil -extract CFBundleVersion raw Resources/Info.plist) + 1 ))

echo "▸ Releasing $CUR → $V (build $BUILD)"
plutil -replace CFBundleShortVersionString -string "$V" Resources/Info.plist
plutil -replace CFBundleVersion -string "$BUILD" Resources/Info.plist

./scripts/build.sh --universal --zip

git commit -q -am "Release v$V"
git push -q origin HEAD:main
if [ -n "$NOTES" ]; then
  gh release create "v$V" build/ClaudeCompanion.zip --title "Claude Companion $V" --notes "$NOTES"
else
  gh release create "v$V" build/ClaudeCompanion.zip --title "Claude Companion $V" --generate-notes
fi
echo "▸ Done. Running apps will offer v$V within a few hours (or right away via Settings › Setup › Check for updates)."
