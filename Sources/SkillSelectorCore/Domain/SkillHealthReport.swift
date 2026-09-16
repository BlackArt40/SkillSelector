import Foundation

/// One class of thing the consistency list asks the user to look at.
///
/// Adding a case is how a new signal joins the list. `SkillHealthReport`
/// builds one section per category, and the view renders whatever sections
/// it is handed without knowing them by name — which is how `rulesDrift`
/// arrived: one case, one builder, one subject, and no change to the
/// assembly or to the view.
public enum SkillHealthCategory: String, CaseIterable, Hashable, Sendable {
    /// Copies whose SKILL.md content fingerprint matches exactly.
    case exactDuplicates
    /// Copies that drifted apart by small edits and no longer match.
    case nearDuplicates
    /// Symbolic links whose target no longer exists.
    case unreachableLinks
    /// Rules files in the same directory that say different things.
    case rulesDrift
}

/// Two rules files in the same root whose bodies disagree.
///
/// Carries paths rather than descriptors: the list only needs to name the
/// pair and say how far apart it is, and the comparison itself lives in the
/// rules view, where the two documents can be read side by side.
public struct RulesDriftFinding: Identifiable, Hashable, Sendable {
    public let firstPath: String
    public let firstFilename: String
    public let secondPath: String
    public let secondFilename: String
    /// How many paragraphs disagree. Only meaningful when `isAligned`.
    public let divergenceCount: Int
    /// False when the pair exceeded the alignment bound; the count is then
    /// 0 and must not be presented as "no differences".
    public let isAligned: Bool

    public var id: String { "\(firstPath)|\(secondPath)" }

    public init(
        firstPath: String,
        firstFilename: String,
        secondPath: String,
        secondFilename: String,
        divergenceCount: Int,
        isAligned: Bool
    ) {
        self.firstPath = firstPath
        self.firstFilename = firstFilename
        self.secondPath = secondPath
        self.secondFilename = secondFilename
        self.divergenceCount = divergenceCount
        self.isAligned = isAligned
    }
}

/// One entry: a single thing to look at, plus what it concerns.
public struct SkillHealthItem: Identifiable, Hashable, Sendable {
    /// Not every category describes skills — rules drift describes a pair of
    /// files — so the payload is a union rather than an optional bolted onto
    /// the snapshot case.
    public enum Subject: Hashable, Sendable {
        case skills([SkillSnapshot])
        case rulesDrift(RulesDriftFinding)
    }

    public let category: SkillHealthCategory
    /// Stable for as long as the underlying group, link or pair persists, so
    /// selection survives a refresh that changes nothing.
    public let id: String
    public let subject: Subject

    /// Duplicate and near-duplicate items carry two or more snapshots; a
    /// broken link carries exactly one; rules drift carries none.
    public var snapshots: [SkillSnapshot] {
        guard case .skills(let snapshots) = subject else { return [] }
        return snapshots
    }

    public var rulesDrift: RulesDriftFinding? {
        guard case .rulesDrift(let finding) = subject else { return nil }
        return finding
    }

    init(category: SkillHealthCategory, id: String, subject: Subject) {
        self.category = category
        self.id = id
        self.subject = subject
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
/// duplicate, link and rules checkers so the list and the dedicated views
/// can never disagree about what counts as a problem.
public enum SkillHealthReport {
    /// Every category, whether or not it found anything, in declaration
    /// order.
    ///
    /// Empty categories are kept deliberately: the list is a standing
    /// census, and hiding a clean class would make "nothing here" look the
    /// same as "not checked".
    ///
    /// - Parameter rulesDrift: findings supplied by the caller, because
    ///   detecting them means reading files and this type does no I/O.
    public static func sections(
        for snapshots: [SkillSnapshot],
        rulesDrift: [RulesDriftFinding] = []
    ) -> [SkillHealthSection] {
        SkillHealthCategory.allCases.map { category in
            SkillHealthSection(
                category: category,
                items: items(for: category, in: snapshots, rulesDrift: rulesDrift)
            )
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
        in snapshots: [SkillSnapshot],
        rulesDrift: [RulesDriftFinding]
    ) -> [SkillHealthItem] {
        switch category {
        case .exactDuplicates:
            // The grouper already drops groups the user ignored, which is
            // what we want here too: an ignore means "stop telling me".
            return DuplicateSkillGrouper.groups(snapshots).map { group in
                SkillHealthItem(
                    category: category,
                    id: "duplicate:\(group.fingerprint)",
                    subject: .skills(group.members)
                )
            }
        case .nearDuplicates:
            return NearDuplicateSkillGrouper.groups(snapshots).map { group in
                SkillHealthItem(
                    category: category,
                    id: "near:\(group.fingerprint)",
                    subject: .skills(group.members.map(\.snapshot))
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
                        subject: .skills([snapshot])
                    )
                }
        case .rulesDrift:
            return rulesDrift
                .sorted { $0.id < $1.id }
                .map { finding in
                    SkillHealthItem(
                        category: category,
                        id: "rules:\(finding.id)",
                        subject: .rulesDrift(finding)
                    )
                }
        }
    }
}
