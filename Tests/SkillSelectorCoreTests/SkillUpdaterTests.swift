import Darwin
import Foundation
import XCTest
@testable import SkillSelectorCore

final class SkillUpdaterTests: XCTestCase {
    func testSourceRequiresExplicitProvenanceAndParsesSupportedBindings() throws {
        let embedded = try SkillSource.github(
            repository: "acme/skills",
            subdirectory: "skills/demo",
            reference: .branch("main"),
            provenance: .embeddedMetadata
        )
        let containing = try SkillSource.containingGitRemote(
            remoteURL: URL(string: "https://github.com/acme/skills.git")!,
            relativePath: "skills/demo",
            reference: .tag("v1")
        )
        let remembered = try SkillSource.remembered(
            binding: "github:acme/skills:skills/demo",
            reference: .commit("0123456789abcdef")
        )
        let sshRemote = try SkillSource.containingGitRemote(
            remote: "git@github.com:acme/skills.git",
            relativePath: "skills/demo",
            reference: .branch("main")
        )
        let confirmed = try SkillSource.userConfirmed(candidate: .github(
            repository: "acme/skills",
            subdirectory: "skills/demo",
            reference: .branch("main")
        ))
        let rememberedDirect = try SkillSource.remembered(
            binding: "url:https://example.com/demo.zip"
        )

        XCTAssertEqual(embedded.repository, "acme/skills")
        XCTAssertEqual(containing.repository, "acme/skills")
        XCTAssertEqual(containing.provenance, .containingGitRemote)
        XCTAssertEqual(remembered.subdirectory, "skills/demo")
        XCTAssertEqual(sshRemote.repository, "acme/skills")
        XCTAssertEqual(confirmed.provenance, .userConfirmedCandidate)
        XCTAssertEqual(rememberedDirect.directPackageURL?.absoluteString, "https://example.com/demo.zip")
        XCTAssertNil(SkillSource.nameOnlyCandidate("demo"))
        XCTAssertThrowsError(try SkillSource.userConfirmed(candidate: .nameOnly("demo")))
    }

    func testDigestIsStableSortedAndIncludesExecutableBitsAndLinkTargets() throws {
        let root = try makeSkill(name: "demo")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try Data("two".utf8).write(to: root.appending(path: "z.txt"))
        try Data("one".utf8).write(to: root.appending(path: "a.txt"))
        try FileManager.default.createDirectory(at: root.appending(path: ".git"), withIntermediateDirectories: true)
        try Data("ignored".utf8).write(to: root.appending(path: ".git/config"))
        try Data("ignored".utf8).write(to: root.appending(path: ".DS_Store"))
        try Data("ignored".utf8).write(to: root.appending(path: ".skillselector-index.json"))
        let executable = root.appending(path: "run.sh")
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try FileManager.default.createSymbolicLink(
            atPath: root.appending(path: "current").path,
            withDestinationPath: "a.txt"
        )

        let first = try PackageDigest.compute(at: root)
        let reordered = try PackageDigest.compute(at: root)
        XCTAssertEqual(first, reordered)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: executable.path)
        let withoutExecutableBit = try PackageDigest.compute(at: root)
        XCTAssertNotEqual(first, withoutExecutableBit)

        try FileManager.default.removeItem(at: root.appending(path: "current"))
        try FileManager.default.createSymbolicLink(
            atPath: root.appending(path: "current").path,
            withDestinationPath: "z.txt"
        )
        XCTAssertNotEqual(withoutExecutableBit, try PackageDigest.compute(at: root))

