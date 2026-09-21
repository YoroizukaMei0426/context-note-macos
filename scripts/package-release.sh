#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."

app="outputs/ContextNote.app"
codesign --verify --deep --strict "$app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
archive="outputs/ContextNote-${version}-macOS.zip"
temporary="$(mktemp "$PWD/outputs/.ContextNote-release.XXXXXX.zip")"

ditto -c -k --sequesterRsrc --keepParent "$app" "$temporary"
mv -f "$temporary" "$archive"
shasum -a 256 "$archive" > "$archive.sha256"
echo "Packaged $archive"
