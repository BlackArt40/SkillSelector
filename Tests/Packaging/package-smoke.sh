#!/bin/zsh
set -euo pipefail

APP="dist/SkillSelector.app"

test -x "$APP/Contents/MacOS/SkillSelector"
lipo "$APP/Contents/MacOS/SkillSelector" -verify_arch arm64 x86_64
codesign --verify --deep --strict "$APP"
codesign -d --entitlements :- "$APP" 2>&1 | grep -q 'com.apple.security.app-sandbox'
plutil -lint "$APP/Contents/Info.plist"
test -f dist/SkillSelector.dmg
