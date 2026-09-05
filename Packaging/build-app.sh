#!/bin/bash
# Builds a local runnable SkillSelector.app from the release binary.
#
# Usage: Packaging/build-app.sh [output-dir]
#   output-dir   default: /tmp/SkillSelector.app
#
# Dev packaging deliberately omits com.apple.security.app-sandbox: in a
# bare (non-containerized) sandbox environment the app crashes with
# SIGILL (132) on launch. The read-only file access + bookmark scope +
# network client entitlements are kept, matching what the app actually
# uses. An App Store build would sign with the full entitlements file
# (Packaging/SkillSelector.entitlements).
set -euo pipefail

cd "$(dirname "$0")/.."
OUT="${1:-/tmp/SkillSelector.app}"

swift build --disable-sandbox -c release

rm -rf "$OUT"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources/en.lproj" "$OUT/Contents/Resources/zh-Hans.lproj"

cp .build/release/SkillSelector "$OUT/Contents/MacOS/"
cp Packaging/Info.plist "$OUT/Contents/Info.plist"
cp Sources/SkillSelector/Resources/AppIcon.icns Sources/SkillSelector/Resources/AppIcon.png "$OUT/Contents/Resources/"
cp Sources/SkillSelector/Resources/en.lproj/Localizable.strings "$OUT/Contents/Resources/en.lproj/"
cp Sources/SkillSelector/Resources/zh-Hans.lproj/Localizable.strings "$OUT/Contents/Resources/zh-Hans.lproj/"

# Resource bundles ship ONLY in Contents/Resources (same contract as
# package-dmg.sh): the app resolves them through Bundle.appResources, and a
# .app-root copy would break codesign (unsealed bundle-root contents).
for resource_bundle in .build/release/*.bundle; do
    [[ -e "$resource_bundle" ]] || continue
    ditto "$resource_bundle" "$OUT/Contents/Resources/${resource_bundle:t}"
done

# A per-invocation temp path keeps parallel builds from overwriting each
# other's entitlements file.
ENTITLEMENTS="$(mktemp -t skillselector-dev-entitlements)"
trap 'rm -f "$ENTITLEMENTS"' EXIT

cat > "$ENTITLEMENTS" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.files.user-selected.read-only</key>
	<true/>
	<key>com.apple.security.files.bookmarks.app-scope</key>
	<true/>
	<key>com.apple.security.network.client</key>
	<true/>
</dict>
</plist>
EOF

codesign --force --deep --sign - --entitlements "$ENTITLEMENTS" "$OUT"
echo "Built $OUT"
