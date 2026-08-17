import Foundation
import XCTest
@testable import SkillSelectorCore

final class SkillContentFingerprintTests: XCTestCase {
    private var workspace: URL!

    override func setUpWithError() throws {
        workspace = FileManager.default.temporaryDirectory
            .appending(path: "SkillContentFingerprintTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: workspace)
    }

    private func makeSkill(name: String, skillMDContent: String? = nil, extra: String? = nil) throws -> URL {
        let directory = workspace.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let document = skillMDContent ?? "---\nname: \(name)\ndescription: demo\n---\n# \(name)\nbody\n"
        try document.write(
            to: directory.appending(path: "SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        if let extra {
            let subdirectory = directory.appending(path: "scripts", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
            try extra.write(
                to: subdirectory.appending(path: "run.sh"),
                atomically: true,
                encoding: .utf8
            )
        }
        return directory
    }

    func testIdenticalContentInDifferentDirectoriesSharesAFingerprint() throws {
        let content = "---\nname: demo\ndescription: same everywhere\n---\n# demo\nshared body\n"
        let first = try makeSkill(name: "demo-a", skillMDContent: content, extra: "echo hi\n")
        let second = try makeSkill(name: "demo-b", skillMDContent: content, extra: "echo hi\n")

        XCTAssertEqual(
            try SkillContentFingerprint.compute(rootDirectory: first),
            try SkillContentFingerprint.compute(rootDirectory: second)
        )
    }

    func testDifferentContentProducesDifferentFingerprints() throws {
        let first = try makeSkill(name: "demo-a", skillMDContent: "---\nname: d\n---\nbody one")
        let second = try makeSkill(name: "demo-b", skillMDContent: "---\nname: d\n---\nbody two")

        XCTAssertNotEqual(
            try SkillContentFingerprint.compute(rootDirectory: first),
            try SkillContentFingerprint.compute(rootDirectory: second)
        )
    }

    func testAddingAFileChangesTheFingerprint() throws {
        let directory = try makeSkill(name: "demo")
        let before = try SkillContentFingerprint.compute(rootDirectory: directory)

        try "notes".write(
            to: directory.appending(path: "NOTES.txt"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertNotEqual(before, try SkillContentFingerprint.compute(rootDirectory: directory))
    }

    func testCopiesKeepByteLevelStabilityAcrossCopyOperations() throws {
        let original = try makeSkill(name: "original", extra: "echo one\necho two\n")
        let copy = workspace.appending(path: "the-copy", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: original, to: copy)

        XCTAssertEqual(
            try SkillContentFingerprint.compute(rootDirectory: original),
            try SkillContentFingerprint.compute(rootDirectory: copy)
        )
    }
}

final class DuplicateSkillGrouperTests: XCTestCase {
    private func snapshot(path: String, name: String, fingerprint: String?) -> SkillSnapshot {
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
            contentFingerprint: fingerprint
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
}
