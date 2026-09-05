import Foundation
import XCTest
@testable import SkillSelectorCore

final class SkillDocumentReaderTests: XCTestCase {
    private var fixture: URL!

    override func setUpWithError() throws {
        fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillDocumentReaderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let fixture {
            try? FileManager.default.removeItem(at: fixture)
        }
    }

    func testReadsUTF8RegularFileInsideAuthorizedRoot() throws {
        let installation = try makeSkill(source: "# Demo\n\nHello")

        let document = try SkillDocumentReader().read(request(installation: installation))

        XCTAssertEqual(document.source, "# Demo\n\nHello")
        XCTAssertEqual(document.fileURL, installation.appendingPathComponent("SKILL.md").standardizedFileURL)
    }

    func testRejectsTraversalAndNonSimpleEntryFilenames() throws {
        let installation = try makeSkill()
        for filename in ["", ".", "..", "../outside.md", "nested/SKILL.md", "nested\\SKILL.md"] {
            XCTAssertThrowsError(
                try SkillDocumentReader().validatedEntryURL(
                    request(installation: installation, entryFilename: filename)
                )
            ) { error in
                XCTAssertEqual(error as? SkillDocumentReaderError, .invalidEntryFilename(filename))
            }
        }
    }

    func testRejectsNULInEntryFilename() throws {
        // NUL cannot appear in an APFS filename or SwiftUI text input, but a
        // hand-crafted value would trap or truncate in withCString/openat
        // (audit F-08). The shared EntryFilename rule must reject it.
        let installation = try makeSkill()
        let filename = "SKILL\0.md"
        XCTAssertThrowsError(
            try SkillDocumentReader().validatedEntryURL(
                request(installation: installation, entryFilename: filename)
            )
        ) { error in
            XCTAssertEqual(error as? SkillDocumentReaderError, .invalidEntryFilename(filename))
        }
    }

    func testRejectsInstallationOutsideAuthorizedRoots() throws {
        let installation = try makeSkill(parent: FileManager.default.temporaryDirectory)

        XCTAssertThrowsError(try SkillDocumentReader().read(request(installation: installation))) { error in
            XCTAssertEqual(error as? SkillDocumentReaderError, .unauthorizedInstallationPath)
        }
    }

    func testRejectsMismatchedOrEscapingResolvedTarget() throws {
        let installation = try makeSkill()
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("outside-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

        XCTAssertThrowsError(
            try SkillDocumentReader().read(
                request(installation: installation, resolvedTarget: outside)
            )
        ) { error in
            XCTAssertEqual(error as? SkillDocumentReaderError, .invalidResolvedTarget)
        }
    }

    func testRejectsEntrySymlinkEscapingAuthorizedRoot() throws {
        let installation = try makeSkill(source: nil)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("outside-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: installation.appendingPathComponent("SKILL.md"),
            withDestinationURL: outside
        )

        XCTAssertThrowsError(try SkillDocumentReader().read(request(installation: installation))) { error in
            XCTAssertEqual(error as? SkillDocumentReaderError, .entryEscapesAuthorizedRoot)
        }
    }

    func testAcceptsEntrySymlinkToRegularFileInsideAuthorizedRoot() throws {
        let target = fixture.appendingPathComponent("shared.md")
        try Data("shared source".utf8).write(to: target)
        let installation = try makeSkill(source: nil)
        try FileManager.default.createSymbolicLink(
            at: installation.appendingPathComponent("SKILL.md"),
            withDestinationURL: target
        )

        XCTAssertEqual(
            try SkillDocumentReader().read(request(installation: installation)).source,
            "shared source"
        )
        XCTAssertEqual(
            try SkillDocumentReader().validatedEntryURL(request(installation: installation)),
            target.standardizedFileURL
        )
    }

    func testReadsSymlinkInstallationWithMatchingAuthorizedResolvedTarget() throws {
        let target = try makeSkill(name: "target", source: "linked installation")
        let link = fixture.appendingPathComponent("linked-skill")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let document = try SkillDocumentReader().read(
            request(installation: link, resolvedTarget: target)
        )

        XCTAssertEqual(document.source, "linked installation")
        XCTAssertEqual(document.fileURL, target.appendingPathComponent("SKILL.md").standardizedFileURL)
    }

    func testReadsSymlinkInstallationAcrossTwoAuthorizedRoots() throws {
        let linksRoot = fixture.appendingPathComponent("links")
        let targetsRoot = fixture.appendingPathComponent("targets")
        try FileManager.default.createDirectory(at: linksRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: targetsRoot, withIntermediateDirectories: true)
        let target = try makeSkill(parent: targetsRoot, name: "target", source: "cross root")
        let link = linksRoot.appendingPathComponent("linked-skill")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let document = try SkillDocumentReader().read(SkillDocumentRequest(
            installationURL: link,
            resolvedTargetURL: target,
            entryFilename: "SKILL.md",
            authorizedRootURLs: [linksRoot, targetsRoot]
        ))

        XCTAssertEqual(document.source, "cross root")
    }

    func testRejectsSymlinkInstallationWhenRecordedTargetDoesNotMatchActualTarget() throws {
        let target = try makeSkill(name: "actual-target")
        let otherTarget = try makeSkill(name: "recorded-target")
        let link = fixture.appendingPathComponent("mismatched-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertThrowsError(
            try SkillDocumentReader().read(
                request(installation: link, resolvedTarget: otherTarget)
            )
        ) { error in
            XCTAssertEqual(error as? SkillDocumentReaderError, .invalidResolvedTarget)
        }
    }

    func testRejectsSymlinkInstallationWithoutRecordedResolvedTarget() throws {
        let target = try makeSkill(name: "unrecorded-target")
        let link = fixture.appendingPathComponent("unrecorded-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertThrowsError(try SkillDocumentReader().read(request(installation: link))) { error in
            XCTAssertEqual(error as? SkillDocumentReaderError, .invalidResolvedTarget)
        }
    }

    func testRejectsDirectoriesAndMissingFilesAsNonFiles() throws {
        let installation = try makeSkill(source: nil)
        try FileManager.default.createDirectory(
            at: installation.appendingPathComponent("SKILL.md"),
            withIntermediateDirectories: false
        )

        XCTAssertThrowsError(try SkillDocumentReader().read(request(installation: installation))) { error in
            XCTAssertEqual(error as? SkillDocumentReaderError, .notRegularFile)
        }
    }

    func testRejectsUnreadableAndInvalidUTF8Files() throws {
        let unreadable = try makeSkill(name: "unreadable", source: "secret")
        let unreadableFile = unreadable.appendingPathComponent("SKILL.md")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadableFile.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadableFile.path)
        }
        XCTAssertThrowsError(try SkillDocumentReader().read(request(installation: unreadable))) { error in
            XCTAssertEqual(error as? SkillDocumentReaderError, .unreadableFile)
        }

