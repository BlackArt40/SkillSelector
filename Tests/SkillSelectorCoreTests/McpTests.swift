import Foundation
import XCTest
@testable import SkillSelectorCore

final class McpConfigParserTests: XCTestCase {
    // MARK: JSON — the mcp.json family's map shape (Claude / standard)
    func testParsesJsonMapShape() throws {
        let json = """
        {
          "mcpServers": {
            "github": {
              "type": "http",
              "url": "https://api.githubcopilot.com/mcp",
              "headers": { "authorization": "Bearer $TOKEN" }
            },
            "filesystem": {
              "command": "npx",
              "args": ["-y", "@modelcontextprotocol/server-filesystem"]
            }
          }
        }
        """
        let servers = try McpConfigParser.parse(Data(json.utf8), format: "json")

        XCTAssertEqual(servers.count, 2)
        let github = try XCTUnwrap(servers.first { $0.name == "github" })
        XCTAssertEqual(github.transport, .http)
        XCTAssertEqual(github.url, "https://api.githubcopilot.com/mcp")
        XCTAssertNil(github.command)

        let filesystem = try XCTUnwrap(servers.first { $0.name == "filesystem" })
        XCTAssertEqual(filesystem.transport, .stdio)
        XCTAssertEqual(filesystem.command, "npx")
        XCTAssertEqual(filesystem.arguments, ["-y", "@modelcontextprotocol/server-filesystem"])
    }

    /// Cursor stores mcp.json as an array of {name, …} objects, not a map.
    func testParsesJsonArrayShape() throws {
        let json = """
        {
          "mcpServers": [
            { "name": "github", "type": "http", "url": "https://api.githubcopilot.com/mcp/" },
            { "name": "disk", "command": "/usr/local/bin/mcp-disk", "args": ["--read-only"] }
          ]
        }
        """
        let servers = try McpConfigParser.parse(Data(json.utf8), format: "json")

        XCTAssertEqual(servers.count, 2)
        let disk = try XCTUnwrap(servers.first { $0.name == "disk" })
        XCTAssertEqual(disk.transport, .stdio)
        XCTAssertEqual(disk.arguments, ["--read-only"])
    }

    func testParsesSseTransportType() throws {
        let json = """
        { "servers": { "events": { "type": "sse", "url": "https://example.com/sse" } } }
        """
        let servers = try McpConfigParser.parse(Data(json.utf8), format: "json")
        let events = try XCTUnwrap(servers.first { $0.name == "events" })
        XCTAssertEqual(events.transport, .sse)
    }

