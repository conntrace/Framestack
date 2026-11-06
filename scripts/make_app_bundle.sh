#!/usr/bin/env bash
# Builds FrameStack in release mode and wraps it in a double-clickable
# .build/FrameStack.app (ad-hoc signed, local use only — not notarized).
#
#   scripts/make_app_bundle.sh
#   open .build/FrameStack.app
set -euo pipefail

cd "$(dirname "$0")/.."
swift build -c release --product FrameStack
BIN="$(swift build -c release --show-bin-path)/FrameStack"

APP=.build/FrameStack.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/FrameStack"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>FrameStack</string>
    <key>CFBundleIdentifier</key><string>local.framestack.FrameStack</string>
    <key>CFBundleName</key><string>FrameStack</string>
    <key>CFBundleDisplayName</key><string>FrameStack</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.photography</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <!-- Lets Finder offer FrameStack under "Open With" for movies, and makes
         `open -a FrameStack clip.mov` and Dock-icon drops work. -->
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Video</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.movie</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"
