#!/bin/sh
# Build EnhancedFM.app (needs: brew install librtlsdr nrsc5)
set -e
cd "$(dirname "$0")"
swift build -c release
APP=EnhancedFM.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/EnhancedFM "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>EnhancedFM</string>
  <key>CFBundleIdentifier</key><string>local.enhancedfm</string>
  <key>CFBundleExecutable</key><string>EnhancedFM</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF
codesign --force -s - "$APP"
echo "Built $PWD/$APP"
