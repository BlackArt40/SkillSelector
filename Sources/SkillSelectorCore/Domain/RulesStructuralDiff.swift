import Foundation

/// What two rules files say differently, in paragraphs rather than lines.
///
/// Rules files are prose, and the question that matters is not "which lines
/// moved" but "does the other file say something this one does not". Blocks
/// are aligned with a longest-common-subsequence walk, so inserting a
/// paragraph does not make every paragraph after it look changed — the
/// false-positive storm that makes an index-by-index comparison useless on
/// exactly the files this is meant to help with.
public struct RulesStructuralComparison: Hashable, Sendable {

    public enum Kind: Hashable, Sendable {
        /// The block exists only in the first file.
        case onlyInFirst
        /// The block exists only in the second file.
        case onlyInSecond
        /// Both files have a block here and the text differs.
        case changed
    }

    /// One block that is not identical on both sides.
    public struct Divergence: Identifiable, Hashable, Sendable {
        public let id: Int
        public let kind: Kind
        /// 1-based block number in the first file; nil when absent there.
        public let firstBlock: Int?
        /// 1-based block number in the second file; nil when absent there.
        public let secondBlock: Int?
        public let firstText: String?
        public let secondText: String?
    }

    public let divergences: [Divergence]
    public let firstBlockCount: Int
    public let secondBlockCount: Int
    /// False when a file was too large to align. `divergences` is then empty
    /// even if the files differ, so read this alongside `isIdentical`.
    public let isAligned: Bool
    /// Whether the two files say the same thing. Kept separate from
    /// `divergences.isEmpty` because an unaligned comparison still knows
    /// identity — it just cannot say where.
    public let isIdentical: Bool
}

public enum RulesStructuralDiff {
    /// Beyond this many blocks on either side the alignment table stops
    /// being cheap: it is O(n·m) integers, so a pathological pair could
    /// allocate hundreds of megabytes. The reader hands us bodies of up to a
    /// megabyte, and a megabyte of one-line paragraphs is not a rules file,
    /// but the bound is here rather than assumed away. Past it the
    /// comparison degrades to "same or different" instead of guessing.
    public static let maximumAlignedBlocks = 800

    public static func compare(_ first: [String], _ second: [String]) -> RulesStructuralComparison {
        let left = blocks(in: first)
        let right = blocks(in: second)
        let identical = left == right

        guard left.count <= maximumAlignedBlocks, right.count <= maximumAlignedBlocks else {
            return RulesStructuralComparison(
                divergences: [],
                firstBlockCount: left.count,
                secondBlockCount: right.count,
                isAligned: false,
                isIdentical: identical
            )
        }

        return RulesStructuralComparison(
            divergences: align(left, right),
            firstBlockCount: left.count,
            secondBlockCount: right.count,
            isAligned: true,
            isIdentical: identical
        )
    }

    /// Splits body lines into blocks: blank-line-separated runs, with each
    /// heading kept as its own block so renaming a section does not read as
    /// a change to the prose beneath it. Text is normalized as it is built,
    /// so equal-meaning blocks compare equal.
    public static func blocks(in lines: [String]) -> [String] {
        var blocks: [String] = []
        var buffer: [String] = []

        func flush() {
            let text = normalized(buffer.joined(separator: "\n"))
            if !text.isEmpty { blocks.append(text) }
            buffer.removeAll(keepingCapacity: true)
        }

        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
            } else if line.hasPrefix("#") {
                // A heading closes whatever came before it and stands alone.
                flush()
                blocks.append(normalized(line))
            } else {
                buffer.append(line)
            }
        }
        flush()
        return blocks
    }

    /// Trailing whitespace and blank-line padding are not content: two files
    /// that differ only there have not drifted.
    static func normalized(_ text: String) -> String {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                var trimmed = line
                while let last = trimmed.last, last.isWhitespace {
                    trimmed.removeLast()
                }
                return String(trimmed)
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Alignment

    private enum Step {
        case equal
        case first(Int)
        case second(Int)
    }

    /// Walks the LCS table into a step list, then groups consecutive
    /// non-equal steps into divergences. Pairing a dropped-left with a
    /// dropped-right yields `.changed` — what a reader means by "this
    /// paragraph is different" — rather than a delete plus an insert.
    private static func align(
        _ left: [String],
        _ right: [String]
    ) -> [RulesStructuralComparison.Divergence] {
        let rows = left.count
        let columns = right.count

        var table = Array(
            repeating: Array(repeating: 0, count: columns + 1),
            count: rows + 1
        )
        if rows > 0 && columns > 0 {
            for i in stride(from: rows - 1, through: 0, by: -1) {
                for j in stride(from: columns - 1, through: 0, by: -1) {
                    table[i][j] = left[i] == right[j]
                        ? table[i + 1][j + 1] + 1
                        : max(table[i + 1][j], table[i][j + 1])
                }
            }
        }

        var steps: [Step] = []
        steps.reserveCapacity(rows + columns)
        var i = 0
        var j = 0
        while i < rows && j < columns {
            if left[i] == right[j] {
                steps.append(.equal)
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                steps.append(.first(i))
                i += 1
            } else {
                steps.append(.second(j))
                j += 1
            }
        }
        while i < rows {
            steps.append(.first(i))
            i += 1
        }
        while j < columns {
            steps.append(.second(j))
            j += 1
        }

        var divergences: [RulesStructuralComparison.Divergence] = []
        var cursor = 0
        while cursor < steps.count {
            if case .equal = steps[cursor] {
                cursor += 1
                continue
            }

            var firstIndices: [Int] = []
            var secondIndices: [Int] = []
            var end = cursor
            run: while end < steps.count {
                switch steps[end] {
                case .equal:
                    break run
                case .first(let index):
                    firstIndices.append(index)
                case .second(let index):
                    secondIndices.append(index)
                }
                end += 1
            }

            let paired = min(firstIndices.count, secondIndices.count)
            for position in 0..<paired {
                divergences.append(
                    RulesStructuralComparison.Divergence(
                        id: divergences.count,
                        kind: .changed,
                        firstBlock: firstIndices[position] + 1,
                        secondBlock: secondIndices[position] + 1,
                        firstText: left[firstIndices[position]],
                        secondText: right[secondIndices[position]]
                    )
                )
            }
            for index in firstIndices.dropFirst(paired) {
                divergences.append(
                    RulesStructuralComparison.Divergence(
                        id: divergences.count,
                        kind: .onlyInFirst,
                        firstBlock: index + 1,
                        secondBlock: nil,
                        firstText: left[index],
                        secondText: nil
                    )
                )
            }
            for index in secondIndices.dropFirst(paired) {
                divergences.append(
                    RulesStructuralComparison.Divergence(
                        id: divergences.count,
                        kind: .onlyInSecond,
                        firstBlock: nil,
                        secondBlock: index + 1,
                        firstText: nil,
                        secondText: right[index]
                    )
                )
            }

            cursor = end
        }
        return divergences
    }
}
