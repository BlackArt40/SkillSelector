import Foundation
import XCTest
@testable import SkillSelectorCore

final class SkillScannerTests: XCTestCase {
    func testSharedRootProducesOneInstallationWithManyAgents() async throws {
        let fixture = try ScanFixture()
        try fixture.writeSkill(at: ".agents/skills/demo", name: "demo", description: "Demo")

        let report = await SkillScanner().scan(
            fixture.rootsForSharedAgents(["cursor", "gemini-cli"])
        )

        XCTAssertEqual(report.installations.count, 1)
        XCTAssertEqual(report.installations[0].agentIDs, ["cursor", "gemini-cli"])
        XCTAssertEqual(report.installations[0].document.name, "demo")
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

        XCTAssertTrue(report.installations.isEmpty)
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
