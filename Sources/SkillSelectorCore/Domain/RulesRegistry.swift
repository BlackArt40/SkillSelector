import Foundation

/// Where one Agent keeps its rules files — the instruction/memory files
/// (`CLAUDE.md`, `AGENTS.md`, `.cursorrules`, …) that shape its behavior.
/// Mirrors the shape of `McpAgentDeclaration` so the scanner walks the
/// same two authorized-root scopes used for Skills and MCP configs.
public struct RulesFileDeclaration: Hashable, Sendable {
    public let agentID: String
    /// User-level path relative to the home root ("~/.claude/CLAUDE.md"),
    /// or nil when the Agent only reads project-level rules.
    public let globalPath: String?
    /// Project-level path relative to an authorized project root
    /// ("CLAUDE.md", ".cursorrules", …), or nil for global-only files.
    public let projectPath: String?
    /// User-level rules directory relative to the home root
    /// ("~/.claude/rules"), or nil. Immediate children matching
    /// `directoryExtensions` are reported — one level, no recursion.
    public let globalDirectory: String?
    /// Project-level rules directory relative to an authorized project root
    /// (".cursor/rules"), or nil.
    public let projectDirectory: String?
    /// Allowed filename extensions (without dot, lowercase) for the
    /// directory sources, e.g. ["mdc"] for Cursor or ["md"] for Claude.
    public let directoryExtensions: Set<String>

    public init(
        agentID: String,
        globalPath: String?,
        projectPath: String?,
        globalDirectory: String? = nil,
        projectDirectory: String? = nil,
        directoryExtensions: Set<String> = []
    ) {
        self.agentID = agentID
        self.globalPath = globalPath
        self.projectPath = projectPath
        self.globalDirectory = globalDirectory
        self.projectDirectory = projectDirectory
        self.directoryExtensions = directoryExtensions
    }
}

