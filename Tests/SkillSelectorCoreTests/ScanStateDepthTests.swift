import Foundation
import XCTest
@testable import SkillSelectorCore

/// ScanStateBuilder walks a stat-only tree with plain recursion, and scan
/// code must never recurse unbounded (512 KB cooperative stack). A deep
/// directory chain — `mkdir -p` deep enough — must be capped, not fatal.
final class ScanStateDepthTests: XCTestCase {
    func testShallowTreeIsFullyEnumerated() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(component: "ScanStateDepth-shallow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root.appending(component: "docs"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appending(component: "SKILL.md"))
        try Data("y".utf8).write(to: root.appending(component: "docs").appending(component: "notes.md"))

        let state = ScanStateBuilder.build(
            contentDirectory: root,
            entryFilename: "SKILL.md",
            resolvedTarget: nil
        )

        XCTAssertEqual(state.entries.count, 4, "root + dir + 2 files")
    }

    func testDeepTreeIsCappedWithoutOverflow() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(component: "ScanStateDepth-deep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Far beyond the cap: building the state must not overflow the
        // cooperative stack and must stop descending at the bound. Single-
        // character component names keep the absolute path under PATH_MAX
        // (the limit being exercised here is depth, not path length).
        var cursor = root
        let totalDepth = ScanStateBuilder.maximumWalkDepth + 50
        for _ in 0..<totalDepth {
            cursor = cursor.appending(component: "d")
        }
        try FileManager.default.createDirectory(at: cursor, withIntermediateDirectories: true)

        let state = ScanStateBuilder.build(
            contentDirectory: root,
            entryFilename: "SKILL.md",
            resolvedTarget: nil
        )

        let maximumComponents = state.entries
            .map { $0.relativePath.split(separator: "/").count }
            .max() ?? 0
        XCTAssertLessThanOrEqual(
            maximumComponents,
            ScanStateBuilder.maximumWalkDepth,
            "the stat walk must stop at the declared depth bound"
        )
    }
}
