import Foundation
import XCTest
@testable import SkillSelectorCore

final class SkillDocumentReaderTests: XCTestCase {
    private var fixture: URL!

    override func setUpWithError() throws {
        fixture = FileManager.default.temporaryDirectory
            .appending(path: "SkillDocumentReaderTests-\(UUID().uuidString)")
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
        XCTAssertEqual(document.fileURL, installation.appending(path: "SKILL.md").standardizedFileURL)
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

    func testRejectsInstallationOutsideAuthorizedRoots() throws {
        let installation = try makeSkill(parent: FileManager.default.temporaryDirectory)

        XCTAssertThrowsError(try SkillDocumentReader().read(request(installation: installation))) { error in
            XCTAssertEqual(error as? SkillDocumentReaderError, .unauthorizedInstallationPath)
        }
    }

    func testRejectsMismatchedOrEscapingResolvedTarget() throws {
        let installation = try makeSkill()
        let outside = FileManager.default.temporaryDirectory
            .appending(path: "outside-\(UUID().uuidString)")
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
            .appending(path: "outside-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: installation.appending(path: "SKILL.md"),
            withDestinationURL: outside
        )

        XCTAssertThrowsError(try SkillDocumentReader().read(request(installation: installation))) { error in
            XCTAssertEqual(error as? SkillDocumentReaderError, .entryEscapesAuthorizedRoot)
        }
    }

    func testAcceptsEntrySymlinkToRegularFileInsideAuthorizedRoot() throws {
        let target = fixture.appending(path: "shared.md")
        try Data("shared source".utf8).write(to: target)
        let installation = try makeSkill(source: nil)
        try FileManager.default.createSymbolicLink(
            at: installation.appending(path: "SKILL.md"),
            withDestinationURL: target
        )

        XCTAssertEqual(
            try SkillDocumentReader().read(request(installation: installation)).source,
            "shared source"
        )
    }

    func testReadsSymlinkInstallationWithMatchingAuthorizedResolvedTarget() throws {
        let target = try makeSkill(name: "target", source: "linked installation")
        let link = fixture.appending(path: "linked-skill")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let document = try SkillDocumentReader().read(
            request(installation: link, resolvedTarget: target)
        )

        XCTAssertEqual(document.source, "linked installation")
        XCTAssertEqual(document.fileURL, link.appending(path: "SKILL.md").standardizedFileURL)
    }

    func testRejectsSymlinkInstallationWhenRecordedTargetDoesNotMatchActualTarget() throws {
        let target = try makeSkill(name: "actual-target")
        let otherTarget = try makeSkill(name: "recorded-target")
        let link = fixture.appending(path: "mismatched-link")
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
        let link = fixture.appending(path: "unrecorded-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertThrowsError(try SkillDocumentReader().read(request(installation: link))) { error in
            XCTAssertEqual(error as? SkillDocumentReaderError, .invalidResolvedTarget)
        }
    }

    func testRejectsDirectoriesAndMissingFilesAsNonFiles() throws {
        let installation = try makeSkill(source: nil)
        try FileManager.default.createDirectory(
            at: installation.appending(path: "SKILL.md"),
            withIntermediateDirectories: false
        )

        XCTAssertThrowsError(try SkillDocumentReader().read(request(installation: installation))) { error in
            XCTAssertEqual(error as? SkillDocumentReaderError, .notRegularFile)
        }
    }

    func testRejectsUnreadableAndInvalidUTF8Files() throws {
        let unreadable = try makeSkill(name: "unreadable", source: "secret")
        let unreadableFile = unreadable.appending(path: "SKILL.md")
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
        var requestedByteCount = 0
        let reader = SkillDocumentReader { _, byteCount in
            requestedByteCount = byteCount
            return Data(repeating: 0x61, count: byteCount)
        }

        XCTAssertThrowsError(try reader.read(request(installation: installation))) { error in
            XCTAssertEqual(
                error as? SkillDocumentReaderError,
                .tooLarge(
                    limit: SkillDocumentReader.maximumRenderBytes,
                    actual: SkillDocumentReader.maximumRenderBytes + 1
                )
            )
        }
        XCTAssertEqual(requestedByteCount, SkillDocumentReader.maximumRenderBytes + 1)
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
        let installation = (parent ?? fixture).appending(path: name)
        try FileManager.default.createDirectory(at: installation, withIntermediateDirectories: true)
        if let data {
            try data.write(to: installation.appending(path: "SKILL.md"))
        } else if let source {
            try Data(source.utf8).write(to: installation.appending(path: "SKILL.md"))
        }
        return installation
    }
}
