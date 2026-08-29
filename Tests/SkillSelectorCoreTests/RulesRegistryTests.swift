import Foundation
import XCTest
@testable import SkillSelectorCore

final class RulesRegistryTests: XCTestCase {
    func testEveryDeclarationReferencesAKnownAgent() {
        let knownIDs = Set(BuiltInAgentRegistry.make().definitions.map(\.id))
        for declaration in RulesRegistry.declarations {
            XCTAssertTrue(
                knownIDs.contains(declaration.agentID),
                "\(declaration.agentID) is not a registered Agent"
            )
        }
    }

    func testProjectDeclarationsDeduplicateByPath() {
        let keys = RulesRegistry.projectDeclarations.map { declaration -> String in
            if let projectPath = declaration.projectPath { return "file:\(projectPath)" }
            return "dir:\(declaration.projectDirectory ?? "")"
        }
        XCTAssertEqual(keys.count, Set(keys).count, "project sources must be unique")
        // CLAUDE.md is declared by several Agents but listed once.
        XCTAssertEqual(
            RulesRegistry.projectDeclarations.filter { $0.projectPath == "CLAUDE.md" }.count,
            1
        )
        // The surviving declaration is the first one (Claude Code).
        XCTAssertEqual(
            RulesRegistry.projectDeclarations.first { $0.projectPath == "CLAUDE.md" }?.agentID,
            "claude-code"
        )
    }

    func testGlobalDeclarationsCarryResolvableHomePaths() {
        for declaration in RulesRegistry.globalDeclarations {
            for path in [declaration.globalPath, declaration.globalDirectory].compactMap(\.self) {
                XCTAssertTrue(
                    path.hasPrefix("~/"),
                    "global paths must be home-relative: \(path)"
                )
                XCTAssertFalse(path.contains(".."), "global paths must not escape the home root")
            }
            XCTAssertFalse(
                declaration.globalPath == nil && declaration.globalDirectory == nil,
                "globalDeclarations must carry a globalPath or a globalDirectory"
            )
        }
        XCTAssertFalse(RulesRegistry.globalDeclarations.isEmpty)
    }

    func testDirectoryRuleSourcesAreDeclared() {
        let cursor = RulesRegistry.declarations.first {
            $0.agentID == "cursor" && $0.projectDirectory != nil
        }
        XCTAssertEqual(cursor?.globalDirectory, "~/.cursor/rules")
        XCTAssertEqual(cursor?.projectDirectory, ".cursor/rules")
        XCTAssertEqual(cursor?.directoryExtensions, ["mdc"])

        let claude = RulesRegistry.declarations.first {
            $0.agentID == "claude-code" && $0.projectDirectory != nil
        }
        XCTAssertEqual(claude?.globalDirectory, "~/.claude/rules")
        XCTAssertEqual(claude?.projectDirectory, ".claude/rules")
        XCTAssertEqual(claude?.directoryExtensions, ["md"])

        // The project-local layer of Claude's memory hierarchy.
        XCTAssertEqual(
            RulesRegistry.declarations.first { $0.projectPath == "CLAUDE.local.md" }?.agentID,
            "claude-code"
        )
    }

    func testDirectoryOnlyDeclarationsSurviveScopeFilters() {
        // Directory-only declarations must not be dropped by the scope
        // filters: they are the only way `.cursor/rules` and
        // `.claude/rules` reach the scanner.
        XCTAssertTrue(
            RulesRegistry.projectDeclarations.contains { $0.projectDirectory == ".cursor/rules" }
        )
        XCTAssertTrue(
            RulesRegistry.globalDeclarations.contains { $0.globalDirectory == "~/.cursor/rules" }
        )
        XCTAssertTrue(
            RulesRegistry.projectDeclarations.contains { $0.projectDirectory == ".claude/rules" }
        )
        XCTAssertTrue(
            RulesRegistry.globalDeclarations.contains { $0.globalDirectory == "~/.claude/rules" }
        )
        XCTAssertTrue(
            RulesRegistry.projectDeclarations.contains { $0.projectDirectory == ".roo/rules" }
        )
        XCTAssertTrue(
            RulesRegistry.globalDeclarations.contains { $0.globalDirectory == "~/.roo/rules" }
        )
        XCTAssertTrue(
            RulesRegistry.projectDeclarations.contains { $0.projectDirectory == ".kilocode/rules" }
        )
        XCTAssertTrue(
            RulesRegistry.projectDeclarations.contains { $0.projectDirectory == ".clinerules" }
        )
        XCTAssertTrue(
            RulesRegistry.globalDeclarations.contains {
                $0.globalDirectory == "~/Documents/Cline/Rules"
            }
        )
        XCTAssertTrue(
            RulesRegistry.projectDeclarations.contains { $0.projectDirectory == ".windsurf/rules" }
        )
        XCTAssertTrue(
            RulesRegistry.projectDeclarations.contains {
                $0.projectDirectory == ".github/instructions"
            }
        )
    }

