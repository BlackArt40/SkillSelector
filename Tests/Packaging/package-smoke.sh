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
# from a pipe closed early under `set -euo pipefail`. -a because the `:-`
# blob can carry a trailing NUL, which BSD grep treats as binary input and
# answers "no match" even when the key is present.
codesign -d --entitlements :- "$APP" 2>&1 | grep -a 'com.apple.security.app-sandbox' >/dev/null

# The read-only catalog fetches GitHub on demand — the sandbox must grant
# outbound network client access, and nothing beyond it (no server, no
# arbitrary file writes).
codesign -d --entitlements :- "$APP" 2>&1 | grep -a 'com.apple.security.network.client' >/dev/null

# Diagnostics export presents an NSSavePanel. A sandboxed app can only
# present save panels with user-selected.read-write: read-only covers
# open panels, and without the write grant the save panel never surfaces
# (no window, no error — the modal call just returns .cancel).
codesign -d --entitlements :- "$APP" 2>&1 | grep -a 'com.apple.security.files.user-selected.read-write' >/dev/null

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

# Single-arch DMGs: same signing and version, one machine family each.
for arch in arm64 x86_64; do
    arch_app="dist/SkillSelector-$arch.app"
    arch_dmg="dist/SkillSelector-$VERSION-$arch.dmg"
    test -x "$arch_app/Contents/MacOS/SkillSelector"
    # Must be a thin single-arch binary, not a fat slice.
    lipo -info "$arch_app/Contents/MacOS/SkillSelector" | grep -q "is architecture: $arch"
    codesign --verify --deep --strict "$arch_app"
    codesign -dvv "$arch_app" 2>&1 | grep '^Signature=adhoc$' >/dev/null
    test "$(plutil -extract CFBundleShortVersionString raw "$arch_app/Contents/Info.plist")" = "$VERSION"
    test -f "$arch_dmg"
    hdiutil verify "$arch_dmg"
    test -f "$arch_dmg.sha256"
    ( cd dist && shasum -a 256 -c "SkillSelector-$VERSION-$arch.dmg.sha256" )
done

typeset -a fallbackBundles
for bundle in "$ROOT_DIR"/.build/**/SkillSelector_SkillSelector.bundle(N); do
    mv "$bundle" "$bundle.unavailable"
    fallbackBundles+=("$bundle")
done
(( ${#fallbackBundles[@]} > 0 ))
trap 'for bundle in "${fallbackBundles[@]}"; do mv "$bundle.unavailable" "$bundle"; done' EXIT
test "$("$APP/Contents/MacOS/SkillSelector" --verify-localization-resource)" = "SkillSelector"
