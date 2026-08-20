import Foundation
import XCTest
@testable import SkillSelectorCore

final class PatternDryRunTests: XCTestCase {
    private var fixture: DryRunFixture!

    override func setUpWithError() throws {
        fixture = try DryRunFixture()
    }

    override func tearDown() {
        fixture = nil
    }

    // MARK: - Matching

    func testMatchesContainerAndCountsSkills() throws {
        try fixture.writeSkill(at: "app-a/.goose/skills/pdf-tools")
        try fixture.writeSkill(at: "app-a/.goose/skills/web-scraper")
        try fixture.writeDirectory(at: "app-a/docs")

        let report = PatternDryRunner().run(
            patterns: [".goose/skills"],
            roots: [fixture.root],
            entryFilename: "SKILL.md"
        )

        XCTAssertEqual(report.matches.count, 1)
        XCTAssertTrue(
            report.matches[0].url.path.hasSuffix("/app-a/.goose/skills"),
            "\(report.matches[0].url.path) should end with /app-a/.goose/skills"
        )
        XCTAssertEqual(report.matches[0].patterns, [".goose/skills"])
        XCTAssertEqual(report.matches[0].skillNames, ["pdf-tools", "web-scraper"])
        XCTAssertTrue(report.skippedRootPaths.isEmpty)
    }

    func testTemplatePatternBindsValues() throws {
        try fixture.writeSkill(at: "app-a/.agents/skills-lint/lint")
        try fixture.writeSkill(at: "app-b/.agents/skills-pdf/pdf")

        let report = PatternDryRunner().run(
            patterns: [".agents/skills-{modeSlug}"],
            roots: [fixture.root],
            entryFilename: "SKILL.md"
        )

        XCTAssertEqual(report.matches.count, 2)
        XCTAssertEqual(
            report.matches[0].bindings["modeSlug"],
            "lint",
            "\(report.matches[0].url.path) should bind modeSlug = lint"
        )
        XCTAssertEqual(
            report.matches[1].bindings["modeSlug"],
            "pdf",
            "\(report.matches[1].url.path) should bind modeSlug = pdf"
        )
    }

    func testTypoPatternMatchesNothing() throws {
        try fixture.writeSkill(at: "app-a/.goose/skills/pdf-tools")

        let report = PatternDryRunner().run(
            patterns: [".myagent/skill"],
            roots: [fixture.root],
            entryFilename: "SKILL.md"
        )

        XCTAssertTrue(report.isEmpty)
        XCTAssertTrue(report.skippedRootPaths.isEmpty)
    }

    func testMultiplePatternsMatchingSameDirectoryAreMerged() throws {
        try fixture.writeSkill(at: "app-a/.goose/skills/pdf-tools")

        let report = PatternDryRunner().run(
            patterns: ["skills", ".goose/skills"],
            roots: [fixture.root],
            entryFilename: "SKILL.md"
        )

        XCTAssertEqual(report.matches.count, 1)
        XCTAssertEqual(report.matches[0].patterns, ["skills", ".goose/skills"])
    }

    func testEntryFilenameVariantCountsOnlyMatchingChildren() throws {
        try fixture.writeSkill(at: "app-a/.myagent/skills/with-agent", entryFilename: "AGENT.md")
        try fixture.writeSkill(at: "app-a/.myagent/skills/with-skill", entryFilename: "SKILL.md")

        let report = PatternDryRunner().run(
            patterns: [".myagent/skills"],
            roots: [fixture.root],
            entryFilename: "AGENT.md"
        )

        XCTAssertEqual(report.matches[0].skillNames, ["with-agent"])
    }

    // MARK: - Walk fidelity

    func testSkipsHeavyDirectoriesLikeTheScanner() throws {
        try fixture.writeSkill(at: "app-a/node_modules/pkg/.goose/skills/ignored")
        try fixture.writeSkill(at: "app-a/.goose/skills/real")

        let report = PatternDryRunner().run(
            patterns: [".goose/skills"],
            roots: [fixture.root],
            entryFilename: "SKILL.md"
        )

        XCTAssertEqual(report.matches.map(\.skillNames), [["real"]])
    }

