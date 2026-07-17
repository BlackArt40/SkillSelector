import Foundation
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

    func testCommandApprovalIsExactAndConfigurationScoped() {
        let defaults = UserDefaults(suiteName: "ExternalCommandRunnerTests-\(UUID().uuidString)")!
        let approval = CommandApproval(store: UserDefaultsCommandApprovalStore(defaults: defaults))
        let command = ApprovedCommand(executablePath: "/usr/bin/npx", arguments: ["-y", "server@1"], configurationFingerprint: "mcp-a")
        XCTAssertEqual(approval.state(for: command), .approvalRequired)
        approval.approve(command)
        XCTAssertEqual(approval.state(for: command), .approved)
        XCTAssertEqual(approval.state(executableURL: URL(fileURLWithPath: "/usr/bin/npx"), arguments: ["-y", "server@2"], configurationFingerprint: "mcp-a"), .approvalRequired)
        XCTAssertEqual(approval.state(executableURL: URL(fileURLWithPath: "/usr/bin/npx"), arguments: ["-y", "server@1"], configurationFingerprint: "mcp-b"), .approvalRequired)
    }

    func testToolLocatorBindsBookmarkAndReportsVersion() throws {
        let script = try makeExecutable("#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then printf 'fake 1.0\\n'; exit 0; fi\n", name: "npm")
        let adapter = FixtureBookmarkAdapter()
        let store = FixtureToolStore()
        let locator = ToolLocator(
            store: store,
            bookmarkAdapter: adapter,
            searchDirectories: [fixture]
        )
        let found = locator.locate("npm")
        XCTAssertEqual(found.state, .available)
        XCTAssertEqual(found.executableURL, fixture.appendingPathComponent("npm").standardizedFileURL)
        XCTAssertNotNil(found.bookmarkData)
        XCTAssertEqual(store.saved[.npm], found.bookmarkData)
        XCTAssertEqual(found.version, "fake 1.0")
        _ = try locator.bind(script, as: .gh)
        XCTAssertEqual(store.saved[.gh], Data(script.path.utf8))
    }

    private func makeExecutable(_ body: String, name: String = "fixture") throws -> URL {
        let url = fixture.appendingPathComponent(name)
        try body.data(using: .utf8)!.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}

private final class FixtureToolStore: ExecutableBookmarkStoring {
    var saved: [ToolKind: Data] = [:]
    func bookmarkData(for tool: ToolKind) -> Data? { saved[tool] }
    func save(bookmarkData: Data, for tool: ToolKind) throws { saved[tool] = bookmarkData }
}

private final class FixtureBookmarkAdapter: BookmarkDataCreating {
    func createBookmarkData(for url: URL) throws -> Data { Data(url.path.utf8) }
    func resolveBookmarkData(_ data: Data) throws -> BookmarkResolution {
        BookmarkResolution(url: URL(fileURLWithPath: String(decoding: data, as: UTF8.self)), isStale: false)
    }
    func startAccessing(_ url: URL) -> Bool { true }
    func stopAccessing(_ url: URL) {}
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
