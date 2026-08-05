#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="SkillSelector"
BUILD_DIR=".build/run-app"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
EXECUTABLE="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Kill previous instance
pkill -f "$APP_NAME.app" 2>/dev/null || true
sleep 0.5

# Build
echo "Building..."
swift build 2>&1 | tail -1

# Create .app bundle structure
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp ".build/debug/$APP_NAME" "$EXECUTABLE"

cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleDisplayName</key>
	<string>SkillSelector</string>
	<key>CFBundleExecutable</key>
	<string>SkillSelector</string>
	<key>CFBundleIdentifier</key>
	<string>io.github.skillselector.SkillSelector</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleLocalizations</key>
	<array>
		<string>en</string>
		<string>zh-Hans</string>
	</array>
	<key>CFBundleName</key>
	<string>SkillSelector</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.0.0</string>
	<key>CFBundleVersion</key>
	<string>0</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST

# Launch
echo "Launching $APP_NAME..."
open "$APP_BUNDLE"
echo "App is running. Close the window and reopen from Dock to test lifecycle fix."
