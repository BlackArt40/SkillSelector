import Foundation

/// Where one Agent stores its MCP server configuration. Mirrors the shape
/// of `AgentDefinition` (global + project scopes) so the scanner walks the
/// same two authorized-root scopes used for Skills.
public struct McpAgentDeclaration: Hashable, Sendable {
    public let agentID: String
    /// User-level config path relative to the home root ("~/.codex/...").
    public let globalPath: String
    /// Project-level config file relative to an authorized project root.
    public let projectPath: String?
    /// Config format: "toml" (Codex) or "json" (mcp.json family).
    public let format: String

    public init(agentID: String, globalPath: String, projectPath: String?, format: String) {
        self.agentID = agentID
        self.globalPath = globalPath
        self.projectPath = projectPath
        self.format = format
    }
}

/// Fixed, code-embedded table of where each supported Agent keeps MCP
/// configuration — same philosophy as `BuiltInAgentRegistry`: known paths
/// declared in one place, not discovered heuristically.
public enum McpRegistry {
    public static let declarations: [McpAgentDeclaration] = [
        // Codex: TOML; global ~/.codex/config.toml, project .codex/config.toml.
        McpAgentDeclaration(
            agentID: "codex",
            globalPath: "~/.codex/config.toml",
            projectPath: ".codex/config.toml",
            format: "toml"
        ),
        // Cursor: JSON; global ~/.cursor/mcp.json, project .cursor/mcp.json.
        McpAgentDeclaration(
            agentID: "cursor",
            globalPath: "~/.cursor/mcp.json",
            projectPath: ".cursor/mcp.json",
            format: "json"
        ),
        // Claude Code: global mcpServers live at the top level of
        // ~/.claude.json (a large JSON whose only MCP-relevant member is
        // that key); project-level config uses the standard .mcp.json.
        McpAgentDeclaration(
            agentID: "claude-code",
            globalPath: "~/.claude.json",
            projectPath: ".mcp.json",
            format: "json"
        ),
        // Windsurf: JSON; global mcp_config.json.
        McpAgentDeclaration(
            agentID: "windsurf",
            globalPath: "~/.codeium/windsurf/mcp_config.json",
            projectPath: ".windsurf/mcp_config.json",
            format: "json"
        ),
        // Gemini CLI: JSON; project-level .mcp.json.
        McpAgentDeclaration(
            agentID: "gemini-cli",
            globalPath: "",
            projectPath: ".mcp.json",
            format: "json"
        ),
        // Gemini CLI: JSON; mcpServers live at the top level of
        // settings.json, both globally and per-project.
        McpAgentDeclaration(
            agentID: "gemini-cli",
            globalPath: "~/.gemini/settings.json",
            projectPath: ".gemini/settings.json",
            format: "json"
        ),
        // GitHub Copilot: VS Code's native MCP config — the user-profile
        // mcp.json and the workspace .vscode/mcp.json ("servers" key).
        McpAgentDeclaration(
            agentID: "github-copilot",
            globalPath: "~/Library/Application Support/Code/User/mcp.json",
            projectPath: ".vscode/mcp.json",
            format: "json"
        ),
        // Cline: mcpServers live in the extension's VS Code globalStorage
        // settings; the Cline CLI reads ~/.cline/mcp.json.
        McpAgentDeclaration(
            agentID: "cline",
            globalPath: "~/Library/Application Support/Code/User/globalStorage/saoudrizwan.claude-dev/settings/cline_mcp_settings.json",
            projectPath: nil,
            format: "json"
        ),
        McpAgentDeclaration(
            agentID: "cline",
            globalPath: "~/.cline/mcp.json",
            projectPath: nil,
            format: "json"
        ),
        // Roo Code: VS Code extension globalStorage plus project .roo/mcp.json.
        McpAgentDeclaration(
            agentID: "roo-code",
            globalPath: "~/Library/Application Support/Code/User/globalStorage/RooVeterinaryInc.roo-cline/settings/mcp_settings.json",
            projectPath: ".roo/mcp.json",
            format: "json"
        ),
        // Kilo Code: VS Code extension globalStorage plus project
        // .kilocode/mcp.json.
        McpAgentDeclaration(
            agentID: "kilo-code",
            globalPath: "~/Library/Application Support/Code/User/globalStorage/kilocode.kilo-code/settings/mcp_settings.json",
            projectPath: ".kilocode/mcp.json",
            format: "json"
        ),
        // Goose: YAML with an `extensions` map; the CLI keeps a single
        // global config and has no project-level file.
        McpAgentDeclaration(
            agentID: "goose",
            globalPath: "~/.config/goose/config.yaml",
            projectPath: nil,
            format: "yaml"
        ),
        // OpenCode: JSON with the `mcp` key — local servers carry a command
        // array, remote ones a url.
        McpAgentDeclaration(
            agentID: "opencode",
            globalPath: "~/.config/opencode/opencode.json",
            projectPath: "opencode.json",
            format: "json"
        ),
        // Generic project-level .mcp.json applies to every project as a
        // shared declaration, regardless of Agent.
        McpAgentDeclaration(
            agentID: "shared",
            globalPath: "",
            projectPath: ".mcp.json",
            format: "json"
        ),
    ]

    /// Global (user-level, home-root) config paths.
    public static var globalDeclarations: [McpAgentDeclaration] {
        declarations.filter { !$0.globalPath.isEmpty }
    }

    /// Project-level config files, deduplicated by path.
    public static var projectDeclarations: [McpAgentDeclaration] {
        var seen = Set<String>()
        return declarations.filter { declaration in
            guard let projectPath = declaration.projectPath,
                  projectPath != "/" else { return false }
            return seen.insert(projectPath).inserted
        }
    }
}