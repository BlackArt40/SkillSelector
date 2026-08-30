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

swift build --package-path "$ROOT_DIR" --configuration release --arch arm64 --scratch-path "$ARM_SCRATCH"
swift build --package-path "$ROOT_DIR" --configuration release --arch x86_64 --scratch-path "$X86_SCRATCH"

test -x "$ARM_RELEASE/SkillSelector"
test -x "$X86_RELEASE/SkillSelector"
lipo -create \
    "$ARM_RELEASE/SkillSelector" \
    "$X86_RELEASE/SkillSelector" \
    -output "$APP/Contents/MacOS/SkillSelector"

for resource_bundle in "$ARM_RELEASE"/*.bundle(N); do
    ditto "$resource_bundle" "$APP/Contents/Resources/${resource_bundle:t}"
done

# App icon (design/assets) for Finder, Dock and the About pane.
ditto "$ROOT_DIR/Sources/SkillSelector/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

ditto "$ROOT_DIR/Packaging/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"

# Sign nested code inside-out. `codesign --deep` is deprecated for signing:
# it applies the outer identity to nested items without their own entitlements
# and silently skips anything it fails to recognise. Signing each nested bundle
# explicitly keeps the set of signed items visible in this script.
#
# Dependency resource bundles (math fonts from swiftui-math, the syntax
# highlighter from Textual) carry no code and codesign rejects them as
# "bundle format unrecognized". They are plain resources — nothing to sign —
# so those failures are tolerated; the app-level signature below still
# covers the whole bundle.
for nested_bundle in "$APP/Contents/Resources"/*.bundle(N); do
    codesign --force --sign - "$nested_bundle" 2>/dev/null || true
done

codesign --force --sign - \
    --entitlements "$ROOT_DIR/Packaging/SkillSelector.entitlements" \
    "$APP"

# Stage the app so the DMG volume can carry the logo as its icon
# (.VolumeIcon.icns + the custom-icon Finder flag).
STAGING="$ROOT_DIR/.build/dmg-staging"
rm -rf "$STAGING"
mkdir -p "$STAGING"
ditto "$APP" "$STAGING/SkillSelector.app"
ditto "$ROOT_DIR/Sources/SkillSelector/Resources/AppIcon.icns" "$STAGING/.VolumeIcon.icns"
SetFile -a C "$STAGING"

hdiutil create \
    -format UDZO \
    -imagekey zlib-level=9 \
    -volname SkillSelector \
    -srcfolder "$STAGING" \
    "$DIST_DIR/SkillSelector.dmg"
cp "$DIST_DIR/SkillSelector.dmg" "$DIST_DIR/SkillSelector-$VERSION.dmg"

# Checksum is written with a bare filename so downloaders can run
# `shasum -a 256 -c SkillSelector-$VERSION.dmg.sha256` next to the DMG.
(
    cd "$DIST_DIR"
    shasum -a 256 "SkillSelector-$VERSION.dmg" > "SkillSelector-$VERSION.dmg.sha256"
)
