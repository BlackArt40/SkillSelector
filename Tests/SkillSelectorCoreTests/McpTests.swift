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

    // MARK: YAML — Goose's `extensions` map

    func testParsesGooseYamlExtensions() throws {
        let yaml = """
        GOOSE_PROVIDER: anthropic
        extensions:
          fetch:
            cmd: uvx
            args: ["mcp-server-fetch"]
            type: stdio
            enabled: true
          dice:
            name: Dice Roller
            cmd: uvx
            args: ["dice-mcp"]
            enabled: false
          remote:
            type: streamable_http
            uri: https://example.com/mcp
          sse-one:
            type: sse
            uri: https://example.com/sse
          bare-remote:
            uri: https://example.com/bare
        """
        let servers = try McpConfigParser.parse(Data(yaml.utf8), format: "yaml")

        // Disabled extensions are skipped, like unusable entries elsewhere.
        XCTAssertEqual(Set(servers.map(\.name)), ["fetch", "remote", "sse-one", "bare-remote"])
        let fetch = servers.first { $0.name == "fetch" }
        XCTAssertEqual(fetch?.transport, .stdio)
        XCTAssertEqual(fetch?.command, "uvx")
        XCTAssertEqual(fetch?.arguments, ["mcp-server-fetch"])
        XCTAssertEqual(servers.first { $0.name == "remote" }?.transport, .http)
        XCTAssertEqual(servers.first { $0.name == "remote" }?.url, "https://example.com/mcp")
        XCTAssertEqual(servers.first { $0.name == "sse-one" }?.transport, .sse)
        XCTAssertEqual(servers.first { $0.name == "bare-remote" }?.transport, .http)
    }

    func testGooseYamlWithoutExtensionsYieldsEmpty() throws {
        let servers = try McpConfigParser.parse(Data("GOOSE_MODE: approve\n".utf8), format: "yaml")
        XCTAssertTrue(servers.isEmpty)
    }

    func testMalformedYamlThrows() {
        XCTAssertThrowsError(try McpConfigParser.parse(Data("extensions: [unclosed".utf8), format: "yaml"))
    }

    // MARK: OpenCode — the `mcp` key with array command

    func testParsesOpenCodeMcpKeyWithArrayCommand() throws {
        let json = """
        {
          "$schema": "https://opencode.ai/config.json",
          "mcp": {
            "shadcn": { "type": "local", "command": ["npx", "-y", "shadcn-vue@latest", "mcp"], "enabled": true },
            "off": { "type": "local", "command": ["uvx", "mcp-off"], "enabled": false },
            "remote": { "type": "remote", "url": "https://example.com/mcp", "enabled": true }
          }
        }
        """
        let servers = try McpConfigParser.parse(Data(json.utf8), format: "json")

        XCTAssertEqual(Set(servers.map(\.name)), ["shadcn", "remote"], "disabled entries are skipped")
        let shadcn = servers.first { $0.name == "shadcn" }
        XCTAssertEqual(shadcn?.command, "npx", "the array's first element is the command")
        XCTAssertEqual(shadcn?.arguments, ["-y", "shadcn-vue@latest", "mcp"])
        XCTAssertEqual(shadcn?.transport, .stdio)
        let remote = servers.first { $0.name == "remote" }
        XCTAssertEqual(remote?.transport, .http)
        XCTAssertEqual(remote?.url, "https://example.com/mcp")
    }

    func testUnsupportedFormatThrows() {
        XCTAssertThrowsError(try McpConfigParser.parse(Data("nope".utf8), format: "xml"))
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

    /// Gemini CLI keeps its MCP servers under the top-level `mcpServers`
    /// key of settings.json — global and per-project.
    func testScansGeminiSettingsJsonMcpServers() throws {
        let home = tempRoot.appending(path: "home")
        try FileManager.default.createDirectory(
            at: home.appending(path: ".gemini"),
            withIntermediateDirectories: true
        )
        try """
        {
          "theme": "auto",
          "mcpServers": {
            "context7": { "command": "npx", "args": ["-y", "@upstash/context7-mcp"] }
          }
        }
        """.write(to: home.appending(path: ".gemini/settings.json"), atomically: true, encoding: .utf8)

        let project = tempRoot.appending(path: "demo-webapp")
        try FileManager.default.createDirectory(
            at: project.appending(path: ".gemini"),
            withIntermediateDirectories: true
        )
        try """
        { "mcpServers": { "search": { "type": "http", "url": "https://example.com/mcp" } } }
        """.write(to: project.appending(path: ".gemini/settings.json"), atomically: true, encoding: .utf8)

        let servers = McpScanner().scan(
            homeRoot: AuthorizedRootSnapshot(id: "home", url: home, kind: .home),
            projectRoots: [
                AuthorizedRootSnapshot(id: "proj", url: project, kind: .project),
            ]
        )

        let context7 = try XCTUnwrap(servers.first { $0.name == "context7" })
        XCTAssertEqual(context7.agentID, "gemini-cli")
        XCTAssertNil(context7.projectRootID)
        XCTAssertEqual(context7.command, "npx")

        let search = try XCTUnwrap(servers.first { $0.name == "search" })
        XCTAssertEqual(search.agentID, "gemini-cli")
        XCTAssertEqual(search.projectRootID, "proj")
        XCTAssertEqual(search.transport, .http)
    }

    /// The VS Code family: Copilot reads VS Code's native mcp.json
    /// ("servers" key), while Cline keeps mcpServers in its extension's
    /// globalStorage settings.
    func testScansVSCodeFamilyMcpConfigs() throws {
        let home = tempRoot.appending(path: "home")
        let codeUser = home.appending(path: "Library/Application Support/Code/User")
        try FileManager.default.createDirectory(at: codeUser, withIntermediateDirectories: true)
        try """
        { "servers": { "github": { "type": "http", "url": "https://api.githubcopilot.com/mcp" } } }
        """.write(to: codeUser.appending(path: "mcp.json"), atomically: true, encoding: .utf8)

        let clineSettings = codeUser.appending(
            path: "globalStorage/saoudrizwan.claude-dev/settings",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: clineSettings, withIntermediateDirectories: true)
        try """
        { "mcpServers": { "browser": { "command": "npx", "args": ["-y", "@cline/browser"] } } }
        """.write(
            to: clineSettings.appending(path: "cline_mcp_settings.json"),
            atomically: true,
            encoding: .utf8
        )

        let project = tempRoot.appending(path: "demo-webapp")
        try FileManager.default.createDirectory(
            at: project.appending(path: ".vscode"),
            withIntermediateDirectories: true
        )
        try """
        { "servers": { "local-disk": { "command": "npx", "args": ["-y", "mcp-disk"] } } }
        """.write(to: project.appending(path: ".vscode/mcp.json"), atomically: true, encoding: .utf8)

        let servers = McpScanner().scan(
            homeRoot: AuthorizedRootSnapshot(id: "home", url: home, kind: .home),
            projectRoots: [
                AuthorizedRootSnapshot(id: "proj", url: project, kind: .project),
            ]
        )

        let github = try XCTUnwrap(servers.first { $0.name == "github" })
        XCTAssertEqual(github.agentID, "github-copilot")
        XCTAssertNil(github.projectRootID)

        let browser = try XCTUnwrap(servers.first { $0.name == "browser" })
        XCTAssertEqual(browser.agentID, "cline")
        XCTAssertEqual(browser.configFile, clineSettings.appending(path: "cline_mcp_settings.json").path)

        let disk = try XCTUnwrap(servers.first { $0.name == "local-disk" })
        XCTAssertEqual(disk.agentID, "github-copilot")
        XCTAssertEqual(disk.projectRootID, "proj")
    }

    /// Goose (YAML `extensions`) and OpenCode (the `mcp` key) round-trip
    /// through the scanner at their declared paths.
    func testScansGooseAndOpenCodeConfigs() throws {
        let home = tempRoot.appending(path: "home")
        try FileManager.default.createDirectory(
            at: home.appending(path: ".config/goose"),
            withIntermediateDirectories: true
        )
        try """
        extensions:
          fetch:
            cmd: npx
            args: ["-y", "@upstash/context7-mcp"]
            type: stdio
        """.write(to: home.appending(path: ".config/goose/config.yaml"), atomically: true, encoding: .utf8)

        try FileManager.default.createDirectory(
            at: home.appending(path: ".config/opencode"),
            withIntermediateDirectories: true
        )
        try """
        { "mcp": { "agent-docs": { "type": "remote", "url": "https://opencode.ai/mcp" } } }
        """.write(to: home.appending(path: ".config/opencode/opencode.json"), atomically: true, encoding: .utf8)

        let project = tempRoot.appending(path: "demo-webapp")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try """
        { "mcp": { "disk": { "type": "local", "command": ["npx", "-y", "mcp-disk"] } } }
        """.write(to: project.appending(path: "opencode.json"), atomically: true, encoding: .utf8)

        let servers = McpScanner().scan(
            homeRoot: AuthorizedRootSnapshot(id: "home", url: home, kind: .home),
            projectRoots: [
                AuthorizedRootSnapshot(id: "proj", url: project, kind: .project),
            ]
        )

        let fetch = try XCTUnwrap(servers.first { $0.name == "fetch" })
        XCTAssertEqual(fetch.agentID, "goose")
        XCTAssertNil(fetch.projectRootID)
        XCTAssertEqual(fetch.transport, .stdio)

        let docs = try XCTUnwrap(servers.first { $0.name == "agent-docs" })
        XCTAssertEqual(docs.agentID, "opencode")
        XCTAssertNil(docs.projectRootID)

        let disk = try XCTUnwrap(servers.first { $0.name == "disk" })
        XCTAssertEqual(disk.agentID, "opencode")
        XCTAssertEqual(disk.projectRootID, "proj")
        XCTAssertEqual(disk.command, "npx")
    }

    func testGooseAndOpenCodeMcpDeclarations() {
        let goose = McpRegistry.declarations.first { $0.agentID == "goose" }
        XCTAssertEqual(goose?.globalPath, "~/.config/goose/config.yaml")
        XCTAssertNil(goose?.projectPath)
        XCTAssertEqual(goose?.format, "yaml")

        let opencode = McpRegistry.declarations.first { $0.agentID == "opencode" }
        XCTAssertEqual(opencode?.globalPath, "~/.config/opencode/opencode.json")
        XCTAssertEqual(opencode?.projectPath, "opencode.json")
        XCTAssertEqual(opencode?.format, "json")
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

    /// A config file beyond the read bound must be skipped entirely instead
    /// of being slurped into memory during a scan (audit R3/F-01 parity with
    /// the Skill entry cap).
    func testOversizedConfigFileIsSkipped() throws {
        let home = tempRoot.appending(path: "home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let codexDir = home.appending(path: ".codex")
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        let oversized = String(
            repeating: "# padding line\n",
            count: McpScanner.maximumConfigFileBytes / 16 + 1
        )
        try oversized.write(
            to: codexDir.appending(path: "config.toml"),
            atomically: true,
            encoding: .utf8
        )

        let homeSnapshot = AuthorizedRootSnapshot(id: "home", url: home, kind: .home)
        let servers = McpScanner().scan(homeRoot: homeSnapshot, projectRoots: [])

        XCTAssertTrue(servers.isEmpty, "oversized config must be skipped, not read whole")
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

    /// A server that emits one unparseable line and then hangs: the probe
    /// must still hit the deadline, terminate the child, and return — the
    /// deadline check applies to every loop iteration, not only to servers
    /// that never wrote anything. (The old code only checked the deadline
    /// while the collector was empty, so this outcome spun forever.)
    func testStdioProbeTimesOutAfterGarbageOutputThenHang() async throws {
        let descriptor = McpServerDescriptor(
            name: "garbage-then-hang",
            agentID: "test",
            transport: .stdio,
            command: "/bin/sh",
            arguments: ["-c", "echo 'not json at all'; sleep 30"],
            url: nil,
            configFile: "/tmp/fake",
            projectRootID: nil
        )

        let start = Date()
        let status = await McpProber(handshakeTimeout: 0.6).probe(descriptor)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(status, .notRunning)
        XCTAssertLessThan(elapsed, 3, "probe must stay finite after garbage output")
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

    /// A server that merely echoes "result"-looking text (not a valid
    /// JSON-RPC initialize reply) must not fake a `.running` verdict — the
    /// verdict is decided by parsing the reply, not by substring matching.
    func testStdioProbeRejectsEchoThatMentionsResult() async throws {
        let descriptor = McpServerDescriptor(
            name: "fake-echo",
            agentID: "test",
            transport: .stdio,
            command: "/bin/echo",
            arguments: [#"plain text with "id":1 and "result" inside"#],
            url: nil,
            configFile: "/tmp/fake",
            projectRootID: nil
        )

        let status = await McpProber(handshakeTimeout: 2).probe(descriptor)

        XCTAssertEqual(status, .notRunning)
    }

    /// A real JSON-RPC `initialize` error reply (id 1, error member) must
    /// surface as `.failed`, not `.running` or `.notRunning`.
    func testStdioProbeFailsOnInitializeError() async throws {
        let descriptor = McpServerDescriptor(
            name: "error-server",
            agentID: "test",
            transport: .stdio,
            command: "/bin/echo",
            arguments: [#"{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"Method not found"}}"#],
            url: nil,
            configFile: "/tmp/fake",
            projectRootID: nil
        )

        let status = await McpProber(handshakeTimeout: 2).probe(descriptor)

        guard case .failed = status else {
            return XCTFail("expected .failed, got \(status)")
        }
    }

    /// Only http/https endpoints are probeable; a file:/custom-scheme URL
    /// must fail fast instead of being handed to URLSession.
    func testHttpProbeRejectsUnsupportedScheme() async {
        let descriptor = McpServerDescriptor(
            name: "file-scheme",
            agentID: "test",
            transport: .http,
            command: nil,
            arguments: [],
            url: "file:///tmp/fake-endpoint",
            configFile: "/tmp/fake",
            projectRootID: nil
        )

        let status = await McpProber(handshakeTimeout: 1).probe(descriptor)

        guard case .failed(let message) = status else {
            return XCTFail("expected .failed, got \(status)")
        }
        XCTAssertTrue(message.contains("scheme"), "failure should cite the scheme, got: \(message)")
    }
}