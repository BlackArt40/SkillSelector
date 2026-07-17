import Foundation

public enum BuiltInAgentRegistry {
    public static func make() -> AgentRegistry {
        AgentRegistry(definitions: [
            AgentDefinition(
                id: "claude-code",
                displayName: "Claude Code",
                globalRoots: ["~/.claude/skills"],
                projectPatterns: [".claude/skills"]
            ),
            AgentDefinition(
                id: "codex",
                displayName: "Codex",
                globalRoots: ["~/.codex/skills"],
                projectPatterns: [".codex/skills", ".agents/skills"]
            ),
            AgentDefinition(
                id: "qoder",
                displayName: "Qoder",
                globalRoots: ["~/.qoder/skills"],
                projectPatterns: [".qoder/skills"]
            ),
            AgentDefinition(
                id: "codebuddy",
                displayName: "CodeBuddy",
                globalRoots: ["~/.codebuddy/skills"],
                projectPatterns: [".codebuddy/skills"]
            ),
            AgentDefinition(
                id: "opencode",
                displayName: "OpenCode",
                globalRoots: ["~/.config/opencode/skills", "~/.opencode/skills"],
                projectPatterns: [".opencode/skills", ".agents/skills"]
            ),
            AgentDefinition(
                id: "cursor",
                displayName: "Cursor",
                globalRoots: ["~/.cursor/skills", "~/.agents/skills", "~/.claude/skills", "~/.codex/skills"],
                projectPatterns: [".cursor/skills", ".agents/skills", ".claude/skills", ".codex/skills"]
            ),
            AgentDefinition(
                id: "kilo-code",
                displayName: "Kilo Code",
                globalRoots: ["~/.kilo/skills"],
                projectPatterns: [".kilo/skills", ".agents/skills"]
            ),
            AgentDefinition(
                id: "cline",
                displayName: "Cline",
                globalRoots: ["~/.cline/skills", "~/.agents/skills"],
                projectPatterns: [".cline/skills", ".clinerules/skills", ".claude/skills", ".agents/skills"]
            ),
            AgentDefinition(
                id: "roo-code",
                displayName: "Roo Code",
                globalRoots: ["~/.roo/skills", "~/.agents/skills", "~/.roo/skills-{modeSlug}", "~/.agents/skills-{modeSlug}"],
                projectPatterns: [".roo/skills", ".agents/skills", ".roo/skills-{modeSlug}", ".agents/skills-{modeSlug}"],
                isLegacy: true
            ),
            AgentDefinition(
                id: "windsurf",
                displayName: "Windsurf",
                globalRoots: ["~/.codeium/windsurf/skills", "~/.agents/skills", "~/.claude/skills", "/Library/Application Support/Windsurf/skills"],
                projectPatterns: [".windsurf/skills", ".agents/skills", ".claude/skills"]
            ),
            AgentDefinition(
                id: "gemini-cli",
                displayName: "Gemini CLI",
                globalRoots: ["~/.gemini/skills", "~/.agents/skills"],
                projectPatterns: [".gemini/skills", ".agents/skills"]
            ),
            AgentDefinition(
                id: "github-copilot",
                displayName: "GitHub Copilot",
                globalRoots: ["~/.copilot/skills", "~/.claude/skills", "~/.agents/skills"],
                projectPatterns: [".github/skills", ".claude/skills", ".agents/skills"]
            ),
        ])
    }
}
