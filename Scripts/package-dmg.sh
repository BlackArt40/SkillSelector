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

ROOT_DIR="${0:A:h:h}"
DIST_DIR="$ROOT_DIR/dist"
ARM_SCRATCH="$ROOT_DIR/.build/package-arm64"
X86_SCRATCH="$ROOT_DIR/.build/package-x86_64"
APP="$DIST_DIR/SkillSelector.app"
ARM_RELEASE="$ARM_SCRATCH/arm64-apple-macosx/release"
X86_RELEASE="$X86_SCRATCH/x86_64-apple-macosx/release"

rm -rf "$DIST_DIR" "$ARM_SCRATCH" "$X86_SCRATCH"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swift build --package-path "$ROOT_DIR" --configuration release --arch arm64 --scratch-path "$ARM_SCRATCH" --disable-sandbox
swift build --package-path "$ROOT_DIR" --configuration release --arch x86_64 --scratch-path "$X86_SCRATCH" --disable-sandbox

test -x "$ARM_RELEASE/SkillSelector"
test -x "$X86_RELEASE/SkillSelector"
lipo -create \
    "$ARM_RELEASE/SkillSelector" \
    "$X86_RELEASE/SkillSelector" \
    -output "$DIST_DIR/SkillSelector-universal"

# Assemble, sign and seal one app bundle into a DMG. Used three times: the
# universal build (the default download) plus one single-arch DMG per
# machine family. $1 binary, $2 app bundle path, $3 DMG output path.
build_sealed_dmg() {
    local bin="$1" app="$2" dmg="$3"

    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp "$bin" "$app/Contents/MacOS/SkillSelector"

    # Resource bundles ship ONLY in Contents/Resources. Never copy them to the
    # .app root: codesign rejects unsealed contents at the bundle root ("unsealed
    # contents present in the bundle root") and the app-side resolver
    # (`Bundle.appResources`, mirroring L10n) reads this location. Direct
    # `Bundle.module` use is forbidden in app code for the same reason.
    for resource_bundle in "$ARM_RELEASE"/*.bundle(N); do
        ditto "$resource_bundle" "$app/Contents/Resources/${resource_bundle:t}"
    done

    # App icon (design/assets) for Finder, Dock and the About pane.
    ditto "$ROOT_DIR/Sources/SkillSelector/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"

    ditto "$ROOT_DIR/Packaging/Info.plist" "$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$app/Contents/Info.plist"

    # Sign nested code inside-out. `codesign --deep` is deprecated for signing:
    # it applies the outer identity to nested items without their own entitlements
    # and silently skips anything it fails to recognise. Signing each nested bundle
    # explicitly keeps the set of signed items visible in this script.
    #
    # Dependency resource bundles (GRDB's) may carry no code and codesign rejects
    # them as "bundle format unrecognized". They are plain resources — nothing to
    # sign — so those failures are tolerated; the app-level signature below still
    # covers the whole bundle.
    for nested_bundle in "$app/Contents/Resources"/*.bundle(N) "$app"/*.bundle(N); do
        codesign --force --sign - "$nested_bundle" 2>/dev/null || true
    done

    codesign --force --sign - \
        --entitlements "$ROOT_DIR/Packaging/SkillSelector.entitlements" \
        "$app"

    # Stage the app so the DMG volume can carry the logo as its icon
    # (.VolumeIcon.icns + the custom-icon Finder flag).
    local staging="$ROOT_DIR/.build/dmg-staging"
    rm -rf "$staging"
    mkdir -p "$staging"
    ditto "$app" "$staging/SkillSelector.app"
    ditto "$ROOT_DIR/Sources/SkillSelector/Resources/AppIcon.icns" "$staging/.VolumeIcon.icns"
    SetFile -a C "$staging"

    hdiutil create \
        -format UDZO \
        -imagekey zlib-level=9 \
        -volname SkillSelector \
        -srcfolder "$staging" \
        "$dmg"
}

build_sealed_dmg \
    "$DIST_DIR/SkillSelector-universal" \
    "$APP" \
    "$DIST_DIR/SkillSelector.dmg"

build_sealed_dmg \
    "$ARM_RELEASE/SkillSelector" \
    "$DIST_DIR/SkillSelector-arm64.app" \
    "$DIST_DIR/SkillSelector-$VERSION-arm64.dmg"

build_sealed_dmg \
    "$X86_RELEASE/SkillSelector" \
    "$DIST_DIR/SkillSelector-x86_64.app" \
    "$DIST_DIR/SkillSelector-$VERSION-x86_64.dmg"

rm -f "$DIST_DIR/SkillSelector-universal"

cp "$DIST_DIR/SkillSelector.dmg" "$DIST_DIR/SkillSelector-$VERSION.dmg"

# Checksums are written with a bare filename so downloaders can run
# `shasum -a 256 -c SkillSelector-$VERSION[-arch].dmg.sha256` next to the DMG.
(
    cd "$DIST_DIR"
    shasum -a 256 "SkillSelector-$VERSION.dmg" > "SkillSelector-$VERSION.dmg.sha256"
    shasum -a 256 "SkillSelector-$VERSION-arm64.dmg" > "SkillSelector-$VERSION-arm64.dmg.sha256"
    shasum -a 256 "SkillSelector-$VERSION-x86_64.dmg" > "SkillSelector-$VERSION-x86_64.dmg.sha256"
)
