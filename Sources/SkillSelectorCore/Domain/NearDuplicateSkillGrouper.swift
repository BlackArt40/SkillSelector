import Foundation

/// One member of a near-duplicate cluster: the Skill plus its estimated
/// similarity to its nearest neighbor in the group. The percentage is an
/// approximation derived from the SimHash Hamming distance and is labeled
/// as an estimate in the UI.
public struct NearDuplicateMember: Identifiable, Hashable, Sendable {
    public let snapshot: SkillSnapshot
    public let similarityPercent: Int

    public var id: String { snapshot.path }

    init(snapshot: SkillSnapshot, similarityPercent: Int) {
        self.snapshot = snapshot
        self.similarityPercent = similarityPercent
    }
}

/// A cluster of Skills whose bodies drifted apart by small edits: same
/// origin, no longer byte-identical. Grouping is transitive (union-find
/// over near pairs) — a chain of similar copies lands in one cluster even
/// when its two ends are no longer similar to each other.
public struct NearDuplicateSkillGroup: Identifiable, Hashable, Sendable {
    /// Sorted member paths joined with a unit-separator — the ignore key.
    public let fingerprint: String
    public let members: [NearDuplicateMember]

    public var id: String { fingerprint }

    init(fingerprint: String, members: [NearDuplicateMember]) {
        self.fingerprint = fingerprint
        self.members = members
    }
}

public enum NearDuplicateSkillGrouper {
    /// Clusters snapshots whose estimated body similarity
    /// (`SkillSimilarityFingerprint.similarityPercent`) reaches the
    /// near-duplicate threshold. Pairs that are *exact* duplicates
    /// (identical content fingerprints) never create a near edge — the
    /// exact-duplicates view already covers them.
    ///
    /// Members whose record carries the group key in
    /// `ignoredNearDuplicateGroup` leave the group; fewer than two
    /// remaining members dissolves it. The key derives from member paths,
    /// so an ignore goes stale when membership changes — the group simply
    /// reappears and can be ignored again.
    public static func groups(_ snapshots: [SkillSnapshot]) -> [NearDuplicateSkillGroup] {
        let candidates = snapshots.filter {
            $0.similarityFingerprint.map(SkillSimilarityFingerprint.isCurrentVersion(_:)) == true
        }

        // Union-find over near pairs.
        var parent = Dictionary(uniqueKeysWithValues: candidates.map { ($0.path, $0.path) })
        func root(_ path: String) -> String {
            var current = path
            while let next = parent[current], next != current {
                let grandparent = parent[next] ?? next
                parent[current] = grandparent
                current = grandparent
            }
            return current
        }
        func union(_ lhs: String, _ rhs: String) {
            let left = root(lhs), right = root(rhs)
            guard left != right else { return }
            parent[left] = right
        }

        for index in candidates.indices {
            for other in candidates.indices[(index + 1)...] {
                let left = candidates[index], right = candidates[other]
                // Exact duplicates belong to the exact-duplicates view.
                if let leftContent = left.contentFingerprint,
                   leftContent == right.contentFingerprint {
                    continue
                }
                guard SkillSimilarityFingerprint.areNearDuplicates(
                    left.similarityFingerprint ?? "", right.similarityFingerprint ?? ""
                ) else {
                    continue
                }
                union(left.path, right.path)
            }
        }

        let clusters = Dictionary(grouping: candidates.map(\.path)) { root($0) }
            .values
            .filter { $0.count > 1 }

        return clusters
            .compactMap { paths -> NearDuplicateSkillGroup? in
                let byPath = Dictionary(uniqueKeysWithValues: candidates.map { ($0.path, $0) })
                let members = paths.compactMap { byPath[$0] }
                let key = members.map(\.path).sorted().joined(separator: "\u{1f}")
                let visible = members.filter { $0.ignoredNearDuplicateGroup != key }
                guard visible.count > 1 else { return nil }

                let percentages = visible.map { member in
                    member.similarityPercent(
                        against: visible.filter { $0.path != member.path }
                    )
                }
                let ranked = zip(visible, percentages)
                    .map { member, percent in
                        NearDuplicateMember(snapshot: member, similarityPercent: percent)
                    }
                    .sorted { $0.snapshot.path < $1.snapshot.path }
                return NearDuplicateSkillGroup(fingerprint: key, members: ranked)
            }
            .sorted { lhs, rhs in
                let lhsName = lhs.members.map(\.snapshot.name).min() ?? ""
                let rhsName = rhs.members.map(\.snapshot.name).min() ?? ""
                return lhsName == rhsName ? lhs.fingerprint < rhs.fingerprint : lhsName < rhsName
            }
    }

    public static func memberCount(in groups: [NearDuplicateSkillGroup]) -> Int {
        groups.reduce(0) { $0 + $1.members.count }
    }
}

private extension SkillSnapshot {
    /// Highest estimated similarity to any of the other visible members,
    /// as a percentage.
    func similarityPercent(against others: [SkillSnapshot]) -> Int {
        let percentages = others.compactMap {
            SkillSimilarityFingerprint.similarityPercent(
                similarityFingerprint ?? "", $0.similarityFingerprint ?? ""
            )
        }
        return percentages.max() ?? 100
    }
}
