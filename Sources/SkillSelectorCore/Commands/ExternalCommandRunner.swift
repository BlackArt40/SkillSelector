import Foundation

public enum CommandOutputStream: String, Codable, Hashable, Sendable {
    case stdout
    case stderr
}

public struct ExternalCommand: Hashable, Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let authorizedHomeURL: URL?
    public let timeout: TimeInterval
    public let maximumOutputBytes: Int

    public init(
        executableURL: URL,
        arguments: [String] = [],
        environment: [String: String] = [:],
        authorizedHomeURL: URL? = nil,
        timeout: TimeInterval = 30,
        maximumOutputBytes: Int = 1_048_576
    ) {
        self.executableURL = executableURL.standardizedFileURL
        self.arguments = arguments
        self.environment = environment
        self.authorizedHomeURL = authorizedHomeURL?.standardizedFileURL
        self.timeout = timeout
        self.maximumOutputBytes = maximumOutputBytes
    }
}

public typealias CommandRequest = ExternalCommand

public struct CommandResult: Hashable, Sendable {
    public let stdout: Data
    public let stderr: Data
    public let terminationStatus: Int32
    public let terminationReason: Process.TerminationReason

    public init(
        stdout: Data,
        stderr: Data,
        terminationStatus: Int32,
        terminationReason: Process.TerminationReason
    ) {
        self.stdout = stdout
        self.stderr = stderr
        self.terminationStatus = terminationStatus
        self.terminationReason = terminationReason
    }

    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }
    public var succeeded: Bool { terminationReason == .exit && terminationStatus == 0 }
}

public enum ExternalCommandError: Error, Equatable, Sendable {
    case invalidExecutable(URL)
    case invalidTimeout
    case invalidOutputLimit
    case launchFailed(String)
    case timedOut
    case cancelled
    case outputLimitExceeded(CommandOutputStream)
}

private final class CommandRunState: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var finished = false
    private var started = false
    private var continuation: CheckedContinuation<CommandResult, Error>?
    private var terminationError: ExternalCommandError?

    init(continuation: CheckedContinuation<CommandResult, Error>) {
        self.continuation = continuation
    }

    func setProcess(_ process: Process) {
        lock.lock(); defer { lock.unlock() }
        self.process = process
    }

    func terminate() {
        lock.lock()
        let process = self.process
        lock.unlock()
        guard let process, process.isRunning else { return }
        process.terminate()
        // Some processes ignore SIGTERM. A short grace period prevents a
        // cancelled or timed-out command from holding the continuation open.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.2) {
            if process.isRunning { process.interrupt() }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    func fail(_ error: ExternalCommandError) {
        lock.lock()
        if !started && !finished {
            finished = true
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(throwing: error)
            return
        }
        terminationError = terminationError ?? error
        lock.unlock()
        terminate()
    }

    func markStarted() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !finished, terminationError == nil else { return false }
        started = true
        return true
    }

    func abort(_ error: ExternalCommandError) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(throwing: error)
    }

    func finish(_ result: CommandResult) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let error = terminationError
        lock.unlock()
        if let error { continuation?.resume(throwing: error) }
        else { continuation?.resume(returning: result) }
    }
}

public final class ExternalCommandRunner: @unchecked Sendable {
    public static let defaultPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    private let defaultTimeout: TimeInterval
    private let defaultMaximumOutputBytes: Int
    private let activeLock = NSLock()
    private var activeRuns: [UUID: CommandRunState] = [:]

    public init(
        defaultTimeout: TimeInterval = 30,
        defaultMaximumOutputBytes: Int = 1_048_576
    ) {
        self.defaultTimeout = defaultTimeout
        self.defaultMaximumOutputBytes = defaultMaximumOutputBytes
    }

