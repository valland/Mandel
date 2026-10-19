#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
./tools/zig build -Doptimize=ReleaseFast
APP=zig-out/Mandel.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp zig-out/bin/Mandel "$APP/Contents/MacOS/Mandel.new"
mv -f "$APP/Contents/MacOS/Mandel.new" "$APP/Contents/MacOS/Mandel"
cp README.md "$APP/Contents/Resources/README.md"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Mandel</string>
<key>CFBundleIdentifier</key><string>local.mandel.explorer</string>
<key>CFBundleName</key><string>Mandel</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.7.0</string>
<key>CFBundleVersion</key><string>9</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
printf 'Built %s\n' "$APP"
