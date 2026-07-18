# Releasing SkillSelector

SkillSelector releases are GitHub Release assets. They are ad-hoc signed, App Sandbox enabled, and intentionally not Developer ID signed or notarized.

1. Choose a numeric `MAJOR.MINOR.PATCH` version and ensure the release commit is clean.
2. Run the full verification suite:

   ```zsh
   swift test
   swift build
   ```

3. Package and validate the Universal 2 application:

   ```zsh
   VERSION=0.1.0
   zsh Scripts/package-dmg.sh "$VERSION"
   zsh Tests/Packaging/package-smoke.sh
   ```

   This creates `dist/SkillSelector.app`, a stable local smoke-test image at `dist/SkillSelector.dmg`, and the versioned release asset `dist/SkillSelector-$VERSION.dmg`.

4. Create the checksum alongside the release asset:

   ```zsh
   shasum -a 256 "dist/SkillSelector-$VERSION.dmg" > "dist/SkillSelector-$VERSION.dmg.sha256"
   ```

5. Create the GitHub Release and upload exactly the versioned DMG and checksum:

   ```zsh
   gh release create "v$VERSION" \
     "dist/SkillSelector-$VERSION.dmg" \
     "dist/SkillSelector-$VERSION.dmg.sha256" \
     --title "SkillSelector $VERSION" \
     --generate-notes
   ```

Do not submit the build for notarization and do not claim that it is notarized. The release notes should link users to the Gatekeeper procedure in the README.
