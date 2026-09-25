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
# A provisioning profile (Resources/NotchAssistant.provisionprofile, not in
# git: it holds this Mac's device ID) grants restricted entitlements such as
# WeatherKit. Without one, the app is signed without them and falls back.
profile="Resources/NotchAssistant.provisionprofile"
entitlements=()
if [[ -f "$profile" ]]; then
  work="$(mktemp -d)"
  cp "$profile" "$app/Contents/embedded.provisionprofile"
  security cms -D -i "$profile" > "$work/profile.plist"
  ent="$work/entitlements.plist"
  plutil -create xml1 "$ent"
  # Only what the app uses, copied from the profile. PlistBuddy, not plutil:
  # plutil reads the dots in these key names as a key path.
  for key in com.apple.application-identifier com.apple.developer.team-identifier; do
    value="$(/usr/libexec/PlistBuddy -c "Print :Entitlements:$key" "$work/profile.plist" 2>/dev/null)" || continue
    /usr/libexec/PlistBuddy -c "Add :$key string $value" "$ent"
  done
  if [[ "$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.developer.weatherkit" "$work/profile.plist" 2>/dev/null)" == "true" ]]; then
    /usr/libexec/PlistBuddy -c "Add :com.apple.developer.weatherkit bool true" "$ent"
  else
    echo "warning: the provisioning profile doesn't include WeatherKit" >&2
  fi
  entitlements=(--entitlements "$ent")
  echo "embedded $(/usr/libexec/PlistBuddy -c 'Print :Name' "$work/profile.plist") (expires $(/usr/libexec/PlistBuddy -c 'Print :ExpirationDate' "$work/profile.plist"))"
fi

# Copied files can carry extended attributes that codesign rejects.
xattr -cr "$app"
codesign --force --sign "$identity" ${entitlements[@]+"${entitlements[@]}"} "$app"
echo "built $app (signed: $identity)"
