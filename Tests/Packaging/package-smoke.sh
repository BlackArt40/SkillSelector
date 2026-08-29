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

# `--deep` is deprecated for signing but is the correct flag for verification:
# it walks nested code, which package-dmg.sh now signs explicitly.
codesign --verify --deep --strict "$APP"
# grep without -q: consume the entire stream so codesign never hits SIGPIPE
# from a pipe closed early under `set -euo pipefail`.
codesign -d --entitlements :- "$APP" 2>&1 | grep 'com.apple.security.app-sandbox' >/dev/null

# The read-only catalog fetches GitHub on demand — the sandbox must grant
# outbound network client access, and nothing beyond it (no server, no
# arbitrary file writes).
codesign -d --entitlements :- "$APP" 2>&1 | grep 'com.apple.security.network.client' >/dev/null

# The README tells users this build is ad-hoc signed. Assert that stays true so
# the disclosure never silently drifts from the artifact.
codesign -dvv "$APP" 2>&1 | grep '^Signature=adhoc$' >/dev/null

plutil -lint "$INFO_PLIST"
test "$(plutil -extract CFBundleShortVersionString raw "$INFO_PLIST")" = "$VERSION"
test "$(plutil -extract CFBundleVersion raw "$INFO_PLIST")" = "$VERSION"
test -f "$STABLE_DMG"
hdiutil verify "$STABLE_DMG"
test -f "$RELEASE_DMG"
hdiutil verify "$RELEASE_DMG"

test -f "$RELEASE_DMG.sha256"
( cd dist && shasum -a 256 -c "SkillSelector-$VERSION.dmg.sha256" )

typeset -a fallbackBundles
for bundle in "$ROOT_DIR"/.build/**/SkillSelector_SkillSelector.bundle(N); do
    mv "$bundle" "$bundle.unavailable"
    fallbackBundles+=("$bundle")
done
(( ${#fallbackBundles[@]} > 0 ))
trap 'for bundle in "${fallbackBundles[@]}"; do mv "$bundle.unavailable" "$bundle"; done' EXIT
test "$("$APP/Contents/MacOS/SkillSelector" --verify-localization-resource)" = "SkillSelector"
