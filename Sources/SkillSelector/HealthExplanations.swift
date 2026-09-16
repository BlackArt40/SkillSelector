import Foundation
import SkillSelectorCore

/// Every user-facing string the Health destination produces, in one place —
/// the same arrangement as `McpExplanations`, so the list, the detail pane
/// and any future caller cannot drift apart on wording.
///
/// Note what is absent: there is no copy for "recommended copy", and none
/// for a combined score. That is the design, not an oversight — see
/// `DuplicateAuthorityFacts` for why.
enum HealthExplanations {

    static func categoryTitle(_ category: SkillHealthCategory) -> String {
        switch category {
        case .exactDuplicates: return L10n.string("Health Exact Duplicates")
        case .nearDuplicates: return L10n.string("Health Near Duplicates")
        case .unreachableLinks: return L10n.string("Health Unreachable Links")
        }
    }

    /// One line saying why this class of thing is worth a look — the "为什么"
    /// the list promises per entry.
    static func categoryReason(_ category: SkillHealthCategory) -> String {
        switch category {
        case .exactDuplicates: return L10n.string("Health Exact Duplicates Reason")
        case .nearDuplicates: return L10n.string("Health Near Duplicates Reason")
        case .unreachableLinks: return L10n.string("Health Unreachable Links Reason")
        }
    }

    /// The one-line summary shown for an item in the list.
    static func itemSummary(_ item: SkillHealthItem) -> String {
        switch item.category {
        case .exactDuplicates, .nearDuplicates:
            let copies = L10n.string("Health Copies %d", item.snapshots.count)
            // Names are usually shared, but a fingerprint match can span
            // differently-named folders — showing both beats picking one and
            // implying the other is not involved.
            let names = Set(item.snapshots.map(\.name)).filter { !$0.isEmpty }.sorted()
            return names.isEmpty ? copies : "\(names.joined(separator: " · ")) · \(copies)"
        case .unreachableLinks:
            return item.snapshots.first?.path ?? ""
        }
    }

    static func criterionTitle(_ criterion: DuplicateCriterion) -> String {
        switch criterion {
        case .pathDepth: return L10n.string("Criterion Path Depth")
        case .modificationDate: return L10n.string("Criterion Last Modified")
        case .referencingAgents: return L10n.string("Criterion Referenced By")
        }
    }

    /// The transparent count: how many of the criteria this copy is strictly
    /// best at. Never a combined score, and a tie reads as nothing to claim.
    static func winSummary(_ facts: DuplicateMemberFacts, totalCriteria: Int) -> String {
        guard facts.winCount > 0 else { return L10n.string("Health Criteria Wins None") }
        return L10n.string("Health Criteria Wins %d of %d", facts.winCount, totalCriteria)
    }

    static func modificationDate(_ date: Date?) -> String {
        guard let date else { return L10n.string("Health Unknown Date") }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
