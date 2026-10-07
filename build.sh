#!/usr/bin/env bash
# Builds "Mini Notes.app" into ./build.
#   ./build.sh           build for this Mac
#   ./build.sh install   build, copy to /Applications and launch
#   ./build.sh dist      universal (Apple Silicon + Intel) build, zipped for a GitHub release
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Mini Notes.app"
MODE="${1:-}"

if [[ "$MODE" == "dist" ]]; then
    swift build -c release --arch arm64 --arch x86_64
    BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/MiniNotes"
else
    swift build -c release
    BIN="$(swift build -c release --show-bin-path)/MiniNotes"
fi
mkdir -p build

if [[ ! -f Resources/AppIcon.icns ]]; then
    swift scripts/make-icon.swift build/AppIcon.iconset
    iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MiniNotes"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"

case "$MODE" in
    install)
        pkill -x MiniNotes 2>/dev/null && sleep 1 || true
        rm -rf "/Applications/Mini Notes.app"
        cp -R "$APP" /Applications/
        open "/Applications/Mini Notes.app"
        echo "Installed to /Applications and launched"
        ;;
    dist)
        rm -f build/MiniNotes.zip
        ditto -c -k --sequesterRsrc --keepParent "$APP" build/MiniNotes.zip
        echo "Packaged build/MiniNotes.zip ($(lipo -archs "$APP/Contents/MacOS/MiniNotes"))"
        ;;
esac
