import Darwin
import Foundation
import XCTest
@testable import SkillSelectorCore

final class SkillUpdaterTests: XCTestCase {
    func testBindingRoundTripsReferenceKindAndValueAndReadsLegacyBinding() throws {
        let source = try SkillSource.github(
            repository: "acme/skills",
            subdirectory: "skills/demo",
            reference: .tag("v1.2.3"),
            provenance: .rememberedBinding
        )
        let remembered = try SkillSource.remembered(binding: source.binding)
        XCTAssertEqual(remembered.reference, .tag("v1.2.3"))
        XCTAssertEqual(
            try SkillSource.remembered(binding: "github:acme/skills:skills/demo").reference,
            .branch("HEAD")
        )
        XCTAssertEqual(
            try SkillSource.remembered(binding: "github:acme/skills:skills/demo:commit:0123456789abcdef").reference,
            .commit("0123456789abcdef")
        )
    }

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

    func testDiscoveryFindsEmbeddedMetadataAndContainingGitRepository() throws {
        let repository = temporaryDirectory()
        let skill = repository.appending(path: "skills/demo")
        let git = repository.appending(path: ".git")
        defer { try? FileManager.default.removeItem(at: repository) }
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try Data("[remote \"origin\"]\n  url = git@github.com:acme/repository.git\n".utf8)
            .write(to: git.appending(path: "config"))
        try Data("ref: refs/heads/develop\n".utf8).write(to: git.appending(path: "HEAD"))
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        let text = """
        ---
        name: demo
        description: test
        source: https://github.com/acme/embedded
        subdirectory: packages/demo
        tag: v2
        ---
        """
        try Data(text.utf8).write(to: skill.appending(path: "SKILL.md"))

        let candidates = SkillSourceDiscovery().candidates(
            for: skill,
            document: FrontmatterParser.parse(text)
        )
        XCTAssertEqual(candidates.map(\.binding), [
            "github:acme/embedded:packages/demo:tag:v2",
            "github:acme/repository:skills/demo:branch:develop",
        ])
        XCTAssertEqual(candidates.map(\.provenance), [.embeddedMetadata, .containingGitRemote])
    }

    func testDiscoveryReadsRelativeWorktreeGitDirectoryAndCommonRepositoryFiles() throws {
        let parent = temporaryDirectory()
        let repository = parent.appending(path: "repository")
        let commonGit = repository.appending(path: ".git")
        let worktreeGit = commonGit.appending(path: "worktrees/demo")
        let worktree = parent.appending(path: "worktree")
        let skill = worktree.appending(path: "skills/demo")
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: worktreeGit, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try Data("[remote \"origin\"]\n  url = https://github.com/acme/worktree.git\n".utf8)
            .write(to: commonGit.appending(path: "config"))
        try Data("ref: refs/heads/release\n".utf8).write(to: worktreeGit.appending(path: "HEAD"))
        try Data("../..\n".utf8).write(to: worktreeGit.appending(path: "commondir"))
        try Data("gitdir: ../repository/.git/worktrees/demo\n".utf8)
            .write(to: worktree.appending(path: ".git"))

        let source = try XCTUnwrap(SkillSource.containingGitRepository(for: skill))

        XCTAssertEqual(source.binding, "github:acme/worktree:skills/demo:branch:release")
    }

