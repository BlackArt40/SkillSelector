import Darwin
import Foundation

private final class StdioRunState: @unchecked Sendable {
    private let lock = NSLock()
    private var processGroupID: pid_t?
    private var failure: MCPClientError?
    private var finished = false

    func attach(processGroupID: pid_t) {
        lock.lock()
        self.processGroupID = processGroupID
        let shouldStop = failure != nil
        lock.unlock()
        if shouldStop { terminateProcessGroup(processGroupID) }
    }

    func stop(_ error: MCPClientError) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        failure = failure ?? error
        let processGroupID = self.processGroupID
        lock.unlock()
        if let processGroupID { terminateProcessGroup(processGroupID) }
    }

    func check() throws {
        lock.lock(); defer { lock.unlock() }
        if let failure { throw failure }
    }

    func complete() {
        lock.lock()
        finished = true
        processGroupID = nil
        lock.unlock()
    }

    private func terminateProcessGroup(_ processGroupID: pid_t) {
        guard processGroupID > 0 else { return }
        kill(-processGroupID, SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.2) {
            if kill(-processGroupID, 0) == 0 || errno == EPERM { kill(-processGroupID, SIGKILL) }
        }
    }
}

private final class StdioSession: @unchecked Sendable {
    private let processID: pid_t
    private let standardInput: FileHandle
    private let standardOutput: FileHandle
    private let standardError: FileHandle
    private let state: StdioRunState
    private let maximumResponseBytes: Int
    private let stderrQueue = DispatchQueue(label: "SkillSelector.MCP.stderr")

    init(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String?,
        authorizedHomeURL: URL?,
        maximumResponseBytes: Int,
        state: StdioRunState
    ) throws {
        var inputDescriptors: [Int32] = [0, 0]
        var outputDescriptors: [Int32] = [0, 0]
        var errorDescriptors: [Int32] = [0, 0]
        guard pipe(&inputDescriptors) == 0,
              pipe(&outputDescriptors) == 0,
              pipe(&errorDescriptors) == 0 else {
            for descriptor in inputDescriptors + outputDescriptors + errorDescriptors where descriptor > 0 {
                close(descriptor)
            }
            throw MCPClientError.launchFailed(String(cString: strerror(errno)))
        }
        var allowedEnvironment = [
            "PATH": ExternalCommandRunner.defaultPath,
            "LC_ALL": "en_US.UTF-8",
            "LANG": "en_US.UTF-8",
        ]
        for (key, value) in environment { allowedEnvironment[key] = value }
        if let authorizedHomeURL { allowedEnvironment["HOME"] = authorizedHomeURL.path }
        var actions: posix_spawn_file_actions_t? = nil
        var attributes: posix_spawnattr_t? = nil
        guard posix_spawn_file_actions_init(&actions) == 0,
              posix_spawnattr_init(&attributes) == 0 else {
            for descriptor in inputDescriptors + outputDescriptors + errorDescriptors { close(descriptor) }
            throw MCPClientError.launchFailed("posix_spawn initialization")
        }
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        posix_spawn_file_actions_addclose(&actions, inputDescriptors[1])
        posix_spawn_file_actions_adddup2(&actions, inputDescriptors[0], STDIN_FILENO)
        posix_spawn_file_actions_addclose(&actions, inputDescriptors[0])
        posix_spawn_file_actions_addclose(&actions, outputDescriptors[0])
        posix_spawn_file_actions_adddup2(&actions, outputDescriptors[1], STDOUT_FILENO)
        posix_spawn_file_actions_addclose(&actions, outputDescriptors[1])
        posix_spawn_file_actions_addclose(&actions, errorDescriptors[0])
        posix_spawn_file_actions_adddup2(&actions, errorDescriptors[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, errorDescriptors[1])
        if let workingDirectory {
            posix_spawn_file_actions_addchdir_np(&actions, workingDirectory)
        }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)
        let argumentValues = [executable.path] + arguments
        let environmentValues = allowedEnvironment.map { "\($0.key)=\($0.value)" }.sorted()
        var spawnedProcessID: pid_t = 0
        let spawnStatus = withMutableCStringArray(argumentValues) { argumentPointers in
            withMutableCStringArray(environmentValues) { environmentPointers in
                posix_spawn(
                    &spawnedProcessID,
                    executable.path,
                    &actions,
                    &attributes,
                    argumentPointers,
                    environmentPointers
                )
            }
        }
        close(inputDescriptors[0])
        close(outputDescriptors[1])
        close(errorDescriptors[1])
        guard spawnStatus == 0 else {
            close(inputDescriptors[1]); close(outputDescriptors[0]); close(errorDescriptors[0])
            throw MCPClientError.launchFailed(String(cString: strerror(spawnStatus)))
        }
        processID = spawnedProcessID
        standardInput = FileHandle(fileDescriptor: inputDescriptors[1], closeOnDealloc: true)
        standardOutput = FileHandle(fileDescriptor: outputDescriptors[0], closeOnDealloc: true)
        standardError = FileHandle(fileDescriptor: errorDescriptors[0], closeOnDealloc: true)
        self.state = state
        self.maximumResponseBytes = maximumResponseBytes
        state.attach(processGroupID: spawnedProcessID)
        drainStandardError()
    }