    func testRooKiloWindsurfRuleDirectoriesAreDeclared() {
        let roo = RulesRegistry.declarations.first {
            $0.agentID == "roo-code" && $0.projectDirectory != nil
        }
        XCTAssertEqual(roo?.globalDirectory, "~/.roo/rules")
        XCTAssertEqual(roo?.projectDirectory, ".roo/rules")
        XCTAssertEqual(roo?.directoryExtensions, ["md"])

        let kilo = RulesRegistry.declarations.first {
            $0.agentID == "kilo-code" && $0.projectDirectory != nil
        }
        XCTAssertEqual(kilo?.projectDirectory, ".kilocode/rules")
        XCTAssertEqual(kilo?.directoryExtensions, ["md"])

        let windsurf = RulesRegistry.declarations.first {
            $0.agentID == "windsurf" && $0.projectDirectory != nil
        }
        XCTAssertEqual(windsurf?.projectDirectory, ".windsurf/rules")
        XCTAssertEqual(windsurf?.directoryExtensions, ["md"])
        // Windsurf's global rules file sits under the Codeium memories dir.
        XCTAssertEqual(
            RulesRegistry.declarations.first { $0.agentID == "windsurf" }?.globalPath,
            "~/.codeium/windsurf/AGENTS.md"
        )
        XCTAssertTrue(
            RulesRegistry.declarations.contains {
                $0.agentID == "windsurf" && $0.globalPath == "~/.codeium/windsurf/memories/global_rules.md"
            }
        )
    }

    func testClineAndCopilotDirectorySourcesAreDeclared() {
        // Cline: the project `.clinerules` may be a directory of .md files,
        // and global rules live in the Cline Rules folder under Documents.
        let clineDir = RulesRegistry.declarations.first {
            $0.agentID == "cline" && $0.projectDirectory != nil
        }
        XCTAssertEqual(clineDir?.projectDirectory, ".clinerules")
        XCTAssertEqual(clineDir?.directoryExtensions, ["md"])
        XCTAssertEqual(clineDir?.globalDirectory, "~/Documents/Cline/Rules")

        // Copilot: per-file instructions with `applyTo` frontmatter.
        let copilot = RulesRegistry.declarations.first {
            $0.agentID == "github-copilot" && $0.projectDirectory != nil
        }
        XCTAssertEqual(copilot?.projectDirectory, ".github/instructions")
        XCTAssertEqual(copilot?.directoryExtensions, ["instructions.md"])
    }

    func testGeminiMdHierarchyIsDeclared() {
        XCTAssertTrue(
            RulesRegistry.declarations.contains {
                $0.agentID == "gemini-cli" && $0.globalPath == "~/.gemini/GEMINI.md"
            }
        )
        XCTAssertTrue(
            RulesRegistry.projectDeclarations.contains {
                $0.agentID == "gemini-cli" && $0.projectPath == "GEMINI.md"
            }
        )
    }

    func testQoderRulesDirectoryAndAmpAgentFileAreDeclared() {
        let qoder = RulesRegistry.declarations.first {
            $0.agentID == "qoder" && $0.projectDirectory != nil
        }
        XCTAssertEqual(qoder?.projectDirectory, ".qoder/rules")
        XCTAssertEqual(qoder?.directoryExtensions, ["md"])

        // Amp's own project-root instructions file (AGENTS.md is already
        // covered by the industry-wide declaration).
        XCTAssertEqual(
            RulesRegistry.declarations.first { $0.agentID == "amp" }?.projectPath,
            "AGENT.md"
        )
    }

    func testRooAndKiloModeRulesPatternsAreDeclared() {
        // Mode-specific rules live in `rules-{mode}` sibling directories;
        // the pattern only wildcards the last path segment.
        XCTAssertTrue(RulesRegistry.declarations.contains {
            $0.agentID == "roo-code"
                && $0.globalDirectory == "~/.roo/rules-*"
                && $0.projectDirectory == ".roo/rules-*"
                && $0.directoryExtensions == ["md"]
        })
        XCTAssertTrue(
            RulesRegistry.projectDeclarations.contains {
                $0.agentID == "kilo-code" && $0.projectDirectory == ".kilocode/rules-*"
            }
        )
    }

    func testWellKnownRulesFilesAreDeclared() {
        let projectPaths = Set(RulesRegistry.projectDeclarations.compactMap(\.projectPath))
        for wellKnown in ["CLAUDE.md", "AGENTS.md", "GEMINI.md", ".cursorrules", ".clinerules", ".roorules", ".windsurfrules"] {
            XCTAssertTrue(
                projectPaths.contains(wellKnown),
                "\(wellKnown) should be a declared project rules file"
            )
        }
    }
}
