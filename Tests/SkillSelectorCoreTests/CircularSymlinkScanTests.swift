import Foundation
import XCTest
@testable import SkillSelectorCore

/// Circular symbolic links inside an authorized root (spec §1.11): a
/// self-referential link, a mutual two-link cycle, and a link pointing
/// back at an ancestor directory must never hang the scan. The walker
/// treats symlinked directories as leaves, and a candidate whose resolved
/// target equals the link itself is rejected outright — these tests pin
/// that termination contract so a future "follow symlinks while walking"
/// change cannot reintroduce an infinite loop unnoticed.
final class CircularSymlinkScanTests: XCTestCase {
    private var fixture: URL!

    override func setUpWithError() throws {
        fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("CircularSymlinkScanTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: fixture)
    }

    private var projectRoot: ScanRoot {
        .project(id: "project", url: fixture, registry: BuiltInAgentRegistry.make())
    }

    private func makePackage(at relativePath: String) throws -> URL {
        let directory = fixture.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func writeSkill(at relativePath: String, name: String) throws {
        let directory = try makePackage(at: relativePath)
        try "---\nname: \(name)\ndescription: demo\n---\n# \(name)\n".write(
            to: directory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
    }

    /// `loop -> loop` resolves to its own path, so the scanner's
    /// `target != installation` guard rejects it; the healthy sibling
    /// keeps scanning normally and the root stays available.
    func testSelfReferentialSkillDirectoryIsSkippedWithoutHanging() async throws {
        try writeSkill(at: ".cursor/skills/real", name: "real")
        let loop = fixture.appendingPathComponent(".cursor/skills/loop")
        try FileManager.default.createSymbolicLink(at: loop, withDestinationURL: loop)

        let report = await SkillScanner().scan([projectRoot])

        XCTAssertEqual(report.installations.map(\.document.name), ["real"])
        XCTAssertEqual(report.roots.first?.availability, .available)
    }

    /// `alpha -> beta`, `beta -> alpha`: both resolve back to themselves,
    /// so neither becomes an installation while the real Skill is found.
    func testMutualSymlinkCycleIsSkippedWithoutHanging() async throws {
        try writeSkill(at: ".cursor/skills/real", name: "real")
        let alpha = fixture.appendingPathComponent(".cursor/skills/alpha")
        let beta = fixture.appendingPathComponent(".cursor/skills/beta")
        try FileManager.default.createSymbolicLink(at: alpha, withDestinationURL: beta)
        try FileManager.default.createSymbolicLink(at: beta, withDestinationURL: alpha)

        let report = await SkillScanner().scan([projectRoot])

        XCTAssertEqual(report.installations.map(\.document.name), ["real"])
        XCTAssertEqual(report.roots.first?.availability, .available)
    }

    /// `skills/backlink -> skills` points at an ancestor directory. The
    /// walker never recurses into symlinked directories, so the scan
    /// terminates with exactly one bounded installation that reads the
    /// ancestor's entry file through the link path.
    func testSymlinkPointingBackAtAncestorDirectoryTerminatesWithOneInstallation() async throws {
        let skills = try makePackage(at: ".cursor/skills")
        try "---\nname: top\ndescription: container entry\n---\n# top\n".write(
            to: skills.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        let backlink = skills.appendingPathComponent("backlink")
        try FileManager.default.createSymbolicLink(at: backlink, withDestinationURL: skills)

        let report = await SkillScanner().scan([projectRoot])

        XCTAssertEqual(report.installations.count, 1)
        let installation = try XCTUnwrap(report.installations.first)
        XCTAssertEqual(installation.path.path, backlink.standardizedFileURL.path)
        XCTAssertEqual(installation.resolvedTarget?.path, skills.standardizedFileURL.path)
        XCTAssertEqual(installation.document.name, "top")
        XCTAssertEqual(report.roots.first?.availability, .available)
    }

    /// An entry file that links to itself (or to a sibling that links
    /// back) cannot be resolved to a regular file, so the package
    /// surfaces an `.unsafeEntryFile` diagnostic instead of hanging the
    /// read.
    func testCircularEntrySymlinksSurfaceUnsafeDiagnosticsInsteadOfHanging() async throws {
        let selfLoop = try makePackage(at: ".cursor/skills/self-entry-loop")
        let entry = selfLoop.appendingPathComponent("SKILL.md")
        try FileManager.default.createSymbolicLink(at: entry, withDestinationURL: entry)

        let mutual = try makePackage(at: ".cursor/skills/mutual-entry-loop")
        let first = mutual.appendingPathComponent("SKILL.md")
        let second = mutual.appendingPathComponent("OTHER.md")
        try FileManager.default.createSymbolicLink(at: first, withDestinationURL: second)
        try FileManager.default.createSymbolicLink(at: second, withDestinationURL: first)

        let report = await SkillScanner().scan([projectRoot])

        XCTAssertEqual(report.installations.count, 2)
        XCTAssertEqual(
            Set(report.installations.map { $0.path.lastPathComponent }),
            ["self-entry-loop", "mutual-entry-loop"]
        )
        for installation in report.installations {
            XCTAssertEqual(
                installation.document.issues.first?.diagnostic?.code,
                .unsafeEntryFile,
                "circular entry symlinks must surface the unsafe-entry diagnostic"
            )
        }
    }
}