    func request(method: String, id: Int, params: MCPJSONValue = .object([:])) throws -> MCPJSONValue {
        try write(MCPProtocolCodec.request(method: method, id: id, params: params))
        return try MCPProtocolCodec.response(readLine(), expectedID: id)
    }

    func notify(method: String, params: MCPJSONValue = .object([:])) throws {
        try write(MCPProtocolCodec.request(method: method, id: nil, params: params))
    }

    func shutdown() {
        try? standardInput.close()
        kill(-processID, SIGTERM)
        let groupID = processID
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.2) {
            if kill(-groupID, 0) == 0 || errno == EPERM { kill(-groupID, SIGKILL) }
        }
        var status: Int32 = 0
        var result: pid_t
        repeat { result = waitpid(processID, &status, 0) } while result == -1 && errno == EINTR
        try? standardOutput.close()
        try? standardError.close()
    }

    private func write(_ data: Data) throws {
        try state.check()
        var framed = data
        framed.append(0x0a)
        do { try standardInput.write(contentsOf: framed) }
        catch {
            try state.check()
            throw MCPClientError.invalidResponse
        }
    }

    private func readLine() throws -> Data {
        var response = Data()
        while true {
            try state.check()
            let byte: Data
            do { byte = try standardOutput.read(upToCount: 1) ?? Data() }
            catch {
                try state.check()
                throw MCPClientError.invalidResponse
            }
            guard !byte.isEmpty else {
                try state.check()
                throw MCPClientError.invalidResponse
            }
            if byte[byte.startIndex] == 0x0a { return response }
            response.append(byte)
            if response.count > maximumResponseBytes {
                state.stop(.responseTooLarge)
                throw MCPClientError.responseTooLarge
            }
        }
    }

    private func drainStandardError() {
        let handle = standardError
        let limit = maximumResponseBytes
        let state = state
        stderrQueue.async {
            var count = 0
            while true {
                let data = try? handle.read(upToCount: 8_192)
                guard let data, !data.isEmpty else { return }
                count += data.count
                if count > limit {
                    state.stop(.responseTooLarge)
                    return
                }
            }
        }
    }
}

private func withMutableCStringArray<Result>(
    _ strings: [String],
    _ body: ([UnsafeMutablePointer<CChar>?]) -> Result
) -> Result {
    let pointers = strings.map { strdup($0) }
    defer { pointers.forEach { free($0) } }
    return body(pointers + [nil])
}

public final class StdioMCPClient: MCPClient, @unchecked Sendable {
    private let configuration: MCPServerConfiguration
    private let approval: CommandApproval
    private let timeout: TimeInterval
    private let maximumResponseBytes: Int
    private let confirmation: MCPToolConfirmation
    private let authorizedHomeURL: URL?

