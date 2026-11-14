#!/bin/bash
# Builds build/Nook.app (universal) and build/Nook.dmg
set -euo pipefail
cd "$(dirname "$0")"
rm -rf build && mkdir -p build/Nook.app/Contents/MacOS build/dmg

for arch in arm64 x86_64; do
  swiftc -O -target "$arch-apple-macos13.0" Sources/main.swift -o "build/Nook-$arch"
done
lipo -create build/Nook-arm64 build/Nook-x86_64 -output build/Nook.app/Contents/MacOS/Nook
rm build/Nook-arm64 build/Nook-x86_64

cat > build/Nook.app/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Nook</string>
  <key>CFBundleDisplayName</key><string>Nook</string>
  <key>CFBundleIdentifier</key><string>dev.nook.app</string>
  <key>CFBundleIconFile</key><string>Nook</string>
  <key>CFBundleExecutable</key><string>Nook</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>Nook</string>
</dict></plist>
PLIST

# app icon
mkdir -p build/icon/Nook.iconset build/Nook.app/Contents/Resources
swiftc -O Tools/make-icon.swift -o build/icon/mk && build/icon/mk build/icon/1024.png
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon/1024.png --out build/icon/Nook.iconset/icon_${s}x${s}.png >/dev/null
  sips -z $((s*2)) $((s*2)) build/icon/1024.png --out build/icon/Nook.iconset/icon_${s}x${s}@2x.png >/dev/null
done
iconutil -c icns build/icon/Nook.iconset -o build/Nook.app/Contents/Resources/Nook.icns
rm -rf build/icon

codesign --force --sign - build/Nook.app

cp -R build/Nook.app build/dmg/
ln -s /Applications build/dmg/Applications
hdiutil create -volname Nook -srcfolder build/dmg -ov -format UDZO build/Nook.dmg >/dev/null
rm -rf build/dmg
echo "Built build/Nook.dmg"
