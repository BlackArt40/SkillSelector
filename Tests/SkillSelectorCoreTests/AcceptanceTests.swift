import Foundation
import SwiftData
import XCTest
@testable import SkillSelectorCore

@MainActor
final class AcceptanceTests: XCTestCase {
    func testTemporaryHomeDiscoveryRefreshAndDescriptionPrecedence() async throws {
        let fixture = try AcceptanceFixture()
        let container = try fixture.makeContainer()
        let bookmarkAdapter = AcceptanceBookmarkAdapter()
        let bookmarks = BookmarkStore(container: container, adapter: bookmarkAdapter)
        _ = try bookmarks.save(url: fixture.home, kind: .home)
        _ = try bookmarks.save(url: fixture.parentProject, kind: .project)
        _ = try bookmarks.save(url: fixture.childProject, kind: .project)
        let index = SkillIndex(container: container)
        let refresher = IndexRefresher(
            registry: BuiltInAgentRegistry.make(),
            bookmarks: bookmarks,
            index: index
        )

        let startup = try await refresher.refresh(.startup)
        var skills = try index.skills()

        XCTAssertEqual(startup.added, 6)
        XCTAssertEqual(skills.count, 6)
        XCTAssertEqual(Set(skills.map(\.path)), fixture.expectedInstallationPaths)
        XCTAssertFalse(skills.contains { $0.name == "ignored" })

        let shared = try XCTUnwrap(skills.first { $0.path == fixture.sharedSkill.path })
        XCTAssertEqual(shared.agentIDs, [])
        XCTAssertEqual(skills.filter { $0.path == shared.path }.count, 1)
        XCTAssertFalse(try XCTUnwrap(skills.first {
            $0.path == fixture.brokenSkill.path
        }).parseDiagnostics.isEmpty)
        let linked = try XCTUnwrap(skills.first { $0.path == fixture.linkedSkill.path })
        XCTAssertEqual(linked.resolvedTarget, fixture.sharedSkill.path)

        _ = try index.setEnrichedDescription(
            path: shared.path,
            value: "Remote description",
            provenance: "fixture"
        )
        XCTAssertEqual(
            DescriptionResolver.resolve(DescriptionCandidates(snapshot: try XCTUnwrap(
                index.skills().first { $0.path == shared.path }
            ))),
            EffectiveDescription(text: "Local description", source: .local)
        )
        _ = try index.setCustomDescription(path: shared.path, value: "  Custom description  ")
        XCTAssertEqual(
            DescriptionResolver.resolve(DescriptionCandidates(snapshot: try XCTUnwrap(
                index.skills().first { $0.path == shared.path }
            ))),
            EffectiveDescription(text: "Custom description", source: .custom)
        )

        try FileManager.default.removeItem(at: fixture.childProject)
        let manual = try await refresher.refresh(.manual)
        skills = try index.skills()

        XCTAssertEqual(manual.removed, 0)
        XCTAssertEqual(manual.unavailable, 1)
        XCTAssertEqual(skills.first {
            $0.path == fixture.childSkill.path
        }?.availability, .unavailable)
        XCTAssertTrue(bookmarkAdapter.startedURLs.allSatisfy {
            $0.path.hasPrefix(fixture.root.path)
        })
        XCTAssertEqual(bookmarkAdapter.startedURLs.count, bookmarkAdapter.stoppedURLs.count)
    }

