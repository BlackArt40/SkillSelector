import Foundation
import XCTest
@testable import SkillSelectorCore

final class CatalogRegistryTests: XCTestCase {
    func testSourcesAreDeclaredAndWellFormed() {
        XCTAssertFalse(CatalogRegistry.sources.isEmpty, "the catalog ships with at least one source")
        var seen = Set<String>()
        for source in CatalogRegistry.sources {
            XCTAssertTrue(seen.insert(source.id).inserted, "source ids must be unique: \(source.id)")
            XCTAssertEqual(source.id, "\(source.owner)/\(source.repo)")
            XCTAssertFalse(source.displayName.isEmpty)
            for component in [source.owner, source.repo, source.branch] {
                XCTAssertFalse(component.isEmpty)
                XCTAssertEqual(component, component.trimmingCharacters(in: .whitespaces))
                XCTAssertFalse(component.contains(" "), "GitHub path components must not contain spaces")
                XCTAssertFalse(component.hasPrefix("."), "source components must not be hidden paths")
            }
        }
    }

    func testKnownSourcesShipByDefault() {
        // The declarative default set: official Anthropic repos, the
        // community Superpowers collection, and the popular community
        // skill libraries (each verified to ship SKILL.md files at
        // declaration time).
        XCTAssertEqual(
            CatalogRegistry.sources.map(\.id),
            [
                "anthropics/skills",
                "anthropics/claude-plugins-official",
                "obra/superpowers",
                "vercel-labs/agent-skills",
                "alirezarezvani/claude-skills",
                "wshobson/agents",
                "mattpocock/skills",
            ]
        )
    }

    func testInstallCommandUsesVerifiedSkillsCLISyntax() {
        let skill = CatalogSkill(
            id: "anthropics/skills:skills/pdf/SKILL.md",
            sourceID: "anthropics/skills",
            name: "pdf",
            skillPath: "skills/pdf/SKILL.md",
            githubURL: URL(string: "https://github.com/anthropics/skills/tree/main/skills/pdf")!,
            rawURL: URL(string: "https://raw.githubusercontent.com/anthropics/skills/main/skills/pdf/SKILL.md")!
        )
        // vercel-labs/skills CLI: `npx skills add <owner/repo> --skill <name>`.
        XCTAssertEqual(skill.installCommand, "npx skills add anthropics/skills --skill pdf")
    }

    // MARK: Imported sources

    func testParsingAcceptsRepoURLOrBranchForms() {
        XCTAssertEqual(CustomCatalogSource.parsing("vercel-labs/agent-skills")?.owner, "vercel-labs")
        XCTAssertEqual(CustomCatalogSource.parsing("  vercel-labs/agent-skills ")?.repo, "agent-skills")
        XCTAssertEqual(CustomCatalogSource.parsing("https://github.com/vercel-labs/agent-skills")?.branch, "main")
        XCTAssertEqual(
            CustomCatalogSource.parsing("https://github.com/vercel-labs/agent-skills/tree/main")?.owner,
            "vercel-labs",
            "longer URL paths collapse to owner/repo"
        )
        XCTAssertEqual(CustomCatalogSource.parsing("github.com/o/r@dev")?.branch, "dev")
        XCTAssertEqual(CustomCatalogSource.parsing("o/r@dev")?.branch, "dev")

        XCTAssertNil(CustomCatalogSource.parsing(""))
        XCTAssertNil(CustomCatalogSource.parsing("just-a-name"))
        XCTAssertNil(CustomCatalogSource.parsing("a/b/c"))
        XCTAssertNil(CustomCatalogSource.parsing("a /b"))
        XCTAssertNil(CustomCatalogSource.parsing("a/b@"))
    }

    func testCustomSourceCarriesCustomFlagAndRepoName() {
        let source = CustomCatalogSource(owner: "me", repo: "my-skills", branch: "dev").source
        XCTAssertEqual(source.id, "me/my-skills")
        XCTAssertEqual(source.displayName, "my-skills")
        XCTAssertEqual(source.branch, "dev")
        XCTAssertEqual(source.isCustom, true)
        XCTAssertEqual(CatalogRegistry.sources.first?.isCustom, false, "built-ins are not custom")
    }

    func testSourceStoreRoundtripAndMalformedTolerance() throws {
        let suite = "CatalogSourceStore-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsCatalogSourceStore(defaults: defaults)

        XCTAssertTrue(store.loadCustomSources().isEmpty)
        store.saveCustomSources([CustomCatalogSource(owner: "me", repo: "my-skills", branch: "dev")])
        XCTAssertEqual(store.loadCustomSources(), [CustomCatalogSource(owner: "me", repo: "my-skills", branch: "dev")])

        // Corrupt payloads degrade to an empty list instead of crashing.
        defaults.set(Data("not json".utf8), forKey: "SkillSelector.customCatalogSources")
        XCTAssertEqual(store.loadCustomSources().isEmpty, true)
    }
}
