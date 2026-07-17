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

public final class ToolAccess: @unchecked Sendable {
    public let location: ToolLocation
    public let executableURL: URL
    public let authorizedHomeURL: URL
    private let leases: [AccessLease]

    fileprivate init(
        location: ToolLocation,
        executableURL: URL,
        authorizedHomeURL: URL,
        leases: [AccessLease]
    ) {
        self.location = location
        self.executableURL = executableURL.standardizedFileURL
        self.authorizedHomeURL = authorizedHomeURL.standardizedFileURL
        self.leases = leases
    }

    public func close() {
        leases.forEach { $0.close() }
    }

    deinit {
        close()
    }
}

public struct ToolAccessResult: Sendable {
    public let location: ToolLocation
    public let access: ToolAccess?

    fileprivate init(location: ToolLocation, access: ToolAccess?) {
        self.location = location
        self.access = access
    }
}

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
        let result = await resolveAccess(kind: kind, authorizedHomeAccess: nil)
        result.access?.close()
        return result.location
    }

    public func openAccess(
        _ kind: ToolKind,
        authorizedHomeAccess: AuthorizedRootAccess
    ) async -> ToolAccessResult {
        await resolveAccess(kind: kind, authorizedHomeAccess: authorizedHomeAccess)
    }

    private func resolveAccess(
        kind: ToolKind,
        authorizedHomeAccess: AuthorizedRootAccess?
    ) async -> ToolAccessResult {
        var leases = authorizedHomeAccess.map { [$0.lease] } ?? []
        var transfersLeases = false
        defer {
            if !transfersLeases {
                leases.forEach { $0.close() }
            }
        }

        if let authorizedHomeAccess, authorizedHomeAccess.root.kind != .home {
            return ToolAccessResult(
                location: ToolLocation(
                    kind: kind,
                    executableURL: nil,
                    bookmarkData: nil,
                    state: .invalid
                ),
                access: nil
            )
        }
        let candidate: (url: URL, data: Data?)?
        if let data = store.bookmarkData(for: kind) {
            do {
                let resolution = try bookmarkAdapter.resolveBookmarkData(data)
                let url = resolution.url.standardizedFileURL
                let refreshedData = resolution.isStale
                    ? try bookmarkAdapter.createBookmarkData(for: url)
                    : data
                candidate = (url, refreshedData)
            } catch {
                return ToolAccessResult(
                    location: ToolLocation(kind: kind, executableURL: nil, bookmarkData: data, state: .invalid),
                    access: nil
                )
            }
        } else if let url = searchDirectories
            .map({ $0.appendingPathComponent(kind.rawValue) })
            .first(where: isValidExecutable) {
            do {
                let data = try bookmarkAdapter.createBookmarkData(for: url)
                let resolution = try bookmarkAdapter.resolveBookmarkData(data)
                let resolvedURL = resolution.url.standardizedFileURL
                let refreshedData = resolution.isStale
                    ? try bookmarkAdapter.createBookmarkData(for: resolvedURL)
                    : data
                candidate = (resolvedURL, refreshedData)
            } catch {
                return ToolAccessResult(
                    location: ToolLocation(kind: kind, executableURL: url, bookmarkData: nil, state: .invalid),
                    access: nil
                )
            }
        } else {
            return ToolAccessResult(
                location: ToolLocation(kind: kind, executableURL: nil, bookmarkData: nil, state: .unavailable),
                access: nil
            )
        }

        guard let candidate else {
            return ToolAccessResult(
                location: ToolLocation(kind: kind, executableURL: nil, bookmarkData: nil, state: .unavailable),
                access: nil
            )
        }
        let url = candidate.url
        let data = candidate.data
        let didStartAccessing = bookmarkAdapter.startAccessing(url)
        let adapter = bookmarkAdapter
        leases.append(AccessLease(
            closeAction: didStartAccessing ? { adapter.stopAccessing(url) } : nil
        ))

        guard isValidExecutable(url) else {
            return ToolAccessResult(
                location: ToolLocation(kind: kind, executableURL: url, bookmarkData: data, state: .invalid),
                access: nil
            )
        }
        let version: CommandResult
        do {
            version = try await runner.run(validationCommand(
                url: url,
                arguments: ["--version"],
                authorizedHomeURL: authorizedHomeAccess?.root.url
            ))
        } catch {
            return ToolAccessResult(
                location: ToolLocation(kind: kind, executableURL: url, bookmarkData: data, state: .invalid),
                access: nil
            )
        }
        guard version.succeeded else {
            return ToolAccessResult(
                location: ToolLocation(kind: kind, executableURL: url, bookmarkData: data, state: .invalid),
                access: nil
            )
        }
        let state: ToolAvailabilityState
        if kind == .gh {
            do {
                let auth = try await runner.run(validationCommand(
                    url: url,
                    arguments: ["auth", "status"],
                    authorizedHomeURL: authorizedHomeAccess?.root.url
                ))
                guard auth.terminationReason == .exit else {
                    return ToolAccessResult(
                        location: ToolLocation(kind: kind, executableURL: url, bookmarkData: data, state: .invalid),
                        access: nil
                    )
                }
                state = auth.terminationStatus == 0 ? .available : .unauthenticated
            } catch {
                return ToolAccessResult(
                    location: ToolLocation(kind: kind, executableURL: url, bookmarkData: data, state: .invalid),
                    access: nil
                )
            }
        } else {
            state = .available
        }
        if let data {
            do {
                try store.save(bookmarkData: data, for: kind)
            } catch {
                return ToolAccessResult(
                    location: ToolLocation(kind: kind, executableURL: url, bookmarkData: data, state: .invalid),
                    access: nil
                )
            }
        }
        let location = ToolLocation(
            kind: kind,
            executableURL: url,
            bookmarkData: data,
            state: state,
            version: version.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard state == .available,
              let homeURL = authorizedHomeAccess?.root.url else {
            return ToolAccessResult(location: location, access: nil)
        }
        let access = ToolAccess(
            location: location,
            executableURL: url,
            authorizedHomeURL: homeURL,
            leases: leases
        )
        transfersLeases = true
        return ToolAccessResult(location: location, access: access)
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

    private func validationCommand(
        url: URL,
        arguments: [String],
        authorizedHomeURL: URL? = nil
    ) -> ExternalCommand {
        ExternalCommand(
            executableURL: url,
            arguments: arguments,
            authorizedHomeURL: authorizedHomeURL,
            timeout: 5,
            maximumOutputBytes: 64 * 1024
        )
    }
}
