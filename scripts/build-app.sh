#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
mkdir -p work/cache/clang work/cache/swiftpm
CLANG_MODULE_CACHE_PATH="$PWD/work/cache/clang" swift build -c release -debug-info-format none --disable-sandbox --cache-path "$PWD/work/cache/swiftpm" --manifest-cache local
app="outputs/ContextNote.app"
iconset="work/AppIcon.iconset"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$iconset"
cp .build/release/ContextNote "$app/Contents/MacOS/ContextNote"

# Build the standard multi-resolution macOS icon from the checked-in master.
sips -s format png -z 16 16 Resources/AppIcon.jpg --out "$iconset/icon_16x16.png" >/dev/null
sips -s format png -z 32 32 Resources/AppIcon.jpg --out "$iconset/icon_16x16@2x.png" >/dev/null
sips -s format png -z 32 32 Resources/AppIcon.jpg --out "$iconset/icon_32x32.png" >/dev/null
sips -s format png -z 64 64 Resources/AppIcon.jpg --out "$iconset/icon_32x32@2x.png" >/dev/null
sips -s format png -z 128 128 Resources/AppIcon.jpg --out "$iconset/icon_128x128.png" >/dev/null
sips -s format png -z 256 256 Resources/AppIcon.jpg --out "$iconset/icon_128x128@2x.png" >/dev/null
sips -s format png -z 256 256 Resources/AppIcon.jpg --out "$iconset/icon_256x256.png" >/dev/null
sips -s format png -z 512 512 Resources/AppIcon.jpg --out "$iconset/icon_256x256@2x.png" >/dev/null
sips -s format png -z 512 512 Resources/AppIcon.jpg --out "$iconset/icon_512x512.png" >/dev/null
sips -s format png -z 1024 1024 Resources/AppIcon.jpg --out "$iconset/icon_512x512@2x.png" >/dev/null
python3 scripts/make-icns.py "$iconset" "$app/Contents/Resources/AppIcon.icns"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.contextnote.mvp</string>
<key>CFBundleName</key><string>情境便签</string>
<key>CFBundleDisplayName</key><string>情境便签</string>
<key>CFBundleExecutable</key><string>ContextNote</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleShortVersionString</key><string>1.0.2</string>
<key>CFBundleVersion</key><string>3</string>
<key>NSHumanReadableCopyright</key><string>Copyright © 2026 ContextNote.</string>
<key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign - "$app"
echo "Built $app"
