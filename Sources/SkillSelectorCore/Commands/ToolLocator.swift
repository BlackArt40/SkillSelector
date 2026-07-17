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

public protocol ExecutableBookmarkStoring: AnyObject {
    func bookmarkData(for tool: ToolKind) -> Data?
    func save(bookmarkData: Data, for tool: ToolKind) throws
}

public final class UserDefaultsExecutableBookmarkStore: ExecutableBookmarkStoring {
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

public final class ToolLocator {
    private let store: ExecutableBookmarkStoring
    private let bookmarkAdapter: any BookmarkDataCreating
    private let runner: ExternalCommandRunner
    private let searchDirectories: [URL]

    public init(
        store: ExecutableBookmarkStoring = UserDefaultsExecutableBookmarkStore(),
        bookmarkAdapter: any BookmarkDataCreating = SecurityScopedBookmarkAdapter(),
        runner: ExternalCommandRunner = ExternalCommandRunner(),
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

    /// Locate and validate a supported executable. The method is synchronous
    /// so environment checks can run during app launch without an async UI hop.
    public func locate(_ name: String) -> ToolLocation {
        guard let kind = ToolKind(rawValue: name) else {
            return ToolLocation(kind: .gh, executableURL: nil, bookmarkData: nil, state: .invalid)
        }
        let candidate: (URL, Data?)?
        if let data = store.bookmarkData(for: kind) {
            do {
                let resolution = try bookmarkAdapter.resolveBookmarkData(data)
                let url = resolution.url.standardizedFileURL
                guard isValidExecutable(url) else {
                    return ToolLocation(kind: kind, executableURL: url, bookmarkData: data, state: .invalid)
                }
                let refreshedData = resolution.isStale
                    ? (try? bookmarkAdapter.createBookmarkData(for: url)) ?? data
                    : data
                candidate = (url, refreshedData)
            } catch {
                return ToolLocation(kind: kind, executableURL: nil, bookmarkData: data, state: .invalid)
            }
        } else if let url = searchDirectories
            .map({ $0.appendingPathComponent(kind.rawValue) })
            .first(where: isValidExecutable) {
            do {
                candidate = (url, try bookmarkAdapter.createBookmarkData(for: url))
            } catch {
                return ToolLocation(kind: kind, executableURL: url, bookmarkData: nil, state: .invalid)
            }
        } else {
            return ToolLocation(kind: kind, executableURL: nil, bookmarkData: nil, state: .unavailable)
        }

        guard let (url, data) = candidate else {
            return ToolLocation(kind: kind, executableURL: nil, bookmarkData: nil, state: .unavailable)
        }
        let version = runSync(url: url, arguments: ["--version"])
        guard let version, version.status == 0 else {
            return ToolLocation(kind: kind, executableURL: url, bookmarkData: data, state: .invalid)
        }
        let state: ToolAvailabilityState
        if kind == .gh {
            let auth = runSync(url: url, arguments: ["auth", "status"])
            state = auth?.status == 0 ? .available : .unauthenticated
        } else {
            state = .available
        }
        if let data { try? store.save(bookmarkData: data, for: kind) }
        return ToolLocation(kind: kind, executableURL: url, bookmarkData: data, state: state, version: version.output)
    }

    public func bind(_ executableURL: URL, as kind: ToolKind) throws -> ToolLocation {
        let url = executableURL.standardizedFileURL
        guard isValidExecutable(url) else {
            return ToolLocation(kind: kind, executableURL: url, bookmarkData: nil, state: .invalid)
        }
        let data = try bookmarkAdapter.createBookmarkData(for: url)
        try store.save(bookmarkData: data, for: kind)
        return locate(kind.rawValue)
    }

    private func isValidExecutable(_ url: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: url.path)
    }

    private func runSync(url: URL, arguments: [String]) -> (status: Int32, output: String)? {
        let process = Process()
        process.executableURL = url
        process.arguments = arguments
        process.environment = ["PATH": ExternalCommandRunner.defaultPath, "LC_ALL": "en_US.UTF-8", "LANG": "en_US.UTF-8"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return nil }
        if finished.wait(timeout: .now() + 5) == .timedOut {
            if process.isRunning { process.terminate() }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            return nil
        }
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
