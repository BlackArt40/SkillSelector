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
