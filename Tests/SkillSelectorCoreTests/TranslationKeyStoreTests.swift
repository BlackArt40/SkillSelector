import Foundation
import XCTest
@testable import SkillSelectorCore

final class TranslationKeyStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranslationKeyStoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        TranslationKeyStore.overrideDirectoryURL = directory
    }

    override func tearDown() {
        TranslationKeyStore.overrideDirectoryURL = nil
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private var blobURL: URL {
        directory.appendingPathComponent("translation-key.enc")
    }

    // MARK: Load

    func testLoadReturnsNilWhenNoFile() {
        XCTAssertNil(TranslationKeyStore.load())
    }

    func testLoadReturnsNilWhenBlobCorrupt() throws {
        try Data("definitely-not-a-sealed-box".utf8).write(to: blobURL)
        XCTAssertNil(TranslationKeyStore.load())
    }

    // MARK: Save / update

    func testSaveThenLoadRoundTrips() throws {
        try TranslationKeyStore.save("sk-test-key-123")
        XCTAssertEqual(TranslationKeyStore.load(), "sk-test-key-123")
    }

    func testSaveOverwritesPreviousValue() throws {
        try TranslationKeyStore.save("first-key")
        try TranslationKeyStore.save("second-key")
        XCTAssertEqual(TranslationKeyStore.load(), "second-key")
    }

    func testBlobIsEncryptedNotPlaintext() throws {
        try TranslationKeyStore.save("super-secret-key")
        let blob = try Data(contentsOf: blobURL)
        XCTAssertFalse(blob.isEmpty)
        let hit = (blob as NSData).range(
            of: Data("super-secret-key".utf8),
            options: [],
            in: NSRange(location: 0, length: blob.count)
        )
        XCTAssertEqual(hit.location, NSNotFound)
    }

    func testSaveThrowsIOErrorOnUnwritableDirectory() throws {
        let readOnly = directory.appendingPathComponent("readonly", isDirectory: true)
        try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: readOnly.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: readOnly.path
            )
        }
        // Permission enforcement is environment-dependent (CI runs as root);
        // skip instead of flaking when the environment ignores it.
        let probe = readOnly.appendingPathComponent("probe")
        if (try? Data("x".utf8).write(to: probe)) != nil {
            try? FileManager.default.removeItem(at: probe)
            throw XCTSkip("directory permissions are not enforced in this environment")
        }
        TranslationKeyStore.overrideDirectoryURL = readOnly
        XCTAssertThrowsError(try TranslationKeyStore.save("nope")) { error in
            XCTAssertEqual(error as? TranslationKeyStore.StoreError, .io)
        }
    }

    // MARK: Delete

    func testDeleteRemovesFileAndClearsValue() throws {
        try TranslationKeyStore.save("gone-later")
        TranslationKeyStore.delete()
        XCTAssertNil(TranslationKeyStore.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: blobURL.path))
    }

    func testDeleteWhenNothingStoredIsHarmless() {
        TranslationKeyStore.delete()
        XCTAssertNil(TranslationKeyStore.load())
    }
}