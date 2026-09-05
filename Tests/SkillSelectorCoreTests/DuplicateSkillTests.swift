import Foundation
import XCTest
@testable import SkillSelectorCore

final class SkillContentFingerprintTests: XCTestCase {
    private var workspace: URL!

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillContentFingerprintTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: workspace)
    }

    private func makeSkill(name: String, skillMDContent: String? = nil, extra: String? = nil) throws -> URL {
        let directory = workspace.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let document = skillMDContent ?? "---\nname: \(name)\ndescription: demo\n---\n# \(name)\nbody\n"
        try document.write(
            to: directory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        if let extra {
            let subdirectory = directory.appendingPathComponent("scripts", isDirectory: true)
            try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
            try extra.write(
                to: subdirectory.appendingPathComponent("run.sh"),
                atomically: true,
                encoding: .utf8
            )
        }
        return directory
    }

    private func fingerprint(of directory: URL) throws -> String {
        try SkillContentFingerprint.compute(
            entryFileURL: directory.appendingPathComponent("SKILL.md")
        )
    }

    // AC-1: identical entry bodies in different paths group together.
    func testIdenticalContentInDifferentDirectoriesSharesAFingerprint() throws {
        let content = "---\nname: demo\ndescription: same everywhere\n---\n# demo\nshared body\n"
        let first = try makeSkill(name: "demo-a", skillMDContent: content, extra: "echo hi\n")
        let second = try makeSkill(name: "demo-b", skillMDContent: content, extra: "echo hi\n")

        XCTAssertEqual(
            try fingerprint(of: first),
            try fingerprint(of: second)
        )
    }

    // AC-2: frontmatter differences (name/description) never participate.
    func testFrontmatterDifferencesDoNotChangeTheFingerprint() throws {
        let first = try makeSkill(
            name: "demo-a",
            skillMDContent: "---\nname: alpha\ndescription: first\n---\n# shared\nbody\n"
        )
        let second = try makeSkill(
            name: "demo-b",
            skillMDContent: "---\nname: beta\ndescription: second\n---\n# shared\nbody\n"
        )

        XCTAssertEqual(
            try fingerprint(of: first),
            try fingerprint(of: second)
        )
    }

    // AC-3: different bodies produce different fingerprints.
    func testDifferentContentProducesDifferentFingerprints() throws {
        let first = try makeSkill(name: "demo-a", skillMDContent: "---\nname: d\n---\nbody one")
        let second = try makeSkill(name: "demo-b", skillMDContent: "---\nname: d\n---\nbody two")

        XCTAssertNotEqual(
            try fingerprint(of: first),
            try fingerprint(of: second)
        )
    }

    // AC-4: sibling files (docs/, templates/, scripts/) never participate.
    func testSubfilesDoNotChangeTheFingerprint() throws {
        let directory = try makeSkill(name: "demo")
        let before = try fingerprint(of: directory)

        try "notes".write(
            to: directory.appendingPathComponent("NOTES.txt"),
            atomically: true,
            encoding: .utf8
        )
        let subdirectory = directory.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
        try "extra documentation".write(
            to: subdirectory.appendingPathComponent("README.md"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertEqual(before, try fingerprint(of: directory))
    }

    func testCopiesKeepByteLevelStabilityAcrossCopyOperations() throws {
        let original = try makeSkill(name: "original", extra: "echo one\necho two\n")
        let copy = workspace.appendingPathComponent("the-copy", isDirectory: true)
        try FileManager.default.copyItem(at: original, to: copy)

        XCTAssertEqual(
            try fingerprint(of: original),
            try fingerprint(of: copy)
        )
    }

    // A skill whose entry is only frontmatter hashes its empty body; two
    // such skills still share a fingerprint (they are byte-identical in
    // the meaningful sense the duplicates view hunts for).
    func testFrontmatterOnlySkillsShareAnEmptyBodyFingerprint() throws {
        let first = try makeSkill(name: "a", skillMDContent: "---\nname: a\n---\n")
        let second = try makeSkill(name: "b", skillMDContent: "---\nname: b\n---\n")

        XCTAssertEqual(
            try fingerprint(of: first),
            try fingerprint(of: second)
        )
    }
}

final class DuplicateSkillGrouperTests: XCTestCase {
    private func snapshot(
        path: String,
        name: String,
        fingerprint: String?,
        ignoredDuplicateGroup: String? = nil
    ) -> SkillSnapshot {
        SkillSnapshot(
            path: path,
            resolvedTarget: nil,
            name: name,
            localDescription: nil,
            modificationDate: nil,
            agentIDs: [],
            rootIDs: [],
            entryFilename: "SKILL.md",
            parseDiagnostics: [],
            contentFingerprint: fingerprint,
            ignoredDuplicateGroup: ignoredDuplicateGroup
        )
    }

    func testGroupsSkillsSharingAFingerprint() {
        let groups = DuplicateSkillGrouper.groups([
            snapshot(path: "/a/demo", name: "demo", fingerprint: "fff"),
            snapshot(path: "/b/demo", name: "demo", fingerprint: "fff"),
            snapshot(path: "/c/other", name: "other", fingerprint: "aaa"),
        ])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].members.map(\.path), ["/a/demo", "/b/demo"])
        XCTAssertEqual(DuplicateSkillGrouper.memberCount(in: groups), 2)
    }

    func testSkillsWithoutFingerprintNeverGroup() {
        let groups = DuplicateSkillGrouper.groups([
            snapshot(path: "/a/demo", name: "demo", fingerprint: nil),
            snapshot(path: "/b/demo", name: "demo", fingerprint: nil),
        ])

        XCTAssertTrue(groups.isEmpty)
    }

    func testUniqueSkillsDoNotAppear() {
        let groups = DuplicateSkillGrouper.groups([
            snapshot(path: "/a/demo", name: "demo", fingerprint: "fff"),
            snapshot(path: "/b/other", name: "other", fingerprint: "aaa"),
            snapshot(path: "/c/third", name: "third", fingerprint: "aaa"),
        ])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(DuplicateSkillGrouper.memberCount(in: groups), 2)
    }

    // AC-6: an ignored member leaves the group.
    func testIgnoredMembersLeaveTheGroup() {
        let groups = DuplicateSkillGrouper.groups([
            snapshot(path: "/a/demo", name: "demo", fingerprint: "fff", ignoredDuplicateGroup: "fff"),
            snapshot(path: "/b/demo", name: "demo", fingerprint: "fff"),
            snapshot(path: "/c/demo", name: "demo", fingerprint: "fff"),
        ])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].members.map(\.path), ["/b/demo", "/c/demo"])
    }

    // AC-6: a group left with a single visible member disappears.
    func testGroupWithSingleVisibleMemberDisappears() {
        let groups = DuplicateSkillGrouper.groups([
            snapshot(path: "/a/demo", name: "demo", fingerprint: "fff", ignoredDuplicateGroup: "fff"),
            snapshot(path: "/b/demo", name: "demo", fingerprint: "fff"),
        ])

        XCTAssertTrue(groups.isEmpty)
    }

    // AC-6: a fully ignored group disappears entirely.
    func testFullyIgnoredGroupDisappears() {
        let groups = DuplicateSkillGrouper.groups([
            snapshot(path: "/a/demo", name: "demo", fingerprint: "fff", ignoredDuplicateGroup: "fff"),
            snapshot(path: "/b/demo", name: "demo", fingerprint: "fff", ignoredDuplicateGroup: "fff"),
        ])

        XCTAssertTrue(groups.isEmpty)
    }

    // Ignoring one fingerprint never touches another group.
    func testIgnoringOneGroupLeavesOthersUntouched() {
        let groups = DuplicateSkillGrouper.groups([
            snapshot(path: "/a/one", name: "one", fingerprint: "111", ignoredDuplicateGroup: "111"),
            snapshot(path: "/b/one", name: "one", fingerprint: "111", ignoredDuplicateGroup: "111"),
            snapshot(path: "/c/two", name: "two", fingerprint: "222"),
            snapshot(path: "/d/two", name: "two", fingerprint: "222"),
        ])

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].fingerprint, "222")
    }
}
