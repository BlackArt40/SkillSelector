import Foundation

public enum ToolKind: String, CaseIterable, Codable, Hashable, Sendable {
    case gh
    case npm
}

public enum ToolAvailabilityState: String, Codable, Hashable, Sendable {
    case unavailable
    case available
    case unauthenticated
    case invalid
}

public struct ToolLocation: Codable, Hashable, Sendable {
    public let kind: ToolKind
    public let executableURL: URL?
    public let bookmarkData: Data?
    public let state: ToolAvailabilityState
    public let version: String?

    public init(
        kind: ToolKind,
        executableURL: URL?,
        bookmarkData: Data?,
        state: ToolAvailabilityState,
        version: String? = nil
    ) {
        self.kind = kind
        self.executableURL = executableURL
        self.bookmarkData = bookmarkData
        self.state = state
        self.version = version
    }
}

public typealias ToolStatus = ToolLocation

public protocol ExecutableBookmarkStoring: AnyObject, Sendable {
    func bookmarkData(for tool: ToolKind) -> Data?
    func save(bookmarkData: Data, for tool: ToolKind) throws
}

public final class UserDefaultsExecutableBookmarkStore: ExecutableBookmarkStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let keyPrefix: String

    public init(defaults: UserDefaults = .standard, keyPrefix: String = "SkillSelector.toolBookmark.") {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    public func bookmarkData(for tool: ToolKind) -> Data? {
        defaults.data(forKey: keyPrefix + tool.rawValue)
    }

    public func save(bookmarkData: Data, for tool: ToolKind) throws {
        defaults.set(bookmarkData, forKey: keyPrefix + tool.rawValue)
    }
}

public actor ToolLocator {
    private let store: ExecutableBookmarkStoring
    private let bookmarkAdapter: any BookmarkDataCreating
    private let runner: any ExternalCommandRunning
    private let searchDirectories: [URL]

    public init(
        store: ExecutableBookmarkStoring = UserDefaultsExecutableBookmarkStore(),
        bookmarkAdapter: any BookmarkDataCreating = SecurityScopedBookmarkAdapter(),
        runner: any ExternalCommandRunning = ExternalCommandRunner(),
        searchDirectories: [URL]? = nil
    ) {
        self.store = store
        self.bookmarkAdapter = bookmarkAdapter
        self.runner = runner
        self.searchDirectories = searchDirectories ?? [
            URL(fileURLWithPath: "/opt/homebrew/bin"),
            URL(fileURLWithPath: "/usr/local/bin"),
            URL(fileURLWithPath: "/usr/bin"),
            URL(fileURLWithPath: "/bin"),
            URL(fileURLWithPath: "/usr/sbin"),
            URL(fileURLWithPath: "/sbin"),
        ]
    }

    public func locate(_ name: String) async -> ToolLocation {
        guard let kind = ToolKind(rawValue: name) else {
            return ToolLocation(kind: .gh, executableURL: nil, bookmarkData: nil, state: .invalid)
        }
        let candidate: (url: URL, data: Data?, isResolvedBookmark: Bool)?
        if let data = store.bookmarkData(for: kind) {
            do {
                let resolution = try bookmarkAdapter.resolveBookmarkData(data)
                let url = resolution.url.standardizedFileURL
                let refreshedData = resolution.isStale
                    ? try bookmarkAdapter.createBookmarkData(for: url)
                    : data
                candidate = (url, refreshedData, true)
            } catch {
                return ToolLocation(kind: kind, executableURL: nil, bookmarkData: data, state: .invalid)
            }
        } else if let url = searchDirectories
            .map({ $0.appendingPathComponent(kind.rawValue) })
            .first(where: isValidExecutable) {
            do {
                candidate = (url, try bookmarkAdapter.createBookmarkData(for: url), false)
            } catch {
                return ToolLocation(kind: kind, executableURL: url, bookmarkData: nil, state: .invalid)
            }
        } else {
            return ToolLocation(kind: kind, executableURL: nil, bookmarkData: nil, state: .unavailable)
        }

        guard let candidate else {
            return ToolLocation(kind: kind, executableURL: nil, bookmarkData: nil, state: .unavailable)
        }
        let url = candidate.url
        let data = candidate.data
        let didStartAccessing = candidate.isResolvedBookmark
            ? bookmarkAdapter.startAccessing(url)
            : false
        defer {
            if didStartAccessing { bookmarkAdapter.stopAccessing(url) }
        }

        guard isValidExecutable(url) else {
            return ToolLocation(kind: kind, executableURL: url, bookmarkData: data, state: .invalid)
        }
        let version: CommandResult
        do {
            version = try await runner.run(validationCommand(url: url, arguments: ["--version"]))
        } catch {
            return ToolLocation(kind: kind, executableURL: url, bookmarkData: data, state: .invalid)
        }
        guard version.succeeded else {
            return ToolLocation(kind: kind, executableURL: url, bookmarkData: data, state: .invalid)
        }
        let state: ToolAvailabilityState
        if kind == .gh {
            do {
                let auth = try await runner.run(validationCommand(url: url, arguments: ["auth", "status"]))
                guard auth.terminationReason == .exit else {
                    return ToolLocation(kind: kind, executableURL: url, bookmarkData: data, state: .invalid)
                }
                state = auth.terminationStatus == 0 ? .available : .unauthenticated
            } catch {
                return ToolLocation(kind: kind, executableURL: url, bookmarkData: data, state: .invalid)
            }
        } else {
            state = .available
        }
        if let data {
            do {
                try store.save(bookmarkData: data, for: kind)
            } catch {
                return ToolLocation(kind: kind, executableURL: url, bookmarkData: data, state: .invalid)
            }
        }
        return ToolLocation(
            kind: kind,
            executableURL: url,
            bookmarkData: data,
            state: state,
            version: version.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    public func bind(_ executableURL: URL, as kind: ToolKind) async throws -> ToolLocation {
        let url = executableURL.standardizedFileURL
        guard isValidExecutable(url) else {
            return ToolLocation(kind: kind, executableURL: url, bookmarkData: nil, state: .invalid)
        }
        let data = try bookmarkAdapter.createBookmarkData(for: url)
        try store.save(bookmarkData: data, for: kind)
        return await locate(kind.rawValue)
    }

    private func isValidExecutable(_ url: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: url.path)
    }

    private func validationCommand(url: URL, arguments: [String]) -> ExternalCommand {
        ExternalCommand(
            executableURL: url,
            arguments: arguments,
            timeout: 5,
            maximumOutputBytes: 64 * 1024
        )
    }
}