    func testEmptyOrMissingMcpServersYieldsEmpty() throws {
        XCTAssertEqual(try McpConfigParser.parse(Data("{}".utf8), format: "json"), [])
        XCTAssertEqual(
            try McpConfigParser.parse(Data(#"{"somethingElse": 1}"#.utf8), format: "json"),
            []
        )
    }

    func testMalformedJsonThrows() {
        XCTAssertThrowsError(try McpConfigParser.parse(Data("{nope".utf8), format: "json"))
    }

    // MARK: TOML — Codex config.toml subset

    func testParsesCodexTomlMcpServers() throws {
        let toml = """
        # A config.toml with many unrelated tables; only [mcp_servers.*] counts.
        model = "gpt-5"

        [model_providers.openai]
        name = "openai"

        [mcp_servers.context7]
        command = "npx"
        args = ["-y", "@upstash/context7-mcp"]
        startup_timeout_sec = 10

        [mcp_servers.docs]
        url = "https://example.com/mcp"
        enabled = true

        [sandbox_mode]
        read_only = true
        """
        let servers = try McpConfigParser.parse(Data(toml.utf8), format: "toml")

        XCTAssertEqual(servers.count, 2)
        let context7 = try XCTUnwrap(servers.first { $0.name == "context7" })
        XCTAssertEqual(context7.transport, .stdio)
        XCTAssertEqual(context7.command, "npx")
        XCTAssertEqual(context7.arguments, ["-y", "@upstash/context7-mcp"])

        let docs = try XCTUnwrap(servers.first { $0.name == "docs" })
        XCTAssertEqual(docs.transport, .http)
        XCTAssertEqual(docs.url, "https://example.com/mcp")
    }

    func testTomlIgnoresCommentValuesInsideStrings() throws {
        let toml = """
        [mcp_servers.withcomment]
        command = "npx #not-a-comment"
        args = ["-y", "server"]
        """
        let servers = try McpConfigParser.parse(Data(toml.utf8), format: "toml")
        let server = try XCTUnwrap(servers.first)
        XCTAssertEqual(server.command, "npx #not-a-comment")
        XCTAssertEqual(server.arguments, ["-y", "server"])
    }

    /// A `[mcp_servers.foo.env]` sub-table declares the server's environment
    /// variables (Codex writes env that way); it must not be parsed as a
    /// separate server — only the two-segment `mcp_servers.<name>` header
    /// opens one.
    func testTomlEnvSubTableIsNotAServer() throws {
        let toml = """
        [mcp_servers.node_repl]
        command = "/Applications/.../node_repl"
        args = []

        [mcp_servers.node_repl.env]
        NODE_REPL_NODE_PATH = "/Applications/.../node"
        CODEX_HOME = "/Users/me/.codex"
        """
        let servers = try McpConfigParser.parse(Data(toml.utf8), format: "toml")

        XCTAssertEqual(servers.count, 1)
        XCTAssertEqual(servers.first?.name, "node_repl")
        XCTAssertEqual(servers.first?.command, "/Applications/.../node_repl")
    }

    func testUnsupportedFormatThrows() {
        XCTAssertThrowsError(try McpConfigParser.parse(Data("nope".utf8), format: "yaml"))
    }

    // MARK: Transport inference

    func testTransportInference() {
        XCTAssertEqual(McpTransport.infer(typeField: "streamable-http", command: nil, url: "u"), .http)
        XCTAssertEqual(McpTransport.infer(typeField: "streamable_http", command: nil, url: "u"), .http)
        XCTAssertEqual(McpTransport.infer(typeField: nil, command: "npx", url: nil), .stdio)
        XCTAssertEqual(McpTransport.infer(typeField: nil, command: nil, url: "https://x"), .http)
        XCTAssertEqual(McpTransport.infer(typeField: "stdio", command: "npx", url: nil), .stdio)
        XCTAssertEqual(McpTransport.infer(typeField: "sse", command: nil, url: "https://x"), .sse)
    }
}

final class McpScannerTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("McpScannerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    /// Writes ~/.codex/config.toml under a fake home root and a .mcp.json
    /// under a fake project root; the scanner should surface both.
    func testScansGlobalAndProjectConfigs() throws {
        let home = tempRoot.appending(path: "home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let codexDir = home.appending(path: ".codex")
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        try """
        [mcp_servers.context7]
        command = "npx"
        args = ["-y", "@upstash/context7-mcp"]
        """.write(to: codexDir.appending(path: "config.toml"), atomically: true, encoding: .utf8)

        let project = tempRoot.appending(path: "demo-webapp")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try """
        {
          "mcpServers": {
            "filesystem": { "command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "."] }
          }
        }
        """.write(to: project.appending(path: ".mcp.json"), atomically: true, encoding: .utf8)

        let homeSnapshot = AuthorizedRootSnapshot(id: "home", url: home, kind: .home)
        let projectSnapshot = AuthorizedRootSnapshot(id: "proj", url: project, kind: .project)

        let servers = McpScanner().scan(homeRoot: homeSnapshot, projectRoots: [projectSnapshot])

        let context7 = try XCTUnwrap(servers.first { $0.name == "context7" })
        XCTAssertEqual(context7.agentID, "codex")
        XCTAssertNil(context7.projectRootID)
        XCTAssertEqual(context7.command, "npx")

        let filesystem = try XCTUnwrap(servers.first { $0.name == "filesystem" })
        // .mcp.json is declared by several agents; projectDeclarations
        // deduplicates by path keeping the first declaration (claude-code).
        XCTAssertEqual(filesystem.agentID, "claude-code")
        XCTAssertEqual(filesystem.projectRootID, "proj")
        XCTAssertTrue(filesystem.configFile.hasSuffix("/.mcp.json"))
    }

    func testNoRootsYieldsEmpty() {
        XCTAssertEqual(McpScanner().scan(homeRoot: nil, projectRoots: []), [])
    }

    /// A declared server with neither command nor url is unusable and must
    /// not show up in the list.
    func testServerWithoutCommandOrUrlIsFilteredOut() throws {
        let home = tempRoot.appending(path: "home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let codexDir = home.appending(path: ".codex")
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        try """
        [mcp_servers.empty]
        startup_timeout_sec = 10

        [mcp_servers.valid]
        command = "npx"
        args = ["-y", "@upstash/context7-mcp"]
        """.write(to: codexDir.appending(path: "config.toml"), atomically: true, encoding: .utf8)

        let homeSnapshot = AuthorizedRootSnapshot(id: "home", url: home, kind: .home)
        let servers = McpScanner().scan(homeRoot: homeSnapshot, projectRoots: [])

        XCTAssertEqual(servers.map(\.name), ["valid"])
    }

    /// Claude Code declares global MCP servers at the top level of
    /// ~/.claude.json — a large JSON whose non-MCP members must be ignored.
    func testScansClaudeGlobalMcpServersFromClaudeJson() throws {
        let home = tempRoot.appending(path: "home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try """
        {
          "model": "fable",
          "theme": "dark",
          "projects": {
            "/Users/me/demo": { "mcpServers": {} }
          },
          "mcpServers": {
            "github": {
              "type": "http",
              "url": "https://api.githubcopilot.com/mcp"
            },
            "filesystem": {
              "command": "npx",
              "args": ["-y", "@modelcontextprotocol/server-filesystem"]
            }
          }
        }
        """.write(to: home.appending(path: ".claude.json"), atomically: true, encoding: .utf8)

        let homeSnapshot = AuthorizedRootSnapshot(id: "home", url: home, kind: .home)
        let servers = McpScanner().scan(homeRoot: homeSnapshot, projectRoots: [])

        XCTAssertEqual(Set(servers.compactMap(\.agentID)), Set(["claude-code"]))
        XCTAssertEqual(Set(servers.map(\.name)), Set(["github", "filesystem"]))
        let github = try XCTUnwrap(servers.first { $0.name == "github" })
        XCTAssertEqual(github.transport, .http)
        XCTAssertEqual(github.url, "https://api.githubcopilot.com/mcp")
        // Non-MCP parts of ~/.claude.json (projects with their own empty
        // mcpServers) must not contribute servers.
        XCTAssertEqual(servers.filter { !$0.configFile.hasSuffix("/.claude.json") }.count, 0)
    }

    func testGlobalPathEscapesHomeIsIgnored() {
        let home = tempRoot.appending(path: "home")
        XCTAssertNil(McpScanner.resolve(globalPath: "~/../../etc/passwd", relativeTo: home))
        XCTAssertNil(McpScanner.resolve(globalPath: "no-tilde-prefix", relativeTo: home))
        XCTAssertNotNil(McpScanner.resolve(globalPath: "~/.codex/config.toml", relativeTo: home))
    }
}

final class McpProberTests: XCTestCase {
    /// A server that prints a valid initialize response line and exits:
    /// the probe must report `.running`.
    func testStdioProbeSucceedsOnInitializeResult() async throws {
        let descriptor = McpServerDescriptor(
            name: "echo-server",
            agentID: "test",
            transport: .stdio,
            command: "/bin/echo",
            arguments: [#"{"jsonrpc":"2.0","id":1,"result":{"capabilities":{}}}"#],
            url: nil,
            configFile: "/tmp/fake",
            projectRootID: nil
        )

        let status = await McpProber(handshakeTimeout: 3).probe(descriptor)
        XCTAssertEqual(status, .running)
    }

    /// A stdio server configured with NO arguments must not crash: Process
    /// rejects a nil arguments array, so the probe must pass [] instead.
    func testStdioProbeWithNoArgumentsDoesNotCrash() async throws {
        let descriptor = McpServerDescriptor(
            name: "no-args",
            agentID: "test",
            transport: .stdio,
            command: "/bin/echo",
            arguments: [],
            url: nil,
            configFile: "/tmp/fake",
            projectRootID: nil
        )

        // Would throw NSInvalidArgumentException before the fix.
        let status = await McpProber(handshakeTimeout: 2).probe(descriptor)
        XCTAssertEqual(status, .notRunning)
    }

    /// A command that exits non-zero without a reply: `.notRunning`.
    func testStdioProbeNotRunningWhenProcessExitsWithoutReply() async throws {
        let descriptor = McpServerDescriptor(
            name: "false",
            agentID: "test",
            transport: .stdio,
            command: "/bin/echo",
            arguments: ["nothing useful"],
            url: nil,
            configFile: "/tmp/fake",
            projectRootID: nil
        )

        let status = await McpProber(handshakeTimeout: 2).probe(descriptor)
        XCTAssertEqual(status, .notRunning)
    }

    func testStdioProbeMissingCommandFails() async throws {
        let descriptor = McpServerDescriptor(
            name: "x",
            agentID: "test",
            transport: .stdio,
            command: nil,
            arguments: [],
            url: nil,
            configFile: "/tmp/fake",
            projectRootID: nil
        )
        let status = await McpProber(handshakeTimeout: 1).probe(descriptor)
        guard case .failed = status else {
            return XCTFail("expected .failed, got \(status)")
        }
    }

    /// A server that holds the handshake open past the timeout: the probe
    /// must terminate it and report `.notRunning` within the budget.
    func testStdioProbeTimesOutAndTerminates() async throws {
        let descriptor = McpServerDescriptor(
            name: "slow",
            agentID: "test",
            transport: .stdio,
            command: "/bin/sleep",
            arguments: ["30"],
            url: nil,
            configFile: "/tmp/fake",
            projectRootID: nil
        )

        let start = Date()
        let status = await McpProber(handshakeTimeout: 0.6).probe(descriptor)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(status, .notRunning)
        XCTAssertLessThan(elapsed, 3, "probe exceeded the timeout budget")
    }

    func testHttpProbeMissingUrlFails() async throws {
        let descriptor = McpServerDescriptor(
            name: "x",
            agentID: "test",
            transport: .http,
            command: nil,
            arguments: [],
            url: nil,
            configFile: "/tmp/fake",
            projectRootID: nil
        )
        let status = await McpProber(handshakeTimeout: 1).probe(descriptor)
        guard case .failed = status else {
            return XCTFail("expected .failed, got \(status)")
        }
    }
}