        let invalid = try makeSkill(name: "invalid", data: Data([0xC3, 0x28]))
        XCTAssertThrowsError(try SkillDocumentReader().read(request(installation: invalid))) { error in
            XCTAssertEqual(error as? SkillDocumentReaderError, .invalidUTF8)
        }
    }

    func testRejectsInputOverExactlyOneMiBBeforeReadingAndAllowsExternalValidation() throws {
        let byteCount = SkillDocumentReader.maximumRenderBytes + 1
        let installation = try makeSkill(data: Data(repeating: 0x61, count: byteCount))

        XCTAssertThrowsError(try SkillDocumentReader().read(request(installation: installation))) { error in
            XCTAssertEqual(
                error as? SkillDocumentReaderError,
                .tooLarge(limit: SkillDocumentReader.maximumRenderBytes, actual: byteCount)
            )
        }
        XCTAssertNoThrow(
            try SkillDocumentReader().validatedEntryURL(request(installation: installation))
        )
    }

    func testAcceptsInputAtExactlyOneMiB() throws {
        let byteCount = SkillDocumentReader.maximumRenderBytes
        let installation = try makeSkill(data: Data(repeating: 0x61, count: byteCount))

        XCTAssertEqual(
            try SkillDocumentReader().read(request(installation: installation)).source.utf8.count,
            byteCount
        )
    }

    func testBoundsReadAndRejectsFileThatGrowsAfterMetadataCheck() throws {
        let installation = try makeSkill(source: "initially small")
        let live = SkillDocumentFileOperations.live
        var requestedByteCounts: [Int] = []
        var chunks = [
            Data(repeating: 0x61, count: SkillDocumentReader.maximumRenderBytes),
            Data([0x61]),
        ]
        let reader = SkillDocumentReader(operations: SkillDocumentFileOperations(
            openDirectory: live.openDirectory,
            openEntry: live.openEntry,
            metadata: live.metadata,
            canonicalURL: live.canonicalURL,
            readChunk: { _, byteCount in
                requestedByteCounts.append(byteCount)
                return chunks.removeFirst()
            },
            close: live.close
        ))

        XCTAssertThrowsError(try reader.read(request(installation: installation))) { error in
            XCTAssertEqual(
                error as? SkillDocumentReaderError,
                .tooLarge(
                    limit: SkillDocumentReader.maximumRenderBytes,
                    actual: SkillDocumentReader.maximumRenderBytes + 1
                )
            )
        }
        XCTAssertEqual(
            requestedByteCounts,
            [SkillDocumentReader.maximumRenderBytes + 1, 1]
        )
    }

    func testConcatenatesShortReadsUntilEOF() throws {
        let installation = try makeSkill(source: "placeholder")
        let live = SkillDocumentFileOperations.live
        var chunks = [Data("ab".utf8), Data("c".utf8), Data("def".utf8), Data()]
        let reader = SkillDocumentReader(operations: SkillDocumentFileOperations(
            openDirectory: live.openDirectory,
            openEntry: live.openEntry,
            metadata: live.metadata,
            canonicalURL: live.canonicalURL,
            readChunk: { _, _ in chunks.removeFirst() },
            close: live.close
        ))

        XCTAssertEqual(
            try reader.read(request(installation: installation)).source,
            "abcdef"
        )
        XCTAssertTrue(chunks.isEmpty)
    }

    func testRejectsCanonicalPathThatEscapesWhenDirectoryChangesBeforeOpen() throws {
        let parent = fixture.appendingPathComponent("parent")
        let installation = try makeSkill(parent: parent, name: "swapped", source: "authorized")
        let backup = fixture.appendingPathComponent("parent-backup")
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillDocumentReaderOutside-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outside) }
        _ = try makeSkill(parent: outside, name: "swapped", source: "outside")

        let live = SkillDocumentFileOperations.live
        var didSwap = false
        var closeCount = 0
        let reader = SkillDocumentReader(operations: SkillDocumentFileOperations(
            openDirectory: { url in
                if !didSwap {
                    didSwap = true
                    try FileManager.default.moveItem(at: parent, to: backup)
                    try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: outside)
                }
                return try live.openDirectory(url)
            },
            openEntry: live.openEntry,
            metadata: live.metadata,
            canonicalURL: live.canonicalURL,
            readChunk: live.readChunk,
            close: { descriptor in
                closeCount += 1
                live.close(descriptor)
            }
        ))

        XCTAssertThrowsError(try reader.read(request(installation: installation))) { error in
            XCTAssertEqual(error as? SkillDocumentReaderError, .invalidResolvedTarget)
        }
        XCTAssertEqual(closeCount, 1)
    }

    func testRejectsEntrySymlinkSwappedOutsideBeforeOpenAt() throws {
        let original = fixture.appendingPathComponent("original.md")
        try Data("authorized".utf8).write(to: original)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("SkillDocumentReaderOutside-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("outside".utf8).write(to: outside)
        let installation = try makeSkill(name: "entry-swap", source: nil)
        let entry = installation.appendingPathComponent("SKILL.md")
        try FileManager.default.createSymbolicLink(at: entry, withDestinationURL: original)

        let live = SkillDocumentFileOperations.live
        var didSwap = false
        var closeCount = 0
        let reader = SkillDocumentReader(operations: SkillDocumentFileOperations(
            openDirectory: live.openDirectory,
            openEntry: { directoryDescriptor, filename in
                if !didSwap {
                    didSwap = true
                    try FileManager.default.removeItem(at: entry)
                    try FileManager.default.createSymbolicLink(at: entry, withDestinationURL: outside)
                }
                return try live.openEntry(directoryDescriptor, filename)
            },
            metadata: live.metadata,
            canonicalURL: live.canonicalURL,
            readChunk: live.readChunk,
            close: { descriptor in
                closeCount += 1
                live.close(descriptor)
            }
        ))

        XCTAssertThrowsError(try reader.read(request(installation: installation))) { error in
            XCTAssertEqual(error as? SkillDocumentReaderError, .entryEscapesAuthorizedRoot)
        }
        XCTAssertEqual(closeCount, 2)
    }

    func testInstallationSymlinkSwapBeforeEntryOpenStillReadsRecordedTarget() throws {
        let targetA = try makeSkill(name: "target-a", source: "A")
        let targetB = try makeSkill(name: "target-b", source: "B")
        let link = fixture.appendingPathComponent("switched-installation")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: targetA)

        let live = SkillDocumentFileOperations.live
        var didSwap = false
        let reader = SkillDocumentReader(operations: SkillDocumentFileOperations(
            openDirectory: live.openDirectory,
            openEntry: { directoryDescriptor, filename in
                if !didSwap {
                    didSwap = true
                    try FileManager.default.removeItem(at: link)
                    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: targetB)
                }
                return try live.openEntry(directoryDescriptor, filename)
            },
            metadata: live.metadata,
            canonicalURL: live.canonicalURL,
            readChunk: live.readChunk,
            close: live.close
        ))

        XCTAssertEqual(
            try reader.read(request(installation: link, resolvedTarget: targetA)).source,
            "A"
        )
    }

    private func request(
        installation: URL,
        resolvedTarget: URL? = nil,
        entryFilename: String = "SKILL.md"
    ) -> SkillDocumentRequest {
        SkillDocumentRequest(
            installationURL: installation,
            resolvedTargetURL: resolvedTarget,
            entryFilename: entryFilename,
            authorizedRootURLs: [fixture]
        )
    }

    private func makeSkill(
        parent: URL? = nil,
        name: String = UUID().uuidString,
        source: String? = "demo",
        data: Data? = nil
    ) throws -> URL {
        let installation = (parent ?? fixture).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: installation, withIntermediateDirectories: true)
        if let data {
            try data.write(to: installation.appendingPathComponent("SKILL.md"))
        } else if let source {
            try Data(source.utf8).write(to: installation.appendingPathComponent("SKILL.md"))
        }
        return installation
    }
}