        let beforeIgnoredMutation = try PackageDigest.compute(at: root)
        try Data("different ignored bytes".utf8).write(to: root.appending(path: ".DS_Store"))
        XCTAssertEqual(beforeIgnoredMutation, try PackageDigest.compute(at: root))
    }

    func testValidatorRejectsMissingMalformedAndMismatchedEntryFiles() throws {
        let parent = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let package = parent.appending(path: "package")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let validator = PackageValidator()

        XCTAssertThrowsError(try validator.validate(package, requiredName: "demo")) {
            XCTAssertEqual($0 as? PackageValidationError, .missingEntryFile("SKILL.md"))
        }
        try Data("# Demo\n".utf8).write(to: package.appending(path: "SKILL.md"))
        XCTAssertThrowsError(try validator.validate(package, requiredName: "demo"))
        try writeSkill(at: package, name: "other")
        XCTAssertThrowsError(try validator.validate(package, requiredName: "demo")) {
            XCTAssertEqual($0 as? PackageValidationError, .nameMismatch(expected: "demo", actual: "other"))
        }
    }

    func testValidatorRejectsHostileArchiveEntriesLinksDevicesAndLimits() throws {
        let validator = PackageValidator(limits: .init(maximumFileCount: 2, maximumTotalBytes: 80))
        for path in ["../escape", "/tmp/escape", "folder/../../escape"] {
            XCTAssertThrowsError(try validator.validateArchiveEntries([
                PackageArchiveEntry(path: path, kind: .regularFile, byteCount: 1),
            ]))
        }

        let root = try makeSkill(name: "demo")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try FileManager.default.createSymbolicLink(
            atPath: root.appending(path: "escape").path,
            withDestinationPath: "../../outside"
        )
        XCTAssertThrowsError(try validator.validate(root, requiredName: "demo")) {
            XCTAssertEqual($0 as? PackageValidationError, .escapingSymbolicLink("escape"))
        }

        XCTAssertThrowsError(try validator.validateArchiveEntries([
            PackageArchiveEntry(path: "device", kind: .device, byteCount: 0),
        ]))
        XCTAssertThrowsError(try validator.validateArchiveEntries([
            PackageArchiveEntry(path: "a", kind: .regularFile, byteCount: 1),
            PackageArchiveEntry(path: "b", kind: .regularFile, byteCount: 1),
            PackageArchiveEntry(path: "c", kind: .regularFile, byteCount: 1),
        ]))
        XCTAssertThrowsError(try validator.validateArchiveEntries([
            PackageArchiveEntry(path: "large", kind: .regularFile, byteCount: 81),
        ]))
    }

    func testZIPExtractorValidatesTheWholeArchiveBeforeWritingAnything() throws {
        let destination = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }
        let archive = storedZIP(entries: [
            ("SKILL.md", Data("safe".utf8), 0o100644),
            ("../escape", Data("hostile".utf8), 0o100644),
        ])

        XCTAssertThrowsError(try SafeZIPExtractor.extract(
            archive,
            into: destination,
            validator: PackageValidator()
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testZIPExtractorMaterializesValidatedFilesExecutableBitsAndLinks() throws {
        let destination = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }
        let archive = storedZIP(entries: [
            ("SKILL.md", Data("---\nname: demo\ndescription: test\n---\n".utf8), 0o100644),
            ("bin/run", Data("#!/bin/sh\n".utf8), 0o100755),
            ("current", Data("SKILL.md".utf8), 0o120777),
        ])

        try SafeZIPExtractor.extract(
            archive,
            into: destination,
            validator: PackageValidator()
        )

        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: destination.appending(path: "bin/run").path))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: destination.appending(path: "current").path),
            "SKILL.md"
        )
    }

    func testValidatorAcceptsCompleteNestedRepositorySubdirectory() throws {
        let parent = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let nested = parent.appending(path: "repo/skills/demo")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try writeSkill(at: nested, name: "demo")

        let validated = try PackageValidator().validate(nested, requiredName: "demo")
        XCTAssertEqual(validated.packageURL, nested.standardizedFileURL)
        XCTAssertEqual(validated.document.name, "demo")
    }

    func testScannerIndexesTheNormalizedPackageDigestAsUpdateBaseline() async throws {
        let root = temporaryDirectory()
        let skill = root.appending(path: "demo")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSkill(at: skill, name: "demo")

        let report = await SkillScanner().scan([
            .skillDirectory(id: "root", url: root, agentIDs: ["codex"]),
        ])

        XCTAssertEqual(report.installations.first?.digest, try PackageDigest.compute(at: skill).value)
    }

    func testCheckDownloadsExactPackageAndBuildsFileLevelProposalWithoutMutation() async throws {
        let installed = try makeSkill(name: "demo", body: "old")
        let remote = try makeSkill(name: "demo", body: "new")
        defer {
            try? FileManager.default.removeItem(at: installed.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: remote.deletingLastPathComponent())
        }
        try Data("gone".utf8).write(to: installed.appending(path: "deleted.txt"))
        try Data("added".utf8).write(to: remote.appending(path: "added.txt"))
        let baseline = try PackageDigest.compute(at: installed)
        let fetcher = FixturePackageFetcher(packageURL: remote, resolvedReference: "abc123")
        let updater = SkillUpdater(fetcher: fetcher)
        let source = try SkillSource.github(
            repository: "acme/skills",
            subdirectory: "skills/demo",
            reference: .branch("main"),
            provenance: .rememberedBinding
        )

        let proposal = try await updater.check(UpdateRequest(
            installationURL: installed,
            entryFilename: "SKILL.md",
            requiredName: "demo",
            source: source,
            indexedDigest: baseline,
            authorizedRootURLs: [installed.deletingLastPathComponent()]
        ))

        XCTAssertEqual(try String(contentsOf: installed.appending(path: "SKILL.md"), encoding: .utf8).contains("old"), true)
        XCTAssertEqual(proposal.resolvedReference, "abc123")
        XCTAssertFalse(proposal.isPinned)
        XCTAssertEqual(proposal.changes.map(\.path), ["SKILL.md", "added.txt", "deleted.txt"])
        XCTAssertEqual(proposal.changes.map(\.kind), [.changed, .added, .deleted])
        XCTAssertNotEqual(proposal.baselineDigest, proposal.remoteDigest)
    }

    func testTagAndCommitSourcesArePinned() throws {
        XCTAssertTrue(UpdateReference.tag("v1").isPinned)
        XCTAssertTrue(UpdateReference.commit("abc").isPinned)
        XCTAssertFalse(UpdateReference.branch("main").isPinned)
    }

    func testGitHubFetcherUsesGhAndDownloadsOnlyTheExactSubtree() async throws {
        let skill = "---\nname: demo\ndescription: test\n---\n"
        let runner = UpdateFixtureRunner(results: [
            commandResult("abcdef0123456789\n"),
            commandResult(#"{"tree":[{"path":"README.md","mode":"100644","type":"blob","sha":"outside","size":7},{"path":"skills/demo","mode":"040000","type":"tree","sha":"dir"},{"path":"skills/demo/SKILL.md","mode":"100644","type":"blob","sha":"skill","size":49},{"path":"skills/demo/run.sh","mode":"100755","type":"blob","sha":"script","size":10},{"path":"skills/other/SKILL.md","mode":"100644","type":"blob","sha":"other","size":49}],"truncated":false}"#),
            commandResult(skill),
            commandResult("#!/bin/sh\n"),
        ])
        let destination = temporaryDirectory().appending(path: "package")
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        let source = try SkillSource.github(
            repository: "acme/skills",
            subdirectory: "skills/demo",
            reference: .branch("main"),
            provenance: .rememberedBinding
        )

        let fetched = try await LiveSkillPackageFetcher(
            executableURL: URL(fileURLWithPath: "/usr/bin/gh"),
            runner: runner
        ).fetch(source, into: destination)

        XCTAssertEqual(fetched.resolvedReference, "abcdef0123456789")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appending(path: "SKILL.md").path))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: destination.appending(path: "run.sh").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appending(path: "README.md").path))
        XCTAssertEqual(runner.commands.map(\.arguments), [
            ["api", "repos/acme/skills/commits/main", "--jq", ".sha"],
            ["api", "repos/acme/skills/git/trees/abcdef0123456789?recursive=1"],
            ["api", "repos/acme/skills/git/blobs/skill", "-H", "Accept: application/vnd.github.raw+json"],
            ["api", "repos/acme/skills/git/blobs/script", "-H", "Accept: application/vnd.github.raw+json"],
        ])
    }

    func testApplyRequiresConfirmationAndDetectsPostCheckLocalChanges() async throws {
        let installed = try makeSkill(name: "demo", body: "old")
        let remote = try makeSkill(name: "demo", body: "new")
        defer {
            try? FileManager.default.removeItem(at: installed.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: remote.deletingLastPathComponent())
        }
        let updater = SkillUpdater(
            fetcher: FixturePackageFetcher(packageURL: remote),
            replacer: SkillFileOperatorPackageReplacer(trash: UpdateFixtureTrash())
        )
        let proposal = try await updater.check(request(installed: installed))

        let unconfirmedResult = try await updater.apply(proposal)
        XCTAssertEqual(unconfirmedResult, .confirmationRequired)
        try Data("local edit".utf8).write(to: installed.appending(path: "local.txt"))
        let changed = try await updater.apply(proposal.confirmed())
        guard case .localChangesRequireConfirmation(let warning) = changed else {
            return XCTFail("Expected local change warning")
        }
        let result = try await updater.apply(warning.confirmed(allowLocalChanges: true))
        guard case .updated(let digest, _) = result else { return XCTFail("Expected update") }
        XCTAssertEqual(digest, try PackageDigest.compute(at: installed))
        XCTAssertTrue(try String(contentsOf: installed.appending(path: "SKILL.md"), encoding: .utf8).contains("new"))
    }

    func testApplyDisclosesResolvedLinkTargetAndAllAliases() async throws {
        let installed = try makeSkill(name: "demo", body: "old")
        let remote = try makeSkill(name: "demo", body: "new")
        let linkParent = temporaryDirectory()
        try FileManager.default.createDirectory(at: linkParent, withIntermediateDirectories: true)
        let first = linkParent.appending(path: "demo-one")
        let second = linkParent.appending(path: "demo-two")
        try FileManager.default.createSymbolicLink(atPath: first.path, withDestinationPath: installed.path)
        try FileManager.default.createSymbolicLink(atPath: second.path, withDestinationPath: installed.path)
        defer {
            try? FileManager.default.removeItem(at: installed.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: remote.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: linkParent)
        }
        let updater = SkillUpdater(
            fetcher: FixturePackageFetcher(packageURL: remote),
            aliasesProvider: { [
                IndexedSkillAlias(path: first.path, resolvedTarget: installed.path, rootIDs: ["a"]),
                IndexedSkillAlias(path: second.path, resolvedTarget: installed.path, rootIDs: ["b"]),
            ] }
        )

        let proposal = try await updater.check(UpdateRequest(
            installationURL: first,
            resolvedTargetURL: installed,
            entryFilename: "SKILL.md",
            requiredName: "demo",
            source: source(),
            indexedDigest: try PackageDigest.compute(at: installed),
            authorizedRootURLs: [installed.deletingLastPathComponent(), linkParent]
        ))

        XCTAssertEqual(proposal.actualTargetURL, installed.standardizedFileURL)
        XCTAssertEqual(proposal.affectedAliases.map(\.path), [first.path, second.path])
    }

    func testFailedInstallationRollsBackOriginalPackage() async throws {
        let installed = try makeSkill(name: "demo", body: "old")
        let remote = try makeSkill(name: "demo", body: "new")
        defer {
            try? FileManager.default.removeItem(at: installed.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: remote.deletingLastPathComponent())
        }
        let replacer = FixtureReplacer(error: FixtureError.installFailed)
        let updater = SkillUpdater(
            fetcher: FixturePackageFetcher(packageURL: remote),
            replacer: replacer
        )
        let proposal = try await updater.check(request(installed: installed))

        do {
            _ = try await updater.apply(proposal.confirmed())
            XCTFail("Expected failure")
        } catch {
            XCTAssertEqual(error as? FixtureError, .installFailed)
        }
        XCTAssertTrue(try String(contentsOf: installed.appending(path: "SKILL.md"), encoding: .utf8).contains("old"))
        XCTAssertEqual(replacer.calls, 1)
        XCTAssertEqual(replacer.expectedDigest, try PackageDigest.compute(at: installed))
    }

    private func request(installed: URL) throws -> UpdateRequest {
        UpdateRequest(
            installationURL: installed,
            entryFilename: "SKILL.md",
            requiredName: "demo",
            source: source(),
            indexedDigest: try PackageDigest.compute(at: installed),
            authorizedRootURLs: [installed.deletingLastPathComponent()]
        )
    }

    private func source() -> SkillSource {
        try! SkillSource.github(
            repository: "acme/skills",
            subdirectory: "skills/demo",
            reference: .branch("main"),
            provenance: .rememberedBinding
        )
    }

    private func makeSkill(name: String, body: String = "body") throws -> URL {
        let parent = temporaryDirectory()
        let skill = parent.appending(path: "skill")
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try writeSkill(at: skill, name: name, body: body)
        return skill
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "SkillUpdaterTests-\(UUID().uuidString)")
    }

    private func writeSkill(at directory: URL, name: String, body: String = "body") throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("---\nname: \(name)\ndescription: test\n---\n\n\(body)\n".utf8)
            .write(to: directory.appending(path: "SKILL.md"))
    }
}

