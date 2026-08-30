import Foundation

/// Connects the remote marketplace to the local index, read-only. The
/// only stable identity the two sides share is the skill directory name:
/// the marketplace publishes `<name>/SKILL.md` and the ecosystem CLI
/// installs it as `<name>/SKILL.md` under an agent's skills root. Matching
/// is therefore by normalized name, and the UI shows the matched paths so
/// a same-name-but-different-source copy stays visible.
public enum LocalInstallationMatcher {
    /// Local installations matching the catalog skill's directory name
    /// (case-, diacritic- and width-insensitive). Pure and read-only; the
    /// caller decides how to present the result.
    public static func localInstallations(
        of skill: CatalogSkill,
        in snapshots: [SkillSnapshot]
    ) -> [SkillSnapshot] {
        let key = Self.key(for: skill.name)
        return snapshots.filter { Self.key(for: $0.name) == key }
    }

    /// The normalized names present in the local index — the one-time
    /// set a list builds once, then queries per row in O(1).
    public static func installedNames(in snapshots: [SkillSnapshot]) -> Set<String> {
        Set(snapshots.map { Self.key(for: $0.name) })
    }

    /// Whether a skill name exists in the local index, using the same
    /// normalized identity as `localInstallations`.
    public static func isInstalled(name: String, installedNames: Set<String>) -> Bool {
        installedNames.contains(Self.key(for: name))
    }

    /// Case-, diacritic- and width-insensitive identity shared by every
    /// matching path, so detail and list never disagree.
    private static func key(for name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}
