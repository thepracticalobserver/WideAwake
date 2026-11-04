#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="Wide Awake.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
# Universal binary (Apple Silicon + Intel), macOS 14+.
swiftc -O -target arm64-apple-macos14.0 main.swift -o /tmp/WideAwake-arm64
swiftc -O -target x86_64-apple-macos14.0 main.swift -o /tmp/WideAwake-x86_64
lipo -create /tmp/WideAwake-arm64 /tmp/WideAwake-x86_64 -output "$APP/Contents/MacOS/WideAwake"
rm -f /tmp/WideAwake-arm64 /tmp/WideAwake-x86_64
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Wide Awake</string>
  <key>CFBundleIdentifier</key><string>com.local.wideawake</string>
  <key>CFBundleExecutable</key><string>WideAwake</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
# Pin the designated requirement to the bundle id so the Accessibility grant survives rebuilds.
codesign --force --sign - -r='designated => identifier "com.local.wideawake"' "$APP"
echo "Built $APP"
