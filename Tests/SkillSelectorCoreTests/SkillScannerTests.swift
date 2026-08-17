import Foundation
import XCTest
@testable import SkillSelectorCore

final class SkillScannerTests: XCTestCase {
    func testProjectTraversalUsesFolderOwnerAndLeavesSharedPatternsOwnerless() async throws {
        let fixture = try ScanFixture()
        try fixture.writeSkill(at: ".codex/skills/codex-only", name: "codex-only")
        try fixture.writeSkill(at: ".claude/skills/claude-only", name: "claude-only")
        try fixture.writeSkill(at: ".agents/skills/shared", name: "shared")
        try fixture.writeSkill(at: ".agents/skills-code/shared-mode", name: "shared-mode")

        let report = await SkillScanner().scan([fixture.projectRoot])
        let skills = Dictionary(uniqueKeysWithValues: report.installations.map {
            ($0.document.name ?? "", $0)
        })

        XCTAssertEqual(skills["codex-only"]?.agentIDs, ["codex"])
        XCTAssertEqual(skills["claude-only"]?.agentIDs, ["claude-code"])
        XCTAssertEqual(skills["shared"]?.agentIDs, [])
        XCTAssertEqual(skills["shared-mode"]?.agentIDs, [])
    }

    func testProjectTraversalFindsNestedPatternsAndSkipsHeavyDirectories() async throws {
        let fixture = try ScanFixture()
        try fixture.writeSkill(at: "packages/app/.cursor/skills/real", name: "real")

        let skippedDirectories = [
            ".git", "node_modules", ".build", "build", "dist", "DerivedData",
            ".swiftpm", "Pods", "vendor", ".cache", "Carthage",
        ]
        for directory in skippedDirectories {
            try fixture.writeSkill(
                at: "\(directory)/pkg/.cursor/skills/ignored-\(directory.replacingOccurrences(of: ".", with: "dot"))",
                name: "ignored"
            )
        }

        let report = await SkillScanner().scan([fixture.projectRoot])

        XCTAssertEqual(report.installations.map(\.path.lastPathComponent), ["real"])
        XCTAssertEqual(report.installations[0].agentIDs, ["cursor"])
    }

    func testTraversalStopsAfterRecognizingSkillPackage() async throws {
        let fixture = try ScanFixture()
        try fixture.writeSkill(at: ".cursor/skills/outer", name: "outer")
        try fixture.writeSkill(
            at: ".cursor/skills/outer/examples/.cursor/skills/inner",
            name: "inner"
        )

        let report = await SkillScanner().scan([fixture.projectRoot])

        XCTAssertEqual(report.installations.map(\.document.name), ["outer"])
    }

