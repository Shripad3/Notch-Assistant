#!/usr/bin/env bash
# Builds NotchAssistant.app into ~/Applications (override with APP_DIR) and
# signs it.
#
# Not built inside the project: this folder is in iCloud Drive, whose file
# provider keeps re-adding a Finder attribute that codesign refuses.
#
# Signing with a stable identity (the Apple Development certificate) keeps
# Microphone and Speech Recognition grants across rebuilds; an ad-hoc
# signature changes every build and macOS asks again each time.
#
# Usage: scripts/build-app.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."

config="${1:-debug}"
swift build -c "$config" --product NotchAssistant
bin="$(swift build -c "$config" --show-bin-path)/NotchAssistant"

app="${APP_DIR:-$HOME/Applications}/NotchAssistant.app"
mkdir -p "$(dirname "$app")"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin" "$app/Contents/MacOS/NotchAssistant"
cp Resources/Info.plist "$app/Contents/Info.plist"
mkdir -p "$app/Contents/Resources/WakeWord"
cp Resources/WakeWord/*.onnx "$app/Contents/Resources/WakeWord/"

identity="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }')}"
if [[ -z "$identity" ]]; then
  echo "warning: no Apple Development identity; signing ad hoc (permissions will re-prompt after each build)" >&2
  identity="-"
fi
# Copied files can carry extended attributes that codesign rejects.
xattr -cr "$app"
codesign --force --sign "$identity" "$app"
echo "built $app (signed: $identity)"
