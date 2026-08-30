import Foundation

/// A line-level diff between two texts, presented as an ordered row list
/// (context / added / removed) — the shape a unified-diff view renders
/// directly. Used by the copy-comparison view to show what drifted between
/// two near-duplicate bodies.
public struct LineDiff: Hashable, Sendable {
    public enum RowKind: Hashable, Sendable {
        case same
        case added
        case removed
    }

    public struct Row: Hashable, Sendable {
        public let kind: RowKind
        public let text: String

        init(kind: RowKind, text: String) {
            self.kind = kind
            self.text = text
        }
    }

    public let rows: [Row]

    init(rows: [Row]) {
        self.rows = rows
    }

    public var addedCount: Int {
        rows.filter { $0.kind == .added }.count
    }

    public var removedCount: Int {
        rows.filter { $0.kind == .removed }.count
    }

    /// LCS-based diff. Common prefixes and suffixes are trimmed first (the
/// typical near-duplicate differs in one region), and the remaining
/// middle is diffed with a classic DP. Pathologically large middles
/// degrade to "everything replaced" rather than exhausting memory.
public static func compute(_ left: [String], _ right: [String]) -> LineDiff {
        var rows: [Row] = []
        var leftIndex = 0
        var rightIndex = 0
        var leftEnd = left.count
        var rightEnd = right.count

        // Common prefix.
        while leftIndex < leftEnd, rightIndex < rightEnd,
              left[leftIndex] == right[rightIndex] {
            rows.append(Row(kind: .same, text: left[leftIndex]))
            leftIndex += 1
            rightIndex += 1
        }
        // Common suffix.
        var suffix: [Row] = []
        while leftEnd > leftIndex, rightEnd > rightIndex,
              left[leftEnd - 1] == right[rightEnd - 1] {
            suffix.insert(Row(kind: .same, text: left[leftEnd - 1]), at: 0)
            leftEnd -= 1
            rightEnd -= 1
        }

        let middleLeft = Array(left[leftIndex..<leftEnd])
        let middleRight = Array(right[rightIndex..<rightEnd])
        rows.append(contentsOf: middleRows(middleLeft, middleRight))
        rows.append(contentsOf: suffix)
        return LineDiff(rows: rows)
    }

    private static func middleRows(_ left: [String], _ right: [String]) -> [Row] {
        guard !left.isEmpty || !right.isEmpty else { return [] }
        // Size guard: the DP table is (n+1)×(m+1) Ints. Huge middles
        // (generated files, minified dumps) degrade to a replace block.
        guard left.count * right.count <= 4_000_000 else {
            return left.map { Row(kind: .removed, text: $0) }
                + right.map { Row(kind: .added, text: $0) }
        }
        guard !left.isEmpty else { return right.map { Row(kind: .added, text: $0) } }
        guard !right.isEmpty else { return left.map { Row(kind: .removed, text: $0) } }

        var lengths = [[Int]](
            repeating: [Int](repeating: 0, count: right.count + 1),
            count: left.count + 1
        )
        for i in stride(from: left.count - 1, through: 0, by: -1) {
            for j in stride(from: right.count - 1, through: 0, by: -1) {
                if left[i] == right[j] {
                    lengths[i][j] = lengths[i + 1][j + 1] + 1
                } else {
                    lengths[i][j] = max(lengths[i + 1][j], lengths[i][j + 1])
                }
            }
        }

        var rows: [Row] = []
        var i = 0
        var j = 0
        while i < left.count, j < right.count {
            if left[i] == right[j] {
                rows.append(Row(kind: .same, text: left[i]))
                i += 1
                j += 1
            } else if lengths[i + 1][j] >= lengths[i][j + 1] {
                rows.append(Row(kind: .removed, text: left[i]))
                i += 1
            } else {
                rows.append(Row(kind: .added, text: right[j]))
                j += 1
            }
        }
        while i < left.count {
            rows.append(Row(kind: .removed, text: left[i]))
            i += 1
        }
        while j < right.count {
            rows.append(Row(kind: .added, text: right[j]))
            j += 1
        }
        return rows
    }
}

/// Compact added/removed counts of a line diff — what the near-duplicates
/// list renders per member as "+N −M lines" against the group baseline.
public struct LineDiffSummary: Hashable, Sendable {
    public let added: Int
    public let removed: Int

    public var isEmpty: Bool { added == 0 && removed == 0 }

    public init(diff: LineDiff) {
        self.added = diff.addedCount
        self.removed = diff.removedCount
    }
}
