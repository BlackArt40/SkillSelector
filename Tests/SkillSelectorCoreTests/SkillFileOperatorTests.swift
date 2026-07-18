import Foundation
import XCTest
@testable import SkillSelectorCore

final class SkillFileOperatorTests: XCTestCase {
    private var fixture: URL!
    private var home: URL!
    private var sourceRoot: URL!
    private var destinationRoot: URL!
    private var trashRoot: URL!
    private var roots: [AuthorizedRootSnapshot]!
    private var registry: AgentRegistry!
    private var trash: RecordingTrash!

    override func setUpWithError() throws {
        fixture = FileManager.default.temporaryDirectory
            .appending(path: "SkillFileOperatorTests-\(UUID().uuidString)")
        home = fixture.appending(path: "home")
        sourceRoot = home.appending(path: ".agents/skills")
        destinationRoot = home.appending(path: ".codex/skills")
        trashRoot = fixture.appending(path: "trash")
        for directory in [sourceRoot!, destinationRoot!, trashRoot!] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        roots = [AuthorizedRootSnapshot(id: "home", url: home, kind: .home)]
        registry = AgentRegistry(definitions: [
            AgentDefinition(
                id: "codex",
                displayName: "Codex",
                globalRoots: ["~/.codex/skills"],
                projectPatterns: [".codex/skills"]
            ),
        ],
        sharedGlobalRoots: ["~/.agents/skills"],
        sharedProjectPatterns: [".agents/skills"])
        trash = RecordingTrash(root: trashRoot)
    }

    override func tearDownWithError() throws {
        if let fixture { try? FileManager.default.removeItem(at: fixture) }
    }

