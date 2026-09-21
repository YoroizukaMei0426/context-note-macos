#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
mkdir -p work/cache/clang work/cache/swiftpm
CLANG_MODULE_CACHE_PATH="$PWD/work/cache/clang" swift build -c release -debug-info-format none --disable-sandbox --cache-path "$PWD/work/cache/swiftpm" --manifest-cache local
app="outputs/ContextNote.app"
mkdir -p "$app/Contents/MacOS"
cp .build/release/ContextNote "$app/Contents/MacOS/ContextNote"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.contextnote.mvp</string>
<key>CFBundleName</key><string>情境便签</string>
<key>CFBundleDisplayName</key><string>情境便签</string>
<key>CFBundleExecutable</key><string>ContextNote</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign - "$app"
echo "Built $app"