    func testFileOperationsRequireAuthorizationConfirmationAndExplicitConflictChoice() async throws {
        let fixture = try AcceptanceFixture()
        let destinationRoot = fixture.home.appending(path: ".codex/skills")
        let existing = destinationRoot.appending(path: "shared")
        try fixture.writeSkill(at: existing, name: "shared", description: "Existing destination")
        let trash = AcceptanceTrash(root: fixture.trash)
        let roots = [
            AuthorizedRootSnapshot(id: "home", url: fixture.home, kind: .home),
            AuthorizedRootSnapshot(id: "parent", url: fixture.parentProject, kind: .project),
        ]
        let fileOperator = SkillFileOperator(
            registryProvider: { BuiltInAgentRegistry.make() },
            authorizedRootsProvider: { roots },
            indexedAliasesProvider: {
                [IndexedSkillAlias(
                    path: fixture.linkedSkill.path,
                    resolvedTarget: fixture.sharedSkill.path,
                    rootIDs: ["home"]
                )]
            },
            trash: trash
        )

        XCTAssertThrowsError(try fileOperator.plan(fixture.fileRequest(
            .copy,
            source: fixture.copiedSkill,
            destination: destinationRoot,
            name: "shared",
            conflict: .fail
        ))) { error in
            XCTAssertEqual(error as? SkillFileOperatorError, .destinationConflict)
        }

        let cancel = try fileOperator.plan(fixture.fileRequest(
            .copy,
            source: fixture.copiedSkill,
            destination: destinationRoot,
            name: "shared",
            conflict: .cancel
        ))
        let cancelled = try await fileOperator.execute(cancel, confirmation: cancel.confirmationToken)
        XCTAssertEqual(cancelled.outcome, .cancelled)
        XCTAssertEqual(try fixture.description(at: existing), "Existing destination")

        let keepBoth = try fileOperator.plan(fixture.fileRequest(
            .copy,
            source: fixture.copiedSkill,
            destination: destinationRoot,
            name: "shared",
            conflict: .keepBoth
        ))
        let kept = try await fileOperator.execute(keepBoth, confirmation: keepBoth.confirmationToken)
        XCTAssertNotEqual(kept.destinationURL, existing)
        XCTAssertEqual(try fixture.description(at: try XCTUnwrap(kept.destinationURL)), "Fixture description")

        let replaceTarget = destinationRoot.appending(path: "replace-me")
        try fixture.writeSkill(at: replaceTarget, name: "copied", description: "Old copy")
        let replace = try fileOperator.plan(fixture.fileRequest(
            .copy,
            source: fixture.copiedSkill,
            destination: destinationRoot,
            name: "replace-me",
            conflict: .replace
        ))
        await XCTAssertThrowsAcceptanceError(
            try await fileOperator.execute(replace, confirmation: replace.confirmationToken),
            expected: SkillFileOperatorError.replacementConfirmationRequired
        )
        _ = try await fileOperator.execute(
            replace,
            confirmation: replace.confirmationToken,
            replacementConfirmation: replace.replacementConfirmationToken
        )
        XCTAssertEqual(try fixture.description(at: replaceTarget), "Fixture description")
        XCTAssertEqual(trash.movedItems, [replaceTarget.standardizedFileURL])

        let move = try fileOperator.plan(fixture.fileRequest(
            .move,
            source: fixture.parentSkill,
            destination: destinationRoot,
            name: "moved-parent"
        ))
        let moved = try await fileOperator.execute(move, confirmation: move.confirmationToken)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.parentSkill.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(moved.destinationURL).path))

        let link = try fileOperator.plan(fixture.fileRequest(
            .createSymbolicLink,
            source: fixture.sharedSkill,
            destination: destinationRoot,
            name: "new-link"
        ))
        let linked = try await fileOperator.execute(link, confirmation: link.confirmationToken)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: try XCTUnwrap(linked.destinationURL).path),
            link.linkTarget
        )

        let delete = try fileOperator.plan(fixture.fileRequest(
            .delete,
            source: fixture.linkedSkill,
            resolved: fixture.sharedSkill
        ))
        _ = try await fileOperator.execute(delete, confirmation: delete.confirmationToken)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.sharedSkill.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.linkedSkill.path))
        XCTAssertEqual(trash.movedItems.last?.path, fixture.linkedSkill.standardizedFileURL.path)

        let unauthorized = fixture.root.appending(path: "outside/demo")
        try fixture.writeSkill(at: unauthorized, name: "outside")
        XCTAssertThrowsError(try fileOperator.plan(fixture.fileRequest(
            .copy,
            source: unauthorized,
            destination: destinationRoot
        ))) { error in
            XCTAssertEqual(error as? SkillFileOperatorError, .unauthorizedSource)
        }
    }

    func testUpdateRejectsHostilePackagesWarnsForLocalChangesAndReplacesAtomically() async throws {
        let fixture = try AcceptanceFixture()
        let validator = PackageValidator()
        XCTAssertThrowsError(try validator.validateArchiveEntries([
            PackageArchiveEntry(path: "../escape", kind: .regularFile, byteCount: 1),
        ])) { error in
            XCTAssertEqual(error as? PackageValidationError, .unsafeArchivePath("../escape"))
        }
        XCTAssertThrowsError(try validator.validateArchiveEntries([
            PackageArchiveEntry(
                path: "references/escape",
                kind: .symbolicLink,
                byteCount: 12,
                symbolicLinkTarget: "../../escape"
            ),
        ])) { error in
            XCTAssertEqual(error as? PackageValidationError, .escapingSymbolicLink("references/escape"))
        }

        let remote = fixture.root.appending(path: "remote/shared")
        try fixture.writeSkill(at: remote, name: "shared", description: "Remote update")
        let executionMarker = fixture.root.appending(path: "downloaded-content-ran")
        let downloadedScript = remote.appending(path: "scripts/postinstall")
        try fixture.writeExecutable("#!/bin/sh\ntouch \"\(executionMarker.path)\"\n", to: downloadedScript)
        let indexedDigest = try PackageDigest.compute(at: fixture.sharedSkill)
        let trash = AcceptanceTrash(root: fixture.trash)
        let refreshes = AcceptanceRefreshRecorder()
        let updater = SkillUpdater(
            fetcher: AcceptancePackageFetcher(packageURL: remote),
            replacer: SkillFileOperatorPackageReplacer(trash: trash),
            aliasesProvider: {
                [
                    IndexedSkillAlias(path: fixture.sharedSkill.path, resolvedTarget: nil, rootIDs: ["home"]),
                    IndexedSkillAlias(
                        path: fixture.linkedSkill.path,
                        resolvedTarget: fixture.sharedSkill.path,
                        rootIDs: ["home"]
                    ),
                ]
            },
            refresh: { rootIDs in await refreshes.record(rootIDs) }
        )
        let source = try SkillSource.github(
            repository: "acme/skills",
            subdirectory: "skills/shared",
            reference: .branch("main"),
            provenance: .rememberedBinding
        )
        let request = UpdateRequest(
            installationURL: fixture.sharedSkill,
            entryFilename: "SKILL.md",
            requiredName: "shared",
            source: source,
            indexedDigest: indexedDigest,
            authorizedRootURLs: [fixture.home],
            refreshRootIDs: ["home"]
        )

        let proposal = try await updater.check(request)

        XCTAssertTrue(proposal.changes.contains { $0.path == "SKILL.md" && $0.kind == .changed })
        XCTAssertTrue(proposal.changes.contains { $0.path == "scripts/postinstall" && $0.kind == .added })
        XCTAssertEqual(proposal.actualTargetURL.path, fixture.sharedSkill.path)
        XCTAssertEqual(Set(proposal.affectedAliases.map(\.path)), [fixture.linkedSkill.path])
        XCTAssertFalse(FileManager.default.fileExists(atPath: executionMarker.path))

        try fixture.write("local edit\n", to: fixture.sharedSkill.appending(path: "notes.txt"))
        let warned = try await updater.apply(proposal.confirmed())
        guard case .localChangesRequireConfirmation(let warning) = warned else {
            return XCTFail("Expected an additional local-change confirmation")
        }
        XCTAssertTrue(warning.hasIndexedLocalChanges)
        XCTAssertTrue(trash.movedItems.isEmpty)

        let result = try await updater.apply(warning.confirmed(allowLocalChanges: true))

        guard case .updated(_, let rootIDs) = result else {
            return XCTFail("Expected an atomic update")
        }
        XCTAssertEqual(rootIDs, ["home"])
        XCTAssertEqual(try fixture.description(at: fixture.sharedSkill), "Remote update")
        XCTAssertEqual(try fixture.description(at: fixture.linkedSkill), "Remote update")
        XCTAssertEqual(trash.movedItems.map(\.path), [fixture.sharedSkill.path])
        let recordedRefreshes = await refreshes.recordedValues()
        XCTAssertEqual(recordedRefreshes, [["home"]])
        XCTAssertFalse(FileManager.default.fileExists(atPath: executionMarker.path))
    }
}

