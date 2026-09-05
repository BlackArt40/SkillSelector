import Foundation
import GRDB

public enum SkillIndexError: Error, Equatable {
    case skillNotFound(path: String)
    case invalidAgentProvenance(path: String)
    case unableToEncodeAgentProvenance(path: String)
}

public final class SkillIndex {
    private let database: DatabaseQueue
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(database: DatabaseQueue) {
        self.database = database
    }

    public func apply(report: ScanReport) throws {
        try database.write { db in
            var records = try self.recordsByPath(db)
            var associationsByPath: [String: [String: Set<String>]] = [:]

            func associations(for path: String) throws -> [String: Set<String>] {
                if let cached = associationsByPath[path] { return cached }
                guard let record = records[path] else { return [:] }
                let value = try self.agentIDsByRoot(record)
                associationsByPath[path] = value
                return value
            }
            func setAssociations(_ value: [String: Set<String>], for path: String) throws {
                associationsByPath[path] = value
                guard var record = records[path] else { return }
                record.agentIDsByRootData = try self.encode(value, path: path)
                records[path] = record
                try record.upsert(db)
            }
            func drop(_ path: String) throws {
                guard records[path] != nil else { return }
                _ = try SkillRecord.deleteOne(db, key: path)
                records[path] = nil
                associationsByPath[path] = nil
            }

            // Roots that are no longer accessible drop their associated
            // records entirely (semantics unchanged from the SwiftData era).
            for root in report.roots {
                guard case .unavailable = root.availability else { continue }
                for path in Array(records.keys) {
                    var ass = try associations(for: path)
                    guard ass[root.id] != nil else { continue }
                    ass[root.id] = nil
                    if ass.isEmpty { try drop(path) } else { try setAssociations(ass, for: path) }
                }
            }

            for root in report.roots where root.availability == .available {
                let reportedPaths = Set(
                    report.installations
                        .filter { $0.rootIDs.contains(root.id) }
                        .map { $0.path.standardizedFileURL.path }
                )
                for path in Array(records.keys) {
                    var ass = try associations(for: path)
                    guard ass[root.id] != nil, !reportedPaths.contains(path) else { continue }
                    ass[root.id] = nil
                    if ass.isEmpty { try drop(path) } else { try setAssociations(ass, for: path) }
                }
            }

            for scanned in report.installations {
                let path = scanned.path.standardizedFileURL.path
                var record: SkillRecord
                if let existing = records[path] {
                    record = existing
                } else {
                    record = SkillRecord(
                        path: path,
                        name: resolvedName(for: scanned),
                        entryFilename: scanned.entryFilename
                    )
                    records[path] = record
                    associationsByPath[path] = [:]
                }
                try update(&record, from: scanned)
                records[path] = record
                try record.upsert(db)
                if let fresh = try? decoder.decode([String: Set<String>].self, from: record.agentIDsByRootData) {
                    associationsByPath[path] = fresh
                }
            }
            // 单事务：write 闭包抛错自动回滚，等价于原 context.rollback()
        }
    }

    public func skills() throws -> [SkillSnapshot] {
        let records = try database.read { db in
            try SkillRecord.order(Column("path")).fetchAll(db)
        }
        return try records.map { try snapshot($0) }
    }

    public func cachedScanEntries() throws -> [String: ScannedSkillCacheEntry] {
        var entries: [String: ScannedSkillCacheEntry] = [:]
        try database.read { db in
            for record in try SkillRecord.fetchAll(db) {
                guard let data = record.scanStateData,
                      let entry = try? decoder.decode(ScannedSkillCacheEntry.self, from: data) else { continue }
                if let fingerprint = entry.contentFingerprint,
                   !SkillContentFingerprint.isCurrentVersion(fingerprint) { continue }
                entries[record.path] = entry
            }
        }
        return entries
    }

    @discardableResult
    public func backfillContentFingerprints(_ fingerprintsByPath: [String: String]) throws -> Int {
        try backfillFingerprints(contentByPath: fingerprintsByPath, similarityByPath: [:])
    }

    @discardableResult
    public func backfillFingerprints(
        contentByPath: [String: String],
        similarityByPath: [String: String]
    ) throws -> Int {
        guard !contentByPath.isEmpty || !similarityByPath.isEmpty else { return 0 }
        // The write closure returns Void and mutates `updated`: GRDB 7's
        // sync `write` overload is disfavored against the async Sendable
        // one, and a value-returning tail-expression closure fails to
        // type-check under Swift 6 ("missing return in instance method").
        var updated = 0
        try database.write { db in
            var records = try self.recordsByPath(db)
            for (path, content) in contentByPath {
                guard var record = records[path] else { continue }
                let similarity = similarityByPath[path]
                guard record.contentFingerprint != content || record.similarityFingerprint != similarity else { continue }
                if record.contentFingerprint != content { record.contentFingerprint = content }
                if record.similarityFingerprint != similarity { record.similarityFingerprint = similarity }
                record.scanStateData = try self.cacheEntryData(record)
                records[path] = record
                try record.upsert(db)
                updated += 1
            }
            for (path, similarity) in similarityByPath where contentByPath[path] == nil {
                guard var record = records[path], record.similarityFingerprint != similarity else { continue }
                record.similarityFingerprint = similarity
                record.scanStateData = try self.cacheEntryData(record)
                records[path] = record
                try record.upsert(db)
                updated += 1
            }
        }
        return updated
    }