private final class FixturePackageFetcher: SkillPackageFetching, @unchecked Sendable {
    let packageURL: URL
    let resolvedReference: String

    init(packageURL: URL, resolvedReference: String = "remote-ref") {
        self.packageURL = packageURL
        self.resolvedReference = resolvedReference
    }

    func fetch(_ source: SkillSource, into destination: URL) async throws -> FetchedSkillPackage {
        try FileManager.default.copyItem(at: packageURL, to: destination)
        return FetchedSkillPackage(packageURL: destination, resolvedReference: resolvedReference)
    }
}

private final class FixtureReplacer: SkillPackageReplacing, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls = 0
    private(set) var expectedDigest: PackageDigest?
    let error: Error

    init(error: Error) { self.error = error }

    func replace(
        target: URL,
        with package: URL,
        expectedTargetDigest: PackageDigest,
        entryFilename: String,
        authorizedRootURLs: [URL]
    ) async throws {
        lock.withLock {
            calls += 1
            expectedDigest = expectedTargetDigest
        }
        throw error
    }
}

private enum FixtureError: Error, Equatable { case installFailed }

private final class UpdateFixtureTrash: FileOperationTrashing {
    func trashItem(at url: URL) throws -> URL {
        let trashed = url.deletingLastPathComponent()
            .appending(path: ".trashed-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: url, to: trashed)
        return trashed
    }
}

private final class UpdateFixtureRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [CommandResult]
    private var recorded: [ExternalCommand] = []

