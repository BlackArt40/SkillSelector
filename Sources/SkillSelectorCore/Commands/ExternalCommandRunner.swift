import Darwin
import Foundation

public typealias CommandRunning = ExternalCommandRunning

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

public protocol ExternalCommandRunning: Sendable {
    func run(_ command: ExternalCommand) async throws -> CommandResult
}

private final class CommandRunState: @unchecked Sendable {
    private let lock = NSLock()
    private var processGroupID: pid_t?
    private var finished = false
    private var continuation: CheckedContinuation<CommandResult, Error>?
    private var terminationError: ExternalCommandError?

    init(continuation: CheckedContinuation<CommandResult, Error>) {
        self.continuation = continuation
    }

    func pendingError() -> ExternalCommandError? {
        lock.lock(); defer { lock.unlock() }
        return terminationError
    }

    func setProcessGroupID(_ processGroupID: pid_t) {
        lock.lock()
        self.processGroupID = processGroupID
        let shouldTerminate = terminationError != nil
        lock.unlock()
        if shouldTerminate { terminateProcessGroup(processGroupID) }
    }

    func fail(_ error: ExternalCommandError) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        terminationError = terminationError ?? error
        let processGroupID = self.processGroupID
        lock.unlock()
        if let processGroupID { terminateProcessGroup(processGroupID) }
    }

    func abort(_ error: Error) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let recordedError = terminationError
        lock.unlock()
        continuation?.resume(throwing: recordedError ?? error)
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

    private func terminateProcessGroup(_ processGroupID: pid_t) {
        guard processGroupID > 0 else { return }
        kill(-processGroupID, SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.2) {
            // The group can outlive its leader. Probe and kill the group rather
            // than consulting only the original process PID.
            if kill(-processGroupID, 0) == 0 || errno == EPERM {
                kill(-processGroupID, SIGKILL)
            }
        }
    }
}