    func testDiscoveryReadsAbsoluteSubmoduleGitDirectory() throws {
        let parent = temporaryDirectory()
        let module = parent.appending(path: "checkout/modules/demo")
        let gitDirectory = parent.appending(path: "checkout/.git/modules/demo")
        let skill = module.appending(path: "skills/nested")
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try Data("[remote \"origin\"]\n  url = git@github.com:acme/submodule.git\n".utf8)
            .write(to: gitDirectory.appending(path: "config"))
        try Data("ref: refs/heads/custom\n".utf8).write(to: gitDirectory.appending(path: "HEAD"))
        try Data("gitdir: \(gitDirectory.path)\n".utf8).write(to: module.appending(path: ".git"))

        let source = try XCTUnwrap(SkillSource.containingGitRepository(for: skill))

        XCTAssertEqual(source.binding, "github:acme/submodule:skills/nested:branch:custom")
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

    func testGitHubFetcherValidatesAllDownloadedLinkTargetsBeforeMaterializing() async throws {
        let skill = "---\nname: demo\ndescription: test\n---\n"
        let tree = #"{"tree":[{"path":"skills/demo/SKILL.md","mode":"100644","type":"blob","sha":"skill","size":41},{"path":"skills/demo/current","mode":"120000","type":"blob","sha":"link","size":8}],"truncated":false}"#
        let destination = temporaryDirectory().appending(path: "package")
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        let runner = UpdateFixtureRunner(results: [
            commandResult("abcdef0123456789\n"), commandResult(tree),
            commandResult(skill), commandResult("SKILL.md"),
        ])

        _ = try await LiveSkillPackageFetcher(
            executableURL: URL(fileURLWithPath: "/usr/bin/gh"),
            runner: runner
        ).fetch(source(), into: destination)

        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: destination.appending(path: "current").path),
            "SKILL.md"
        )
    }

    func testGitHubFetcherRejectsEscapingLinkWithoutPartialWrites() async throws {
        let skill = "---\nname: demo\ndescription: test\n---\n"
        let tree = #"{"tree":[{"path":"skills/demo/SKILL.md","mode":"100644","type":"blob","sha":"skill","size":41},{"path":"skills/demo/z-escape","mode":"120000","type":"blob","sha":"link","size":10}],"truncated":false}"#
        let destination = temporaryDirectory().appending(path: "package")
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }
        let runner = UpdateFixtureRunner(results: [
            commandResult("abcdef0123456789\n"), commandResult(tree),
            commandResult(skill), commandResult("../outside"),
        ])

        await assertAsyncThrows(try await LiveSkillPackageFetcher(
            executableURL: URL(fileURLWithPath: "/usr/bin/gh"),
            runner: runner
        ).fetch(source(), into: destination))

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
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

    func testApplyDisclosesIndexedLinksWhenRequestUsesRealDirectory() async throws {
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
                IndexedSkillAlias(path: installed.path, resolvedTarget: nil, rootIDs: ["real"]),
                IndexedSkillAlias(path: first.path, resolvedTarget: installed.path, rootIDs: ["a"]),
                IndexedSkillAlias(path: second.path, resolvedTarget: installed.path, rootIDs: ["b"]),
            ] }
        )
        let proposal = try await updater.check(UpdateRequest(
            installationURL: installed,
            entryFilename: "SKILL.md",
            requiredName: "demo",
            source: source(),
            indexedDigest: try PackageDigest.compute(at: installed),
            authorizedRootURLs: [installed.deletingLastPathComponent(), linkParent]
        ))
        XCTAssertEqual(proposal.affectedAliases.map(\.path), [first.path, second.path])
        XCTAssertEqual(Set(proposal.affectedAliases.flatMap(\.rootIDs)), ["a", "b"])
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

    func testZIPRejectsInvalidLinkTargetsBeforeDestinationCreation() throws {
        let destination = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: destination) }
        let archive = storedZIP(entries: [
            ("SKILL.md", Data("safe".utf8), 0o100644),
            ("broken", Data([0xff, 0xfe]), 0o120777),
        ])
        XCTAssertThrowsError(try SafeZIPExtractor.extract(
            archive,
            into: destination,
            validator: PackageValidator()
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testPackageDigestStreamsAndEnforcesPerFileTotalAndCountLimits() throws {
        let root = try makeSkill(name: "demo")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try Data(repeating: 0x41, count: 120).write(to: root.appending(path: "large.bin"))
        XCTAssertThrowsError(try PackageDigest.compute(
            at: root,
            limits: PackageDigestLimits(maximumFileBytes: 100, maximumTotalBytes: 1_000, maximumFileCount: 10)
        )) { XCTAssertEqual($0 as? PackageDigestError, .fileTooLarge("large.bin")) }
        try FileManager.default.removeItem(at: root.appending(path: "large.bin"))
        try Data(repeating: 0x41, count: 9).write(to: root.appending(path: "a.bin"))
        try Data(repeating: 0x42, count: 9).write(to: root.appending(path: "b.bin"))
        XCTAssertThrowsError(try PackageDigest.compute(
            at: root,
            limits: PackageDigestLimits(maximumFileBytes: 100, maximumTotalBytes: 10, maximumFileCount: 10)
        )) { XCTAssertEqual($0 as? PackageDigestError, .totalBytesExceeded) }
        XCTAssertThrowsError(try PackageDigest.compute(
            at: root,
            limits: PackageDigestLimits(maximumFileBytes: 100, maximumTotalBytes: 100, maximumFileCount: 1)
        )) { XCTAssertEqual($0 as? PackageDigestError, .tooManyFiles) }
    }

    func testPackageDigestStopsTraversalAsSoonAsEntryCountExceedsLimit() throws {
        let root = try makeSkill(name: "demo")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        for index in 0..<100 {
            try Data().write(to: root.appending(path: "entry-\(index)"))
        }
        var observedEntries = 0

        XCTAssertThrowsError(try PackageDigest.compute(
            at: root,
            limits: PackageDigestLimits(maximumFileBytes: 100, maximumTotalBytes: 100, maximumFileCount: 10),
            hooks: PackageDigestHooks(entryDiscovered: { observedEntries += 1 })
        )) { XCTAssertEqual($0 as? PackageDigestError, .tooManyFiles) }
        XCTAssertLessThanOrEqual(observedEntries, 10)
    }

    func testPackageDigestRejectsPathReplacedBySymlinkBeforeOpen() throws {
        let root = try makeSkill(name: "demo")
        let outside = root.deletingLastPathComponent().appending(path: "outside")
        let victim = root.appending(path: "victim.txt")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try Data("inside".utf8).write(to: victim)
        try Data("outside".utf8).write(to: outside)

        XCTAssertThrowsError(try PackageDigest.compute(
            at: root,
            hooks: PackageDigestHooks(beforeFileOpen: { path in
                guard path == "victim.txt" else { return }
                try FileManager.default.removeItem(at: victim)
                try FileManager.default.createSymbolicLink(at: victim, withDestinationURL: outside)
            })
        )) { XCTAssertEqual($0 as? PackageDigestError, .sourceChanged("victim.txt")) }
    }

    func testPackageDigestRejectsSameSizeInPlaceMutationAfterInitialDescriptorStatus() throws {
        let root = try makeSkill(name: "demo")
        let victim = root.appending(path: "victim.txt")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try Data("before".utf8).write(to: victim)

        XCTAssertThrowsError(try PackageDigest.compute(
            at: root,
            hooks: PackageDigestHooks(afterBeforeReadStatus: { path in
                guard path == "victim.txt" else { return }
                let handle = try FileHandle(forWritingTo: victim)
                try handle.write(contentsOf: Data("after!".utf8))
                try handle.close()
            })
        )) { XCTAssertEqual($0 as? PackageDigestError, .sourceChanged("victim.txt")) }
    }

    func testPackageDigestRejectsPathReplacementAfterInitialDescriptorStatus() throws {
        let root = try makeSkill(name: "demo")
        let victim = root.appending(path: "victim.txt")
        let replacement = root.deletingLastPathComponent().appending(path: "replacement.txt")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try Data("inside".utf8).write(to: victim)
        try Data("inside".utf8).write(to: replacement)

        XCTAssertThrowsError(try PackageDigest.compute(
            at: root,
            hooks: PackageDigestHooks(afterBeforeReadStatus: { path in
                guard path == "victim.txt" else { return }
                try FileManager.default.removeItem(at: victim)
                try FileManager.default.moveItem(at: replacement, to: victim)
            })
        )) { XCTAssertEqual($0 as? PackageDigestError, .sourceChanged("victim.txt")) }
    }

    func testPackageDigestStopsReadingSingleDirectoryBeforeCollectingBeyondLimit() throws {
        let root = try makeSkill(name: "demo")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        for index in 0..<100 {
            try FileManager.default.createDirectory(
                at: root.appending(path: "empty-\(index)"),
                withIntermediateDirectories: false
            )
        }
        var observedChildren = 0

        XCTAssertThrowsError(try PackageDigest.compute(
            at: root,
            limits: PackageDigestLimits(maximumFileBytes: 100, maximumTotalBytes: 100, maximumFileCount: 10),
            hooks: PackageDigestHooks(directoryChildDiscovered: { observedChildren += 1 })
        )) { XCTAssertEqual($0 as? PackageDigestError, .tooManyFiles) }
        XCTAssertEqual(observedChildren, 11)
    }

    func testPackageDigestCountsEmptyDirectoriesAndDistinguishesTheirLayout() throws {
        let root = try makeSkill(name: "demo")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let baseline = try PackageDigest.compute(at: root)
        try FileManager.default.createDirectory(
            at: root.appending(path: "empty/child"),
            withIntermediateDirectories: true
        )

        XCTAssertNotEqual(baseline, try PackageDigest.compute(at: root))
        XCTAssertTrue(try PackageManifest.read(at: root).contains {
            $0.path == "empty" && $0.kind == .directory
        })
        XCTAssertThrowsError(try PackageDigest.compute(
            at: root,
            limits: PackageDigestLimits(maximumFileBytes: 100, maximumTotalBytes: 100, maximumFileCount: 2)
        )) { XCTAssertEqual($0 as? PackageDigestError, .tooManyFiles) }
    }

    func testPackageDigestStopsWhenOpenFileGrowsPastPerFileLimitAfterInitialDescriptorStatus() throws {
        let root = try makeSkill(name: "demo")
        let growing = root.appending(path: "growing.bin")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try Data(repeating: 0x41, count: 4).write(to: growing)

        XCTAssertThrowsError(try PackageDigest.compute(
            at: root,
            limits: PackageDigestLimits(maximumFileBytes: 64, maximumTotalBytes: 1_000, maximumFileCount: 10),
            hooks: PackageDigestHooks(afterBeforeReadStatus: { path in
                guard path == "growing.bin" else { return }
                let handle = try FileHandle(forWritingTo: growing)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(repeating: 0x42, count: 80))
                try handle.close()
            })
        )) { XCTAssertEqual($0 as? PackageDigestError, .fileTooLarge("growing.bin")) }
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

private func assertAsyncThrows<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {}
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
