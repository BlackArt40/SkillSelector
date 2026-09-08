import Foundation
import SkillSelectorCore

/// Coordinates the deferred background work that keeps the list snappy:
/// the fingerprint backfill (audit R-series) and the body search index
/// rebuild. Owns its task bookkeeping and the associated off-main-actor
/// passes; `AppModel` stays the composition root and forwards
/// `objectWillChange` (same pattern as the other state submodels).
///
/// Snapshots and authorized roots are passed in per call — the caller
/// always hands over the freshest values, so this type never duplicates
/// published state.
@MainActor
final class BackgroundWorkCoordinator: ObservableObject {
    private let index: SkillIndex
    private let diagnosticStore: DiagnosticStore
    /// Invoked when a backfill wrote fingerprints back into the index;
    /// the app side reloads snapshots and records the diagnostic. Set by
    /// the composition root after init — the closure captures AppModel,
    /// which cannot happen while AppModel is still initializing.
    var onFingerprintsBackfilled: (Int, Set<String>) -> Void = { _, _ in }

    /// True while the deferred fingerprint backfill is running off the
    /// main thread — drives the "background indexing" status dot in the
    /// search field (spec §5.9 / §06).
    @Published private(set) var isBackfilling = false
    /// Folded entry-file bodies by installation path, powering body
    /// search (`body:` terms and free-term matching). Rebuilt in the
    /// background after each refresh; empty until the first build lands,
    /// and search degrades to name matching in the meantime.
    @Published private(set) var bodySearchTextsByPath: [String: String] = [:]

    private var activeFingerprintBackfill: (id: UUID, task: Task<Void, Never>)?
    /// Paths whose deferred fingerprint failed to compute (unreadable
    /// content). They are not retried until the next refresh, when files
    /// may have changed — this keeps the schedule self-terminating.
    private var fingerprintFailures: Set<String> = []
    /// Paths whose body is too short for a similarity fingerprint: the
    /// value is legitimately nil, so without this set the backfill would
    /// re-read them after every reload. Reset on refresh (files change).
    private var shortSimilarityBodies: Set<String> = []
    private var activeBodyIndexBuild: (id: UUID, task: Task<Void, Never>)?

    init(index: SkillIndex, diagnosticStore: DiagnosticStore) {
        self.index = index
        self.diagnosticStore = diagnosticStore
    }

    /// Files may have changed since the last backfill attempt; give
    /// previously failed paths another chance.
    func resetFingerprintBookkeeping() {
        fingerprintFailures = []
        shortSimilarityBodies = []
    }

    // MARK: Deferred fingerprint backfill

    /// Computes the fingerprints the scan deferred (its dominant I/O
    /// cost) off the critical path: the list is already on screen, and the
    /// duplicate views fill in when this lands. One read per Skill feeds
    /// both the exact SHA-256 and the similarity SimHash. Read-only aside
    /// from the write-back into the index.
    func backfillMissingFingerprints(
        snapshots: [SkillSnapshot],
        authorizedRoots: [AuthorizedRootSnapshot],
        bookmarks: BookmarkStore?
    ) async {
        let pending = snapshots.filter {
            let needsContent = $0.contentFingerprint == nil
                && !fingerprintFailures.contains($0.path)
            let needsSimilarity = $0.similarityFingerprint == nil
                && !shortSimilarityBodies.contains($0.path)
                && !fingerprintFailures.contains($0.path)
            return needsContent || needsSimilarity
        }
        guard !pending.isEmpty else { return }

        // Reading content under the sandbox needs the roots' security
        // scopes; hold every resolvable lease for the whole hash pass.
        var accesses: [AuthorizedRootAccess] = []
        if let bookmarks {
            for root in authorizedRoots {
                if let access = try? bookmarks.resolve(id: root.id) {
                    accesses.append(access)
                }
            }
        }
        defer { accesses.forEach { $0.lease.close() } }

        let targets = pending.map { skill in
            // The scanner hashes the resolved target of a symlink, not the
            // logical path; mirror that so fingerprints agree.
            (
                path: skill.path,
                directory: skill.resolvedTarget ?? skill.path,
                entryFilename: skill.entryFilename
            )
        }
        let outcome = await Task.detached(priority: .utility) {
            () -> (
                fingerprints: [String: String],
                similarities: [String: String],
                shortBodies: [String],
                failures: [String]
            ) in
            var fingerprints: [String: String] = [:]
            var similarities: [String: String] = [:]
            var shortBodies: [String] = []
            var failures: [String] = []
            for target in targets {
                if Task.isCancelled { break }
                do {
                    let pair = try SkillSimilarityFingerprint.computePair(
                        entryFileURL: URL(fileURLWithPath: target.directory)
                            .appendingPathComponent(target.entryFilename)
                    )
                    fingerprints[target.path] = pair.content
                    if let similarity = pair.similarity {
                        similarities[target.path] = similarity
                    } else {
                        shortBodies.append(target.path)
                    }
                } catch {
                    failures.append(target.path)
                }
            }
            return (fingerprints, similarities, shortBodies, failures)
        }.value
        // Cancelled mid-hash (a newer scan or backfill replaced this one):
        // drop everything, the replacement recomputes.
        guard !Task.isCancelled else { return }

        fingerprintFailures.formUnion(outcome.failures)
        shortSimilarityBodies.formUnion(outcome.shortBodies)
        do {
            let result = try index.backfillFingerprints(
                contentByPath: outcome.fingerprints,
                similarityByPath: outcome.similarities
            )
            if result.updated > 0 {
                onFingerprintsBackfilled(result.updated, result.changedPaths)
            }
        } catch {
            // Non-fatal: the duplicate view simply stays without these
            // fingerprints until the next refresh re-defers them.
        }
    }

