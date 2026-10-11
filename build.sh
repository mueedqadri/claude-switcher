#!/bin/zsh
# Builds Claude Switcher and installs it in ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP="$HOME/Applications/Claude Switcher.app"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -swift-version 5 main.swift -o "$APP/Contents/MacOS/ClaudeSwitcher"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>ClaudeSwitcher</string>
    <key>CFBundleIdentifier</key><string>local.mueed.claude-switcher</string>
    <key>CFBundleName</key><string>Claude Switcher</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.4</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
EOF

codesign --force --sign - "$APP"
echo "Installed: $APP"