    func testDoesNotDescendIntoRecognizedInstallations() throws {
        // The scanner stops at a recognized installation, so a second
        // container nested inside it stays undiscovered.
        try fixture.writeSkill(at: ".goose/skills/outer")
        try fixture.writeSkill(at: ".goose/skills/outer/examples/.goose/skills/inner")

        let report = PatternDryRunner().run(
            patterns: [".goose/skills"],
            roots: [fixture.root],
            entryFilename: "SKILL.md"
        )

        XCTAssertEqual(report.matches.count, 1)
        XCTAssertTrue(
            report.matches[0].url.path.hasSuffix("/.goose/skills"),
            "\(report.matches[0].url.path) should end with /.goose/skills"
        )
    }

    func testDescendsIntoChildWithoutEntryFile() throws {
        // A child without the entry file is not an installation; the walk
        // continues and may find a deeper container.
        try fixture.createDirectory(at: ".myagent/skills/empty")
        try fixture.writeSkill(at: ".myagent/skills/empty/.myagent/skills/deep")

        let report = PatternDryRunner().run(
            patterns: [".myagent/skills"],
            roots: [fixture.root],
            entryFilename: "SKILL.md"
        )

        let paths = report.matches.map(\.url.path).sorted()
        XCTAssertEqual(paths.count, 2)
        XCTAssertTrue(paths[0].hasSuffix("/.myagent/skills"), "\(paths[0])")
        XCTAssertTrue(paths[1].hasSuffix("/.myagent/skills/empty/.myagent/skills"), "\(paths[1])")
    }

    // MARK: - Input handling

    func testEmptyAndWhitespacePatternsYieldEmptyReport() throws {
        try fixture.writeSkill(at: ".goose/skills/pdf-tools")

        let report = PatternDryRunner().run(
            patterns: ["  ", "", "\t"],
            roots: [fixture.root],
            entryFilename: "SKILL.md"
        )

        XCTAssertTrue(report.isEmpty)
    }

    func testDuplicatePatternsAreDeduplicated() throws {
        try fixture.writeSkill(at: ".goose/skills/pdf-tools")

        let report = PatternDryRunner().run(
            patterns: [".goose/skills", ".goose/skills", " .goose/skills "],
            roots: [fixture.root],
            entryFilename: "SKILL.md"
        )

        XCTAssertEqual(report.matches.count, 1)
        XCTAssertEqual(report.matches[0].patterns, [".goose/skills"])
    }

    func testMissingRootIsReportedSkipped() throws {
        let missingRoot = AuthorizedRootSnapshot(
            id: "missing",
            url: FileManager.default.temporaryDirectory
                .appending(path: "PatternDryRunTests-missing-\(UUID().uuidString)"),
            kind: .project
        )

        let report = PatternDryRunner().run(
            patterns: [".goose/skills"],
            roots: [missingRoot],
            entryFilename: "SKILL.md"
        )

        XCTAssertTrue(report.isEmpty)
        XCTAssertEqual(report.skippedRootPaths, [missingRoot.url.path])
    }
}

private final class DryRunFixture: @unchecked Sendable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "PatternDryRunTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    var root: AuthorizedRootSnapshot {
        AuthorizedRootSnapshot(id: "project", url: url, kind: .project)
    }

    func writeSkill(at relativePath: String, entryFilename: String = "SKILL.md") throws {
        try createDirectory(at: relativePath)
        try "---\nname: \(URL(fileURLWithPath: relativePath).lastPathComponent)\n---\n".write(
            to: url.appending(path: relativePath).appending(path: entryFilename),
            atomically: true,
            encoding: .utf8
        )
    }

    func writeDirectory(at relativePath: String) throws {
        try createDirectory(at: relativePath)
    }

    func createDirectory(at relativePath: String) throws {
        try FileManager.default.createDirectory(
            at: url.appending(path: relativePath),
            withIntermediateDirectories: true
        )
    }
}