    /// Fires the background backfill when any snapshot is still missing a
    /// fingerprint. Replaces an in-flight backfill — its hashes may
    /// predate the scan that just reloaded the snapshots.
    func scheduleFingerprintBackfillIfNeeded(
        snapshots: [SkillSnapshot],
        authorizedRoots: [AuthorizedRootSnapshot],
        bookmarks: BookmarkStore?
    ) {
        guard snapshots.contains(where: { skill in
            (skill.contentFingerprint == nil && !fingerprintFailures.contains(skill.path))
                || (skill.similarityFingerprint == nil
                    && !shortSimilarityBodies.contains(skill.path)
                    && !fingerprintFailures.contains(skill.path))
        }) else { return }
        activeFingerprintBackfill?.task.cancel()
        let id = UUID()
        isBackfilling = true
        let task = Task { [weak self] in
            await self?.backfillMissingFingerprints(
                snapshots: snapshots,
                authorizedRoots: authorizedRoots,
                bookmarks: bookmarks
            )
            self?.clearFingerprintBackfill(id: id)
        }
        activeFingerprintBackfill = (id, task)
    }

    /// Waits for any in-flight background backfill. Test seam.
    func waitForFingerprintBackfill() async {
        if let active = activeFingerprintBackfill {
            await active.task.value
        }
    }

    private func clearFingerprintBackfill(id: UUID) {
        guard activeFingerprintBackfill?.id == id else { return }
        activeFingerprintBackfill = nil
        isBackfilling = false
    }

    // MARK: Body search index

    /// Rebuilds the folded body texts powering body search. Runs off the
    /// critical path after every snapshot reload; skills whose entry file
    /// cannot be read are simply absent from the index (name-only match).
    func rebuildBodySearchIndex(
        snapshots: [SkillSnapshot],
        authorizedRoots: [AuthorizedRootSnapshot],
        bookmarks: BookmarkStore?
    ) async {
        // Reading content under the sandbox needs the roots' security
        // scopes; hold every resolvable lease for the whole read pass.
        var accesses: [AuthorizedRootAccess] = []
        if let bookmarks {
            for root in authorizedRoots {
                if let access = try? bookmarks.resolve(id: root.id) {
                    accesses.append(access)
                }
            }
        }
        defer { accesses.forEach { $0.lease.close() } }

        let targets = snapshots.map { skill in
            // The scanner reads the resolved target of a symlink; mirror
            // that so the index sees the same content the scan saw.
            (
                path: skill.path,
                directory: skill.resolvedTarget ?? skill.path,
                entryFilename: skill.entryFilename
            )
        }
        let texts = await Task.detached(priority: .utility) {
            () -> [String: String] in
            var folded: [String: String] = [:]
            for target in targets {
                if Task.isCancelled { break }
                let entryURL = URL(fileURLWithPath: target.directory)
                    .appendingPathComponent(target.entryFilename)
                guard let fileSize = try? entryURL
                    .resourceValues(forKeys: [.fileSizeKey]).fileSize,
                      fileSize <= SkillDocumentReader.maximumRenderBytes,
                      let text = try? String(contentsOf: entryURL, encoding: .utf8)
                else { continue }
                let body = FrontmatterParser.bodyLines(from: text)
                    .joined(separator: "\n")
                folded[target.path] = SkillQuery.foldedSearchKey(body)
            }
            return folded
        }.value
        guard !Task.isCancelled else { return }
        bodySearchTextsByPath = texts
    }

    /// Fires (or replaces) the background body-index rebuild. The index is
    /// derived purely from disk state and rebuilt wholesale — no
    /// incremental bookkeeping for a few hundred small files.
    func scheduleBodySearchIndexRebuild(
        snapshots: [SkillSnapshot],
        authorizedRoots: [AuthorizedRootSnapshot],
        bookmarks: BookmarkStore?
    ) {
        activeBodyIndexBuild?.task.cancel()
        let id = UUID()
        let task = Task { [weak self] in
            await self?.rebuildBodySearchIndex(
                snapshots: snapshots,
                authorizedRoots: authorizedRoots,
                bookmarks: bookmarks
            )
            self?.clearBodySearchIndexBuild(id: id)
        }
        activeBodyIndexBuild = (id, task)
    }

    /// Waits for any in-flight body-index build. Test seam.
    func waitForBodySearchIndex() async {
        if let active = activeBodyIndexBuild {
            await active.task.value
        }
    }

    private func clearBodySearchIndexBuild(id: UUID) {
        guard activeBodyIndexBuild?.id == id else { return }
        activeBodyIndexBuild = nil
    }
}
