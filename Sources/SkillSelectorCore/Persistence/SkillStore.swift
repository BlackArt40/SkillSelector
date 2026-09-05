import Foundation
import GRDB

/// Opens (and version-migrates) the single on-disk index database.
/// Schema mirrors the pre-GRDB SwiftData models column-for-column; future
/// schema changes go through registered migrations, never edits to "v1".
public enum SkillStore {
    public static func open(url: URL) throws -> DatabaseQueue {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let queue = try DatabaseQueue(path: url.path)
        try migrator().migrate(queue)
        return queue
    }

    public static func inMemory() throws -> DatabaseQueue {
        // GRDB 7: the independent in-memory database is the default
        // `DatabaseQueue()` initializer (`:memory:`); the GRDB 6-era
        // `DatabaseQueue.inMemory()` factory no longer exists.
        let queue = try DatabaseQueue()
        try migrator().migrate(queue)
        return queue
    }

    private static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "skillRecords") { t in
                t.column("path", .text).primaryKey()
                t.column("resolvedTarget", .text)
                t.column("name", .text).notNull()
                t.column("localDescription", .text)
                t.column("modificationDate", .datetime)
                t.column("agentIDsByRootData", .blob).notNull()
                t.column("entryFilename", .text).notNull()
                t.column("parseDiagnosticsData", .blob).notNull()
                t.column("contentFingerprint", .text)
                t.column("similarityFingerprint", .text)
                t.column("ignoredDuplicateGroup", .text)
                t.column("ignoredNearDuplicateGroup", .text)
                t.column("scanStateData", .blob)
            }
            try db.create(table: "authorizedRootRecords") { t in
                t.column("id", .text).primaryKey()
                t.column("path", .text).notNull().unique()
                t.column("kindRawValue", .text).notNull()
                t.column("bookmarkData", .blob).notNull()
            }
        }
        return migrator
    }
}
