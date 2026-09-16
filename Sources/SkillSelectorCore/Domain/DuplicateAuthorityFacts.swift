import Foundation

/// The facts laid out side by side for the copies in one duplicate group.
///
/// There is deliberately **no** aggregate score and **no** recommended copy.
/// A weighted number cannot be explained to the person who has to decide,
/// and the point of showing these is to inform that decision rather than
/// replace it.
public enum DuplicateCriterion: String, CaseIterable, Hashable, Sendable {
    /// Fewer path components — a shallow copy is usually the shared original
    /// rather than a nested per-Agent install.
    case pathDepth
    /// Most recent modification.
    case modificationDate
    /// Referenced by the most Agents.
    case referencingAgents
}

/// What is known about one copy, plus which criteria it is strictly best at.
public struct DuplicateMemberFacts: Identifiable, Hashable, Sendable {
    public let snapshot: SkillSnapshot
    /// Number of path components, including the root.
    public let pathDepth: Int
    public let modificationDate: Date?
    /// How many real Agents reference this copy. Synthetic owners are
    /// excluded: they mark the app's own scopes, not an Agent's use, so
    /// counting them would inflate every copy equally and say nothing.
    public let referencingAgentCount: Int
    /// Criteria this copy is *strictly* best at. A tie leaves the criterion
    /// unclaimed, so a win count always reflects a real distinction rather
    /// than an arbitrary tie-break.
    public let wonCriteria: Set<DuplicateCriterion>

    public var id: String { snapshot.path }
    public var winCount: Int { wonCriteria.count }
}

public enum DuplicateAuthorityFacts {
    /// One entry per member, in the order given, so a caller can zip the
    /// result against the group it came from.
    public static func facts(for members: [SkillSnapshot]) -> [DuplicateMemberFacts] {
        guard !members.isEmpty else { return [] }

        let depths = members.map { URL(fileURLWithPath: $0.path).pathComponents.count }
        let dates = members.map(\.modificationDate)
        let agentCounts = members.map { snapshot in
            snapshot.agentIDs.filter { !SyntheticAgentID.all.contains($0) }.count
        }

        let shallowest = uniqueBest(depths, preferLower: true)
        let newest = uniqueBest(dates, preferLower: false)
        let mostReferenced = uniqueBest(agentCounts, preferLower: false)

        return members.indices.map { index in
            var won: Set<DuplicateCriterion> = []
            if shallowest == index { won.insert(.pathDepth) }
            if newest == index { won.insert(.modificationDate) }
            if mostReferenced == index { won.insert(.referencingAgents) }
            return DuplicateMemberFacts(
                snapshot: members[index],
                pathDepth: depths[index],
                modificationDate: dates[index],
                referencingAgentCount: agentCounts[index],
                wonCriteria: won
            )
        }
    }

    /// The index holding the unique best value, or nil when nobody does —
    /// including when two members tie, which is what keeps a displayed win
    /// count honest.
    private static func uniqueBest(_ values: [Int], preferLower: Bool) -> Int? {
        guard let best = preferLower ? values.min() : values.max() else { return nil }
        let winners = values.indices.filter { values[$0] == best }
        return winners.count == 1 ? winners[0] : nil
    }

    /// A missing date cannot win: for this purpose "unknown" is not the same
    /// as "oldest", and pretending otherwise would hand the criterion to
    /// whichever copy simply failed to record a date.
    private static func uniqueBest(_ values: [Date?], preferLower: Bool) -> Int? {
        let known = values.enumerated().compactMap { index, date in
            date.map { (index: index, date: $0) }
        }
        guard let best = preferLower
            ? known.map(\.date).min()
            : known.map(\.date).max()
        else { return nil }
        let winners = known.filter { $0.date == best }
        return winners.count == 1 ? winners[0].index : nil
    }
}
