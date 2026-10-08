#!/bin/zsh
# Builds TubeTunes.app into ./build (and optionally installs it to /Applications).
#   scripts/build-app.sh            build only
#   scripts/build-app.sh --install  build and copy to /Applications
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
APP=build/TubeTunes.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/TubeTunes "$APP/Contents/MacOS/TubeTunes"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [[ ! -f build/AppIcon.icns ]]; then
    ICONSET=build/AppIcon.iconset
    mkdir -p "$ICONSET"
    swift scripts/make-icon.swift build/icon-1024.png
    for s in 16 32 128 256 512; do
        sips -z $s $s build/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
        sips -z $((s*2)) $((s*2)) build/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - --identifier net.wesyarber.TubeTunes "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x TubeTunes || true
    rm -rf /Applications/TubeTunes.app
    cp -R "$APP" /Applications/
    echo "Installed to /Applications/TubeTunes.app"
fi
