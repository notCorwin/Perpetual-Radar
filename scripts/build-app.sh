#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."

npm run build
swift build -c release

app="$PWD/.build/app/Perpetual Radar.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp ".build/release/PerpetualRadar" "$app/Contents/MacOS/PerpetualRadar"
cp macos/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
iconset="$PWD/.build/icon-assets/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$iconset"
iconutil -c iconset macos/AppIcon.icns -o "$PWD/.build/icon-assets/AppIcon.iconset"
cp "$PWD/.build/icon-assets/AppIcon.iconset/"*.png "$iconset/"
cp macos/AppIconContents.json "$iconset/Contents.json"
compiled="$PWD/.build/icon-assets/compiled"
mkdir -p "$compiled"
xcrun actool --compile "$compiled" --platform macosx --minimum-deployment-target 14.0 --app-icon AppIcon --output-partial-info-plist "$PWD/.build/icon-assets/Info.plist" "$PWD/.build/icon-assets/Assets.xcassets"
cp "$compiled/Assets.car" "$app/Contents/Resources/Assets.car"
rm -rf "$app/Contents/Resources/Web"
ditto dist "$app/Contents/Resources/Web"
cp macos/Info.plist "$app/Contents/Info.plist"
printf 'APPL????' > "$app/Contents/PkgInfo"
helper="$app/Contents/Library/LoginItems/Perpetual Radar Monitor.app"
mkdir -p "$helper/Contents/MacOS" "$helper/Contents/Resources"
cp ".build/release/PerpetualRadar" "$helper/Contents/MacOS/PerpetualRadar"
cp macos/AppIcon.icns "$helper/Contents/Resources/AppIcon.icns"
cp macos/Monitor-Info.plist "$helper/Contents/Info.plist"
printf 'APPL????' > "$helper/Contents/PkgInfo"
revision="${APP_REVISION:-$(git rev-parse HEAD 2>/dev/null || true)}"
if [[ -n "$revision" ]]; then
  /usr/libexec/PlistBuddy -c "Add :CFBundleSourceRevision string $revision" "$app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleSourceRevision string $revision" "$helper/Contents/Info.plist"
fi
codesign --force --sign - "$helper" >/dev/null
codesign --force --sign - "$app" >/dev/null
touch "$app"
if [[ -z "${CI:-}" ]]; then
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$app"
fi
echo "$app"
