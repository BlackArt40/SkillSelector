import Darwin
import Foundation
import XCTest
@testable import SkillSelectorCore

final class MCPClientTests: XCTestCase {
    private var fixture: URL!

    override func setUpWithError() throws {
        fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("MCPClientTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let fixture { try? FileManager.default.removeItem(at: fixture) }
    }

    func testDiscoveryReadsClaudeCodexAndGenericConfigsWithoutExecutingThem() throws {
        let marker = fixture.appendingPathComponent("executed")
        let executable = fixture.appendingPathComponent("npx")
        try "#!/bin/sh\ntouch \"\(marker.path)\"\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        try #"{"mcpServers":{"claude":{"command":"__EXECUTABLE__","args":["-y","demo@1"]}}}"#
            .replacingOccurrences(of: "__EXECUTABLE__", with: executable.path)
            .write(to: fixture.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: fixture.appendingPathComponent(".codex"),
            withIntermediateDirectories: true
        )
        try """
        [mcp_servers.codex]
        url = "https://example.com/mcp"
        """.write(
            to: fixture.appendingPathComponent(".codex/config.toml"),
            atomically: true,
            encoding: .utf8
        )
        try #"{"servers":{"old":{"type":"sse","url":"https://example.com/sse"},"generic":{"url":"http://127.0.0.1:9000/mcp"}}}"#
            .write(to: fixture.appendingPathComponent("mcp.json"), atomically: true, encoding: .utf8)

        let servers = try MCPConfigDiscovery().discover(in: fixture)

        XCTAssertEqual(servers.map(\.name), ["claude", "codex", "generic", "old"])
        XCTAssertTrue(servers.allSatisfy { !$0.isEnabled })
        XCTAssertEqual(servers.first(where: { $0.name == "claude" })?.source, .claude)
        XCTAssertEqual(servers.first(where: { $0.name == "codex" })?.source, .codex)
        XCTAssertEqual(servers.first(where: { $0.name == "generic" })?.source, .generic)
        XCTAssertEqual(servers.first(where: { $0.name == "old" })?.support, .unsupportedLegacySSE)
        let initialApproval = try XCTUnwrap(
            servers.first(where: { $0.name == "claude" })?.commandApproval?.fingerprint
        )
        XCTAssertEqual(servers.first(where: { $0.name == "claude" })?.isPackageRunner, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))

        try #"{"mcpServers":{"claude":{"command":"__EXECUTABLE__","args":["-y","demo@2"]}}}"#
            .replacingOccurrences(of: "__EXECUTABLE__", with: executable.path)
            .write(to: fixture.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        let changed = try MCPConfigDiscovery().discover(in: fixture)
        let changedServer = try XCTUnwrap(changed.first(where: { $0.name == "claude" }))
        XCTAssertNotEqual(changedServer.commandApproval?.fingerprint, initialApproval)
        XCTAssertFalse(changedServer.isEnabled)
    }

    func testCodexConfigurationFingerprintCoversEverySupportedServerFieldWithoutPersistingSecrets() throws {
        try FileManager.default.createDirectory(
            at: fixture.appendingPathComponent(".codex"),
            withIntermediateDirectories: true
        )
        let configURL = fixture.appendingPathComponent(".codex/config.toml")
        let baseline = """
        [mcp_servers.local]
        command = "/usr/bin/env"
        args = ["printf", "arg-one"]
        env = { API_TOKEN = "secret-env", MODE = "mode-one" }
        cwd = "/tmp"
        type = "stdio"
        startup_timeout_sec = 10

        [mcp_servers.remote]
        url = "https://example.com/mcp"
        type = "streamable-http"
        headers = { Authorization = "secret-header", X_Mode = "header-one" }
        """

        func discover(_ text: String) throws -> [String: MCPServerConfiguration] {
            try text.write(to: configURL, atomically: true, encoding: .utf8)
            return Dictionary(uniqueKeysWithValues: try MCPConfigDiscovery().discover(in: fixture).map {
                ($0.name, $0)
            })
        }

        let initial = try discover(baseline)
        let local = try XCTUnwrap(initial["local"])
        let remote = try XCTUnwrap(initial["remote"])
        let localApproval = try XCTUnwrap(local.commandApproval)
        guard case .stdio(let executable, let arguments, let environment, let workingDirectory) = local.transport else {
            return XCTFail("Expected Codex stdio configuration")
        }
        XCTAssertEqual(executable, "/usr/bin/env")
        XCTAssertEqual(arguments, ["printf", "arg-one"])
        XCTAssertEqual(environment, ["API_TOKEN": "secret-env", "MODE": "mode-one"])
        XCTAssertEqual(workingDirectory, "/tmp")
        guard case .streamableHTTP(let endpoint, let headers) = remote.transport else {
            return XCTFail("Expected Codex Streamable HTTP configuration")
        }
        XCTAssertEqual(endpoint.absoluteString, "https://example.com/mcp")
        XCTAssertEqual(headers, ["Authorization": "secret-header", "X_Mode": "header-one"])
        for secret in ["secret-env", "secret-header"] {
            XCTAssertFalse(local.id.contains(secret))
            XCTAssertFalse(remote.id.contains(secret))
            XCTAssertFalse(localApproval.fingerprint.contains(secret))
            XCTAssertFalse(localApproval.configurationFingerprint?.contains(secret) ?? false)
        }

        let localVariations = [
            baseline.replacingOccurrences(of: "/usr/bin/env", with: "/bin/echo"),
            baseline.replacingOccurrences(of: "arg-one", with: "arg-two"),
            baseline.replacingOccurrences(of: "mode-one", with: "mode-two"),
            baseline.replacingOccurrences(of: "cwd = \"/tmp\"", with: "cwd = \"/var/tmp\""),
            baseline.replacingOccurrences(of: "type = \"stdio\"", with: "type = \"custom-stdio\""),
            baseline.replacingOccurrences(of: "startup_timeout_sec = 10", with: "startup_timeout_sec = 11"),
        ]
        for variation in localVariations {
            let changed = try XCTUnwrap(try discover(variation)["local"])
            XCTAssertNotEqual(changed.id, local.id)
            XCTAssertNotEqual(changed.commandApproval?.fingerprint, localApproval.fingerprint)
        }

        let remoteVariations = [
            baseline.replacingOccurrences(of: "https://example.com/mcp", with: "https://example.com/other"),
            baseline.replacingOccurrences(of: "streamable-http", with: "custom-http"),
            baseline.replacingOccurrences(of: "header-one", with: "header-two"),
        ]
        for variation in remoteVariations {
            let changed = try XCTUnwrap(try discover(variation)["remote"])
            XCTAssertNotEqual(changed.id, remote.id)
        }

        let defaults = UserDefaults(suiteName: "MCPConfigFingerprintTests-\(UUID().uuidString)")!
        let preferences = MCPPreferenceStore(defaults: defaults)
        let approval = CommandApproval(
            store: UserDefaultsCommandApprovalStore(defaults: defaults, key: "approvals")
        )
        preferences.setServer(local.id, enabled: true)
        approval.approve(localApproval)
        let changed = try XCTUnwrap(
            try discover(baseline.replacingOccurrences(of: "mode-one", with: "mode-two"))["local"]
        )
        XCTAssertFalse(preferences.isServerEnabled(changed.id))
        XCTAssertEqual(approval.state(for: try XCTUnwrap(changed.commandApproval)), .approvalRequired)
    }

    func testStdioListToolsInitializesWithSequentialIDsAndTerminatesProcess() async throws {
        let transcript = fixture.appendingPathComponent("transcript")
        let pidFile = fixture.appendingPathComponent("pid")
        let server = try makeExecutable("""
        #!/bin/sh
        printf '%s' "$$" > "$2"
        count=0
        while IFS= read -r line; do
          count=$((count + 1))
          printf '%s\n' "$line" >> "$1"
          case "$count" in
            1) printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-03-26","capabilities":{},"serverInfo":{"name":"fixture","version":"1"}}}' ;;
            3) printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"metadata_lookup","description":"Look up metadata","inputSchema":{"type":"object"},"annotations":{"readOnlyHint":true,"destructiveHint":false}}]}}' ;;
          esac
        done
        """)
        let configuration = stdioConfiguration(
            executable: server,
            arguments: [transcript.path, pidFile.path],
            enabled: true
        )
        let approval = fixtureApproval(for: configuration)
        let client = StdioMCPClient(configuration: configuration, approval: approval, timeout: 2)

        let tools = try await client.listTools()

        XCTAssertEqual(tools.map(\.name), ["metadata_lookup"])
        XCTAssertEqual(tools.first?.annotations?.readOnlyHint, true)
        XCTAssertFalse(tools.first?.isEnabled ?? true)
        let messages = try String(contentsOf: transcript, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .compactMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        XCTAssertEqual(messages.compactMap { $0["id"] as? Int }, [1, 2])
        XCTAssertEqual(messages.compactMap { $0["method"] as? String }, [
            "initialize", "notifications/initialized", "tools/list",
        ])
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8)))
        let processIsGone = await waitUntilProcessIsGone(pid)
        XCTAssertTrue(processIsGone, "MCP stdio process survived listTools")
    }

    func testStdioCallRequiresEnabledToolAndPerCallConfirmationWithoutEvaluatingText() async throws {
        let transcript = fixture.appendingPathComponent("call-transcript")
        let marker = fixture.appendingPathComponent("must-not-exist")
        let server = try makeExecutable("""
        #!/bin/sh
        count=0
        while IFS= read -r line; do
          count=$((count + 1))
          printf '%s\n' "$line" >> "$1"
          if [ "$count" -eq 1 ]; then
            printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-03-26","capabilities":{},"serverInfo":{"name":"fixture","version":"1"}}}'
          elif [ "$count" -eq 3 ]; then
            case "$line" in
              *call*) printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"touch __MARKER__"}],"structuredContent":{"description":"Exact MCP description.","sourceIdentifier":"acme/demo","evidenceURL":"https://example.com/demo"}}}' ;;
              *) printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"metadata_lookup","description":"Look up metadata","inputSchema":{"type":"object"}}]}}' ;;
            esac
          fi
        done
        """.replacingOccurrences(of: "__MARKER__", with: marker.path))
        let configuration = stdioConfiguration(
            executable: server,
            arguments: [transcript.path],
            enabled: true,
            enabledTools: ["metadata_lookup"]
        )
        let approval = fixtureApproval(for: configuration)
        let denied = StdioMCPClient(configuration: configuration, approval: approval)
        await XCTAssertThrowsMCPError(
            try await denied.call(tool: "metadata_lookup", arguments: ["name": .string("demo")]),
            expected: .toolConfirmationRequired("metadata_lookup")
        )
        let client = StdioMCPClient(
            configuration: configuration,
            approval: approval,
            confirmation: { _, _ in true }
        )

        let result = try await client.call(
            tool: "metadata_lookup",
            arguments: ["name": .string("demo")]
        )

        XCTAssertEqual(
            result.content.first?.text,
            "touch \(marker.path)"
        )
        XCTAssertEqual(
            result.structuredContent?.objectValue?["description"]?.stringValue,
            "Exact MCP description."
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testStdioRejectsDisabledAndUnapprovedServersBeforeLaunch() async throws {
        let marker = fixture.appendingPathComponent("launched")
        let server = try makeExecutable("#!/bin/sh\ntouch \"\(marker.path)\"\n")
        let disabled = stdioConfiguration(executable: server, enabled: false)
        await XCTAssertThrowsMCPError(
            try await StdioMCPClient(
                configuration: disabled,
                approval: fixtureApproval(for: disabled)
            ).listTools(),
            expected: .disabled
        )
        let enabled = stdioConfiguration(executable: server, enabled: true)
        let emptyApproval = CommandApproval(
            store: UserDefaultsCommandApprovalStore(
                defaults: UserDefaults(suiteName: "MCPClientTests-empty-\(UUID().uuidString)")!
            )
        )
        await XCTAssertThrowsMCPError(
            try await StdioMCPClient(configuration: enabled, approval: emptyApproval).listTools(),
            expected: .approvalRequired
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testStdioTimeoutAndCancellationTerminateTheProcess() async throws {
        let timeoutPID = fixture.appendingPathComponent("timeout-pid")
        let server = try makeExecutable("""
        #!/bin/sh
        printf '%s' "$$" > "$1"
        while IFS= read -r line; do :; done
        """)
        let timedConfiguration = stdioConfiguration(
            executable: server,
            arguments: [timeoutPID.path],
            enabled: true
        )
        let timedClient = StdioMCPClient(
            configuration: timedConfiguration,
            approval: fixtureApproval(for: timedConfiguration),
            timeout: 2
        )
        let timedTask = Task { try await timedClient.listTools() }
        let timedPID = try await waitForPID(in: timeoutPID)
        await XCTAssertThrowsMCPError(try await timedTask.value, expected: .timedOut)
        XCTAssertTrue(awaitProcessGone(timedPID))

        let cancellationPID = fixture.appendingPathComponent("cancel-pid")
        let cancellationConfiguration = stdioConfiguration(
            executable: server,
            arguments: [cancellationPID.path],
            enabled: true
        )
        let client = StdioMCPClient(
            configuration: cancellationConfiguration,
            approval: fixtureApproval(for: cancellationConfiguration),
            timeout: 10
        )
        let task = Task { try await client.listTools() }
        let cancelledPID = try await waitForPID(in: cancellationPID)
        task.cancel()
        await XCTAssertThrowsMCPError(try await task.value, expected: .cancelled)
        XCTAssertTrue(awaitProcessGone(cancelledPID))
    }

    func testStdioTimeoutTerminatesBackgroundChildrenHoldingProtocolPipes() async throws {
        let parentPIDFile = fixture.appendingPathComponent("group-parent-pid")
        let childPIDFile = fixture.appendingPathComponent("group-child-pid")
        let server = try makeExecutable("""
        #!/bin/sh
        sleep 30 &
        printf '%s' "$!" > "$2"
        printf '%s' "$$" > "$1"
        while IFS= read -r line; do :; done
        """)
        let configuration = stdioConfiguration(
            executable: server,
            arguments: [parentPIDFile.path, childPIDFile.path],
            enabled: true
        )
        let client = StdioMCPClient(
            configuration: configuration,
            approval: fixtureApproval(for: configuration),
            timeout: 2
        )
        let task = Task { try await client.listTools() }
        let parentPID = try await waitForPID(in: parentPIDFile)
        let childPID = try await waitForPID(in: childPIDFile)

        await XCTAssertThrowsMCPError(try await task.value, expected: .timedOut)

        XCTAssertTrue(awaitProcessGone(parentPID))
        XCTAssertTrue(awaitProcessGone(childPID))
    }

    func testStdioBoundsResponsesAndSurfacesServerErrors() async throws {
        let oversized = try makeExecutable("""
        #!/bin/sh
        IFS= read -r line
        printf '12345678901234567890\n'
        while IFS= read -r line; do :; done
        """)
        let oversizedConfiguration = stdioConfiguration(executable: oversized, enabled: true)
        await XCTAssertThrowsMCPError(
            try await StdioMCPClient(
                configuration: oversizedConfiguration,
                approval: fixtureApproval(for: oversizedConfiguration),
                maximumResponseBytes: 10
            ).listTools(),
            expected: .responseTooLarge
        )

        let failed = try makeExecutable("""
        #!/bin/sh
        IFS= read -r line
        printf '%s\n' '{"jsonrpc":"2.0","id":1,"error":{"code":-32001,"message":"fixture denied"}}'
        while IFS= read -r line; do :; done
        """)
        let failedConfiguration = stdioConfiguration(executable: failed, enabled: true)
        await XCTAssertThrowsMCPError(
            try await StdioMCPClient(
                configuration: failedConfiguration,
                approval: fixtureApproval(for: failedConfiguration)
            ).listTools(),
            expected: .serverError(code: -32001, message: "fixture denied")
        )
    }

    func testHTTPListToolsUsesStreamableHTTPSessionAndCleansItUp() async throws {
        let recorder = MCPURLProtocolRecorder()
        let sessionID = "fixture-session"
        recorder.handler = { request in
            let body = requestBodyData(request).flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
            let method = body?["method"] as? String
            let id = body?["id"] as? Int
            let headers = method == "initialize" ? ["Mcp-Session-Id": sessionID] : [:]
            let payload: String
            let status: Int
            switch method {
            case "initialize":
                status = 200
                payload = #"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-03-26","capabilities":{},"serverInfo":{"name":"fixture","version":"1"}}}"#
            case "notifications/initialized":
                status = 202
                payload = ""
            case "tools/list":
                status = 200
                payload = #"{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"metadata_lookup","description":"Lookup","inputSchema":{"type":"object"},"annotations":{"readOnlyHint":true,"destructiveHint":false}}]}}"#
            default:
                XCTAssertEqual(request.httpMethod, "DELETE")
                status = 200
                payload = ""
            }
            recorder.record(request: request, rpcMethod: method, id: id)
            return MCPURLProtocolResponse(status: status, headers: headers, data: Data(payload.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MCPFixtureURLProtocol.self]
        MCPFixtureURLProtocol.recorder = recorder
        let session = URLSession(configuration: configuration)
        let server = httpConfiguration(enabled: true)
        let client = HTTPMCPClient(configuration: server, session: session, timeout: 2)

        let tools = try await client.listTools()

        XCTAssertEqual(tools.map(\.name), ["metadata_lookup"])
        let requests = recorder.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "POST", "POST", "DELETE"])
        XCTAssertEqual(requests.compactMap(\.id), [1, 2])
        XCTAssertEqual(requests.compactMap(\.rpcMethod), [
            "initialize", "notifications/initialized", "tools/list",
        ])
        XCTAssertNil(requests.first?.sessionID)
        XCTAssertTrue(requests.dropFirst().allSatisfy { $0.sessionID == sessionID })
    }

    func testHTTPCallUsesSequentialRequestIDsAndReturnsDataWithoutInterpretation() async throws {
        let recorder = MCPURLProtocolRecorder()
        let marker = fixture.appendingPathComponent("http-must-not-exist")
        recorder.handler = { request in
            let body = requestBodyData(request).flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
            let method = body?["method"] as? String
            let id = body?["id"] as? Int
            recorder.record(request: request, rpcMethod: method, id: id)
            guard let id else {
                return MCPURLProtocolResponse(status: 202, headers: [:], data: Data())
            }
            let result: String
            if method == "initialize" {
                result = #"{"protocolVersion":"2025-03-26","capabilities":{},"serverInfo":{"name":"fixture","version":"1"}}"#
            } else if method == "tools/list" {
                result = #"{"tools":[{"name":"metadata_lookup","inputSchema":{"type":"object"},"annotations":{"readOnlyHint":true,"destructiveHint":false}}]}"#
            } else {
                result = #"{"content":[{"type":"text","text":"touch __MARKER__"}],"structuredContent":{"description":"HTTP source"}}"#
                    .replacingOccurrences(of: "__MARKER__", with: marker.path)
            }
            return MCPURLProtocolResponse(
                status: 200,
                headers: method == "initialize" ? ["Mcp-Session-Id": "session-\(id)"] : [:],
                data: Data("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"result\":\(result)}".utf8)
            )
        }
        let session = fixtureSession(recorder)
        let client = HTTPMCPClient(
            configuration: httpConfiguration(enabled: true, enabledTools: ["metadata_lookup"]),
            session: session
        )

        let result = try await client.call(tool: "metadata_lookup", arguments: ["name": .string("demo")])

        XCTAssertEqual(result.structuredContent?.objectValue?["description"]?.stringValue, "HTTP source")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(recorder.requests.compactMap(\.id), [1, 2, 3, 4])
        XCTAssertEqual(recorder.requests.compactMap(\.rpcMethod), [
            "initialize", "notifications/initialized", "tools/list",
            "initialize", "notifications/initialized", "tools/call",
        ])
    }

    func testHTTPRejectsDisabledInvalidAndLegacyServersWithoutNetworkAccess() async throws {
        let recorder = MCPURLProtocolRecorder()
        let session = fixtureSession(recorder)
        await XCTAssertThrowsMCPError(
            try await HTTPMCPClient(
                configuration: httpConfiguration(enabled: false),
                session: session
            ).listTools(),
            expected: .disabled
        )
        let invalid = MCPServerConfiguration(
            id: "invalid",
            name: "invalid",
            source: .generic,
            configurationURL: fixture,
            transport: .streamableHTTP(endpoint: URL(string: "ftp://example.com/mcp")!, headers: [:]),
            support: .supported,
            isEnabled: true
        )
        await XCTAssertThrowsMCPError(
            try await HTTPMCPClient(configuration: invalid, session: session).listTools(),
            expected: .invalidEndpoint
        )
        let legacy = MCPServerConfiguration(
            id: "legacy",
            name: "legacy",
            source: .generic,
            configurationURL: fixture,
            transport: .legacySSE(URL(string: "https://example.com/sse")!),
            support: .unsupportedLegacySSE,
            isEnabled: true
        )
        await XCTAssertThrowsMCPError(
            try await HTTPMCPClient(configuration: legacy, session: session).listTools(),
            expected: .unsupportedTransport
        )
        XCTAssertEqual(recorder.requests, [])
    }

    func testHTTPBoundsResponsesAndTimesOutUnresponsiveServer() async throws {
        let oversizedRecorder = MCPURLProtocolRecorder()
        oversizedRecorder.handler = { request in
            oversizedRecorder.record(request: request, rpcMethod: "initialize", id: 1)
            return MCPURLProtocolResponse(status: 200, headers: [:], data: Data(repeating: 0x31, count: 100))
        }
        await XCTAssertThrowsMCPError(
            try await HTTPMCPClient(
                configuration: httpConfiguration(enabled: true),
                session: fixtureSession(oversizedRecorder),
                maximumResponseBytes: 16
            ).listTools(),
            expected: .responseTooLarge
        )

        let stalledRecorder = MCPURLProtocolRecorder()
        stalledRecorder.handler = { request in
            stalledRecorder.record(request: request, rpcMethod: "initialize", id: 1)
            return MCPURLProtocolResponse(status: -1, headers: [:], data: Data())
        }
        await XCTAssertThrowsMCPError(
            try await HTTPMCPClient(
                configuration: httpConfiguration(enabled: true),
                session: fixtureSession(stalledRecorder),
                timeout: 0.1
            ).listTools(),
            expected: .timedOut
        )
    }

    func testHTTPCleanupHasIndependentHardDeadlineForSlowDripResponse() async throws {
        let recorder = cleanupRecorder(
            response: MCPURLProtocolResponse(
                status: 200,
                headers: [:],
                data: Data(repeating: 0x31, count: 200),
                chunkSize: 1,
                chunkInterval: 0.01
            )
        )
        let clock = ContinuousClock()
        let start = clock.now
        let tools = try await HTTPMCPClient(
            configuration: httpConfiguration(enabled: true),
            session: fixtureSession(recorder),
            timeout: 2,
            cleanupTimeout: 0.1
        ).listTools()

        XCTAssertEqual(tools.map(\.name), ["metadata_lookup"])
        XCTAssertLessThan(start.duration(to: clock.now), .milliseconds(500))
        XCTAssertLessThan(recorder.deliveredDeleteBytes, 200)
    }

    func testHTTPCleanupStopsStreamingWhenResponseExceedsBound() async throws {
        let recorder = cleanupRecorder(
            response: MCPURLProtocolResponse(
                status: 200,
                headers: [:],
                data: Data(repeating: 0x31, count: 800),
                chunkSize: 1,
                chunkInterval: 0.001
            )
        )
        let tools = try await HTTPMCPClient(
            configuration: httpConfiguration(enabled: true),
            session: fixtureSession(recorder),
            timeout: 2,
            maximumResponseBytes: 256,
            cleanupTimeout: 2
        ).listTools()

        XCTAssertEqual(tools.map(\.name), ["metadata_lookup"])
        XCTAssertLessThan(recorder.deliveredDeleteBytes, 800)
    }

    func testCancellingOuterTaskInterruptsHTTPCleanup() async throws {
        let recorder = cleanupRecorder(
            response: MCPURLProtocolResponse(
                status: 200,
                headers: [:],
                data: Data(repeating: 0x31, count: 200),
                chunkSize: 1,
                chunkInterval: 0.01
            )
        )
        let configuration = httpConfiguration(enabled: true)
        let session = fixtureSession(recorder)
        let task = Task {
            try await HTTPMCPClient(
                configuration: configuration,
                session: session,
                timeout: 3,
                cleanupTimeout: 3
            ).listTools()
        }
        for _ in 0..<100 where !recorder.hasDeleteRequest {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(recorder.hasDeleteRequest)

        let clock = ContinuousClock()
        let start = clock.now
        task.cancel()
        let tools = try await task.value

        XCTAssertEqual(tools.map(\.name), ["metadata_lookup"])
        XCTAssertLessThan(start.duration(to: clock.now), .milliseconds(500))
        XCTAssertLessThan(recorder.deliveredDeleteBytes, 200)
    }

    func testToolSafetyRequiresExplicitReadOnlyAndNonDestructiveAnnotations() {
        let safe = MCPTool(
            name: "safe",
            description: nil,
            inputSchema: .object([:]),
            annotations: MCPToolAnnotations(readOnlyHint: true, destructiveHint: false)
        )
        let contradictory = MCPTool(
            name: "contradictory",
            description: nil,
            inputSchema: .object([:]),
            annotations: MCPToolAnnotations(readOnlyHint: true, destructiveHint: true)
        )
        let unknownDestructiveness = MCPTool(
            name: "unknown",
            description: nil,
            inputSchema: .object([:]),
            annotations: MCPToolAnnotations(readOnlyHint: true)
        )

        XCTAssertFalse(safe.requiresPerCallConfirmation)
        XCTAssertTrue(contradictory.requiresPerCallConfirmation)
        XCTAssertTrue(unknownDestructiveness.requiresPerCallConfirmation)
    }

    func testStructuredToolResultMapsToMetadataCandidateOnlyAfterValidation() throws {
        let valid = MCPToolResult(
            content: [.init(type: "text", text: "This text is not parsed as metadata.")],
            structuredContent: .object([
                "description": .string("Exact structured description."),
                "sourceIdentifier": .string("acme/demo"),
                "evidenceURL": .string("https://example.com/acme/demo"),
                "skillSubdirectory": .string("skills/demo"),
            ]),
            isError: false
        )

        XCTAssertEqual(
            try MCPMetadataCandidateMapper.map(valid),
            MetadataCandidate(
                provider: .mcp,
                sourceIdentifier: "acme/demo",
                skillSubdirectory: "skills/demo",
                description: "Exact structured description.",
                evidenceURL: URL(string: "https://example.com/acme/demo")!,
                sourceBinding: nil
            )
        )
        for invalid in [
            MCPToolResult(content: [.init(type: "text", text: "description only")], structuredContent: nil, isError: false),
            MCPToolResult(
                content: [],
                structuredContent: .object([
                    "description": .string("Description"),
                    "sourceIdentifier": .string("demo"),
                    "evidenceURL": .string("file:///tmp/private"),
                ]),
                isError: false
            ),
            MCPToolResult(
                content: [],
                structuredContent: .object([
                    "description": .string("Description"),
                    "sourceIdentifier": .string("demo"),
                    "evidenceURL": .string("https://example.com/demo"),
                    "skillSubdirectory": .string("../private"),
                ]),
                isError: false
            ),
        ] {
            XCTAssertThrowsError(try MCPMetadataCandidateMapper.map(invalid)) { error in
                XCTAssertEqual(error as? MCPMetadataMappingError, .invalidStructuredResult)
            }
        }
    }

    func testEnabledApprovedMCPProviderProducesStructuredMetadataCandidate() async throws {
        let transcript = fixture.appendingPathComponent("provider-transcript")
        let server = try makeExecutable("""
        #!/bin/sh
        count=0
        while IFS= read -r line; do
          count=$((count + 1))
          printf '%s\n' "$line" >> "$1"
          if [ "$count" -eq 1 ]; then
            printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-03-26","capabilities":{},"serverInfo":{"name":"fixture","version":"1"}}}'
          elif [ "$count" -eq 3 ]; then
            case "$line" in
              *call*) printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"structuredContent":{"description":"Provider description.","sourceIdentifier":"fixture/demo","evidenceURL":"https://example.com/fixture/demo"}}}' ;;
              *) printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"metadata_lookup","inputSchema":{"type":"object"},"annotations":{"readOnlyHint":true,"destructiveHint":false}}]}}' ;;
            esac
          fi
        done
        """)
        let config = #"{"mcpServers":{"fixture":{"command":"__COMMAND__","args":["__TRANSCRIPT__"]}}}"#
            .replacingOccurrences(of: "__COMMAND__", with: server.path)
            .replacingOccurrences(of: "__TRANSCRIPT__", with: transcript.path)
        try config.write(to: fixture.appendingPathComponent("mcp.json"), atomically: true, encoding: .utf8)
        let discovered = try MCPConfigDiscovery().discover(in: fixture)
        let configuration = try XCTUnwrap(discovered.first)
        let defaults = UserDefaults(suiteName: "MCPProviderTests-\(UUID().uuidString)")!
        let preferences = MCPPreferenceStore(defaults: defaults)
        preferences.setServer(configuration.id, enabled: true)
        preferences.setTool("metadata_lookup", serverID: configuration.id, enabled: true)
        let approval = CommandApproval(
            store: UserDefaultsCommandApprovalStore(defaults: defaults, key: "approvals")
        )
        approval.approve(try XCTUnwrap(configuration.commandApproval))
        let provider = MCPMetadataProvider(
            rootURL: fixture,
            authorizedHomeURL: fixture,
            preferences: preferences,
            approval: approval
        )

        let candidates = try await provider.candidates(for: MetadataQuery(name: "demo"))

        XCTAssertEqual(candidates, [
            MetadataCandidate(
                provider: .mcp,
                sourceIdentifier: "fixture/demo",
                skillSubdirectory: nil,
                description: "Provider description.",
                evidenceURL: URL(string: "https://example.com/fixture/demo")!,
                sourceBinding: nil
            ),
        ])
    }

    func testAutomaticMCPProviderDoesNotCallToolWithContradictorySafetyAnnotations() async throws {
        let transcript = fixture.appendingPathComponent("unsafe-provider-transcript")
        let server = try makeExecutable("""
        #!/bin/sh
        count=0
        while IFS= read -r line; do
          count=$((count + 1))
          printf '%s\n' "$line" >> "$1"
          if [ "$count" -eq 1 ]; then
            printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-03-26","capabilities":{},"serverInfo":{"name":"fixture","version":"1"}}}'
          elif [ "$count" -eq 3 ]; then
            printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"metadata_lookup","inputSchema":{"type":"object"},"annotations":{"readOnlyHint":true,"destructiveHint":true}}]}}'
          fi
        done
        """)
        let config = #"{"mcpServers":{"fixture":{"command":"__COMMAND__","args":["__TRANSCRIPT__"]}}}"#
            .replacingOccurrences(of: "__COMMAND__", with: server.path)
            .replacingOccurrences(of: "__TRANSCRIPT__", with: transcript.path)
        try config.write(to: fixture.appendingPathComponent("mcp.json"), atomically: true, encoding: .utf8)
        let configuration = try XCTUnwrap(MCPConfigDiscovery().discover(in: fixture).first)
        let defaults = UserDefaults(suiteName: "MCPUnsafeProviderTests-\(UUID().uuidString)")!
        let preferences = MCPPreferenceStore(defaults: defaults)
        preferences.setServer(configuration.id, enabled: true)
        preferences.setTool("metadata_lookup", serverID: configuration.id, enabled: true)
        let approval = CommandApproval(
            store: UserDefaultsCommandApprovalStore(defaults: defaults, key: "approvals")
        )
        approval.approve(try XCTUnwrap(configuration.commandApproval))
        let provider = MCPMetadataProvider(
            rootURL: fixture,
            authorizedHomeURL: fixture,
            preferences: preferences,
            approval: approval
        )

        let candidates = try await provider.candidates(for: MetadataQuery(name: "demo"))

        XCTAssertEqual(candidates, [])
        let messages = try String(contentsOf: transcript, encoding: .utf8)
        XCTAssertFalse(messages.contains("tools/call"))
    }

    private func makeExecutable(_ contents: String) throws -> URL {
        let url = fixture.appendingPathComponent("server-\(UUID().uuidString).sh")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func stdioConfiguration(
        executable: URL,
        arguments: [String] = [],
        enabled: Bool,
        enabledTools: Set<String> = []
    ) -> MCPServerConfiguration {
        let id = "generic:mcp.json:fixture:\(UUID().uuidString)"
        return MCPServerConfiguration(
            id: id,
            name: "fixture",
            source: .generic,
            configurationURL: fixture.appendingPathComponent("mcp.json"),
            transport: .stdio(
                executable: executable.path,
                arguments: arguments,
                environment: [:],
                workingDirectory: nil
            ),
            support: .supported,
            isEnabled: enabled,
            enabledToolNames: enabledTools,
            commandApproval: ApprovedCommand(
                executablePath: executable.path,
                arguments: arguments,
                configurationFingerprint: id
            )
        )
    }

    private func httpConfiguration(
        enabled: Bool,
        enabledTools: Set<String> = []
    ) -> MCPServerConfiguration {
        MCPServerConfiguration(
            id: "generic:mcp.json:http",
            name: "http",
            source: .generic,
            configurationURL: fixture.appendingPathComponent("mcp.json"),
            transport: .streamableHTTP(
                endpoint: URL(string: "https://example.com/mcp")!,
                headers: [:]
            ),
            support: .supported,
            isEnabled: enabled,
            enabledToolNames: enabledTools
        )
    }

    private func fixtureSession(_ recorder: MCPURLProtocolRecorder) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MCPFixtureURLProtocol.self]
        MCPFixtureURLProtocol.recorder = recorder
        return URLSession(configuration: configuration)
    }

    private func cleanupRecorder(response cleanupResponse: MCPURLProtocolResponse) -> MCPURLProtocolRecorder {
        let recorder = MCPURLProtocolRecorder()
        recorder.handler = { request in
            let body = requestBodyData(request).flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            }
            let method = body?["method"] as? String
            let id = body?["id"] as? Int
            recorder.record(request: request, rpcMethod: method, id: id)
            if request.httpMethod == "DELETE" { return cleanupResponse }
            if method == "notifications/initialized" {
                return MCPURLProtocolResponse(status: 202, headers: [:], data: Data())
            }
            let result = method == "initialize"
                ? #"{"protocolVersion":"2025-03-26","capabilities":{},"serverInfo":{"name":"fixture","version":"1"}}"#
                : #"{"tools":[{"name":"metadata_lookup","inputSchema":{"type":"object"}}]}"#
            return MCPURLProtocolResponse(
                status: 200,
                headers: method == "initialize" ? ["Mcp-Session-Id": "cleanup-session"] : [:],
                data: Data("{\"jsonrpc\":\"2.0\",\"id\":\(id!),\"result\":\(result)}".utf8)
            )
        }
        return recorder
    }

    private func fixtureApproval(for configuration: MCPServerConfiguration) -> CommandApproval {
        let defaults = UserDefaults(suiteName: "MCPClientTests-\(UUID().uuidString)")!
        let approval = CommandApproval(store: UserDefaultsCommandApprovalStore(defaults: defaults))
        if let command = configuration.commandApproval { approval.approve(command) }
        return approval
    }

    private func waitUntilProcessIsGone(_ pid: Int32) async -> Bool {
        for _ in 0..<100 {
            if kill(pid, 0) != 0, errno == ESRCH { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    private func awaitProcessGone(_ pid: Int32) -> Bool {
        for _ in 0..<100 {
            if kill(pid, 0) != 0, errno == ESRCH { return true }
            usleep(20_000)
        }
        return false
    }

    private func waitForPID(in url: URL) async throws -> Int32 {
        for _ in 0..<100 {
            if let text = try? String(contentsOf: url, encoding: .utf8), let pid = Int32(text) {
                return pid
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw MCPFixtureError.missingPID
    }
}

private enum MCPFixtureError: Error { case missingPID }

private func requestBodyData(_ request: URLRequest) -> Data? {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        if count <= 0 { break }
        result.append(contentsOf: buffer.prefix(count))
    }
    return result
}

private struct MCPURLProtocolResponse: Sendable {
    let status: Int
    let headers: [String: String]
    let data: Data
    let chunkSize: Int?
    let chunkInterval: TimeInterval

    init(
        status: Int,
        headers: [String: String],
        data: Data,
        chunkSize: Int? = nil,
        chunkInterval: TimeInterval = 0
    ) {
        self.status = status
        self.headers = headers
        self.data = data
        self.chunkSize = chunkSize
        self.chunkInterval = chunkInterval
    }
}

private struct MCPRecordedRequest: Sendable, Equatable {
    let httpMethod: String
    let rpcMethod: String?
    let id: Int?
    let sessionID: String?
}

private final class MCPURLProtocolRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [MCPRecordedRequest] = []
    private var deliveredDeleteByteCount = 0
    var handler: @Sendable (URLRequest) -> MCPURLProtocolResponse = { _ in
        MCPURLProtocolResponse(status: 500, headers: [:], data: Data())
    }

    var requests: [MCPRecordedRequest] {
        lock.withLock { recorded }
    }

    var hasDeleteRequest: Bool {
        lock.withLock { recorded.contains { $0.httpMethod == "DELETE" } }
    }

    var deliveredDeleteBytes: Int {
        lock.withLock { deliveredDeleteByteCount }
    }

    func record(request: URLRequest, rpcMethod: String?, id: Int?) {
        lock.withLock {
            recorded.append(MCPRecordedRequest(
                httpMethod: request.httpMethod ?? "",
                rpcMethod: rpcMethod,
                id: id,
                sessionID: request.value(forHTTPHeaderField: "Mcp-Session-Id")
            ))
        }
    }

    func recordDelivery(request: URLRequest, byteCount: Int) {
        guard request.httpMethod == "DELETE" else { return }
        lock.withLock { deliveredDeleteByteCount += byteCount }
    }
}

private final class MCPFixtureURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var recorder: MCPURLProtocolRecorder?
    private let lock = NSLock()
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let recorder = Self.recorder else {
            client?.urlProtocol(self, didFailWithError: MCPFixtureError.missingPID)
            return
        }
        let response = recorder.handler(request)
        if response.status < 0 { return }
        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: response.status,
            httpVersion: "HTTP/1.1",
            headerFields: response.headers
        )!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        guard let chunkSize = response.chunkSize, chunkSize > 0 else {
            if !response.data.isEmpty {
                recorder.recordDelivery(request: request, byteCount: response.data.count)
                client?.urlProtocol(self, didLoad: response.data)
            }
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        DispatchQueue.global(qos: .utility).async { [self] in
            var offset = 0
            while offset < response.data.count {
                if response.chunkInterval > 0 { Thread.sleep(forTimeInterval: response.chunkInterval) }
                if lock.withLock({ stopped }) { return }
                let end = min(offset + chunkSize, response.data.count)
                let chunk = response.data.subdata(in: offset..<end)
                recorder.recordDelivery(request: request, byteCount: chunk.count)
                client?.urlProtocol(self, didLoad: chunk)
                offset = end
            }
            if !lock.withLock({ stopped }) { client?.urlProtocolDidFinishLoading(self) }
        }
    }

    override func stopLoading() {
        lock.withLock { stopped = true }
    }
}

private func XCTAssertThrowsMCPError<T>(
    _ expression: @autoclosure () async throws -> T,
    expected: MCPClientError,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected MCP client error", file: file, line: line)
    } catch {
        XCTAssertEqual(error as? MCPClientError, expected, file: file, line: line)
    }
}
