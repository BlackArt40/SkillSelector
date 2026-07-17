import Foundation
import SwiftData
import XCTest
@testable import SkillSelectorCore

final class ExternalCommandRunnerTests: XCTestCase {
    private var fixture: URL!

    override func setUpWithError() throws {
        fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExternalCommandRunnerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let fixture { try? FileManager.default.removeItem(at: fixture) }
    }

    func testArgumentsArePassedLiterallyAndEnvironmentIsAllowlisted() async throws {
        let script = try makeExecutable("#!/bin/sh\nprintf '%s\\n' \"$@\"\nprintf 'secret=%s\\n' \"${SECRET-unset}\" 1>&2\nprintf 'home=%s\\n' \"${HOME-unset}\" 1>&2\n")
        let command = ExternalCommand(
            executableURL: script,
            arguments: ["a b", "semi;colon", "$value", "`quoted`"],
            environment: ["SECRET": "should-not-appear"],
            authorizedHomeURL: fixture.appendingPathComponent("home")
        )

        let result = try await ExternalCommandRunner().run(command)

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.stdoutString, "a b\nsemi;colon\n$value\n`quoted`\n")
        XCTAssertTrue(result.stderrString.contains("secret=unset"))
        XCTAssertTrue(result.stderrString.contains("home=\(fixture.appendingPathComponent("home").path)"))
    }

    func testOutputLimitTerminatesProcessAndRejectsTheStream() async throws {
        let script = try makeExecutable("#!/bin/sh\nprintf '1234567890'\n")
        await XCTAssertThrowsErrorAsync(
            try await ExternalCommandRunner().run(ExternalCommand(
                executableURL: script,
                maximumOutputBytes: 5
            ))
        ) { error in
            XCTAssertEqual(error as? ExternalCommandError, .outputLimitExceeded(.stdout))
        }
    }

    func testStdoutOutputLimitTerminatesBackgroundChildHoldingPipe() async throws {
        let pidFile = fixture.appendingPathComponent("stdout-limit-child.pid")
        let script = try makeExecutable("#!/bin/sh\nsleep 30 &\nprintf '%s' \"$!\" > \"$1\"\nprintf '1234567890'\nwait\n")
        let task = Task {
            try await ExternalCommandRunner().run(ExternalCommand(
                executableURL: script,
                arguments: [pidFile.path],
                timeout: 10,
                maximumOutputBytes: 5
            ))
        }
        let childPID = try await waitForPID(in: pidFile)
        let started = Date()

        await XCTAssertThrowsErrorAsync(try await task.value) { error in
            XCTAssertEqual(error as? ExternalCommandError, .outputLimitExceeded(.stdout))
        }

        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        let childGone = await waitUntilProcessIsGone(childPID)
        XCTAssertTrue(childGone, "Background child \(childPID) survived stdout output limit")
    }

    func testStderrOutputLimitTerminatesBackgroundChildHoldingPipe() async throws {
        let pidFile = fixture.appendingPathComponent("stderr-limit-child.pid")
        let script = try makeExecutable("#!/bin/sh\nsleep 30 &\nprintf '%s' \"$!\" > \"$1\"\nprintf '1234567890' 1>&2\nwait\n")
        let task = Task {
            try await ExternalCommandRunner().run(ExternalCommand(
                executableURL: script,
                arguments: [pidFile.path],
                timeout: 10,
                maximumOutputBytes: 5
            ))
        }
        let childPID = try await waitForPID(in: pidFile)
        let started = Date()

        await XCTAssertThrowsErrorAsync(try await task.value) { error in
            XCTAssertEqual(error as? ExternalCommandError, .outputLimitExceeded(.stderr))
        }

        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        let childGone = await waitUntilProcessIsGone(childPID)
        XCTAssertTrue(childGone, "Background child \(childPID) survived stderr output limit")
    }

    func testTimeoutTerminatesProcess() async throws {
        let script = try makeExecutable("#!/bin/sh\nsleep 5\n")
        let started = Date()
        await XCTAssertThrowsErrorAsync(
            try await ExternalCommandRunner().run(ExternalCommand(executableURL: script, timeout: 0.1))
        ) { error in
            XCTAssertEqual(error as? ExternalCommandError, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testTimeoutTerminatesBackgroundChildHoldingOutputPipes() async throws {
        let pidFile = fixture.appendingPathComponent("timeout-child.pid")
        let script = try makeExecutable("#!/bin/sh\nsleep 30 &\nprintf '%s' \"$!\" > \"$1\"\nwait\n")
        let command = ExternalCommand(
            executableURL: script,
            arguments: [pidFile.path],
            timeout: 2
        )
        let task = Task { try await ExternalCommandRunner().run(command) }
        let childPID = try await waitForPID(in: pidFile)
        let started = Date()

        await XCTAssertThrowsErrorAsync(
            try await task.value
        ) { error in
            XCTAssertEqual(error as? ExternalCommandError, .timedOut)
        }

        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        let childGone = await waitUntilProcessIsGone(childPID)
        XCTAssertTrue(childGone, "Background child \(childPID) survived timeout")
    }

    func testCancellationTerminatesProcess() async throws {
        let script = try makeExecutable("#!/bin/sh\nsleep 5\n")
        let task = Task {
            try await ExternalCommandRunner().run(ExternalCommand(executableURL: script, timeout: 10))
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await XCTAssertThrowsErrorAsync(try await task.value) { error in
            XCTAssertEqual(error as? ExternalCommandError, .cancelled)
        }
    }

    func testCancellationTerminatesBackgroundChildHoldingOutputPipes() async throws {
        let pidFile = fixture.appendingPathComponent("cancelled-child.pid")
        let script = try makeExecutable("#!/bin/sh\nsleep 30 &\nprintf '%s' \"$!\" > \"$1\"\nwait\n")
        let task = Task {
            try await ExternalCommandRunner().run(ExternalCommand(
                executableURL: script,
                arguments: [pidFile.path],
                timeout: 10
            ))
        }
        let childPID = try await waitForPID(in: pidFile)
        let started = Date()
        task.cancel()

        await XCTAssertThrowsErrorAsync(try await task.value) { error in
            XCTAssertEqual(error as? ExternalCommandError, .cancelled)
        }

        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        let childGone = await waitUntilProcessIsGone(childPID)
        XCTAssertTrue(childGone, "Background child \(childPID) survived cancellation")
    }

    func testCommandApprovalIsExactAndConfigurationScoped() {
        let defaults = UserDefaults(suiteName: "ExternalCommandRunnerTests-\(UUID().uuidString)")!
        let approval = CommandApproval(store: UserDefaultsCommandApprovalStore(defaults: defaults))
        let command = ApprovedCommand(executablePath: "/usr/bin/npx", arguments: ["-y", "server@1"], configurationFingerprint: "mcp-a")
        XCTAssertEqual(approval.state(for: command), .approvalRequired)
        approval.approve(command)
        XCTAssertEqual(approval.state(for: command), .approved)
        XCTAssertEqual(approval.state(executableURL: URL(fileURLWithPath: "/usr/bin/npx"), arguments: ["-y", "server@2"], configurationFingerprint: "mcp-a"), .approvalRequired)
        XCTAssertEqual(approval.state(executableURL: URL(fileURLWithPath: "/usr/bin/npx"), arguments: ["-y", "server@1"], configurationFingerprint: "mcp-b"), .approvalRequired)
        XCTAssertNotEqual(
            CommandApproval.fingerprint(executablePath: "/usr/bin/npx", arguments: [], configurationFingerprint: nil),
            CommandApproval.fingerprint(executablePath: "/usr/bin/npx", arguments: [], configurationFingerprint: "")
        )
    }

    func testToolLocatorBindsBookmarkAndReportsVersion() async throws {
        let script = try makeExecutable("#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then printf 'fake 1.0\\n'; exit 0; fi\n", name: "npm")
        let adapter = FixtureBookmarkAdapter()
        let store = FixtureToolStore()
        let locator = ToolLocator(
            store: store,
            bookmarkAdapter: adapter,
            searchDirectories: [fixture]
        )
        let found = await locator.locate("npm")
        XCTAssertEqual(found.state, .available)
        XCTAssertEqual(found.executableURL, fixture.appendingPathComponent("npm").standardizedFileURL)
        XCTAssertNotNil(found.bookmarkData)
        XCTAssertEqual(store.saved[.npm], found.bookmarkData)
        XCTAssertEqual(found.version, "fake 1.0")
        _ = try await locator.bind(script, as: .gh)
        XCTAssertEqual(store.saved[.gh], Data(script.path.utf8))
    }

    func testToolLocatorKeepsResolvedBookmarkLeaseDuringValidation() async throws {
        let script = try makeExecutable("#!/bin/sh\nexit 0\n", name: "npm")
        let adapter = FixtureBookmarkAdapter()
        let store = FixtureToolStore()
        store.saved[.npm] = Data(script.path.utf8)
        let runner = FixtureRunner { command in
            XCTAssertTrue(adapter.isAccessing)
            XCTAssertEqual(command.timeout, 5)
            XCTAssertEqual(command.maximumOutputBytes, 64 * 1024)
            return commandResult(stdout: "fake 1.0\n")
        }
        let locator = ToolLocator(
            store: store,
            bookmarkAdapter: adapter,
            runner: runner,
            searchDirectories: []
        )

        let found = await locator.locate("npm")

        XCTAssertEqual(found.state, .available)
        XCTAssertEqual(adapter.accessEvents, ["start", "stop"])
        XCTAssertFalse(adapter.isAccessing)
        XCTAssertEqual(runner.commands.map(\.arguments), [["--version"]])
    }

    func testToolAccessKeepsExecutableAndHomeLeasesForBothProviders() async throws {
        let npmScript = try makeExecutable("#!/bin/sh\nexit 0\n", name: "npm")
        let ghScript = try makeExecutable("#!/bin/sh\nexit 0\n", name: "gh")
        let home = fixture.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let homeAdapter = FixtureBookmarkAdapter()
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: SkillRecord.self,
            AuthorizedRootRecord.self,
            configurations: configuration
        )
        let bookmarks = BookmarkStore(container: container, adapter: homeAdapter)
        let homeRoot = try bookmarks.save(url: home, kind: .home)
        let homeAccess = try bookmarks.resolve(id: homeRoot.id)
        let adapter = FixtureBookmarkAdapter()
        let store = FixtureToolStore()
        store.saved[.npm] = Data(npmScript.path.utf8)
        store.saved[.gh] = Data(ghScript.path.utf8)
        let locator = ToolLocator(
            store: store,
            bookmarkAdapter: adapter,
            runner: FixtureRunner { _ in commandResult(stdout: "fake 1.0\n") },
            searchDirectories: []
        )

        let result = await locator.openAccess(.npm, authorizedHomeAccess: homeAccess)
        let access = try XCTUnwrap(result.access)
        XCTAssertTrue(adapter.isAccessing)
        XCTAssertTrue(homeAdapter.isAccessing)
        let providerRunner = FixtureRunner { command in
            XCTAssertTrue(adapter.isAccessing)
            XCTAssertTrue(homeAdapter.isAccessing)
            XCTAssertEqual(command.authorizedHomeURL, home.standardizedFileURL)
            return commandResult(stdout: "[]")
        }

        let candidates = try await NPMMetadataProvider(
            toolAccess: access,
            runner: providerRunner
        ).candidates(for: MetadataQuery(name: "demo"))

        XCTAssertEqual(candidates, [])
        XCTAssertTrue(adapter.isAccessing)
        XCTAssertTrue(homeAdapter.isAccessing)
        access.close()
        XCTAssertFalse(adapter.isAccessing)
        XCTAssertFalse(homeAdapter.isAccessing)
        XCTAssertEqual(adapter.accessEvents, ["start", "stop"])
        XCTAssertEqual(homeAdapter.accessEvents, ["start", "stop"])

        let secondHomeAccess = try bookmarks.resolve(id: homeRoot.id)
        let ghResult = await locator.openAccess(.gh, authorizedHomeAccess: secondHomeAccess)
        let ghAccess = try XCTUnwrap(ghResult.access)
        let ghRunner = FixtureRunner { command in
            XCTAssertTrue(adapter.isAccessing)
            XCTAssertTrue(homeAdapter.isAccessing)
            XCTAssertEqual(command.authorizedHomeURL, home.standardizedFileURL)
            return commandResult(stdout: "[]")
        }

        let ghCandidates = try await GitHubMetadataProvider(
            toolAccess: ghAccess,
            runner: ghRunner
        ).candidates(for: MetadataQuery(name: "demo"))
        XCTAssertEqual(ghCandidates, [])
        ghAccess.close()
        XCTAssertFalse(adapter.isAccessing)
        XCTAssertFalse(homeAdapter.isAccessing)
        XCTAssertEqual(adapter.accessEvents, ["start", "stop", "start", "stop"])
        XCTAssertEqual(homeAdapter.accessEvents, ["start", "stop", "start", "stop"])
    }

    func testToolLocatorClassifiesGhAuthOutcomes() async throws {
        let script = try makeExecutable("#!/bin/sh\nexit 0\n", name: "gh")
        let store = FixtureToolStore()
        let adapter = FixtureBookmarkAdapter()
        store.saved[.gh] = Data(script.path.utf8)

        let unauthenticated = ToolLocator(
            store: store,
            bookmarkAdapter: adapter,
            runner: FixtureRunner { command in
                command.arguments == ["--version"]
                    ? commandResult(stdout: "gh 1.0\n")
                    : commandResult(status: 1)
            },
            searchDirectories: []
        )
        let unauthenticatedStatus = await unauthenticated.locate("gh")
        XCTAssertEqual(unauthenticatedStatus.state, .unauthenticated)

        let launchFailure = ToolLocator(
            store: store,
            bookmarkAdapter: adapter,
            runner: FixtureRunner { command in
                if command.arguments == ["--version"] { return commandResult(stdout: "gh 1.0\n") }
                throw ExternalCommandError.launchFailed("fixture")
            },
            searchDirectories: []
        )
        let launchFailureStatus = await launchFailure.locate("gh")
        XCTAssertEqual(launchFailureStatus.state, .invalid)

        let timedOut = ToolLocator(
            store: store,
            bookmarkAdapter: adapter,
            runner: FixtureRunner { command in
                if command.arguments == ["--version"] { return commandResult(stdout: "gh 1.0\n") }
                throw ExternalCommandError.timedOut
            },
            searchDirectories: []
        )
        let timedOutStatus = await timedOut.locate("gh")
        XCTAssertEqual(timedOutStatus.state, .invalid)
    }

    func testToolLocatorReportsInvalidWhenBookmarkSaveFails() async throws {
        _ = try makeExecutable("#!/bin/sh\nprintf 'npm 1.0\\n'\n", name: "npm")
        let store = FixtureToolStore()
        store.saveError = FixtureError.expected
        let locator = ToolLocator(
            store: store,
            bookmarkAdapter: FixtureBookmarkAdapter(),
            runner: FixtureRunner { _ in commandResult(stdout: "npm 1.0\n") },
            searchDirectories: [fixture]
        )

        let found = await locator.locate("npm")

        XCTAssertEqual(found.state, .invalid)
    }

    private func makeExecutable(_ body: String, name: String = "fixture") throws -> URL {
        let url = fixture.appendingPathComponent(name)
        try body.data(using: .utf8)!.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func readPID(from url: URL) throws -> pid_t {
        pid_t(try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
    }

    private func waitForPID(in url: URL) async throws -> pid_t {
        for _ in 0..<100 {
            if let value = try? readPID(from: url) { return value }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw FixtureError.expected
    }

    private func waitUntilProcessIsGone(_ pid: pid_t) async -> Bool {
        for _ in 0..<100 {
            if kill(pid, 0) == -1 && errno == ESRCH { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}

private final class FixtureToolStore: ExecutableBookmarkStoring, @unchecked Sendable {
    var saved: [ToolKind: Data] = [:]
    var saveError: Error?
    func bookmarkData(for tool: ToolKind) -> Data? { saved[tool] }
    func save(bookmarkData: Data, for tool: ToolKind) throws {
        if let saveError { throw saveError }
        saved[tool] = bookmarkData
    }
}

private final class FixtureBookmarkAdapter: BookmarkDataCreating, @unchecked Sendable {
    private let lock = NSLock()
    private var accessing = false
    private(set) var accessEvents: [String] = []
    var isAccessing: Bool {
        lock.lock(); defer { lock.unlock() }
        return accessing
    }
    func createBookmarkData(for url: URL) throws -> Data { Data(url.path.utf8) }
    func resolveBookmarkData(_ data: Data) throws -> BookmarkResolution {
        BookmarkResolution(url: URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), isStale: false)
    }
    func startAccessing(_ url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        accessing = true
        accessEvents.append("start")
        return true
    }
    func stopAccessing(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        accessing = false
        accessEvents.append("stop")
    }
}

private final class FixtureRunner: ExternalCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let handler: @Sendable (ExternalCommand) throws -> CommandResult
    private var recordedCommands: [ExternalCommand] = []

    init(handler: @escaping @Sendable (ExternalCommand) throws -> CommandResult) {
        self.handler = handler
    }

    var commands: [ExternalCommand] {
        lock.lock(); defer { lock.unlock() }
        return recordedCommands
    }

    func run(_ command: ExternalCommand) async throws -> CommandResult {
        recordedCommands.append(command)
        return try handler(command)
    }
}

private enum FixtureError: Error { case expected }

private func commandResult(
    stdout: String = "",
    status: Int32 = 0,
    reason: Process.TerminationReason = .exit
) -> CommandResult {
    CommandResult(
        stdout: Data(stdout.utf8),
        stderr: Data(),
        terminationStatus: status,
        terminationReason: reason
    )
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ handler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {
        handler(error)
    }
}
