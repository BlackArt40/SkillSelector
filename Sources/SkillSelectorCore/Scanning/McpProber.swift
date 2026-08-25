import Darwin
import Foundation

/// One server's run-state probe result. Configuration (`McpServerDescriptor`)
/// is never stateful; probing produces these on demand.
public enum McpProbeStatus: Hashable, Sendable {
    /// Not probed yet (or last result cleared).
    case unknown
    /// A probe is currently in flight.
    case probing
    /// Full MCP `initialize` handshake succeeded within the timeout.
    case running
    /// The process terminated before the handshake (stdio) or the HTTP
    /// endpoint did not respond (http/sse) within the window.
    case notRunning
    /// The probe failed for a concrete reason (bad command, unparseable
    /// reply, probe itself errored).
    case failed(String)

    public var isResolved: Bool {
        switch self {
        case .unknown, .probing: return false
        case .running, .notRunning, .failed: return true
        }
    }
}

/// Probes MCP servers by performing the real `initialize` handshake —
/// the same first step a client (Claude Code, Codex, …) does when
/// connecting. stdio servers are launched as child processes, spoken to
/// over JSON-RPC, and force-terminated after the verdict; http/sse servers
/// get an `initialize` POST.
///
/// **Constraint contract:** every probe is finite, user-initiated, and
/// transient. `terminate()` is always called before returning — a probe
/// never leaves a child process running, regardless of outcome.
public struct McpProber: Sendable {
    /// Overall budget for one handshake, seconds.
    public var handshakeTimeout: TimeInterval
    private static let jsonrpcVersion = "2.0"
    private static let clientName = "SkillSelector"

    public init(handshakeTimeout: TimeInterval = 5) {
        self.handshakeTimeout = handshakeTimeout
    }

    /// Probes one server. Never throws; errors surface as `.failed`.
    public func probe(_ server: McpServerDescriptor) async -> McpProbeStatus {
        switch server.transport {
        case .stdio:
            return await probeStdio(server)
        case .http, .sse:
            return await probeHTTP(server)
        }
    }

    // MARK: stdio

    private func probeStdio(_ server: McpServerDescriptor) async -> McpProbeStatus {
        guard let command = server.command, !command.isEmpty else {
            return .failed("stdio server missing command")
        }
        guard let executableURL = Self.resolveExecutable(command) else {
            return .failed("executable not found: \(command)")
        }

        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        process.executableURL = executableURL
        // Process.arguments does not accept nil — set an empty array when
        // the server takes none (NSInvalidArgumentException otherwise).
        process.arguments = server.arguments
        process.standardInput = stdin
        process.standardOutput = stdout
        // stderr is drained to null — the probe only cares about the
        // initialize reply on stdout; keeping the pipe unread could buffer
        // and stall a chatty server.
        process.standardError = FileHandle.nullDevice

        // Read stdout incrementally; stdio MCP speaks newline-delimited JSON.
        let collected = OutputCollector()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            collected.append(data)
        }

        do {
            try process.run()
        } catch {
            return .failed("launch failed: \(error.localizedDescription)")
        }

        // initialize request (JSON-RPC 2.0).
        let payload = Self.initializePayload() + "\n"
        do {
            try stdin.fileHandleForWriting.write(contentsOf: payload.data(using: .utf8) ?? Data())
            try stdin.fileHandleForWriting.close()
        } catch {
            terminate(process)
            return .failed("could not write initialize request")
        }

        let status = await waitForVerdict(
            process: process,
            collector: collected,
            deadline: Date().addingTimeInterval(handshakeTimeout)
        )
        terminate(process)
        return status
    }

    private func waitForVerdict(
        process: Process,
        collector: OutputCollector,
        deadline: Date
    ) async -> McpProbeStatus {
        // Check the collected reply first: a fast-answering server may have
        // already exited after writing its response, so "process still
        // running" is not the right gate for success.
        while true {
            if let text = collector.snapshot {
                if Self.responseContainsInitializeResult(text) {
                    return .running
                }
                if Self.responseContainsInitializeError(text) {
                    return .failed("server returned initialize error")
                }
                if !process.isRunning {
                    // Server answered something that was neither a result nor
                    // an error, then exited: it never accepted the handshake.
                    return .notRunning
                }
            } else if Date() > deadline {
                return .notRunning
            } else if !process.isRunning {
                return .notRunning
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
    }

    private static func responseContainsInitializeResult(_ text: String) -> Bool {
        text.split(separator: "\n").contains { line in
            line.contains("\"id\":1") && line.contains("\"result\"")
        }
    }

    private static func responseContainsInitializeError(_ text: String) -> Bool {
        text.split(separator: "\n").contains { line in
            line.contains("\"id\":1") && line.contains("\"error\"")
        }
    }

    private static func initializePayload() -> String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "dev"
        return """
        {"jsonrpc":"\(jsonrpcVersion)","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"\(clientName)","version":"\(version)"}}}
        """
    }

    /// Resolves a bare command against PATH, since `Process` needs an
    /// executable URL but users configure bare names ("npx", "uvx").
    private static func resolveExecutable(_ command: String) -> URL? {
        if command.contains("/") {
            let url = URL(fileURLWithPath: command).standardizedFileURL
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }
        guard let path = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        for directory in path.split(separator: ":").map(String.init) {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(command)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        // Grace period for SIGTERM; escalate to SIGKILL so the probe never
        // strands a child. Probe processes are throwaway — no cleanup work.
        let deadline = Date().addingTimeInterval(0.3)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    // MARK: http / sse

    private func probeHTTP(_ server: McpServerDescriptor) async -> McpProbeStatus {
        guard let urlString = server.url, let url = URL(string: urlString) else {
            return .failed("http/sse server missing url")
        }
        let session = URLSession(configuration: .ephemeral)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = handshakeTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = Self.initializePayload().data(using: .utf8)
        do {
            let (_, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            guard let http else { return .notRunning }
            // Only a 2xx reply means the endpoint accepted the init
            // handshake. A 401/404/405 proves something answered but did not
            // complete the handshake — the server is not usable as
            // configured, so it is not "running".
            return (200...299).contains(http.statusCode) ? .running : .notRunning
        } catch {
            return .notRunning
        }
    }
}

/// In-flight stdout accumulation for one stdio probe. The readability
/// handler appends serially; the polling task reads snapshots.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func append(_ data: Data) {
        lock.lock()
        buffer.append(data)
        lock.unlock()
    }

    var snapshot: String? {
        lock.lock()
        defer { lock.unlock() }
        guard !buffer.isEmpty else { return nil }
        return String(data: buffer, encoding: .utf8)
    }
}