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
                    var associations = try agentIDsByRoot(for: record)
                    guard associations[root.id] != nil else { continue }
                    associations[root.id] = nil
                    if associations.isEmpty {
                        context.delete(record)
                        records[record.path] = nil
                    } else {
                        record.agentIDsByRootData = try encode(associations, path: record.path)
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
                    var associations = try agentIDsByRoot(for: record)
                    guard associations[root.id] != nil,
                          !reportedPaths.contains(record.path) else {
                        continue
                    }
                    associations[root.id] = nil
                    if associations.isEmpty {
                        context.delete(record)
                        records[record.path] = nil
                    } else {
                        record.agentIDsByRootData = try encode(associations, path: record.path)
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
            parseDiagnostics: (try? decoder.decode([ParseIssue].self, from: record.parseDiagnosticsData)) ?? []
        )
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
