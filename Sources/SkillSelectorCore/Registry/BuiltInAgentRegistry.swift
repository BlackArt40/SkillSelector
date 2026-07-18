import Foundation

public enum BuiltInAgentRegistry {
    public static func make() -> AgentRegistry {
        let definitions = [
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
                projectPatterns: [".codex/skills"]
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
                projectPatterns: [".opencode/skills"]
            ),
            AgentDefinition(
                id: "cursor",
                displayName: "Cursor",
                globalRoots: ["~/.cursor/skills"],
                projectPatterns: [".cursor/skills"]
            ),
            AgentDefinition(
                id: "kilo-code",
                displayName: "Kilo Code",
                globalRoots: ["~/.kilo/skills"],
                projectPatterns: [".kilo/skills"]
            ),
            AgentDefinition(
                id: "cline",
                displayName: "Cline",
                globalRoots: ["~/.cline/skills"],
                projectPatterns: [".cline/skills", ".clinerules/skills"]
            ),
            AgentDefinition(
                id: "roo-code",
                displayName: "Roo Code",
                globalRoots: ["~/.roo/skills", "~/.roo/skills-{modeSlug}"],
                projectPatterns: [".roo/skills", ".roo/skills-{modeSlug}"],
                isLegacy: true
            ),
            AgentDefinition(
                id: "windsurf",
                displayName: "Windsurf",
                globalRoots: ["~/.codeium/windsurf/skills", "/Library/Application Support/Windsurf/skills"],
                projectPatterns: [".windsurf/skills"]
            ),
            AgentDefinition(
                id: "gemini-cli",
                displayName: "Gemini CLI",
                globalRoots: ["~/.gemini/skills"],
                projectPatterns: [".gemini/skills"]
            ),
            AgentDefinition(
                id: "github-copilot",
                displayName: "GitHub Copilot",
                globalRoots: ["~/.copilot/skills"],
                projectPatterns: [".github/skills"]
            ),
        ]

        return AgentRegistry(
            definitions: definitions,
            sharedGlobalRoots: ["~/.agents/skills", "~/.agents/skills-{modeSlug}"],
            sharedProjectPatterns: [".agents/skills", ".agents/skills-{modeSlug}"]
        )
    }
}
