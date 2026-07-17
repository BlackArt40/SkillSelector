import Foundation
import SwiftData

public final class SkillIndex {
    private let context: ModelContext
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(container: ModelContainer) {
        context = ModelContext(container)
    }

    public func apply(report: ScanReport) throws {
        var records = try recordsByPath()

        for root in report.roots {
            guard case .unavailable(let reason) = root.availability else { continue }
            for record in records.values where agentIDsByRoot(for: record)[root.id] != nil {
                record.availabilityRawValue = SkillAvailability.unavailable.rawValue
                record.unavailableReason = reason
            }
        }

        for root in report.roots where root.availability == .available {
            let reportedPaths = Set(
                report.installations
                    .filter { $0.rootIDs.contains(root.id) }
                    .map { $0.path.standardizedFileURL.path }
            )
            for record in Array(records.values)
                where agentIDsByRoot(for: record)[root.id] != nil
                    && !reportedPaths.contains(record.path) {
                var associations = agentIDsByRoot(for: record)
                associations[root.id] = nil
                if associations.isEmpty {
                    context.delete(record)
                    records[record.path] = nil
                } else {
                    record.agentIDsByRootData = encode(associations)
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
                    name: scanned.document.name
                        ?? scanned.document.title
                        ?? scanned.path.lastPathComponent,
                    entryFilename: scanned.entryFilename
                )
                context.insert(record)
                records[path] = record
            }
            update(record, from: scanned)
        }

        try context.save()
    }

    public func skills() throws -> [SkillSnapshot] {
        let descriptor = FetchDescriptor<SkillRecord>(
            sortBy: [SortDescriptor(\.path)]
        )
        return try context.fetch(descriptor).map(snapshot)
    }

    private func recordsByPath() throws -> [String: SkillRecord] {
        Dictionary(
            uniqueKeysWithValues: try context.fetch(FetchDescriptor<SkillRecord>())
                .map { ($0.path, $0) }
        )
    }

    private func update(_ record: SkillRecord, from scanned: ScannedSkill) {
        record.resolvedTarget = scanned.resolvedTarget?.standardizedFileURL.path
        record.name = scanned.document.name
            ?? scanned.document.title
            ?? scanned.path.lastPathComponent
        record.localDescription = scanned.document.description
        record.modificationDate = scanned.entryModificationDate
        record.availabilityRawValue = SkillAvailability.available.rawValue
        record.unavailableReason = nil
        var associations = agentIDsByRoot(for: record)
        for (rootID, agentIDs) in scanned.agentIDsByRoot {
            associations[rootID] = agentIDs
        }
        record.agentIDsByRootData = encode(associations)
        record.entryFilename = scanned.entryFilename
        record.parseDiagnosticsData = (try? encoder.encode(scanned.document.issues)) ?? Data()
    }

    private func snapshot(_ record: SkillRecord) -> SkillSnapshot {
        let associations = agentIDsByRoot(for: record)
        return SkillSnapshot(
            path: record.path,
            resolvedTarget: record.resolvedTarget,
            name: record.name,
            localDescription: record.localDescription,
            enrichedDescription: record.enrichedDescription,
            enrichedDescriptionProvenance: record.enrichedDescriptionProvenance,
            customDescription: record.customDescription,
            digest: record.digest,
            modificationDate: record.modificationDate,
            availability: SkillAvailability(rawValue: record.availabilityRawValue) ?? .unavailable,
            unavailableReason: record.unavailableReason,
            sourceBinding: record.sourceBinding,
            agentIDs: associations.values.reduce(into: Set<String>()) { result, agentIDs in
                result.formUnion(agentIDs)
            }.sorted(),
            rootIDs: associations.keys.sorted(),
            entryFilename: record.entryFilename,
            parseDiagnostics: (try? decoder.decode([ParseIssue].self, from: record.parseDiagnosticsData)) ?? []
        )
    }

    private func agentIDsByRoot(for record: SkillRecord) -> [String: Set<String>] {
        (try? decoder.decode([String: Set<String>].self, from: record.agentIDsByRootData)) ?? [:]
    }

    private func encode(_ associations: [String: Set<String>]) -> Data {
        (try? encoder.encode(associations)) ?? Data()
    }
}