    public init(
        configuration: MCPServerConfiguration,
        approval: CommandApproval,
        timeout: TimeInterval = 30,
        maximumResponseBytes: Int = 1_048_576,
        authorizedHomeURL: URL? = nil,
        confirmation: @escaping MCPToolConfirmation = { _, _ in false }
    ) {
        self.configuration = configuration
        self.approval = approval
        self.timeout = timeout
        self.maximumResponseBytes = maximumResponseBytes
        self.authorizedHomeURL = authorizedHomeURL
        self.confirmation = confirmation
    }

    public func listTools() async throws -> [MCPTool] {
        let result = try await exchange(method: "tools/list")
        return try MCPProtocolCodec.tools(from: result, enabled: configuration.enabledToolNames)
    }

    public func call(tool: String, arguments: [String: MCPJSONValue]) async throws -> MCPToolResult {
        let tools = try await listTools()
        guard let definition = tools.first(where: { $0.name == tool }), definition.isEnabled else {
            throw MCPClientError.toolNotEnabled(tool)
        }
        if definition.requiresPerCallConfirmation,
           await !confirmation(configuration.id, definition) {
            throw MCPClientError.toolConfirmationRequired(tool)
        }
        let result = try await exchange(
            method: "tools/call",
            params: .object(["name": .string(tool), "arguments": .object(arguments)])
        )
        let decoded = try MCPProtocolCodec.toolResult(from: result)
        if decoded.isError { throw MCPClientError.toolReportedError }
        return decoded
    }

    public func close() async {}

    private func exchange(method: String, params: MCPJSONValue = .object([:])) async throws -> MCPJSONValue {
        let (executable, arguments, environment, workingDirectory) = try validatedCommand()
        guard timeout > 0, maximumResponseBytes > 0 else { throw MCPClientError.invalidResponse }
        let state = StdioRunState()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let session = try StdioSession(
                            executable: executable,
                            arguments: arguments,
                            environment: environment,
                            workingDirectory: workingDirectory,
                            authorizedHomeURL: self.authorizedHomeURL,
                            maximumResponseBytes: self.maximumResponseBytes,
                            state: state
                        )
                        defer {
                            session.shutdown()
                            state.complete()
                        }
                        let initialized = try session.request(
                            method: "initialize",
                            id: 1,
                            params: .object([
                                "protocolVersion": .string("2025-03-26"),
                                "capabilities": .object([:]),
                                "clientInfo": .object([
                                    "name": .string("SkillSelector"),
                                    "version": .string("1"),
                                ]),
                            ])
                        )
                        guard initialized.objectValue?["protocolVersion"]?.stringValue != nil else {
                            throw MCPClientError.invalidResponse
                        }
                        try session.notify(method: "notifications/initialized")
                        let result = try session.request(method: method, id: 2, params: params)
                        continuation.resume(returning: result)
                    } catch {
                        state.complete()
                        continuation.resume(throwing: error)
                    }
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                    state.stop(.timedOut)
                }
            }
        }, onCancel: {
            state.stop(.cancelled)
        })
    }

    private func validatedCommand() throws -> (URL, [String], [String: String], String?) {
        guard configuration.isEnabled else { throw MCPClientError.disabled }
        guard configuration.support == .supported,
              case .stdio(
                let rawExecutable,
                let arguments,
                let environment,
                let workingDirectory
              ) = configuration.transport else {
            throw MCPClientError.unsupportedTransport
        }
        guard let approved = configuration.commandApproval,
              approval.state(for: approved) == .approved else {
            throw MCPClientError.approvalRequired
        }
        let executable = URL(fileURLWithPath: rawExecutable).standardizedFileURL
        guard rawExecutable.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw MCPClientError.invalidExecutable(rawExecutable)
        }
        return (executable, arguments, environment, workingDirectory)
    }
}
