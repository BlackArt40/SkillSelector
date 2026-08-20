import Foundation
import SwiftData

public enum SkillIndexError: Error, Equatable {
    case skillNotFound(path: String)
    case invalidAgentProvenance(path: String)
    case unableToEncodeAgentProvenance(path: String)
}

public final class SkillIndex {
    private let context: ModelContext
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(container: ModelContainer) {
        context = ModelContext(container)
    }

    public func apply(report: ScanReport) throws {
        do {
            var records = try recordsByPath()

            // Roots that are no longer accessible (missing directory, revoked
            // authorization) drop their associated records entirely: the index
            // only ever reflects Skills that exist on disk right now.
            for root in report.roots {
                guard case .unavailable = root.availability else { continue }
                for record in Array(records.values) {
                    if try disassociate(record, rootID: root.id) == .deleted {
                        records[record.path] = nil
                    }
                }
            }

            for root in report.roots where root.availability == .available {
                let reportedPaths = Set(
                    report.installations
                        .filter { $0.rootIDs.contains(root.id) }
                        .map { $0.path.standardizedFileURL.path }
                )
                for record in Array(records.values) {
                    guard try agentIDsByRoot(for: record)[root.id] != nil,
                          !reportedPaths.contains(record.path) else {
                        continue
                    }
                    if try disassociate(record, rootID: root.id) == .deleted {
                        records[record.path] = nil
                    }
                }
            }

            for scanned in report.installations {
                let path = scanned.path.standardizedFileURL.path
                let record: SkillRecord
                if let existing = records[path] {
                    record = existing
                } else {
                    record = SkillRecord(
                        path: path,
                        name: resolvedName(for: scanned),
                        entryFilename: scanned.entryFilename
                    )
                    context.insert(record)
                    records[path] = record
                }
                try update(record, from: scanned)
            }

            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    public func skills() throws -> [SkillSnapshot] {
        let descriptor = FetchDescriptor<SkillRecord>(
            sortBy: [SortDescriptor(\.path)]
        )
        return try context.fetch(descriptor).map { try snapshot($0) }
    }

    /// The persisted incremental-scan cache: last fresh scan state and its
    /// derived data, by installation path. Records without a trustworthy
    /// state are absent — they simply rescan.
    public func cachedScanEntries() throws -> [String: ScannedSkillCacheEntry] {
        var entries: [String: ScannedSkillCacheEntry] = [:]
        for record in try context.fetch(FetchDescriptor<SkillRecord>()) {
            guard let data = record.scanStateData,
                  let entry = try? decoder.decode(ScannedSkillCacheEntry.self, from: data) else {
                continue
            }
            entries[record.path] = entry
        }
        return entries
    }

    /// Writes fingerprints deferred from the scan (computed in the
    /// background after the list was shown) into their records and their
    /// incremental-scan cache entries, so the next cache hit serves the
    /// fingerprint without re-reading the files. Paths without a record are
    /// skipped — the Skill is gone and the next scan drops it anyway.
    /// Returns how many records were updated.
    @discardableResult
    public func backfillContentFingerprints(_ fingerprintsByPath: [String: String]) throws -> Int {
        guard !fingerprintsByPath.isEmpty else { return 0 }
        do {
            let records = try recordsByPath()
            var updated = 0
            for (path, fingerprint) in fingerprintsByPath {
                guard let record = records[path],
                      record.contentFingerprint != fingerprint else {
                    continue
                }
                record.contentFingerprint = fingerprint
                if let data = record.scanStateData,
                   let entry = try? decoder.decode(ScannedSkillCacheEntry.self, from: data) {
                    record.scanStateData = try encoder.encode(ScannedSkillCacheEntry(
                        state: entry.state,
                        document: entry.document,
                        contentFingerprint: fingerprint,
                        entryModificationDate: entry.entryModificationDate
                    ))
                }
                updated += 1
            }
            if updated > 0 {
                try context.save()
            }
            return updated
        } catch {
            context.rollback()
            throw error
        }
    }

    private func requiredRecord(path: String) throws -> SkillRecord {
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        guard let record = try context.fetch(FetchDescriptor<SkillRecord>())
            .first(where: { $0.path == normalizedPath }) else {
            throw SkillIndexError.skillNotFound(path: normalizedPath)
        }
        return record
    }

    private func resolvedName(for scanned: ScannedSkill) -> String {
        scanned.document.name
            ?? scanned.document.title
            ?? scanned.path.lastPathComponent
    }

    private func recordsByPath() throws -> [String: SkillRecord] {
        Dictionary(
            uniqueKeysWithValues: try context.fetch(FetchDescriptor<SkillRecord>())
                .map { ($0.path, $0) }
        )
    }

    private func update(_ record: SkillRecord, from scanned: ScannedSkill) throws {
        record.resolvedTarget = scanned.resolvedTarget?.standardizedFileURL.path
        record.name = resolvedName(for: scanned)
        record.localDescription = scanned.document.description
        record.modificationDate = scanned.entryModificationDate
        var associations = try agentIDsByRoot(for: record)
        for (rootID, agentIDs) in scanned.agentIDsByRoot {
            associations[rootID] = agentIDs
        }
        record.agentIDsByRootData = try encode(associations, path: record.path)
        record.entryFilename = scanned.entryFilename
        record.parseDiagnosticsData = (try? encoder.encode(scanned.document.issues)) ?? Data()
        record.contentFingerprint = scanned.contentFingerprint
        // Fresh scans persist their stat state for the next incremental
        // pass; cache hits keep what they have; diagnostic candidates have
        // no trustworthy state and drop any stale one.
        if scanned.reusedCachedScan {
            // unchanged
        } else if let state = scanned.scanState {
            record.scanStateData = try encoder.encode(ScannedSkillCacheEntry(
                state: state,
                document: scanned.document,
                contentFingerprint: scanned.contentFingerprint,
                entryModificationDate: scanned.entryModificationDate
            ))
        } else {
            record.scanStateData = nil
        }
    }

    private func snapshot(_ record: SkillRecord) throws -> SkillSnapshot {
        let associations = try agentIDsByRoot(for: record)
        return SkillSnapshot(
            path: record.path,
            resolvedTarget: record.resolvedTarget,
            name: record.name,
            localDescription: record.localDescription,
            modificationDate: record.modificationDate,
            agentIDs: associations.values.reduce(into: Set<String>()) { result, agentIDs in
                result.formUnion(agentIDs)
            }.sorted(),
            rootIDs: associations.keys.sorted(),
            entryFilename: record.entryFilename,
            parseDiagnostics: (try? decoder.decode([ParseIssue].self, from: record.parseDiagnosticsData)) ?? [],
            contentFingerprint: record.contentFingerprint
        )
    }

    private enum DisassociationOutcome {
        case untouched
        case updated
        case deleted
    }

    /// Drops the record's association with `rootID`; a record left with no
    /// associations is deleted so the index only holds on-disk Skills.
    private func disassociate(_ record: SkillRecord, rootID: String) throws -> DisassociationOutcome {
        var associations = try agentIDsByRoot(for: record)
        guard associations[rootID] != nil else { return .untouched }
        associations[rootID] = nil
        if associations.isEmpty {
            context.delete(record)
            return .deleted
        }
        record.agentIDsByRootData = try encode(associations, path: record.path)
        return .updated
    }

    private func agentIDsByRoot(for record: SkillRecord) throws -> [String: Set<String>] {
        do {
            return try decoder.decode([String: Set<String>].self, from: record.agentIDsByRootData)
        } catch {
            throw SkillIndexError.invalidAgentProvenance(path: record.path)
        }
    }

    private func encode(_ associations: [String: Set<String>], path: String) throws -> Data {
        do {
            return try encoder.encode(associations)
        } catch {
            throw SkillIndexError.unableToEncodeAgentProvenance(path: path)
        }
    }
}
