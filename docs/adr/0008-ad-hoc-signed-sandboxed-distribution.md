# Distribute an ad-hoc signed sandboxed macOS app

Status: Accepted.

SkillSelector targets macOS 14 or later and ships as a Universal 2 `.dmg` on GitHub Releases. Release builds use an ad-hoc signature so App Sandbox entitlements are active, but do not use an Apple Developer ID and are not notarized. The README must explain the resulting Gatekeeper warning and the manual open procedure.
