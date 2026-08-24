import Foundation

/// Groups installations whose content fingerprint matches, so the user can
/// see the same Skill scattered across Agents. View-level aggregation only:
/// every member keeps its own record — "path is identity, copies are
/// independent" is unchanged.
public struct DuplicateSkillGroup: Identifiable, Hashable, Sendable {
    public let fingerprint: String
    public let members: [SkillSnapshot]

    public var id: String { fingerprint }

    init(fingerprint: String, members: [SkillSnapshot]) {
        self.fingerprint = fingerprint
        self.members = members
    }
}

public enum DuplicateSkillGrouper {
    /// Fingerprint collisions across differently-named skills are fine to
    /// ignore: identical bytes in identically named folders is exactly the
    /// duplicate this view hunts for. Members the user marked ignored (their
    /// record carries the group's fingerprint in `ignoredDuplicateGroup`)
    /// leave the group; a group left with fewer than two visible members
    /// disappears entirely.
    public static func groups(_ snapshots: [SkillSnapshot]) -> [DuplicateSkillGroup] {
        let byFingerprint = Dictionary(grouping: snapshots) { $0.contentFingerprint ?? "" }
            .filter { key, members in
                !key.isEmpty && members.count > 1
            }
        return byFingerprint
            .compactMap { key, members -> DuplicateSkillGroup? in
                let visible = members.filter { $0.ignoredDuplicateGroup != key }
                guard visible.count > 1 else { return nil }
                return DuplicateSkillGroup(
                    fingerprint: key,
                    members: visible.sorted { $0.path < $1.path }
                )
            }
            .sorted { lhs, rhs in
                let lhsName = lhs.members.map(\.name).min() ?? ""
                let rhsName = rhs.members.map(\.name).min() ?? ""
                return lhsName == rhsName ? lhs.fingerprint < rhs.fingerprint : lhsName < rhsName
            }
    }

    public static func memberCount(in groups: [DuplicateSkillGroup]) -> Int {
        groups.reduce(0) { $0 + $1.members.count }
    }
}
