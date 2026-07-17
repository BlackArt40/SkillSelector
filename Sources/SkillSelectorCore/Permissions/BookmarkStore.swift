import Foundation
import SwiftData

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
        try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    public func resolveBookmarkData(_ data: Data) throws -> BookmarkResolution {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return BookmarkResolution(url: url, isStale: isStale)
    }

    public func startAccessing(_ url: URL) -> Bool {
        url.startAccessingSecurityScopedResource()
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

public enum BookmarkStoreError: Error, Equatable {
    case rootNotFound(String)
    case invalidRootKind(String)
    case duplicateRootPath(String)
}

public final class BookmarkStore {
    private let context: ModelContext
    private let adapter: any BookmarkDataCreating

    public init(
        container: ModelContainer,
        adapter: any BookmarkDataCreating = SecurityScopedBookmarkAdapter()
    ) {
        context = ModelContext(container)
        self.adapter = adapter
    }

    @discardableResult
    public func save(url: URL, kind: AuthorizedRootKind) throws -> AuthorizedRootSnapshot {
        let url = url.standardizedFileURL
        let data = try adapter.createBookmarkData(for: url)
        let records = try context.fetch(FetchDescriptor<AuthorizedRootRecord>())
        let record: AuthorizedRootRecord
        if let existing = records.first(where: { $0.path == url.path }) {
            existing.kindRawValue = kind.rawValue
            existing.bookmarkData = data
            record = existing
        } else {
            record = AuthorizedRootRecord(path: url.path, kind: kind, bookmarkData: data)
            context.insert(record)
        }
        try context.save()
        return AuthorizedRootSnapshot(id: record.id, url: url, kind: kind)
    }

    public func resolve(id: String) throws -> AuthorizedRootAccess {
        guard let record = try record(id: id) else {
            throw BookmarkStoreError.rootNotFound(id)
        }
        guard let kind = AuthorizedRootKind(rawValue: record.kindRawValue) else {
            throw BookmarkStoreError.invalidRootKind(record.kindRawValue)
        }

        let resolution = try adapter.resolveBookmarkData(record.bookmarkData)
        let url = resolution.url.standardizedFileURL
        if resolution.isStale {
            let records = try context.fetch(FetchDescriptor<AuthorizedRootRecord>())
            if records.contains(where: { $0.id != record.id && $0.path == url.path }) {
                throw BookmarkStoreError.duplicateRootPath(url.path)
            }
            record.bookmarkData = try adapter.createBookmarkData(for: url)
            record.path = url.path
            try context.save()
        }

        let didStart = adapter.startAccessing(url)
        let adapter = self.adapter
        let lease = AccessLease(closeAction: didStart ? { adapter.stopAccessing(url) } : nil)
        return AuthorizedRootAccess(
            root: AuthorizedRootSnapshot(id: record.id, url: url, kind: kind),
            lease: lease
        )
    }

    public func roots() throws -> [AuthorizedRootSnapshot] {
        let descriptor = FetchDescriptor<AuthorizedRootRecord>(
            sortBy: [SortDescriptor(\.path)]
        )
        return try context.fetch(descriptor).map { record in
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

    private func record(id: String) throws -> AuthorizedRootRecord? {
        try context.fetch(FetchDescriptor<AuthorizedRootRecord>())
            .first { $0.id == id }
    }
}