/// Fixed, code-embedded table of where each supported Agent keeps its
/// rules files — same philosophy as `McpRegistry`: known paths declared in
/// one place, not discovered heuristically.
public enum RulesRegistry {
    public static let declarations: [RulesFileDeclaration] = [
        // Claude Code: CLAUDE.md at the agent's global root and project root.
        RulesFileDeclaration(
            agentID: "claude-code",
            globalPath: "~/.claude/CLAUDE.md",
            projectPath: "CLAUDE.md"
        ),
        // Claude Code: modular rules directories (memory docs, v2.0.64+)
        // layered around CLAUDE.md, plus the project-local CLAUDE.local.md.
        RulesFileDeclaration(
            agentID: "claude-code",
            globalPath: nil,
            projectPath: nil,
            globalDirectory: "~/.claude/rules",
            projectDirectory: ".claude/rules",
            directoryExtensions: ["md"]
        ),
        RulesFileDeclaration(
            agentID: "claude-code",
            globalPath: nil,
            projectPath: "CLAUDE.local.md"
        ),
        // Cursor: modern CLAUDE.md/AGENTS.md plus the legacy .cursorrules.
        RulesFileDeclaration(
            agentID: "cursor",
            globalPath: "~/.cursor/CLAUDE.md",
            projectPath: "CLAUDE.md"
        ),
        RulesFileDeclaration(
            agentID: "cursor",
            globalPath: "~/.cursorrules",
            projectPath: ".cursorrules"
        ),
        RulesFileDeclaration(agentID: "cursor", globalPath: nil, projectPath: "AGENTS.md"),
        // Cursor: the modern rules directories — .mdc files with frontmatter
        // under .cursor/rules, read from both the project and the home root.
        RulesFileDeclaration(
            agentID: "cursor",
            globalPath: nil,
            projectPath: nil,
            globalDirectory: "~/.cursor/rules",
            projectDirectory: ".cursor/rules",
            directoryExtensions: ["mdc"]
        ),
        // Codex: AGENTS.md.
        RulesFileDeclaration(
            agentID: "codex",
            globalPath: "~/.codex/AGENTS.md",
            projectPath: "AGENTS.md"
        ),
        // OpenCode: AGENTS.md.
        RulesFileDeclaration(
            agentID: "opencode",
            globalPath: "~/.config/opencode/AGENTS.md",
            projectPath: "AGENTS.md"
        ),
        // Windsurf: AGENTS.md plus the legacy .windsurfrules.
        RulesFileDeclaration(
            agentID: "windsurf",
            globalPath: "~/.codeium/windsurf/AGENTS.md",
            projectPath: "AGENTS.md"
        ),
        RulesFileDeclaration(
            agentID: "windsurf",
            globalPath: "~/.windsurfrules",
            projectPath: ".windsurfrules"
        ),
        // Windsurf: .md rules under the project's .windsurf/rules directory,
        // with the global rules file in the Codeium memories dir.
        RulesFileDeclaration(
            agentID: "windsurf",
            globalPath: "~/.codeium/windsurf/memories/global_rules.md",
            projectPath: nil,
            projectDirectory: ".windsurf/rules",
            directoryExtensions: ["md"]
        ),
        // Cline: .clinerules plus CLAUDE.md.
        RulesFileDeclaration(
            agentID: "cline",
            globalPath: "~/.clinerules",
            projectPath: ".clinerules"
        ),
        RulesFileDeclaration(
            agentID: "cline",
            globalPath: "~/.cline/CLAUDE.md",
            projectPath: "CLAUDE.md"
        ),
        // Cline: `.clinerules` may be a directory of .md files, and global
        // rules live in the Cline Rules folder (~/Documents/Cline/Rules).
        RulesFileDeclaration(
            agentID: "cline",
            globalPath: nil,
            projectPath: nil,
            globalDirectory: "~/Documents/Cline/Rules",
            projectDirectory: ".clinerules",
            directoryExtensions: ["md"]
        ),
        // Roo Code: .roorules plus CLAUDE.md.
        RulesFileDeclaration(
            agentID: "roo-code",
            globalPath: "~/.roorules",
            projectPath: ".roorules"
        ),
        RulesFileDeclaration(agentID: "roo-code", globalPath: nil, projectPath: "CLAUDE.md"),
        // Roo Code: layered rules directories — .md files under .roo/rules
        // at both the home root and the project root.
        RulesFileDeclaration(
            agentID: "roo-code",
            globalPath: nil,
            projectPath: nil,
            globalDirectory: "~/.roo/rules",
            projectDirectory: ".roo/rules",
            directoryExtensions: ["md"]
        ),
        // Roo Code: mode-specific rules live in `rules-{mode}` sibling
        // directories; the wildcard only names the last segment.
        RulesFileDeclaration(
            agentID: "roo-code",
            globalPath: nil,
            projectPath: nil,
            globalDirectory: "~/.roo/rules-*",
            projectDirectory: ".roo/rules-*",
            directoryExtensions: ["md"]
        ),
        // GitHub Copilot: copilot-instructions.
        RulesFileDeclaration(
            agentID: "github-copilot",
            globalPath: "~/.github/copilot-instructions.md",
            projectPath: ".github/copilot-instructions.md"
        ),
        RulesFileDeclaration(
            agentID: "github-copilot",
            globalPath: nil,
            projectPath: "COPILOT_INSTRUCTIONS.md"
        ),
        // Copilot: per-file instructions with `applyTo` frontmatter under
        // .github/instructions (matched by the *.instructions.md suffix).
        RulesFileDeclaration(
            agentID: "github-copilot",
            globalPath: nil,
            projectPath: nil,
            projectDirectory: ".github/instructions",
            directoryExtensions: ["instructions.md"]
        ),
        // Gemini CLI: GEMINI.md hierarchy — global file and project file.
        RulesFileDeclaration(
            agentID: "gemini-cli",
            globalPath: "~/.gemini/GEMINI.md",
            projectPath: "GEMINI.md"
        ),
        // Gemini CLI: AGENTS.md.
        RulesFileDeclaration(
            agentID: "gemini-cli",
            globalPath: "~/.gemini/AGENTS.md",
            projectPath: "AGENTS.md"
        ),
        // CLAUDE.md/AGENTS.md are the industry-wide defaults, declared for
        // the remaining Agents that consume them at the project root.
        RulesFileDeclaration(agentID: "kilo-code", globalPath: nil, projectPath: "CLAUDE.md"),
        RulesFileDeclaration(agentID: "kilo-code", globalPath: nil, projectPath: "AGENTS.md"),
        // Kilo Code: .md rules under the project's .kilocode/rules directory.
        RulesFileDeclaration(
            agentID: "kilo-code",
            globalPath: nil,
            projectPath: nil,
            projectDirectory: ".kilocode/rules",
            directoryExtensions: ["md"]
        ),
        // Kilo Code: Roo-style mode-specific directories.
        RulesFileDeclaration(
            agentID: "kilo-code",
            globalPath: nil,
            projectPath: nil,
            projectDirectory: ".kilocode/rules-*",
            directoryExtensions: ["md"]
        ),
        RulesFileDeclaration(agentID: "qoder", globalPath: nil, projectPath: "AGENTS.md"),
        // Qoder: .md rules under the project's .qoder/rules directory.
        RulesFileDeclaration(
            agentID: "qoder",
            globalPath: nil,
            projectPath: nil,
            projectDirectory: ".qoder/rules",
            directoryExtensions: ["md"]
        ),
        RulesFileDeclaration(agentID: "qoder", globalPath: nil, projectPath: "CLAUDE.md"),
        RulesFileDeclaration(agentID: "codebuddy", globalPath: nil, projectPath: "CLAUDE.md"),
        RulesFileDeclaration(agentID: "codebuddy", globalPath: nil, projectPath: "AGENTS.md"),
        // Amp: the project-root AGENT.md instructions file (AGENTS.md is
        // already covered by the industry-wide declaration above).
        RulesFileDeclaration(agentID: "amp", globalPath: nil, projectPath: "AGENT.md"),
    ]

    /// Declarations with a global (user-level, home-root) source — a file
    /// or a rules directory.
    public static var globalDeclarations: [RulesFileDeclaration] {
        declarations.filter { $0.globalPath != nil || $0.globalDirectory != nil }
    }

    /// Project-level sources, deduplicated by path — a project `CLAUDE.md`
    /// is one file no matter how many Agents read it, and directory sources
    /// dedupe separately from same-named files.
    public static var projectDeclarations: [RulesFileDeclaration] {
        var seen = Set<String>()
        return declarations.compactMap { declaration -> RulesFileDeclaration? in
            let key: String
            if let projectPath = declaration.projectPath, !projectPath.isEmpty {
                key = "file:\(projectPath)"
            } else if let projectDirectory = declaration.projectDirectory,
                      !projectDirectory.isEmpty {
                key = "dir:\(projectDirectory)"
            } else {
                return nil
            }
            guard seen.insert(key).inserted else { return nil }
            return declaration
        }
    }
}