    public func run(_ command: ExternalCommand) async throws -> CommandResult {
        let timeout = command.timeout == 30 ? defaultTimeout : command.timeout
        let limit = command.maximumOutputBytes == 1_048_576
            ? defaultMaximumOutputBytes : command.maximumOutputBytes
        guard timeout > 0 else { throw ExternalCommandError.invalidTimeout }
        guard limit > 0 else { throw ExternalCommandError.invalidOutputLimit }
        guard FileManager.default.isExecutableFile(atPath: command.executableURL.path) else {
            throw ExternalCommandError.invalidExecutable(command.executableURL)
        }

        let runID = UUID()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                launch(
                    runID: runID,
                    command: command,
                    timeout: timeout,
                    maximumOutputBytes: limit,
                    continuation: continuation
                )
            }
        }, onCancel: {
            activeLock.lock()
            let state = activeRuns[runID]
            activeLock.unlock()
            state?.fail(.cancelled)
        })
    }

    private func launch(
        runID: UUID,
        command: ExternalCommand,
        timeout: TimeInterval,
        maximumOutputBytes: Int,
        continuation: CheckedContinuation<CommandResult, Error>
    ) {
        let state = CommandRunState(continuation: continuation)
        activeLock.lock()
        activeRuns[runID] = state
        activeLock.unlock()
        if Task.isCancelled {
            state.abort(.cancelled)
            activeLock.lock()
            activeRuns.removeValue(forKey: runID)
            activeLock.unlock()
            return
        }

        let process = Process()
        process.executableURL = command.executableURL
        process.arguments = command.arguments
        process.environment = makeEnvironment(command)
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        state.setProcess(process)

        let group = DispatchGroup()
        let collector = OutputCollector(maximumBytes: maximumOutputBytes, state: state)
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            collector.read(stdoutPipe.fileHandleForReading, stream: .stdout)
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            collector.read(stderrPipe.fileHandleForReading, stream: .stderr)
            group.leave()
        }
        process.terminationHandler = { process in
            group.notify(queue: .global(qos: .utility)) {
                state.finish(CommandResult(
                    stdout: collector.stdout,
                    stderr: collector.stderr,
                    terminationStatus: process.terminationStatus,
                    terminationReason: process.terminationReason
                ))
                self.activeLock.lock()
                self.activeRuns.removeValue(forKey: runID)
                self.activeLock.unlock()
            }
        }

        guard state.markStarted() else {
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
            activeLock.lock()
            activeRuns.removeValue(forKey: runID)
            activeLock.unlock()
            return
        }
        do {
            try process.run()
        } catch {
            state.abort(.launchFailed(error.localizedDescription))
            activeLock.lock()
            activeRuns.removeValue(forKey: runID)
            activeLock.unlock()
            return
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
            if process.isRunning { state.fail(.timedOut) }
        }
    }

    private func makeEnvironment(_ command: ExternalCommand) -> [String: String] {
        var environment: [String: String] = [
            "PATH": command.environment["PATH"] ?? Self.defaultPath,
            "LC_ALL": command.environment["LC_ALL"] ?? "en_US.UTF-8",
            "LANG": command.environment["LANG"] ?? "en_US.UTF-8",
        ]
        if let home = command.authorizedHomeURL {
            environment["HOME"] = home.path
        }
        // Only these values are intentionally forwarded. In particular, no
        // token, proxy, shell, or user-provided arbitrary variable is inherited.
        for key in ["TMPDIR"] where command.environment[key] != nil {
            environment[key] = command.environment[key]
        }
        return environment
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBytes: Int
    private let state: CommandRunState
    private(set) var stdout = Data()
    private(set) var stderr = Data()

    init(maximumBytes: Int, state: CommandRunState) {
        self.maximumBytes = maximumBytes
        self.state = state
    }

    func read(_ handle: FileHandle, stream: CommandOutputStream) {
        defer { try? handle.close() }
        do {
            while true {
                let chunk = try handle.read(upToCount: 32 * 1024) ?? Data()
                if chunk.isEmpty { break }
                lock.lock()
                let current = stream == .stdout ? stdout.count : stderr.count
                let total = current + chunk.count
                if total <= maximumBytes {
                    if stream == .stdout { stdout.append(chunk) } else { stderr.append(chunk) }
                    lock.unlock()
                } else {
                    let remaining = max(0, maximumBytes - current)
                    if remaining > 0 {
                        if stream == .stdout { stdout.append(chunk.prefix(remaining)) }
                        else { stderr.append(chunk.prefix(remaining)) }
                    }
                    lock.unlock()
                    state.fail(.outputLimitExceeded(stream))
                    break
                }
            }
        } catch {
            state.fail(.launchFailed(error.localizedDescription))
        }
    }
}
