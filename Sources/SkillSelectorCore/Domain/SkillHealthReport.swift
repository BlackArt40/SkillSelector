import Foundation

/// One class of thing the consistency list asks the user to look at.
///
/// Adding a case is how a new signal joins the list. `SkillHealthReport`
/// builds one section per category, and the view renders whatever sections
/// it is handed without knowing them by name — so a rules-file drift check
/// becomes `case rulesDrift` plus one builder, not a rewrite.
public enum SkillHealthCategory: String, CaseIterable, Hashable, Sendable {
    /// Copies whose SKILL.md content fingerprint matches exactly.
    case exactDuplicates
    /// Copies that drifted apart by small edits and no longer match.
    case nearDuplicates
    /// Symbolic links whose target no longer exists.
    case unreachableLinks
}

/// One entry: a single thing to look at, plus the snapshots it concerns.
public struct SkillHealthItem: Identifiable, Hashable, Sendable {
    public let category: SkillHealthCategory
    /// Stable for as long as the underlying group or link persists, so
    /// selection survives a refresh that changes nothing.
    public let id: String
    /// Duplicate and near-duplicate items carry two or more snapshots; a
    /// broken link carries exactly one.
    public let snapshots: [SkillSnapshot]

    init(category: SkillHealthCategory, id: String, snapshots: [SkillSnapshot]) {
        self.category = category
        self.id = id
        self.snapshots = snapshots
    }
}

/// A category and what it found.
public struct SkillHealthSection: Identifiable, Hashable, Sendable {
    public let category: SkillHealthCategory
    public let items: [SkillHealthItem]

    public var id: SkillHealthCategory { category }
    public var count: Int { items.count }
}

/// Read-only aggregation of the consistency checks the app already runs.
///
/// This adds no detection of its own — it reuses the duplicate, near-
/// duplicate, and link checkers so the list and the dedicated views can
/// never disagree about what counts as a problem.
public enum SkillHealthReport {
    /// Every category, whether or not it found anything, in declaration
    /// order.
    ///
    /// Empty categories are kept deliberately: the list is a standing
    /// census, and hiding a clean class would make "nothing here" look the
    /// same as "not checked".
    public static func sections(for snapshots: [SkillSnapshot]) -> [SkillHealthSection] {
        SkillHealthCategory.allCases.map { category in
            SkillHealthSection(category: category, items: items(for: category, in: snapshots))
        }
    }

    /// The headline count.
    ///
    /// Summed over categories rather than counted as distinct snapshots: one
    /// Skill can be both a duplicate copy and a broken link, and collapsing
    /// those into one number would hide work.
    public static func totalItemCount(in sections: [SkillHealthSection]) -> Int {
        sections.reduce(0) { $0 + $1.count }
    }

    private static func items(
        for category: SkillHealthCategory,
        in snapshots: [SkillSnapshot]
    ) -> [SkillHealthItem] {
        switch category {
        case .exactDuplicates:
            // The grouper already drops groups the user ignored, which is
            // what we want here too: an ignore means "stop telling me".
            return DuplicateSkillGrouper.groups(snapshots).map { group in
                SkillHealthItem(
                    category: category,
                    id: "duplicate:\(group.fingerprint)",
                    snapshots: group.members
                )
            }
        case .nearDuplicates:
            return NearDuplicateSkillGrouper.groups(snapshots).map { group in
                SkillHealthItem(
                    category: category,
                    id: "near:\(group.fingerprint)",
                    snapshots: group.members.map(\.snapshot)
                )
            }
        case .unreachableLinks:
            return snapshots
                .filter(\.linkTargetIsUnreachable)
                .sorted { $0.path < $1.path }
                .map { snapshot in
                    SkillHealthItem(
                        category: category,
                        id: "link:\(snapshot.path)",
                        snapshots: [snapshot]
                    )
                }
        }
    }
}
