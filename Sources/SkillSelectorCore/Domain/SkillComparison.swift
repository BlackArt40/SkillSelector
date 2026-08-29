import Foundation

/// The read-only comparison between two Skill installations — what the
/// copy-comparison sheet renders. Pure data: the app layer gathers inputs
/// (documents + stat trees) and this builder turns them into sections.
///
/// Exact duplicates share a body, so their interesting deltas live in
/// frontmatter and sibling files; near duplicates additionally get a body
/// line diff. All three sections are always computed — the view decides
/// what to emphasize.
public struct SkillComparison: Hashable, Sendable {
    public struct FrontmatterField: Hashable, Sendable, Identifiable {
        public let key: String
        public let left: String?
        public let right: String?
        public var isDifferent: Bool { left != right }
        public var id: String { key }
    }

    public enum FileDifference: Hashable, Sendable {
        case leftOnly
        case rightOnly
        case kindMismatch
        case sizeDiffers
        case identical
    }

    public struct FileEntry: Hashable, Sendable, Identifiable {
        public let relativePath: String
        public let difference: FileDifference
        public var id: String { relativePath }
    }

    public let leftPath: String
    public let rightPath: String
    /// Union of frontmatter keys, sorted; absent keys are nil per side.
    public let frontmatter: [FrontmatterField]
    /// Union of the two stat trees' relative paths, sorted.
    public let files: [FileEntry]
    /// Line diff of the bodies; rows are all `.same` when identical.
    public let bodyDiff: LineDiff

    public var bodiesAreIdentical: Bool {
        bodyDiff.rows.allSatisfy { $0.kind == .same }
    }
}

public enum SkillComparisonBuilder {
    /// Compares two already-read entry documents and two fresh stat trees.
    /// Stat trees come from `ScanStateBuilder.build` on each installation
    /// directory; mtime is deliberately ignored (copies re-saved without
    /// content changes are not "different").
    public static func compare(
        leftPath: String,
        rightPath: String,
        leftDocument: ParsedSkillDocument,
        rightDocument: ParsedSkillDocument,
        leftBody: String,
        rightBody: String,
        leftState: SkillScanState,
        rightState: SkillScanState
    ) -> SkillComparison {
        let frontmatter = compareFrontmatter(leftDocument, rightDocument)
        let files = compareFiles(leftState, rightState)
        let bodyDiff = LineDiff.compute(
            leftBody.components(separatedBy: "\n"),
            rightBody.components(separatedBy: "\n")
        )
        return SkillComparison(
            leftPath: leftPath,
            rightPath: rightPath,
            frontmatter: frontmatter,
            files: files,
            bodyDiff: bodyDiff
        )
    }

    private static func compareFrontmatter(
        _ left: ParsedSkillDocument,
        _ right: ParsedSkillDocument
    ) -> [SkillComparison.FrontmatterField] {
        let keys = Set(left.fields.keys).union(right.fields.keys).sorted()
        return keys.map { key in
            SkillComparison.FrontmatterField(
                key: key,
                left: normalizedFieldValue(left.fields[key]),
                right: normalizedFieldValue(right.fields[key])
            )
        }
    }

    private static func normalizedFieldValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func compareFiles(
        _ left: SkillScanState,
        _ right: SkillScanState
    ) -> [SkillComparison.FileEntry] {
        let leftByPath = Dictionary(
            left.entries.map { ($0.relativePath, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let rightByPath = Dictionary(
            right.entries.map { ($0.relativePath, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let paths = Set(leftByPath.keys).union(rightByPath.keys).sorted()
        return paths.map { path in
            SkillComparison.FileEntry(
                relativePath: path,
                difference: difference(
                    left: leftByPath[path], right: rightByPath[path]
                )
            )
        }
    }

    private static func difference(
        left: SkillScanState.Entry?,
        right: SkillScanState.Entry?
    ) -> SkillComparison.FileDifference {
        switch (left, right) {
        case (nil, nil):
            return .identical
        case (nil, .some):
            return .rightOnly
        case (.some, nil):
            return .leftOnly
        case (.some(let left), .some(let right)):
            guard left.kind == right.kind else { return .kindMismatch }
            guard left.kind == .file || left.kind == .symbolicLink else { return .identical }
            if left.symlinkDestination != right.symlinkDestination { return .kindMismatch }
            guard left.size == right.size else { return .sizeDiffers }
            return .identical
        }
    }
}