public final class ExternalCommandRunner: ExternalCommandRunning, @unchecked Sendable {
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
            completeAbortedRun(runID: runID, state: state, error: ExternalCommandError.cancelled)
            return
        }

        var stdoutDescriptors: [Int32] = [0, 0]
        var stderrDescriptors: [Int32] = [0, 0]
        guard pipe(&stdoutDescriptors) == 0 else {
            completeAbortedRun(runID: runID, state: state, error: posixError("pipe"))
            return
        }
        guard pipe(&stderrDescriptors) == 0 else {
            close(stdoutDescriptors[0]); close(stdoutDescriptors[1])
            completeAbortedRun(runID: runID, state: state, error: posixError("pipe"))
            return
        }

        var actions: posix_spawn_file_actions_t? = nil
        var attributes: posix_spawnattr_t? = nil
        guard posix_spawn_file_actions_init(&actions) == 0,
              posix_spawnattr_init(&attributes) == 0 else {
            closeDescriptors(stdoutDescriptors + stderrDescriptors)
            completeAbortedRun(runID: runID, state: state, error: posixError("posix_spawn initialization"))
            return
        }
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }

        posix_spawn_file_actions_addclose(&actions, stdoutDescriptors[0])
        posix_spawn_file_actions_addclose(&actions, stderrDescriptors[0])
        posix_spawn_file_actions_adddup2(&actions, stdoutDescriptors[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stderrDescriptors[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, stdoutDescriptors[1])
        posix_spawn_file_actions_addclose(&actions, stderrDescriptors[1])
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)

        if let error = state.pendingError() {
            closeDescriptors(stdoutDescriptors + stderrDescriptors)
            completeAbortedRun(runID: runID, state: state, error: error)
            return
        }

        var processID: pid_t = 0
        let arguments = [command.executableURL.path] + command.arguments
        let environment = makeEnvironment(command)
            .map { "\($0.key)=\($0.value)" }
            .sorted()
        let spawnStatus = withMutableCStringArray(arguments) { argumentPointers in
            withMutableCStringArray(environment) { environmentPointers in
                posix_spawn(
                    &processID,
                    command.executableURL.path,
                    &actions,
                    &attributes,
                    argumentPointers,
                    environmentPointers
                )
            }
        }
        close(stdoutDescriptors[1])
        close(stderrDescriptors[1])

        guard spawnStatus == 0 else {
            close(stdoutDescriptors[0]); close(stderrDescriptors[0])
            let message = String(cString: strerror(spawnStatus))
            completeAbortedRun(
                runID: runID,
                state: state,
                error: ExternalCommandError.launchFailed(message)
            )
            return
        }

        state.setProcessGroupID(processID)
        let spawnedProcessID = processID
        let stdoutReadDescriptor = stdoutDescriptors[0]
        let stderrReadDescriptor = stderrDescriptors[0]
        let group = DispatchGroup()
        let collector = OutputCollector(maximumBytes: maximumOutputBytes, state: state)
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            collector.read(descriptor: stdoutReadDescriptor, stream: .stdout)
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            collector.read(descriptor: stderrReadDescriptor, stream: .stderr)
            group.leave()
        }
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            var waitResult: pid_t
            repeat { waitResult = waitpid(spawnedProcessID, &status, 0) } while waitResult == -1 && errno == EINTR
            guard waitResult == spawnedProcessID else {
                let error = ExternalCommandError.launchFailed(self.posixErrorDescription("waitpid"))
                state.fail(error)
                group.notify(queue: .global(qos: .utility)) {
                    state.abort(error)
                    self.removeRun(runID)
                }
                return
            }
            let termination = self.decodeWaitStatus(status)
            group.notify(queue: .global(qos: .utility)) {
                state.finish(CommandResult(
                    stdout: collector.stdout,
                    stderr: collector.stderr,
                    terminationStatus: termination.status,
                    terminationReason: termination.reason
                ))
                self.removeRun(runID)
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
            state.fail(.timedOut)
        }
    }

    private func completeAbortedRun(runID: UUID, state: CommandRunState, error: Error) {
        state.abort(error)
        removeRun(runID)
    }

    private func removeRun(_ runID: UUID) {
        activeLock.lock()
        activeRuns.removeValue(forKey: runID)
        activeLock.unlock()
    }

    private func closeDescriptors(_ descriptors: [Int32]) {
        for descriptor in descriptors { close(descriptor) }
    }

    private func posixError(_ operation: String) -> ExternalCommandError {
        .launchFailed(posixErrorDescription(operation))
    }

    private func posixErrorDescription(_ operation: String) -> String {
        "\(operation): \(String(cString: strerror(errno)))"
    }

    private func decodeWaitStatus(_ status: Int32) -> (status: Int32, reason: Process.TerminationReason) {
        let signal = status & 0x7f
        if signal == 0 {
            return ((status >> 8) & 0xff, .exit)
        }
        return (signal, .uncaughtSignal)
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
        for key in ["TMPDIR"] where command.environment[key] != nil {
            environment[key] = command.environment[key]
        }
        return environment
    }

    private func withMutableCStringArray<Result>(
        _ strings: [String],
        body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result
    ) -> Result {
        var pointers = strings.map { strdup($0) }
        pointers.append(nil)
        defer { for pointer in pointers { free(pointer) } }
        return pointers.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress!)
        }
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBytes: Int
    private let state: CommandRunState
    private var stdoutData = Data()
    private var stderrData = Data()

    var stdout: Data {
        lock.lock(); defer { lock.unlock() }
        return stdoutData
    }

    var stderr: Data {
        lock.lock(); defer { lock.unlock() }
        return stderrData
    }

    init(maximumBytes: Int, state: CommandRunState) {
        self.maximumBytes = maximumBytes
        self.state = state
    }

    func read(descriptor: Int32, stream: CommandOutputStream) {
        defer { close(descriptor) }
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { return }
            if count < 0 {
                if errno == EINTR { continue }
                state.fail(.launchFailed("read: \(String(cString: strerror(errno)))"))
                return
            }
            lock.lock()
            let current = stream == .stdout ? stdoutData.count : stderrData.count
            let total = current + count
            if total <= maximumBytes {
                if stream == .stdout { stdoutData.append(buffer, count: count) }
                else { stderrData.append(buffer, count: count) }
                lock.unlock()
            } else {
                let remaining = max(0, maximumBytes - current)
                if remaining > 0 {
                    if stream == .stdout { stdoutData.append(buffer, count: remaining) }
                    else { stderrData.append(buffer, count: remaining) }
                }
                lock.unlock()
                state.fail(.outputLimitExceeded(stream))
                return
            }
        }
    }
}