    @discardableResult
    public func setIgnoredDuplicateGroup(_ fingerprint: String, ignored: Bool) throws -> Int {
        var updated = 0
        try database.write { db in
            var records = try SkillRecord.fetchAll(db)
            for index in records.indices where records[index].contentFingerprint == fingerprint {
                let target = ignored ? fingerprint : nil
                guard records[index].ignoredDuplicateGroup != target else { continue }
                records[index].ignoredDuplicateGroup = target
                try records[index].upsert(db)
                updated += 1
            }
        }
        return updated
    }

    @discardableResult
    public func setIgnoredNearDuplicateGroup(
        paths: [String],
        key: String,
        ignored: Bool
    ) throws -> Int {
        var updated = 0
        try database.write { db in
            var records = try self.recordsByPath(db)
            for path in paths {
                guard var record = records[path] else { continue }
                let target = ignored ? key : nil
                guard record.ignoredNearDuplicateGroup != target else { continue }
                record.ignoredNearDuplicateGroup = target
                records[path] = record
                try record.upsert(db)
                updated += 1
            }
        }
        return updated
    }

    // MARK: - Private helpers

    /// Loads all records once, keyed by path. The old store's dedup note
    /// (cc4bc7b) no longer applies: the primary key on `path` makes duplicate
    /// rows impossible in a GRDB store, and the fresh-state policy means no
    /// legacy duplicated store is ever opened.
    private func recordsByPath(_ db: Database) throws -> [String: SkillRecord] {
        let records = try SkillRecord.order(Column("path")).fetchAll(db)
        return Dictionary(records.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func cacheEntryData(_ record: SkillRecord) throws -> Data? {
        guard let data = record.scanStateData,
              let entry = try? decoder.decode(ScannedSkillCacheEntry.self, from: data) else { return record.scanStateData }
        return try encoder.encode(ScannedSkillCacheEntry(
            state: entry.state,
            document: entry.document,
            contentFingerprint: record.contentFingerprint,
            similarityFingerprint: record.similarityFingerprint,
            entryModificationDate: entry.entryModificationDate
        ))
    }

    private func resolvedName(for scanned: ScannedSkill) -> String {
        scanned.document.name ?? scanned.document.title ?? scanned.path.lastPathComponent
    }

    private func update(_ record: inout SkillRecord, from scanned: ScannedSkill) throws {
        record.resolvedTarget = scanned.resolvedTarget?.standardizedFileURL.path
        record.name = resolvedName(for: scanned)
        record.localDescription = scanned.document.description
        record.modificationDate = scanned.entryModificationDate
        var associations = try agentIDsByRoot(record)
        for (rootID, agentIDs) in scanned.agentIDsByRoot {
            associations[rootID] = agentIDs
        }
        record.agentIDsByRootData = try encode(associations, path: record.path)
        record.entryFilename = scanned.entryFilename
        record.parseDiagnosticsData = (try? encoder.encode(scanned.document.issues)) ?? Data()
        record.contentFingerprint = scanned.contentFingerprint
        record.similarityFingerprint = scanned.similarityFingerprint
        if scanned.reusedCachedScan {
            // unchanged
        } else if let state = scanned.scanState {
            record.scanStateData = try encoder.encode(ScannedSkillCacheEntry(
                state: state,
                document: scanned.document,
                contentFingerprint: scanned.contentFingerprint,
                similarityFingerprint: scanned.similarityFingerprint,
                entryModificationDate: scanned.entryModificationDate
            ))
        } else {
            record.scanStateData = nil
        }
    }

    private func snapshot(_ record: SkillRecord) throws -> SkillSnapshot {
        let associations = try agentIDsByRoot(record)
        return SkillSnapshot(
            path: record.path,
            resolvedTarget: record.resolvedTarget,
            name: record.name,
            localDescription: record.localDescription,
            modificationDate: record.modificationDate,
            agentIDs: associations.values.reduce(into: Set<String>()) { $0.formUnion($1) }.sorted(),
            rootIDs: associations.keys.sorted(),
            entryFilename: record.entryFilename,
            parseDiagnostics: (try? decoder.decode([ParseIssue].self, from: record.parseDiagnosticsData)) ?? [],
            contentFingerprint: record.contentFingerprint,
            similarityFingerprint: record.similarityFingerprint,
            ignoredDuplicateGroup: record.ignoredDuplicateGroup,
            ignoredNearDuplicateGroup: record.ignoredNearDuplicateGroup
        )
    }

    private func agentIDsByRoot(_ record: SkillRecord) throws -> [String: Set<String>] {
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
