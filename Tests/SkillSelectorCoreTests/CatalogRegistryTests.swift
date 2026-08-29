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
        // The declarative default set: the official Anthropic skills repo
        // and the community Superpowers collection.
        XCTAssertEqual(
            CatalogRegistry.sources.map(\.id),
            ["anthropics/skills", "obra/superpowers"]
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
}