    func testTraversalStopsAtPackageWithUnauthorizedEntrySymlink() async throws {
        let fixture = try ScanFixture()
        let externalEntry = fixture.url.deletingLastPathComponent()
            .appending(path: "external-entry-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: externalEntry) }
        try "---\nname: external\ndescription: External\n---\n".write(
            to: externalEntry,
            atomically: true,
            encoding: .utf8
        )

        let outer = fixture.url.appending(path: ".cursor/skills/outer")
        try FileManager.default.createDirectory(at: outer, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: outer.appending(path: "SKILL.md"),
            withDestinationURL: externalEntry
        )
        try fixture.writeSkill(
            at: ".cursor/skills/outer/examples/.cursor/skills/inner",
            name: "inner"
        )

        let report = await SkillScanner().scan([fixture.projectRoot])

        XCTAssertEqual(report.installations.count, 1)
        let scanned = try XCTUnwrap(report.installations.first)
        XCTAssertEqual(scanned.path.path, outer.standardizedFileURL.path)
        XCTAssertTrue(scanned.document.issues.contains {
            $0.message.contains("authorized package")
        })
        XCTAssertEqual(scanned.document.issues.first?.diagnostic?.code, .unsafeEntryFile)
    }

    func testMalformedSkillRemainsVisibleWithParseDiagnostics() async throws {
        let fixture = try ScanFixture()
        try fixture.write(
            "---\nname: [broken\n---\n# Broken",
            at: ".cursor/skills/broken/SKILL.md"
        )

        let report = await SkillScanner().scan([fixture.projectRoot])

        XCTAssertEqual(report.installations.count, 1)
        XCTAssertEqual(report.installations[0].document.title, "Broken")
        XCTAssertFalse(report.installations[0].document.issues.isEmpty)
        XCTAssertEqual(report.roots[0].availability, .available)
    }

    func testSymbolicLinkUsesLinkPathIdentityAndRecordsResolvedTarget() async throws {
        let fixture = try ScanFixture()
        try fixture.writeSkill(at: "targets/demo", name: "demo")
        let link = fixture.url.appending(path: ".cursor/skills/linked")
        try FileManager.default.createDirectory(
            at: link.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: fixture.url.appending(path: "targets/demo")
        )

        let report = await SkillScanner().scan([fixture.projectRoot])

        XCTAssertEqual(report.installations.count, 1)
        XCTAssertEqual(report.installations[0].path.path, link.standardizedFileURL.path)
        XCTAssertEqual(
            report.installations[0].resolvedTarget?.path,
            fixture.url.appending(path: "targets/demo").standardizedFileURL.path
        )
        XCTAssertEqual(report.installations[0].document.name, "demo")
    }

    func testDoesNotFollowSymbolicLinkOutsideAuthorizedRoots() async throws {
        let fixture = try ScanFixture()
        let external = fixture.url.deletingLastPathComponent()
            .appending(path: "external-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: external) }
        try fixture.writeSkill(at: "allowed/.cursor/skills/real", name: "real")
        try ScanFixture.writeSkill(at: external.appending(path: "hidden"), name: "hidden")

        let escapedLink = fixture.url.appending(path: "allowed/.cursor/skills/escaped")
        try FileManager.default.createSymbolicLink(
            at: escapedLink,
            withDestinationURL: external.appending(path: "hidden")
        )
        let authorized = ScanRoot.project(
            id: "allowed",
            url: fixture.url.appending(path: "allowed"),
            registry: BuiltInAgentRegistry.make()
        )

        let report = await SkillScanner().scan([authorized])

        XCTAssertEqual(report.installations.map(\.document.name), ["real"])
    }

    func testFollowsSymbolicLinkAcrossTwoAuthorizedRoots() async throws {
        let fixture = try ScanFixture()
        let project = fixture.url.appending(path: "project")
        let targets = fixture.url.appending(path: "authorized-targets")
        let target = targets.appending(path: "demo")
        try ScanFixture.writeSkill(at: target, name: "demo")
        let link = project.appending(path: ".cursor/skills/linked")
        try FileManager.default.createDirectory(
            at: link.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let report = await SkillScanner().scan([
            .project(id: "project", url: project, registry: BuiltInAgentRegistry.make()),
            .skillDirectory(id: "targets", url: targets, agentIDs: ["custom"]),
        ])
        let linked = try XCTUnwrap(report.installations.first {
            $0.path.standardizedFileURL.path == link.standardizedFileURL.path
        })
        XCTAssertEqual(linked.resolvedTarget?.standardizedFileURL.path, target.standardizedFileURL.path)
        XCTAssertEqual(linked.document.name, "demo")
    }

    func testRejectsTraversingCustomEntryFilenameAndReportsRootIssue() async throws {
        let fixture = try ScanFixture()
        let authorizedRoot = fixture.url.appending(path: "allowed")
        let package = authorizedRoot.appending(path: ".custom/skills/demo")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let outside = fixture.url.appending(path: "outside.md")
        try "---\nname: outside\ndescription: Must not be read\n---\n".write(
            to: outside,
            atomically: true,
            encoding: .utf8
        )
        let malicious = AgentDefinition(
            id: "custom",
            displayName: "Custom",
            globalRoots: [],
            projectPatterns: [".custom/skills"],
            entryFilename: "../../../../outside.md"
        )
        let root = ScanRoot.project(
            id: "allowed",
            url: authorizedRoot,
            registry: AgentRegistry(definitions: [malicious])
        )

        let report = await SkillScanner().scan([root])

        XCTAssertTrue(report.installations.isEmpty)
        XCTAssertEqual(report.roots[0].availability, .available)
        XCTAssertTrue(report.roots[0].issues.contains {
            $0.message.contains("entryFilename")
        })
    }

    func testRejectsEveryEntryFilenameThatIsNotOneComponent() async throws {
        let fixture = try ScanFixture()
        let invalidEntryFilenames = ["", ".", "..", "nested/SKILL.md", "nested\\SKILL.md"]
        let roots = invalidEntryFilenames.enumerated().map { index, entryFilename in
            ScanRoot.skillDirectory(
                id: "invalid-\(index)",
                url: fixture.url,
                agentIDs: ["custom"],
                entryFilename: entryFilename
            )
        }

        let report = await SkillScanner().scan(roots)

        XCTAssertTrue(report.installations.isEmpty)
        XCTAssertEqual(report.roots.count, invalidEntryFilenames.count)
        XCTAssertTrue(report.roots.allSatisfy { root in
            root.issues.contains { $0.message.contains("entryFilename") }
        })
    }

    func testDirectPackageWithUnauthorizedEntryStopsBeforeNestedSkill() async throws {
        let fixture = try ScanFixture()
        let directPackage = fixture.url.appending(path: "direct-package")
        try FileManager.default.createDirectory(at: directPackage, withIntermediateDirectories: true)
        let externalEntry = fixture.url.deletingLastPathComponent()
            .appending(path: "direct-external-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: externalEntry) }
        try "---\nname: external\ndescription: External\n---\n".write(
            to: externalEntry,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(
            at: directPackage.appending(path: "SKILL.md"),
            withDestinationURL: externalEntry
        )
        try ScanFixture.writeSkill(
            at: directPackage.appending(path: "nested"),
            name: "nested",
            description: "Nested"
        )
        let root = ScanRoot.skillDirectory(
            id: "direct",
            url: directPackage,
            agentIDs: ["custom"]
        )

        let report = await SkillScanner().scan([root])

        XCTAssertEqual(report.installations.count, 1)
        let scanned = try XCTUnwrap(report.installations.first)
        XCTAssertEqual(scanned.path.path, directPackage.standardizedFileURL.path)
        XCTAssertTrue(scanned.document.issues.contains {
            $0.message.contains("authorized package")
        })
    }

    func testUnavailableRootIsReportedSeparatelyFromInstallations() async throws {
        let fixture = try ScanFixture()
        let missing = ScanRoot.project(
            id: "missing",
            url: fixture.url.appending(path: "missing"),
            registry: BuiltInAgentRegistry.make()
        )

        let report = await SkillScanner().scan([missing])

        XCTAssertTrue(report.installations.isEmpty)
        XCTAssertEqual(report.roots.count, 1)
        guard case .unavailable(let reason) = report.roots[0].availability else {
            return XCTFail("Expected an unavailable root")
        }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertEqual(report.roots[0].unavailableDiagnostic?.code, .rootUnreadable)
    }
    func testScannedSkillsCarryAContentFingerprintStableAcrossCopies() async throws {
        let fixture = try ScanFixture()
        try fixture.writeSkill(at: ".codex/skills/demo", name: "demo")
        try fixture.writeSkill(at: ".claude/skills/demo-copy", name: "demo-copy")
        // Identical trees under different names and paths.
        let source = fixture.url.appending(path: ".codex/skills/demo/SKILL.md")
        try String(contentsOf: source, encoding: .utf8).write(
            to: fixture.url.appending(path: ".claude/skills/demo-copy/SKILL.md"),
            atomically: true,
            encoding: .utf8
        )

        let report = await SkillScanner().scan([fixture.projectRoot])
        let fingerprints = report.installations.compactMap(\.contentFingerprint)

        XCTAssertEqual(fingerprints.count, report.installations.count)
        XCTAssertEqual(Set(fingerprints).count, 1)
    }
}

private final class ScanFixture: @unchecked Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "SkillScannerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    var projectRoot: ScanRoot {
        .project(id: "project", url: url, registry: BuiltInAgentRegistry.make())
    }

    func rootsForSharedAgents(_ agentIDs: [String]) -> [ScanRoot] {
        agentIDs.map { agentID in
            .skillDirectory(
                id: agentID,
                url: url.appending(path: ".agents/skills"),
                agentIDs: [agentID]
            )
        }
    }

    func writeSkill(at relativePath: String, name: String, description: String? = nil) throws {
        try Self.writeSkill(
            at: url.appending(path: relativePath),
            name: name,
            description: description
        )
    }

    static func writeSkill(at directory: URL, name: String, description: String? = nil) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var document = "---\nname: \(name)\n"
        if let description {
            document += "description: \(description)\n"
        }
        document += "---\n# \(name)\n"
        try document.write(
            to: directory.appending(path: "SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
    }

    func write(_ contents: String, at relativePath: String) throws {
        let destination = url.appending(path: relativePath)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: destination, atomically: true, encoding: .utf8)
    }
}
