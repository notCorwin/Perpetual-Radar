#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."

npm run build
swift build -c release

app="$PWD/.build/app/Perpetual Radar.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp ".build/release/PerpetualRadar" "$app/Contents/MacOS/PerpetualRadar"
cp macos/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
rm -rf "$app/Contents/Resources/Web"
ditto dist "$app/Contents/Resources/Web"
cp macos/Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app" >/dev/null
echo "$app"
