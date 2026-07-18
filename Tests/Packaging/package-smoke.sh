#!/bin/zsh
set -euo pipefail

if (( $# != 1 )); then
    print -u2 "usage: $0 VERSION"
    exit 64
fi

VERSION="$1"
if [[ ! "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9]+)*$' ]]; then
    print -u2 "VERSION must use numeric major.minor.patch form"
    exit 64
fi

APP="dist/SkillSelector.app"
INFO_PLIST="$APP/Contents/Info.plist"
STABLE_DMG="dist/SkillSelector.dmg"
RELEASE_DMG="dist/SkillSelector-$VERSION.dmg"
ROOT_DIR="${0:A:h:h:h}"

test -x "$APP/Contents/MacOS/SkillSelector"
test -d "$APP/Contents/Resources/SkillSelector_SkillSelector.bundle"
lipo "$APP/Contents/MacOS/SkillSelector" -verify_arch arm64 x86_64
codesign --verify --deep --strict "$APP"
codesign -d --entitlements :- "$APP" 2>&1 | grep -q 'com.apple.security.app-sandbox'
plutil -lint "$INFO_PLIST"
test "$(plutil -extract CFBundleShortVersionString raw "$INFO_PLIST")" = "$VERSION"
test "$(plutil -extract CFBundleVersion raw "$INFO_PLIST")" = "$VERSION"
test -f "$STABLE_DMG"
hdiutil verify "$STABLE_DMG"
test -f "$RELEASE_DMG"
hdiutil verify "$RELEASE_DMG"

typeset -a fallbackBundles
for bundle in "$ROOT_DIR"/.build/**/SkillSelector_SkillSelector.bundle(N); do
    mv "$bundle" "$bundle.unavailable"
    fallbackBundles+=("$bundle")
done
(( ${#fallbackBundles[@]} > 0 ))
trap 'for bundle in "${fallbackBundles[@]}"; do mv "$bundle.unavailable" "$bundle"; done' EXIT
test "$("$APP/Contents/MacOS/SkillSelector" --verify-localization-resource)" = "SkillSelector"
