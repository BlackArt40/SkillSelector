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

ditto "$ROOT_DIR/Packaging/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"

codesign --force --deep --sign - \
    --entitlements "$ROOT_DIR/Packaging/SkillSelector.entitlements" \
    "$APP"

hdiutil create \
    -format UDZO \
    -imagekey zlib-level=9 \
    -volname SkillSelector \
    -srcfolder "$APP" \
    "$DIST_DIR/SkillSelector.dmg"
cp "$DIST_DIR/SkillSelector.dmg" "$DIST_DIR/SkillSelector-$VERSION.dmg"
