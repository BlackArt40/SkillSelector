import Foundation
import GRDB

public struct BookmarkResolution: Hashable, Sendable {
    public let url: URL
    public let isStale: Bool

    public init(url: URL, isStale: Bool) {
        self.url = url.standardizedFileURL
        self.isStale = isStale
    }
}

public protocol BookmarkDataCreating: AnyObject, Sendable {
    func createBookmarkData(for url: URL) throws -> Data
    func resolveBookmarkData(_ data: Data) throws -> BookmarkResolution
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
}

public final class SecurityScopedBookmarkAdapter: BookmarkDataCreating, @unchecked Sendable {
    public init() {}

    public func createBookmarkData(for url: URL) throws -> Data {
        // Prefer security-scoped bookmarks (required for sandboxed apps to
        // restore access across launches). On bare-binary dev launches the
        // entitlement is absent — fall back to a plain bookmark so the
        // authorization flow still works during development (re-pick the
        // directory after a relaunch; the bundled .app is signed with
        // `com.apple.security.files.bookmarks.app-scope` and takes the
        // security-scoped path).
        do {
            return try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            return try url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        }
    }

    public func resolveBookmarkData(_ data: Data) throws -> BookmarkResolution {
        var isStale = false
        if let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) {
            return BookmarkResolution(url: url, isStale: isStale)
        }
        let url = try URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return BookmarkResolution(url: url, isStale: isStale)
    }

    public func startAccessing(_ url: URL) -> Bool {
        // Best-effort: security-scoped access succeeds for sandboxed apps;
        // returns true unconditionally for plain bookmarks (the file
        // permission is checked at I/O time).
        url.startAccessingSecurityScopedResource()
        return true
    }

    public func stopAccessing(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
}

public final class AccessLease: @unchecked Sendable {
    private let lock = NSLock()
    private var closeAction: (() -> Void)?

    init(closeAction: (() -> Void)?) {
        self.closeAction = closeAction
    }

    public func close() {
        lock.lock()
        let action = closeAction
        closeAction = nil
        lock.unlock()
        action?()
    }

    deinit {
        close()
    }
}

public struct AuthorizedRootAccess: Sendable {
    public let root: AuthorizedRootSnapshot
    public let lease: AccessLease
}

private final class WeakAccessLease {
    weak var value: AccessLease?

    init(_ value: AccessLease) {
        self.value = value
    }
}

public enum BookmarkStoreError: Error, Equatable {
    case rootNotFound(String)
    case invalidRootKind(String)
    case duplicateRootPath(String)
}

public final class BookmarkStore {
    private let database: DatabaseQueue
    private let adapter: any BookmarkDataCreating
    private let accessLock = NSLock()
    private var activeAccesses: [String: [UUID: WeakAccessLease]] = [:]

    public init(
        database: DatabaseQueue,
        adapter: any BookmarkDataCreating = SecurityScopedBookmarkAdapter()
    ) {
        self.database = database
        self.adapter = adapter
    }

    @discardableResult
    public func save(url: URL, kind: AuthorizedRootKind) throws -> AuthorizedRootSnapshot {
        var url = url.standardizedFileURL
        // Audit F-09: on case-insensitive filesystems (the APFS default) a
        // user can authorize the same directory with a different case than
        // the scanner sees. Uniformize the spelling when the resolved path
        // is the same directory — but only then, so a genuine symlink's
        // logical identity is preserved.
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        if resolved.path.compare(url.path, options: .caseInsensitive) == .orderedSame {
            url = resolved
        }
        let data = try adapter.createBookmarkData(for: url)
        let records = try database.read {
            try AuthorizedRootRecord.filter(Column("path") == url.path).fetchAll($0)
        }
        let record: AuthorizedRootRecord
        if var existing = records.first {
            existing.kindRawValue = kind.rawValue
            existing.bookmarkData = data
            record = existing
            try database.write { try record.upsert($0) }
        } else {
            record = AuthorizedRootRecord(path: url.path, kind: kind, bookmarkData: data)
            try database.write { try record.upsert($0) }
        }
        return AuthorizedRootSnapshot(id: record.id, url: url, kind: kind)
    }

    public func resolve(id: String) throws -> AuthorizedRootAccess {
        guard var record = try record(id: id) else {
            throw BookmarkStoreError.rootNotFound(id)
        }
        guard let kind = AuthorizedRootKind(rawValue: record.kindRawValue) else {
            throw BookmarkStoreError.invalidRootKind(record.kindRawValue)
        }

        let resolution: BookmarkResolution
        do {
            resolution = try adapter.resolveBookmarkData(record.bookmarkData)
        } catch {
            // A bookmark that can no longer be resolved (for example one
            // created outside the sandbox in an earlier session) is rebuilt
            // from the recorded path so the root heals itself on next use.
            let rebuilt = try adapter.createBookmarkData(
                for: URL(fileURLWithPath: record.path)
            )
            record.bookmarkData = rebuilt
            try database.write { try record.upsert($0) }
            resolution = try adapter.resolveBookmarkData(rebuilt)
        }
        let url = resolution.url.standardizedFileURL
        if resolution.isStale {
            let records = try database.read {
                try AuthorizedRootRecord.filter(Column("path") == url.path).fetchAll($0)
            }
            if records.contains(where: { $0.id != record.id }) {
                throw BookmarkStoreError.duplicateRootPath(url.path)
            }
            record.bookmarkData = try adapter.createBookmarkData(for: url)
            record.path = url.path
            try database.write { try record.upsert($0) }
        }

        let didStart = adapter.startAccessing(url)
        let adapter = self.adapter
        let accessID = UUID()
        let rootID = record.id
        let lease = AccessLease { [weak self] in
            if didStart { adapter.stopAccessing(url) }
            self?.removeActiveAccess(id: accessID, rootID: rootID)
        }
        accessLock.lock()
        activeAccesses[rootID, default: [:]][accessID] = WeakAccessLease(lease)
        accessLock.unlock()
        return AuthorizedRootAccess(
            root: AuthorizedRootSnapshot(id: record.id, url: url, kind: kind),
            lease: lease
        )
    }

    public func roots() throws -> [AuthorizedRootSnapshot] {
        let records = try database.read {
            try AuthorizedRootRecord.order(Column("path")).fetchAll($0)
        }
        return try records.map { record in
            guard let kind = AuthorizedRootKind(rawValue: record.kindRawValue) else {
                throw BookmarkStoreError.invalidRootKind(record.kindRawValue)
            }
            return AuthorizedRootSnapshot(
                id: record.id,
                url: URL(fileURLWithPath: record.path),
                kind: kind
            )
        }
    }

    public func revoke(id: String) throws {
        guard try record(id: id) != nil else {
            throw BookmarkStoreError.rootNotFound(id)
        }
        accessLock.lock()
        let leases = activeAccesses.removeValue(forKey: id)?.values.compactMap(\.value) ?? []
        accessLock.unlock()
        leases.forEach { $0.close() }
        try database.write { _ = try AuthorizedRootRecord.deleteOne($0, key: id) }
    }

    private func record(id: String) throws -> AuthorizedRootRecord? {
        let record = try database.read {
            try AuthorizedRootRecord.filter(Column("id") == id).fetchOne($0)
        }
        return record
    }



    private func removeActiveAccess(id: UUID, rootID: String) {
        accessLock.lock()
        activeAccesses[rootID]?[id] = nil
        if activeAccesses[rootID]?.isEmpty == true {
            activeAccesses[rootID] = nil
        }
        accessLock.unlock()
    }
}
