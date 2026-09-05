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
            // Expansion set: virtualenvs, build output, and IDE state.
            ".venv", "__pycache__", "target", ".gradle", ".next", ".idea",
            ".terraform", ".dart_tool",
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
            .appendingPathComponent("external-entry-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: externalEntry) }
        try "---\nname: external\ndescription: External\n---\n".write(
            to: externalEntry,
            atomically: true,
            encoding: .utf8
        )

        let outer = fixture.url.appendingPathComponent(".cursor/skills/outer")
        try FileManager.default.createDirectory(at: outer, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: outer.appendingPathComponent("SKILL.md"),
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
        let link = fixture.url.appendingPathComponent(".cursor/skills/linked")
        try FileManager.default.createDirectory(
            at: link.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: fixture.url.appendingPathComponent("targets/demo")
        )

        let report = await SkillScanner().scan([fixture.projectRoot])

        XCTAssertEqual(report.installations.count, 1)
        XCTAssertEqual(report.installations[0].path.path, link.standardizedFileURL.path)
        XCTAssertEqual(
            report.installations[0].resolvedTarget?.path,
            fixture.url.appendingPathComponent("targets/demo").standardizedFileURL.path
        )
        XCTAssertEqual(report.installations[0].document.name, "demo")
    }

    func testDoesNotFollowSymbolicLinkOutsideAuthorizedRoots() async throws {
        let fixture = try ScanFixture()
        let external = fixture.url.deletingLastPathComponent()
            .appendingPathComponent("external-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: external) }
        try fixture.writeSkill(at: "allowed/.cursor/skills/real", name: "real")
        try ScanFixture.writeSkill(at: external.appendingPathComponent("hidden"), name: "hidden")

        let escapedLink = fixture.url.appendingPathComponent("allowed/.cursor/skills/escaped")
        try FileManager.default.createSymbolicLink(
            at: escapedLink,
            withDestinationURL: external.appendingPathComponent("hidden")
        )
        let authorized = ScanRoot.project(
            id: "allowed",
            url: fixture.url.appendingPathComponent("allowed"),
            registry: BuiltInAgentRegistry.make()
        )

        let report = await SkillScanner().scan([authorized])

        XCTAssertEqual(report.installations.map(\.document.name), ["real"])
    }

    func testFollowsSymbolicLinkAcrossTwoAuthorizedRoots() async throws {
        let fixture = try ScanFixture()
        let project = fixture.url.appendingPathComponent("project")
        let targets = fixture.url.appendingPathComponent("authorized-targets")
        let target = targets.appendingPathComponent("demo")
        try ScanFixture.writeSkill(at: target, name: "demo")
        let link = project.appendingPathComponent(".cursor/skills/linked")
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
        let authorizedRoot = fixture.url.appendingPathComponent("allowed")
        let package = authorizedRoot.appendingPathComponent(".custom/skills/demo")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let outside = fixture.url.appendingPathComponent("outside.md")
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
        let directPackage = fixture.url.appendingPathComponent("direct-package")
        try FileManager.default.createDirectory(at: directPackage, withIntermediateDirectories: true)
        let externalEntry = fixture.url.deletingLastPathComponent()
            .appendingPathComponent("direct-external-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: externalEntry) }
        try "---\nname: external\ndescription: External\n---\n".write(
            to: externalEntry,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(
            at: directPackage.appendingPathComponent("SKILL.md"),
            withDestinationURL: externalEntry
        )
        try ScanFixture.writeSkill(
            at: directPackage.appendingPathComponent("nested"),
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
            url: fixture.url.appendingPathComponent("missing"),
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
        let source = fixture.url.appendingPathComponent(".codex/skills/demo/SKILL.md")
        try String(contentsOf: source, encoding: .utf8).write(
            to: fixture.url.appendingPathComponent(".claude/skills/demo-copy/SKILL.md"),
            atomically: true,
            encoding: .utf8
        )

        let report = await SkillScanner().scan([fixture.projectRoot])
        let fingerprints = report.installations.compactMap(\.contentFingerprint)

        XCTAssertEqual(fingerprints.count, report.installations.count)
        XCTAssertEqual(Set(fingerprints).count, 1)
    }

    func testOversizedEntryFileReportsDiagnosticInsteadOfSaturatingMemory() async throws {
        // Audit R3/F-01: the scanner must not slurp a multi-MB SKILL.md into
        // memory; the entry is capped at the render path's limit and the
        // skill surfaces an .unableToReadEntry diagnostic instead.
        let fixture = try ScanFixture()
        let oversized = fixture.url.appendingPathComponent(".codex/skills/huge")
        try FileManager.default.createDirectory(at: oversized, withIntermediateDirectories: true)
        let padding = String(repeating: "x", count: SkillDocumentReader.maximumRenderBytes + 1)
        try "---\nname: huge\ndescription: Big\n---\n# Huge\n".appending(padding).write(
            to: oversized.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )

        let report = await SkillScanner().scan([fixture.projectRoot])
        let scanned = try XCTUnwrap(report.installations.first)

        // The diagnostic document has no name (nothing was parsed); its
        // title falls back to the directory name and the issue reports the
        // size cap.
        XCTAssertEqual(scanned.document.title, "huge")
        XCTAssertTrue(scanned.document.issues.contains { issue in
            issue.message.contains("read limit")
        })
    }

    func testBoundarySizedEntryFileStillParses() async throws {
        // The cap is inclusive of the render limit; a file exactly at it
        // must still parse.
        let fixture = try ScanFixture()
        let boundary = fixture.url.appendingPathComponent(".codex/skills/boundary")
        try FileManager.default.createDirectory(at: boundary, withIntermediateDirectories: true)
        let body = String(repeating: "x", count: SkillDocumentReader.maximumRenderBytes - 64)
        try "---\nname: boundary\ndescription: Edge\n---\n# Boundary\n".appending(body).write(
            to: boundary.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )

        let report = await SkillScanner().scan([fixture.projectRoot])
        let scanned = try XCTUnwrap(report.installations.first)

        XCTAssertEqual(scanned.document.name, "boundary")
        XCTAssertFalse(scanned.document.issues.contains { $0.message.contains("read limit") })
    }

    /// A pathological nesting deeper than the walk bound must terminate
    /// with a bounded result instead of overflowing the stack; skills
    /// within the bound still scan normally.
    func testProjectWalkTerminatesOnPathologicalDepth() async throws {
        let fixture = try ScanFixture()
        try fixture.writeSkill(at: ".cursor/skills/shallow", name: "shallow")

        // A chain of empty directories far beyond the walk bound (no skills
        // inside — the recursion must simply stop descending). Single-char
        // names keep the full path under PATH_MAX.
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz")
        var deep = fixture.url
        for index in 0...(SkillScanner.maximumProjectWalkDepth + 50) {
            deep = deep.appendingPathComponent(String(alphabet[index % alphabet.count]))
        }
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)

        let report = await SkillScanner().scan([fixture.projectRoot])

        XCTAssertEqual(report.installations.map(\.document.name), ["shallow"])
        XCTAssertEqual(report.roots.first?.availability, .available)
    }
}

private final class ScanFixture: @unchecked Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillScannerTests-\(UUID().uuidString)", isDirectory: true)
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
                url: url.appendingPathComponent(".agents/skills"),
                agentIDs: [agentID]
            )
        }
    }

    func writeSkill(at relativePath: String, name: String, description: String? = nil) throws {
        try Self.writeSkill(
            at: url.appendingPathComponent(relativePath),
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
            to: directory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
    }

    func write(_ contents: String, at relativePath: String) throws {
        let destination = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: destination, atomically: true, encoding: .utf8)
    }
}