private final class AcceptanceFixture: @unchecked Sendable {
    let root: URL
    let home: URL
    let parentProject: URL
    let childProject: URL
    let sharedSkill: URL
    let copiedSkill: URL
    let parentSkill: URL
    let childSkill: URL
    let brokenSkill: URL
    let linkedSkill: URL
    let trash: URL
    let fakeGH: URL
    let fakeNPM: URL
    let ghLog: URL
    let npmLog: URL
    var expectedInstallationPaths: Set<String> {
        Set([sharedSkill, copiedSkill, parentSkill, childSkill, brokenSkill, linkedSkill].map(\.path))
    }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "SkillSelectorAcceptance-\(UUID().uuidString)")
        home = root.appending(path: "home")
        parentProject = home.appending(path: "projects/parent")
        childProject = parentProject.appending(path: "packages/child")
        sharedSkill = home.appending(path: ".agents/skills/shared")
        copiedSkill = home.appending(path: ".cursor/skills/copied")
        parentSkill = parentProject.appending(path: "apps/main/.cursor/skills/parent")
        childSkill = childProject.appending(path: "Sources/.agents/skills/child")
        brokenSkill = home.appending(path: ".cursor/skills/broken")
        linkedSkill = home.appending(path: ".codex/skills/linked")
        trash = root.appending(path: "trash")
        fakeGH = root.appending(path: "bin/gh")
        fakeNPM = root.appending(path: "bin/npm")
        ghLog = root.appending(path: "gh-invocations.log")
        npmLog = root.appending(path: "npm-invocations.log")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)

        try writeSkill(at: sharedSkill, name: "shared", description: "Local description")
        try writeSkill(at: copiedSkill, name: "copied")
        try writeSkill(at: parentSkill, name: "parent")
        try writeSkill(at: childSkill, name: "child")
        try writeSkill(at: parentProject.appending(path: "node_modules/pkg/.cursor/skills/ignored"), name: "ignored")
        try write(
            "---\nname: [broken\n---\n# Broken",
            to: brokenSkill.appending(path: "SKILL.md")
        )

        try FileManager.default.createDirectory(
            at: linkedSkill.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: linkedSkill, withDestinationURL: sharedSkill)
        try writeExecutable(
            """
            #!/bin/sh
            (IFS='|'; printf '%s\\n' "$*" >> "\(ghLog.path)")
            if [ "$1" = "search" ]; then
              printf '%s' '[{"path":"skills/demo/SKILL.md","repository":{"nameWithOwner":"acme/skills"},"url":"https://github.com/acme/skills/blob/main/skills/demo/SKILL.md"}]'
            elif [ "$2" = "repos/acme/skills" ]; then
              printf '%s' '{"description":"Repository fallback.","html_url":"https://github.com/acme/skills","default_branch":"main"}'
            else
              printf '%b' '---\\nname: demo\\ndescription: Exact remote description.\\n---\\n'
            fi
            """,
            to: fakeGH
        )
        try writeExecutable(
            """
            #!/bin/sh
            (IFS='|'; printf '%s\\n' "$*" >> "\(npmLog.path)")
            if [ "$1" = "search" ]; then
              printf '%s' '[{"name":"@acme/demo"}]'
            else
              printf '%s' '{"name":"@acme/demo","description":"Exact npm description."}'
            fi
            """,
            to: fakeNPM
        )
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: SkillRecord.self,
            AuthorizedRootRecord.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    func writeSkill(at directory: URL, name: String, description: String = "Fixture description") throws {
        try write(
            "---\nname: \(name)\ndescription: \(description)\n---\n\n# \(name)\n",
            to: directory.appending(path: "SKILL.md")
        )
    }

    func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    func writeExecutable(_ contents: String, to url: URL) throws {
        try write(contents, to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    func commandInvocations(at url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
    }

    func description(at skill: URL) throws -> String? {
        FrontmatterParser.parse(
            try String(contentsOf: skill.appending(path: "SKILL.md"), encoding: .utf8)
        ).description
    }

    func fileRequest(
        _ operation: FileOperationKind,
        source: URL,
        resolved: URL? = nil,
        destination: URL? = nil,
        name: String? = nil,
        conflict: FileConflictPolicy = .fail
    ) -> FileOperationRequest {
        FileOperationRequest(
            operation: operation,
            sourceURL: source,
            resolvedSourceURL: resolved,
            sourceEntryFilename: "SKILL.md",
            destinationRootURL: destination,
            proposedName: name,
            conflictPolicy: conflict,
            metadata: SkillAppMetadata(customDescription: "Fixture custom", sourceBinding: "github:acme/demo:.")
        )
    }
}

private final class AcceptanceBookmarkAdapter: BookmarkDataCreating, @unchecked Sendable {
    private let lock = NSLock()
    private var started: [URL] = []
    private var stopped: [URL] = []

    var startedURLs: [URL] { lock.withLock { started } }
    var stoppedURLs: [URL] { lock.withLock { stopped } }

    func createBookmarkData(for url: URL) throws -> Data { Data(url.path.utf8) }

    func resolveBookmarkData(_ data: Data) throws -> BookmarkResolution {
        BookmarkResolution(
            url: URL(fileURLWithPath: String(decoding: data, as: UTF8.self)),
            isStale: false
        )
    }

    func startAccessing(_ url: URL) -> Bool {
        lock.withLock { started.append(url) }
        return true
    }

    func stopAccessing(_ url: URL) {
        lock.withLock { stopped.append(url) }
    }
}

private final class AcceptanceTrash: FileOperationTrashing {
    let root: URL
    private(set) var movedItems: [URL] = []

    init(root: URL) { self.root = root }

    func trashItem(at url: URL) throws -> URL {
        let destination = root.appending(path: "\(UUID().uuidString)-\(url.lastPathComponent)")
        try FileManager.default.moveItem(at: url, to: destination)
        movedItems.append(url.standardizedFileURL)
        return destination
    }
}

private final class AcceptancePackageFetcher: SkillPackageFetching, @unchecked Sendable {
    let packageURL: URL

    init(packageURL: URL) { self.packageURL = packageURL }

    func fetch(_ source: SkillSource, into destination: URL) async throws -> FetchedSkillPackage {
        try FileManager.default.copyItem(at: packageURL, to: destination)
        return FetchedSkillPackage(packageURL: destination, resolvedReference: "fixture-main")
    }
}

private actor AcceptanceRefreshRecorder {
    private var values: [[String]] = []

    func record(_ rootIDs: [String]) { values.append(rootIDs) }
    func recordedValues() -> [[String]] { values }
}

@MainActor
private func XCTAssertThrowsAcceptanceError<T, E: Error & Equatable>(
    _ expression: @autoclosure () async throws -> T,
    expected: E,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected \(expected)", file: file, line: line)
    } catch {
        XCTAssertEqual(error as? E, expected, file: file, line: line)
    }
}