    init(results: [CommandResult]) { self.results = results }

    var commands: [ExternalCommand] { lock.withLock { recorded } }

    func run(_ command: ExternalCommand) async throws -> CommandResult {
        try lock.withLock {
            recorded.append(command)
            guard !results.isEmpty else { throw FixtureError.installFailed }
            return results.removeFirst()
        }
    }
}

private func commandResult(_ stdout: String) -> CommandResult {
    CommandResult(
        stdout: Data(stdout.utf8),
        stderr: Data(),
        terminationStatus: 0,
        terminationReason: .exit
    )
}

private func storedZIP(entries: [(String, Data, UInt32)]) -> Data {
    var local = Data()
    var central = Data()
    for (name, bytes, mode) in entries {
        let nameData = Data(name.utf8)
        let offset = UInt32(local.count)
        let crc = crc32(bytes)
        local.appendLE(UInt32(0x04034b50))
        local.appendLE(UInt16(20))
        local.appendLE(UInt16(0x0800))
        local.appendLE(UInt16(0))
        local.appendLE(UInt16(0)); local.appendLE(UInt16(0))
        local.appendLE(crc)
        local.appendLE(UInt32(bytes.count)); local.appendLE(UInt32(bytes.count))
        local.appendLE(UInt16(nameData.count)); local.appendLE(UInt16(0))
        local.append(nameData); local.append(bytes)

        central.appendLE(UInt32(0x02014b50))
        central.appendLE(UInt16(0x0314)); central.appendLE(UInt16(20))
        central.appendLE(UInt16(0x0800)); central.appendLE(UInt16(0))
        central.appendLE(UInt16(0)); central.appendLE(UInt16(0))
        central.appendLE(crc)
        central.appendLE(UInt32(bytes.count)); central.appendLE(UInt32(bytes.count))
        central.appendLE(UInt16(nameData.count)); central.appendLE(UInt16(0)); central.appendLE(UInt16(0))
        central.appendLE(UInt16(0)); central.appendLE(UInt16(0))
        central.appendLE(mode << 16); central.appendLE(offset)
        central.append(nameData)
    }
    var archive = local
    archive.append(central)
    archive.appendLE(UInt32(0x06054b50))
    archive.appendLE(UInt16(0)); archive.appendLE(UInt16(0))
    archive.appendLE(UInt16(entries.count)); archive.appendLE(UInt16(entries.count))
    archive.appendLE(UInt32(central.count)); archive.appendLE(UInt32(local.count))
    archive.appendLE(UInt16(0))
    return archive
}

private func crc32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xffff_ffff
    for byte in data {
        crc ^= UInt32(byte)
        for _ in 0..<8 {
            crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb8_8320 : 0)
        }
    }
    return crc ^ 0xffff_ffff
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}
