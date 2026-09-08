import Foundation
import SkillSelectorCore

/// Stateless read-only comparison passes between Skill installations:
/// both entry documents (validated reads) and fresh stat trees, fed
/// through the pure `SkillComparisonBuilder`, plus the lightweight body
/// line diffs behind the "+N −M" badges. All I/O runs off the main actor
/// while the document leases stay held for the duration; the caller
/// hands over the current authorized roots per call.
@MainActor
final class ComparisonService {
    private let documentManager: DocumentManager

    init(documentManager: DocumentManager) {
        self.documentManager = documentManager
    }

    /// Gathers the read-only comparison between two Skill installations.
    /// User-triggered from the duplicates views.
    func compareSnapshots(
        _ left: SkillSnapshot,
        _ right: SkillSnapshot,
        authorizedRoots: [AuthorizedRootSnapshot]
    ) async throws -> SkillComparison {
        let leftAccess = try documentManager.resolveDocumentAccess(
            for: left, authorizedRoots: authorizedRoots
        )
        let rightAccess = try documentManager.resolveDocumentAccess(
            for: right, authorizedRoots: authorizedRoots
        )
        defer {
            (leftAccess.leases + rightAccess.leases).forEach { $0.close() }
        }
        let leftRequest = leftAccess.request
        let rightRequest = rightAccess.request
        return try await Task.detached(priority: .userInitiated) {
            let reader = SkillDocumentReader()
            let leftDocument = try reader.read(leftRequest)
            let rightDocument = try reader.read(rightRequest)
            func state(for skill: SkillSnapshot) -> SkillScanState {
                ScanStateBuilder.build(
                    contentDirectory: URL(
                        fileURLWithPath: skill.resolvedTarget ?? skill.path
                    ),
                    entryFilename: skill.entryFilename,
                    resolvedTarget: skill.resolvedTarget.map(URL.init(fileURLWithPath:))
                )
            }
            return SkillComparisonBuilder.compare(
                leftPath: left.path,
                rightPath: right.path,
                leftDocument: FrontmatterParser.parse(leftDocument.source),
                rightDocument: FrontmatterParser.parse(rightDocument.source),
                leftBody: FrontmatterParser.bodyLines(from: leftDocument.source)
                    .joined(separator: "\n"),
                rightBody: FrontmatterParser.bodyLines(from: rightDocument.source)
                    .joined(separator: "\n"),
                leftState: state(for: left),
                rightState: state(for: right)
            )
        }.value
    }

    /// Per-member body line differences within a near-duplicate group,
    /// keyed by member path, relative to the group's highest-similarity
    /// baseline member. Lightweight — body read + line diff only, no stat
    /// tree — and drives the "+N −M lines" badges in the near-duplicates
    /// list.
    func nearBodyDiffs(
        in group: NearDuplicateSkillGroup,
        authorizedRoots: [AuthorizedRootSnapshot]
    ) async -> [String: LineDiffSummary] {
        guard let baseline = group.members.max(by: { $0.similarityPercent < $1.similarityPercent }) else {
            return [:]
        }
        var summaries: [String: LineDiffSummary] = [:]
        for member in group.members where member.snapshot.path != baseline.snapshot.path {
            if let summary = try? await bodyDiffSummary(
                baseline.snapshot, member.snapshot, authorizedRoots: authorizedRoots
            ) {
                summaries[member.snapshot.path] = summary
            }
        }
        return summaries
    }

    private func bodyDiffSummary(
        _ left: SkillSnapshot,
        _ right: SkillSnapshot,
        authorizedRoots: [AuthorizedRootSnapshot]
    ) async throws -> LineDiffSummary {
        let leftAccess = try documentManager.resolveDocumentAccess(
            for: left, authorizedRoots: authorizedRoots
        )
        let rightAccess = try documentManager.resolveDocumentAccess(
            for: right, authorizedRoots: authorizedRoots
        )
        defer {
            (leftAccess.leases + rightAccess.leases).forEach { $0.close() }
        }
        let leftRequest = leftAccess.request
        let rightRequest = rightAccess.request
        return try await Task.detached(priority: .utility) {
            let reader = SkillDocumentReader()
            let leftBody = FrontmatterParser.bodyLines(from: try reader.read(leftRequest).source)
                .joined(separator: "\n")
            let rightBody = FrontmatterParser.bodyLines(from: try reader.read(rightRequest).source)
                .joined(separator: "\n")
            let diff = LineDiff.compute(
                leftBody.components(separatedBy: "\n"),
                rightBody.components(separatedBy: "\n")
            )
            return LineDiffSummary(diff: diff)
        }.value
    }

    /// Line difference between a local installation's SKILL.md body and a
    /// remote marketplace body (already fetched), for the 「对照本地」section:
    /// "+N −M" means the marketplace body adds N lines and drops M that the
    /// local body has. Read-only; a read failure yields nil and the badge
    /// stays hidden.
    func marketVsLocalBodyDiff(
        marketBody: String,
        local: SkillSnapshot,
        authorizedRoots: [AuthorizedRootSnapshot]
    ) async -> LineDiffSummary? {
        do {
            let access = try documentManager.resolveDocumentAccess(
                for: local, authorizedRoots: authorizedRoots
            )
            defer {
                access.leases.forEach { $0.close() }
            }
            let request = access.request
            return try await Task.detached(priority: .utility) {
                let reader = SkillDocumentReader()
                let localBody = FrontmatterParser.bodyLines(from: try reader.read(request).source)
                    .joined(separator: "\n")
                let diff = LineDiff.compute(
                    localBody.components(separatedBy: "\n"),
                    marketBody.components(separatedBy: "\n")
                )
                return LineDiffSummary(diff: diff)
            }.value
        } catch {
            return nil
        }
    }
}
