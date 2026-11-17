#!/bin/zsh
set -euo pipefail

source_dir=${0:A:h}
app_path="${1:-$source_dir/dist/PixelPad.app}"
build_dir="$(mktemp -d)"
trap 'rm -rf -- "$build_dir"' EXIT

swift "$source_dir/make-icon.swift" "$build_dir/PixelPad.iconset"
iconutil -c icns "$build_dir/PixelPad.iconset" -o "$build_dir/PixelPad.icns"
for arch in arm64 x86_64; do
    xcrun swiftc -O -target "${arch}-apple-macos13.0" "$source_dir/main.swift" -o "$build_dir/PixelPad-$arch"
done

mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
xcrun lipo -create "$build_dir/PixelPad-arm64" "$build_dir/PixelPad-x86_64" -output "$app_path/Contents/MacOS/PixelPad"
cp "$build_dir/PixelPad.icns" "$app_path/Contents/Resources/"
cp "$source_dir/Info.plist" "$app_path/Contents/"
codesign --force --sign - "$app_path"
