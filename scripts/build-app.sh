#!/bin/bash
# Build Glide.app: release build -> .app bundle -> codesign with the stable local identity.
# Usage: scripts/build-app.sh [--install]   (--install copies to /Applications and launches)
#
# Signing: the self-signed identity in ~/.glide-signing (scripts/make-signing-identity.sh) keeps the
# designated requirement identical across rebuilds, so macOS keeps the Accessibility grant.
# Falls back to ad-hoc (grant resets on every rebuild) when the identity is missing.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Glide"
APP="build/Glide.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Glide"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

KC="$HOME/.glide-signing/glide.keychain-db"
if [ -f "$KC" ]; then
  security unlock-keychain -p "$(cat "$HOME/.glide-signing/pass")" "$KC"
  ID=$(security find-identity -p codesigning "$KC" | awk '/Glide Local Signing/ {print $2; exit}')
  codesign --force --sign "$ID" --keychain "$KC" --identifier com.melvern.glide "$APP"
else
  echo "warning: no local signing identity, using ad-hoc (Accessibility grant will reset)"
  codesign --force --sign - --identifier com.melvern.glide "$APP"
fi
codesign -dr - "$APP" 2>&1 | grep designated || true
echo "built $APP"

if [ "${1:-}" = "--install" ]; then
  pkill -x Glide || true
  sleep 1
  rm -rf /Applications/Glide.app
  cp -R "$APP" /Applications/
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Glide.app || true
  open /Applications/Glide.app
  echo "installed /Applications/Glide.app"
fi