    func testCopyPlansWithoutMutationAndExecutesWithSingleUseToken() async throws {
        let source = try makeSkill(in: sourceRoot, name: "demo")
        let operatorUnderTest = makeOperator()

        let plan = try operatorUnderTest.plan(request(.copy, source: source, destination: destinationRoot))

        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationRoot.appending(path: "demo").path))
        XCTAssertEqual(plan.operation, .copy)
        XCTAssertEqual(plan.logicalSourceURL, source.standardizedFileURL)
        XCTAssertEqual(plan.resolvedSourceURL, source.standardizedFileURL)
        XCTAssertEqual(plan.destinationURL, destinationRoot.appending(path: "demo").standardizedFileURL)
        XCTAssertEqual(plan.destinationAgentIDs, ["codex"])
        XCTAssertEqual(plan.entryFilename, "SKILL.md")
        XCTAssertEqual(plan.metadataTransfer, .copy(SkillAppMetadata(customDescription: "Mine", sourceBinding: "github:x")))

        let result = try await operatorUnderTest.execute(
            plan,
            confirmation: plan.confirmationToken,
            replacementConfirmation: nil
        )
        XCTAssertEqual(result.outcome, .completed)
        XCTAssertEqual(try String(contentsOf: result.destinationURL!.appending(path: "SKILL.md")), "demo")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        await XCTAssertThrowsErrorAsync(
            try await operatorUnderTest.execute(plan, confirmation: plan.confirmationToken)
        ) { error in
            XCTAssertEqual(error as? SkillFileOperatorError, .invalidOrConsumedPlan)
        }
    }

    func testSharedDestinationIsRegisteredWithoutAgentAssociation() throws {
        let source = try makeSkill(in: destinationRoot, name: "owned")

        let plan = try makeOperator().plan(
            request(.copy, source: source, destination: sourceRoot)
        )

        XCTAssertEqual(plan.destinationURL, sourceRoot.appending(path: "owned").standardizedFileURL)
        XCTAssertEqual(plan.destinationAgentIDs, [])
        XCTAssertEqual(plan.entryFilename, "SKILL.md")
    }

    func testMovePreservesMetadataIntentAndMovesOnlyAfterConfirmation() async throws {
        let source = try makeSkill(in: sourceRoot, name: "move-me")
        let operatorUnderTest = makeOperator()
        let plan = try operatorUnderTest.plan(request(.move, source: source, destination: destinationRoot))

        XCTAssertEqual(plan.metadataTransfer, .move(SkillAppMetadata(customDescription: "Mine", sourceBinding: "github:x")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))

        let result = try await operatorUnderTest.execute(plan, confirmation: plan.confirmationToken)

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.destinationURL!.path))
        XCTAssertEqual(result.refreshRootIDs, ["home"])
    }

    func testDeleteMovesSymlinkOnlyToInjectedTrashAndDisclosesTarget() async throws {
        let target = try makeSkill(in: sourceRoot, name: "target")
        let link = sourceRoot.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let operatorUnderTest = makeOperator(indexed: [
            indexed(link, resolved: target), indexed(target),
        ])
        let plan = try operatorUnderTest.plan(request(.delete, source: link, resolved: target))

        XCTAssertEqual(plan.linkForm, .symbolicLink)
        XCTAssertEqual(plan.resolvedSourceURL, target.standardizedFileURL)
        XCTAssertEqual(plan.affectedIndexedAliases, [link.path])

        _ = try await operatorUnderTest.execute(plan, confirmation: plan.confirmationToken)

        XCTAssertFalse(FileManager.default.fileExists(atPath: link.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(trash.movedItems.map(\.lastPathComponent), ["link"])
    }

    func testDeleteCrossAuthorizedRootLinkTouchesOnlyThatLink() async throws {
        let linksProject = fixture.appending(path: "links-project")
        let targetsProject = fixture.appending(path: "targets-project")
        let linksRoot = linksProject.appending(path: ".agents/skills")
        let targetsRoot = targetsProject.appending(path: ".agents/skills")
        for directory in [linksRoot, targetsRoot] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let target = try makeSkill(in: targetsRoot, name: "target")
        let link = linksRoot.appending(path: "link")
        let otherLink = linksRoot.appending(path: "other-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try FileManager.default.createSymbolicLink(at: otherLink, withDestinationURL: target)
        roots.append(AuthorizedRootSnapshot(id: "links", url: linksProject, kind: .project))
        roots.append(AuthorizedRootSnapshot(id: "targets", url: targetsProject, kind: .project))
        let operatorUnderTest = makeOperator(indexed: [
            indexed(link, resolved: target, rootIDs: ["links"]),
            indexed(otherLink, resolved: target, rootIDs: ["links"]),
            indexed(target, rootIDs: ["targets"]),
        ])
        let plan = try operatorUnderTest.plan(request(.delete, source: link, resolved: target))

        XCTAssertEqual(plan.affectedIndexedAliases, [link.path])
        _ = try await operatorUnderTest.execute(plan, confirmation: plan.confirmationToken)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertTrue((try? otherLink.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true)
    }

    func testMovingLinkDoesNotReportOtherLinksToSameTarget() throws {
        let target = try makeSkill(in: sourceRoot, name: "target")
        let link = sourceRoot.appending(path: "link")
        let other = sourceRoot.appending(path: "other")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try FileManager.default.createSymbolicLink(at: other, withDestinationURL: target)
        let operatorUnderTest = makeOperator(indexed: [
            indexed(link, resolved: target),
            indexed(other, resolved: target),
        ])

        let plan = try operatorUnderTest.plan(
            request(.move, source: link, resolved: target, destination: destinationRoot)
        )

        XCTAssertEqual(plan.affectedIndexedAliases, [link.path])
    }

    func testCreateLinkUsesRelativeTargetWithinProjectAndAbsoluteAcrossRoots() throws {
        let project = fixture.appending(path: "project")
        let projectSourceRoot = project.appending(path: "packages/.agents/skills")
        let projectDestinationRoot = project.appending(path: "nested/.codex/skills")
        for directory in [projectSourceRoot, projectDestinationRoot] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let source = try makeSkill(in: projectSourceRoot, name: "demo")
        roots.append(AuthorizedRootSnapshot(id: "project", url: project, kind: .project))
        let operatorUnderTest = makeOperator()

        let relative = try operatorUnderTest.plan(
            request(.createSymbolicLink, source: source, destination: projectDestinationRoot)
        )
        let absolute = try operatorUnderTest.plan(
            request(.createSymbolicLink, source: source, destination: destinationRoot)
        )

        XCTAssertEqual(relative.linkTargetForm, .relative)
        XCTAssertFalse(try XCTUnwrap(relative.linkTarget).hasPrefix("/"))
        XCTAssertEqual(absolute.linkTargetForm, .absolute)
        XCTAssertEqual(absolute.linkTarget, source.path)
    }

    func testRejectsUnauthorizedAndAuthorizedButUnregisteredDestinations() throws {
        let source = try makeSkill(in: sourceRoot, name: "demo")
        let unregistered = home.appending(path: "Documents")
        let outside = fixture.appending(path: "outside")
        try FileManager.default.createDirectory(at: unregistered, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let operatorUnderTest = makeOperator()

        XCTAssertThrowsError(try operatorUnderTest.plan(request(.copy, source: source, destination: outside))) {
            XCTAssertEqual($0 as? SkillFileOperatorError, .unauthorizedDestination)
        }
        XCTAssertThrowsError(try operatorUnderTest.plan(request(.copy, source: source, destination: unregistered))) {
            XCTAssertEqual($0 as? SkillFileOperatorError, .unregisteredDestination)
        }
    }

    func testRegisteredRootValidationUsesComponentsAndSupportsNestedProjectPatterns() throws {
        let source = try makeSkill(in: sourceRoot, name: "demo")
        let project = fixture.appending(path: "project")
        let valid = project.appending(path: "nested/.agents/skills")
        let prefixLookalike = project.appending(path: "nested/.agents/skills-evil")
        for directory in [valid, prefixLookalike] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        roots.append(AuthorizedRootSnapshot(id: "project", url: project, kind: .project))
        let operatorUnderTest = makeOperator()

        XCTAssertEqual(
            try operatorUnderTest.plan(request(.copy, source: source, destination: valid)).destinationAgentIDs,
            []
        )
        XCTAssertThrowsError(try operatorUnderTest.plan(request(.copy, source: source, destination: prefixLookalike))) {
            XCTAssertEqual($0 as? SkillFileOperatorError, .unregisteredDestination)
        }
    }

    func testRejectsInvalidNamesAndNormalizedSiblingConflict() throws {
        let source = try makeSkill(in: sourceRoot, name: "demo")
        _ = try makeSkill(in: destinationRoot, name: "Caf\u{00e9}")
        let operatorUnderTest = makeOperator()

        for name in ["", ".", "..", "../escape", "nested/name", "nested\\name", ".skillselector-staging-x"] {
            XCTAssertThrowsError(
                try operatorUnderTest.plan(request(.copy, source: source, destination: destinationRoot, name: name))
            ) { XCTAssertEqual($0 as? SkillFileOperatorError, .invalidName(name)) }
        }
        XCTAssertThrowsError(
            try operatorUnderTest.plan(
                request(.copy, source: source, destination: destinationRoot, name: "Cafe\u{0301}", conflict: .fail)
            )
        ) { XCTAssertEqual($0 as? SkillFileOperatorError, .destinationConflict) }
    }

    func testKeepBothChoosesDeterministicSiblingWithoutMerging() async throws {
        let source = try makeSkill(in: sourceRoot, name: "demo")
        _ = try makeSkill(in: destinationRoot, name: "demo")
        _ = try makeSkill(in: destinationRoot, name: "demo copy")
        let operatorUnderTest = makeOperator()
        let plan = try operatorUnderTest.plan(
            request(.copy, source: source, destination: destinationRoot, conflict: .keepBoth)
        )

        XCTAssertEqual(plan.destinationURL?.lastPathComponent, "demo copy 2")
        _ = try await operatorUnderTest.execute(plan, confirmation: plan.confirmationToken)
        XCTAssertEqual(
            try String(contentsOf: destinationRoot.appending(path: "demo copy 2/SKILL.md")),
            "demo"
        )
    }

    func testReplaceRequiresDistinctTokenAndTrashesExistingDestination() async throws {
        let source = try makeSkill(in: sourceRoot, name: "demo", contents: "new")
        _ = try makeSkill(in: destinationRoot, name: "demo", contents: "old")
        let operatorUnderTest = makeOperator()
        let plan = try operatorUnderTest.plan(
            request(.copy, source: source, destination: destinationRoot, conflict: .replace)
        )

        XCTAssertTrue(plan.movesExistingDestinationToTrash)
        let replacement = try XCTUnwrap(plan.replacementConfirmationToken)
        await XCTAssertThrowsErrorAsync(
            try await operatorUnderTest.execute(plan, confirmation: plan.confirmationToken)
        ) { XCTAssertEqual($0 as? SkillFileOperatorError, .replacementConfirmationRequired) }
        await XCTAssertThrowsErrorAsync(
            try await operatorUnderTest.execute(
                plan,
                confirmation: plan.confirmationToken,
                replacementConfirmation: plan.confirmationToken
            )
        ) { XCTAssertEqual($0 as? SkillFileOperatorError, .invalidReplacementConfirmation) }

        _ = try await operatorUnderTest.execute(
            plan,
            confirmation: plan.confirmationToken,
            replacementConfirmation: replacement
        )
        XCTAssertEqual(try String(contentsOf: destinationRoot.appending(path: "demo/SKILL.md")), "new")
        XCTAssertEqual(trash.movedItems.map(\.lastPathComponent), ["demo"])
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: destinationRoot.path).contains {
            $0.hasPrefix(".skillselector-staging-")
        })
    }

    func testCancelPlanAndWrongTokenDoNotMutate() async throws {
        let source = try makeSkill(in: sourceRoot, name: "demo")
        _ = try makeSkill(in: destinationRoot, name: "demo")
        let operatorUnderTest = makeOperator()
        let cancelled = try operatorUnderTest.plan(
            request(.copy, source: source, destination: destinationRoot, conflict: .cancel)
        )

        XCTAssertEqual(cancelled.conflictPolicy, .cancel)
        await XCTAssertThrowsErrorAsync(
            try await operatorUnderTest.execute(cancelled, confirmation: ConfirmationToken())
        ) { XCTAssertEqual($0 as? SkillFileOperatorError, .invalidConfirmation) }
        let result = try await operatorUnderTest.execute(
            cancelled,
            confirmation: cancelled.confirmationToken
        )
        XCTAssertEqual(result.outcome, .cancelled)
        XCTAssertEqual(
            try String(contentsOf: destinationRoot.appending(path: "demo/SKILL.md")),
            "demo"
        )
    }

    func testDestinationAppearanceAndReplacementContentChangeInvalidatePlan() async throws {
        let source = try makeSkill(in: sourceRoot, name: "demo")
        let appearedOperator = makeOperator()
        let appearedPlan = try appearedOperator.plan(
            request(.copy, source: source, destination: destinationRoot)
        )
        _ = try makeSkill(in: destinationRoot, name: "demo", contents: "appeared")
        await XCTAssertThrowsErrorAsync(
            try await appearedOperator.execute(appearedPlan, confirmation: appearedPlan.confirmationToken)
        ) { XCTAssertEqual($0 as? SkillFileOperatorError, .destinationChanged) }

        let replaceOperator = makeOperator()
        let replacePlan = try replaceOperator.plan(
            request(.copy, source: source, destination: destinationRoot, conflict: .replace)
        )
        try Data("changed".utf8).write(to: destinationRoot.appending(path: "demo/SKILL.md"))
        await XCTAssertThrowsErrorAsync(
            try await replaceOperator.execute(
                replacePlan,
                confirmation: replacePlan.confirmationToken,
                replacementConfirmation: replacePlan.replacementConfirmationToken
            )
        ) { XCTAssertEqual($0 as? SkillFileOperatorError, .destinationChanged) }
    }

    func testDestinationRootReplacementInvalidatesPlanEvenAtSamePath() async throws {
        let source = try makeSkill(in: sourceRoot, name: "demo")
        let operatorUnderTest = makeOperator()
        let plan = try operatorUnderTest.plan(
            request(.copy, source: source, destination: destinationRoot)
        )
        let originalRoot = destinationRoot.appendingPathExtension("original")
        try FileManager.default.moveItem(at: destinationRoot, to: originalRoot)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

        await XCTAssertThrowsErrorAsync(
            try await operatorUnderTest.execute(plan, confirmation: plan.confirmationToken)
        ) { XCTAssertEqual($0 as? SkillFileOperatorError, .destinationChanged) }
    }

    func testConcurrentExecutionClaimsPlanOnlyOnce() async throws {
        let source = try makeSkill(in: sourceRoot, name: "demo")
        let operatorUnderTest = makeOperator()
        let plan = try operatorUnderTest.plan(
            request(.copy, source: source, destination: destinationRoot)
        )

        let first = Task {
            do { return Result<FileOperationResult, Error>.success(try await operatorUnderTest.execute(plan, confirmation: plan.confirmationToken)) }
            catch { return Result<FileOperationResult, Error>.failure(error) }
        }
        let second = Task {
            do { return Result<FileOperationResult, Error>.success(try await operatorUnderTest.execute(plan, confirmation: plan.confirmationToken)) }
            catch { return Result<FileOperationResult, Error>.failure(error) }
        }
        let results = await [first.value, second.value]
        XCTAssertEqual(results.filter {
            if case .success = $0 { return true }
            return false
        }.count, 1)
        let errors = results.compactMap { result -> SkillFileOperatorError? in
            guard case .failure(let error) = result else { return nil }
            return error as? SkillFileOperatorError
        }
        XCTAssertEqual(errors, [.invalidOrConsumedPlan])
    }

    func testRejectsUnauthorizedAndUnregisteredSources() throws {
        let outsideRoot = fixture.appending(path: "outside")
        try FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: true)
        let outside = try makeSkill(in: outsideRoot, name: "outside")
        let unregisteredRoot = home.appending(path: "Documents")
        try FileManager.default.createDirectory(at: unregisteredRoot, withIntermediateDirectories: true)
        let unregistered = try makeSkill(in: unregisteredRoot, name: "unregistered")
        let operatorUnderTest = makeOperator()

        XCTAssertThrowsError(try operatorUnderTest.plan(request(.delete, source: outside))) {
            XCTAssertEqual($0 as? SkillFileOperatorError, .unauthorizedSource)
        }
        XCTAssertThrowsError(try operatorUnderTest.plan(request(.delete, source: unregistered))) {
            XCTAssertEqual($0 as? SkillFileOperatorError, .unregisteredSource)
        }
    }

    func testCreateLinkExecutionResolvesRelativeAndAbsoluteTargets() async throws {
        let project = fixture.appending(path: "project")
        let projectSourceRoot = project.appending(path: "packages/.agents/skills")
        let projectDestinationRoot = project.appending(path: "nested/.codex/skills")
        for directory in [projectSourceRoot, projectDestinationRoot] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let source = try makeSkill(in: projectSourceRoot, name: "demo")
        roots.append(AuthorizedRootSnapshot(id: "project", url: project, kind: .project))

        let relativeOperator = makeOperator()
        let relativePlan = try relativeOperator.plan(
            request(.createSymbolicLink, source: source, destination: projectDestinationRoot)
        )
        _ = try await relativeOperator.execute(relativePlan, confirmation: relativePlan.confirmationToken)
        let relativeLink = try XCTUnwrap(relativePlan.destinationURL)
        XCTAssertEqual(relativeLink.resolvingSymlinksInPath().standardizedFileURL, source.standardizedFileURL)
        XCTAssertFalse(try FileManager.default.destinationOfSymbolicLink(atPath: relativeLink.path).hasPrefix("/"))

        let absoluteOperator = makeOperator()
        let absolutePlan = try absoluteOperator.plan(
            request(.createSymbolicLink, source: source, destination: destinationRoot, name: "project-demo")
        )
        _ = try await absoluteOperator.execute(absolutePlan, confirmation: absolutePlan.confirmationToken)
        let absoluteLink = try XCTUnwrap(absolutePlan.destinationURL)
        XCTAssertEqual(absoluteLink.resolvingSymlinksInPath().standardizedFileURL, source.standardizedFileURL)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: absoluteLink.path), source.path)
    }

    func testNestedProjectRootWinsOverHomeRootAndUsesRelativeLinkTarget() async throws {
        let project = home.appending(path: "work/project")
        let projectSourceRoot = project.appending(path: "packages/.agents/skills")
        let projectDestinationRoot = project.appending(path: "nested/.codex/skills")
        for directory in [projectSourceRoot, projectDestinationRoot] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let source = try makeSkill(in: projectSourceRoot, name: "demo")
        roots = [
            AuthorizedRootSnapshot(id: "home", url: home, kind: .home),
            AuthorizedRootSnapshot(id: "project", url: project, kind: .project),
        ]
        let operatorUnderTest = makeOperator()

        let plan = try operatorUnderTest.plan(
            request(.createSymbolicLink, source: source, destination: projectDestinationRoot)
        )

        XCTAssertEqual(plan.destinationRootID, "project")
        XCTAssertEqual(plan.destinationAgentIDs, ["codex"])
        XCTAssertEqual(plan.linkTargetForm, .relative)
        XCTAssertFalse(try XCTUnwrap(plan.linkTarget).hasPrefix("/"))
    }

    func testMoveReplaceToSamePathIsRejectedWithoutMutation() throws {
        let source = try makeSkill(in: sourceRoot, name: "demo", contents: "original")
        let operatorUnderTest = makeOperator()

        XCTAssertThrowsError(
            try operatorUnderTest.plan(
                request(.move, source: source, destination: sourceRoot, conflict: .replace)
            )
        ) { XCTAssertEqual($0 as? SkillFileOperatorError, .destinationConflict) }
        XCTAssertEqual(try String(contentsOf: source.appending(path: "SKILL.md")), "original")
        XCTAssertTrue(trash.movedItems.isEmpty)
    }

    func testRegularDeleteDisclosesAndRefreshesTargetAliases() async throws {
        let source = try makeSkill(in: sourceRoot, name: "target")
        let alias = sourceRoot.appending(path: "alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        let operatorUnderTest = makeOperator(indexed: [
            indexed(source),
            indexed(alias, resolved: source, rootIDs: ["linked-project"]),
        ])
        let plan = try operatorUnderTest.plan(request(.delete, source: source))

        XCTAssertEqual(plan.affectedIndexedAliases, [alias.path, source.path].sorted())
        let result = try await operatorUnderTest.execute(plan, confirmation: plan.confirmationToken)
        XCTAssertEqual(result.refreshRootIDs, ["home", "linked-project"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue((try? alias.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true)
    }

    func testReplacementFinalRenameFailureRestoresOldDestinationAndCleansStage() async throws {
        let source = try makeSkill(in: sourceRoot, name: "demo", contents: "new")
        _ = try makeSkill(in: destinationRoot, name: "demo", contents: "old")
        let live = FileOperationFileSystem.live
        let failing = FileOperationFileSystem(
            snapshot: live.snapshot,
            contents: live.contents,
            copy: live.copy,
            move: { from, to in
                if from.lastPathComponent.hasPrefix(".skillselector-staging-") {
                    throw CocoaError(.fileWriteUnknown)
                }
                try live.move(from, to)
            },
            remove: live.remove,
            createSymbolicLink: live.createSymbolicLink
        )
        let operatorUnderTest = makeOperator(fileSystem: failing)
        let plan = try operatorUnderTest.plan(
            request(.copy, source: source, destination: destinationRoot, conflict: .replace)
        )

        await XCTAssertThrowsErrorAsync(
            try await operatorUnderTest.execute(
                plan,
                confirmation: plan.confirmationToken,
                replacementConfirmation: plan.replacementConfirmationToken
            )
        ) { error in
            guard case .filesystemFailure = error as? SkillFileOperatorError else {
                return XCTFail("Expected filesystemFailure, got \(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: destinationRoot.appending(path: "demo/SKILL.md")), "old")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: destinationRoot.path).contains {
            $0.hasPrefix(".skillselector-staging-")
        })
    }

    func testReplacementReportsRollbackFailureWhenOldDestinationCannotBeRestored() async throws {
        let source = try makeSkill(in: sourceRoot, name: "demo", contents: "new")
        _ = try makeSkill(in: destinationRoot, name: "demo", contents: "old")
        let live = FileOperationFileSystem.live
        let failing = FileOperationFileSystem(
            snapshot: live.snapshot,
            contents: live.contents,
            copy: live.copy,
            move: { from, to in
                if from.lastPathComponent.hasPrefix(".skillselector-staging-") {
                    throw CocoaError(.fileWriteUnknown)
                }
                if from.path.hasPrefix(self.trashRoot.path) {
                    throw CocoaError(.fileWriteNoPermission)
                }
                try live.move(from, to)
            },
            remove: live.remove,
            createSymbolicLink: live.createSymbolicLink
        )
        let operatorUnderTest = makeOperator(fileSystem: failing)
        let plan = try operatorUnderTest.plan(
            request(.copy, source: source, destination: destinationRoot, conflict: .replace)
        )

        await XCTAssertThrowsErrorAsync(
            try await operatorUnderTest.execute(
                plan,
                confirmation: plan.confirmationToken,
                replacementConfirmation: plan.replacementConfirmationToken
            )
        ) { error in
            guard case .rollbackFailed = error as? SkillFileOperatorError else {
                return XCTFail("Expected rollbackFailed, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationRoot.appending(path: "demo").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testMoveFailureKeepsSourceAndLeavesNoDestination() async throws {
        let source = try makeSkill(in: sourceRoot, name: "demo")
        let live = FileOperationFileSystem.live
        let failing = FileOperationFileSystem(
            snapshot: live.snapshot,
            contents: live.contents,
            copy: live.copy,
            move: { _, _ in throw CocoaError(.fileWriteUnknown) },
            remove: live.remove,
            createSymbolicLink: live.createSymbolicLink
        )
        let operatorUnderTest = makeOperator(fileSystem: failing)
        let plan = try operatorUnderTest.plan(request(.move, source: source, destination: destinationRoot))

        await XCTAssertThrowsErrorAsync(
            try await operatorUnderTest.execute(plan, confirmation: plan.confirmationToken)
        ) { error in
            guard case .filesystemFailure = error as? SkillFileOperatorError else {
                return XCTFail("Expected filesystemFailure, got \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationRoot.appending(path: "demo").path))
    }

    func testMoveReplaceSourceRemovalFailureRestoresOldDestination() async throws {
        let source = try makeSkill(in: sourceRoot, name: "demo", contents: "new")
        _ = try makeSkill(in: destinationRoot, name: "demo", contents: "old")
        let live = FileOperationFileSystem.live
        let failing = FileOperationFileSystem(
            snapshot: live.snapshot,
            contents: live.contents,
            copy: live.copy,
            move: live.move,
            remove: { url in
                if url.standardizedFileURL == source.standardizedFileURL {
                    throw CocoaError(.fileWriteNoPermission)
                }
                try live.remove(url)
            },
            createSymbolicLink: live.createSymbolicLink
        )
        let operatorUnderTest = makeOperator(fileSystem: failing)
        let plan = try operatorUnderTest.plan(
            request(.move, source: source, destination: destinationRoot, conflict: .replace)
        )

        await XCTAssertThrowsErrorAsync(
            try await operatorUnderTest.execute(
                plan,
                confirmation: plan.confirmationToken,
                replacementConfirmation: plan.replacementConfirmationToken
            )
        ) { error in
            guard case .filesystemFailure = error as? SkillFileOperatorError else {
                return XCTFail("Expected filesystemFailure, got \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try String(contentsOf: destinationRoot.appending(path: "demo/SKILL.md")), "old")
    }

    func testRooTemplateAndSystemAndCustomExactRootsAreRegistered() throws {
        let source = try makeSkill(in: sourceRoot, name: "demo")
        let roo = home.appending(path: ".roo/skills-architect")
        let system = fixture.appending(path: "System Skills")
        let custom = fixture.appending(path: "Custom Skills")
        for directory in [roo, system, custom] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        registry = AgentRegistry(definitions: registry.definitions + [
            AgentDefinition(
                id: "roo-code",
                displayName: "Roo Code",
                globalRoots: ["~/.roo/skills-{modeSlug}"],
                projectPatterns: [".roo/skills-{modeSlug}"]
            ),
            AgentDefinition(
                id: "system-agent",
                displayName: "System Agent",
                globalRoots: [system.path],
                projectPatterns: []
            ),
        ],
        sharedGlobalRoots: registry.sharedGlobalRoots,
        sharedProjectPatterns: registry.sharedProjectPatterns)
        roots.append(AuthorizedRootSnapshot(id: "system", url: system, kind: .system))
        roots.append(AuthorizedRootSnapshot(id: "custom", url: custom, kind: .custom))
        let operatorUnderTest = makeOperator()

        XCTAssertEqual(
            try operatorUnderTest.plan(request(.copy, source: source, destination: roo)).destinationAgentIDs,
            ["roo-code"]
        )
        XCTAssertEqual(
            try operatorUnderTest.plan(request(.copy, source: source, destination: system)).destinationAgentIDs,
            ["system-agent"]
        )
        XCTAssertEqual(
            try operatorUnderTest.plan(request(.copy, source: source, destination: custom)).destinationAgentIDs,
            ["custom"]
        )
    }

    func testExecutionRejectsSourceAndAuthorizationAndRegistryChanges() async throws {
        let source = try makeSkill(in: sourceRoot, name: "demo")
        let sourceChanged = makeOperator()
        let sourcePlan = try sourceChanged.plan(request(.copy, source: source, destination: destinationRoot))
        try Data("changed".utf8).write(to: source.appending(path: "SKILL.md"))
        await XCTAssertThrowsErrorAsync(
            try await sourceChanged.execute(sourcePlan, confirmation: sourcePlan.confirmationToken)
        ) { XCTAssertEqual($0 as? SkillFileOperatorError, .sourceChanged) }

        try FileManager.default.removeItem(at: source)
        let replacementSource = try makeSkill(in: sourceRoot, name: "demo")
        let authorizationChanged = makeOperator()
        let authorizationPlan = try authorizationChanged.plan(
            request(.copy, source: replacementSource, destination: destinationRoot)
        )
        roots = []
        await XCTAssertThrowsErrorAsync(
            try await authorizationChanged.execute(
                authorizationPlan,
                confirmation: authorizationPlan.confirmationToken
            )
        ) { XCTAssertEqual($0 as? SkillFileOperatorError, .authorizationChanged) }

        roots = [AuthorizedRootSnapshot(id: "home", url: home, kind: .home)]
        let registryChanged = makeOperator()
        let registryPlan = try registryChanged.plan(
            request(.copy, source: replacementSource, destination: destinationRoot)
        )
        registry = AgentRegistry(
            definitions: registry.definitions,
            sharedProjectPatterns: [".agents/skills"]
        )
        await XCTAssertThrowsErrorAsync(
            try await registryChanged.execute(registryPlan, confirmation: registryPlan.confirmationToken)
        ) { XCTAssertEqual($0 as? SkillFileOperatorError, .registryChanged) }
    }

    func testExecutionRejectsSourceThatDisappearedAfterPlanning() async throws {
        let source = try makeSkill(in: sourceRoot, name: "demo")
        let operatorUnderTest = makeOperator()
        let plan = try operatorUnderTest.plan(
            request(.copy, source: source, destination: destinationRoot)
        )
        try FileManager.default.removeItem(at: source)

        await XCTAssertThrowsErrorAsync(
            try await operatorUnderTest.execute(plan, confirmation: plan.confirmationToken)
        ) { XCTAssertEqual($0 as? SkillFileOperatorError, .sourceChanged) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationRoot.appending(path: "demo").path))
    }

    func testReplacementValidationFailureCleansStagingAndKeepsExistingDestination() async throws {
        let source = try makeSkill(in: sourceRoot, name: "demo", entryFilename: nil)
        _ = try makeSkill(in: destinationRoot, name: "demo", contents: "old")
        let operatorUnderTest = makeOperator()
        let plan = try operatorUnderTest.plan(
            request(.copy, source: source, destination: destinationRoot, conflict: .replace)
        )

        await XCTAssertThrowsErrorAsync(
            try await operatorUnderTest.execute(
                plan,
                confirmation: plan.confirmationToken,
                replacementConfirmation: plan.replacementConfirmationToken
            )
        ) { XCTAssertEqual($0 as? SkillFileOperatorError, .invalidStagedSkill) }
        XCTAssertEqual(try String(contentsOf: destinationRoot.appending(path: "demo/SKILL.md")), "old")
        XCTAssertTrue(trash.movedItems.isEmpty)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: destinationRoot.path).contains {
            $0.hasPrefix(".skillselector-staging-")
        })
    }

    func testSourceChangeDuringCopyFailsAndCleansStaging() async throws {
        let source = try makeSkill(in: sourceRoot, name: "demo", contents: "original")
        let live = FileOperationFileSystem.live
        let changing = FileOperationFileSystem(
            snapshot: live.snapshot,
            contents: live.contents,
            copy: { from, to in
                try live.copy(from, to)
                try Data("changed".utf8).write(to: source.appending(path: "SKILL.md"))
            },
            move: live.move,
            remove: live.remove,
            createSymbolicLink: live.createSymbolicLink
        )
        let operatorUnderTest = makeOperator(fileSystem: changing)
        let plan = try operatorUnderTest.plan(
            request(.copy, source: source, destination: destinationRoot)
        )

        await XCTAssertThrowsErrorAsync(
            try await operatorUnderTest.execute(plan, confirmation: plan.confirmationToken)
        ) { XCTAssertEqual($0 as? SkillFileOperatorError, .sourceChanged) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationRoot.appending(path: "demo").path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: destinationRoot.path).contains {
            $0.hasPrefix(".skillselector-staging-")
        })
    }

    func testSourceChangeAfterStagingValidationFailsBeforeInstallation() async throws {
        let source = try makeSkill(in: sourceRoot, name: "demo", contents: "original")
        let live = FileOperationFileSystem.live
        var changed = false
        let changing = FileOperationFileSystem(
            snapshot: { url in
                let snapshot = try live.snapshot(url)
                if !changed, url.lastPathComponent.hasPrefix(".skillselector-staging-") {
                    changed = true
                    try Data("changed after staging".utf8).write(to: source.appending(path: "SKILL.md"))
                }
                return snapshot
            },
            contents: live.contents,
            copy: live.copy,
            move: live.move,
            remove: live.remove,
            createSymbolicLink: live.createSymbolicLink
        )
        let operatorUnderTest = makeOperator(fileSystem: changing)
        let plan = try operatorUnderTest.plan(
            request(.copy, source: source, destination: destinationRoot)
        )

        await XCTAssertThrowsErrorAsync(
            try await operatorUnderTest.execute(plan, confirmation: plan.confirmationToken)
        ) { XCTAssertEqual($0 as? SkillFileOperatorError, .sourceChanged) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationRoot.appending(path: "demo").path))
    }

    func testRegularMoveRejectsSourceChangeDuringFinalValidation() async throws {
        let source = try makeSkill(in: sourceRoot, name: "demo", contents: "original")
        let live = FileOperationFileSystem.live
        var sourceSnapshotCalls = 0
        let changing = FileOperationFileSystem(
            snapshot: { url in
                guard url.standardizedFileURL == source.standardizedFileURL else {
                    return try live.snapshot(url)
                }
                sourceSnapshotCalls += 1
                if sourceSnapshotCalls == 3 {
                    try Data("changed before move".utf8)
                        .write(to: source.appending(path: "SKILL.md"))
                }
                return try live.snapshot(url)
            },
            contents: live.contents,
            copy: live.copy,
            move: live.move,
            remove: live.remove,
            createSymbolicLink: live.createSymbolicLink
        )
        let operatorUnderTest = makeOperator(fileSystem: changing)
        let plan = try operatorUnderTest.plan(
            request(.move, source: source, destination: destinationRoot)
        )

        await XCTAssertThrowsErrorAsync(
            try await operatorUnderTest.execute(plan, confirmation: plan.confirmationToken)
        ) { XCTAssertEqual($0 as? SkillFileOperatorError, .sourceChanged) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationRoot.appending(path: "demo").path))
    }

    func testRegularMoveRejectsDestinationChangeDuringFinalValidation() async throws {
        let source = try makeSkill(in: sourceRoot, name: "demo")
        let destination = destinationRoot.appending(path: "demo")
        let live = FileOperationFileSystem.live
        var destinationSnapshotCalls = 0
        let changing = FileOperationFileSystem(
            snapshot: { url in
                guard url.standardizedFileURL == destination.standardizedFileURL else {
                    return try live.snapshot(url)
                }
                destinationSnapshotCalls += 1
                if destinationSnapshotCalls == 3 {
                    _ = try self.makeSkill(in: self.destinationRoot, name: "demo", contents: "appeared")
                }
                return try live.snapshot(url)
            },
            contents: live.contents,
            copy: live.copy,
            move: live.move,
            remove: live.remove,
            createSymbolicLink: live.createSymbolicLink
        )
        let operatorUnderTest = makeOperator(fileSystem: changing)
        let plan = try operatorUnderTest.plan(
            request(.move, source: source, destination: destinationRoot)
        )

        await XCTAssertThrowsErrorAsync(
            try await operatorUnderTest.execute(plan, confirmation: plan.confirmationToken)
        ) { XCTAssertEqual($0 as? SkillFileOperatorError, .destinationChanged) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try String(contentsOf: destination.appending(path: "SKILL.md")), "appeared")
    }

    func testDeleteRejectsSourceChangeDuringFinalValidation() async throws {
        let source = try makeSkill(in: sourceRoot, name: "demo", contents: "original")
        let live = FileOperationFileSystem.live
        var sourceSnapshotCalls = 0
        let changing = FileOperationFileSystem(
            snapshot: { url in
                guard url.standardizedFileURL == source.standardizedFileURL else {
                    return try live.snapshot(url)
                }
                sourceSnapshotCalls += 1
                if sourceSnapshotCalls == 3 {
                    try Data("changed before trash".utf8)
                        .write(to: source.appending(path: "SKILL.md"))
                }
                return try live.snapshot(url)
            },
            contents: live.contents,
            copy: live.copy,
            move: live.move,
            remove: live.remove,
            createSymbolicLink: live.createSymbolicLink
        )
        let operatorUnderTest = makeOperator(fileSystem: changing)
        let plan = try operatorUnderTest.plan(request(.delete, source: source))

        await XCTAssertThrowsErrorAsync(
            try await operatorUnderTest.execute(plan, confirmation: plan.confirmationToken)
        ) { XCTAssertEqual($0 as? SkillFileOperatorError, .sourceChanged) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(trash.movedItems.isEmpty)
    }

    func testDestinationChangeDuringReplacementFailsBeforeTrashAndCleansStaging() async throws {
        let source = try makeSkill(in: sourceRoot, name: "demo", contents: "new")
        let destination = try makeSkill(in: destinationRoot, name: "demo", contents: "old")
        let live = FileOperationFileSystem.live
        let changing = FileOperationFileSystem(
            snapshot: live.snapshot,
            contents: live.contents,
            copy: { from, to in
                try live.copy(from, to)
                try Data("changed while staging".utf8).write(to: destination.appending(path: "SKILL.md"))
            },
            move: live.move,
            remove: live.remove,
            createSymbolicLink: live.createSymbolicLink
        )
        let operatorUnderTest = makeOperator(fileSystem: changing)
        let plan = try operatorUnderTest.plan(
            request(.copy, source: source, destination: destinationRoot, conflict: .replace)
        )

        await XCTAssertThrowsErrorAsync(
            try await operatorUnderTest.execute(
                plan,
                confirmation: plan.confirmationToken,
                replacementConfirmation: plan.replacementConfirmationToken
            )
        ) { XCTAssertEqual($0 as? SkillFileOperatorError, .destinationChanged) }
        XCTAssertEqual(
            try String(contentsOf: destination.appending(path: "SKILL.md")),
            "changed while staging"
        )
        XCTAssertTrue(trash.movedItems.isEmpty)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: destinationRoot.path).contains {
            $0.hasPrefix(".skillselector-staging-")
        })
    }

    private func makeOperator(
        indexed: [IndexedSkillAlias] = [],
        fileSystem: FileOperationFileSystem = .live
    ) -> SkillFileOperator {
        SkillFileOperator(
            registryProvider: { self.registry },
            authorizedRootsProvider: { self.roots },
            indexedAliasesProvider: { indexed },
            fileSystem: fileSystem,
            trash: trash
        )
    }

    private func request(
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
            metadata: SkillAppMetadata(customDescription: "Mine", sourceBinding: "github:x")
        )
    }

    private func indexed(
        _ url: URL,
        resolved: URL? = nil,
        rootIDs: [String] = []
    ) -> IndexedSkillAlias {
        IndexedSkillAlias(path: url.path, resolvedTarget: resolved?.path, rootIDs: rootIDs)
    }

    @discardableResult
    private func makeSkill(
        in root: URL,
        name: String,
        contents: String = "demo",
        entryFilename: String? = "SKILL.md"
    ) throws -> URL {
        let url = root.appending(path: name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if let entryFilename {
            try Data(contents.utf8).write(to: url.appending(path: entryFilename))
        }
        return url
    }
}

private final class RecordingTrash: FileOperationTrashing {
    let root: URL
    private(set) var movedItems: [URL] = []

    init(root: URL) { self.root = root }

    func trashItem(at url: URL) throws -> URL {
        let destination = root.appending(path: "\(UUID().uuidString)-\(url.lastPathComponent)")
        try FileManager.default.moveItem(at: url, to: destination)
        movedItems.append(url)
        return destination
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw")
    } catch {
        errorHandler(error)
    }
}
