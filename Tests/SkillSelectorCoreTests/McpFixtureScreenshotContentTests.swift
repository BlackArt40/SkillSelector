import Foundation
import XCTest
@testable import SkillSelectorCore

/// Drives the same fixture layout ScreenshotMode builds (fake home with
/// .codex/config.toml and .claude.json) through the real McpScanner to
/// confirm the README MCP screenshot content.
final class McpFixtureScreenshotContentTests: XCTestCase {
    func testFixtureYieldsMCPListContent() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("McpFixtureScreenshotContent-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let home = base.appendingPathComponent("home")

        // Same layouts as ScreenshotMode.writeMcpCodexToml / writeMcpClaudeJson.
        let codexDir = home.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        try """
        [mcp_servers.context7]
        command = "npx"
        args = ["-y", "@upstash/context7-mcp"]

        [mcp_servers.server-health]
        url = "https://example.com/mcp"
        """.write(to: codexDir.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        try """
        {
          "mcpServers": {
            "filesystem": {
              "command": "npx",
              "args": ["-y", "@modelcontextprotocol/server-filesystem", "/Users/alice/Projects/demo-webapp"]
            },
            "github": {
              "type": "http",
              "url": "https://api.githubcopilot.com/mcp/"
            }
          }
        }
        """.write(to: home.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)

        let homeSnapshot = AuthorizedRootSnapshot(id: "home", url: home, kind: .home)
        let servers = McpScanner().scan(homeRoot: homeSnapshot, projectRoots: [])

        print("fixture MCP servers: \(servers.map { "\($0.name)[\($0.transport)]" }.sorted())")
        XCTAssertFalse(servers.isEmpty, "MCP 截图内容验证失败：夹具未产出任何服务器")
        XCTAssertTrue(servers.contains { $0.name == "context7" })
        XCTAssertTrue(servers.contains { $0.name == "server-health" })
        XCTAssertTrue(servers.contains { $0.name == "filesystem" })
        XCTAssertTrue(servers.contains { $0.name == "github" })
    }
}