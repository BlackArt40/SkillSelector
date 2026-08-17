import Foundation
import XCTest
@testable import SkillSelectorCore

final class CustomAgentTransferTests: XCTestCase {
    private let agents = [
        AgentDefinition.custom(
            displayName: "Local Agent",
            globalRoots: ["~/.local-agent/skills"],
            projectPatterns: [".local-agent/skills"]
        ),
        AgentDefinition.custom(
            displayName: "Another Agent",
            globalRoots: [],
            projectPatterns: [".another/skills"],
            entryFilename: "AGENT.md"
        ),
    ]

    func testArchiveAndParseRoundTripsDefinitions() throws {
        let transfer = CustomAgentTransfer()
        let decoded = try transfer.parse(try transfer.archive(agents))

        XCTAssertEqual(decoded.map(\.displayName), agents.map(\.displayName))
        XCTAssertEqual(decoded.map(\.id), agents.map(\.id))
        XCTAssertEqual(decoded.map(\.entryFilename), agents.map(\.entryFilename))
    }

    func testParseDropsInvalidEntriesInsteadOfFailing() throws {
        let document = CustomAgentTransferDocument(agents: agents + [
            AgentDefinition(
                id: "bad-entry",
                displayName: "Bad Entry",
                globalRoots: [],
                projectPatterns: [],
                entryFilename: "../SKILL.md"
            ),
        ])
        let data = try JSONEncoder().encode(document)

        let decoded = try CustomAgentTransfer().parse(data)

        XCTAssertEqual(decoded.map(\.displayName), agents.map(\.displayName))
    }

    func testParseRejectsGarbageDataWithUnreadableFile() throws {
        XCTAssertThrowsError(try CustomAgentTransfer().parse(Data("not json".utf8))) { error in
            guard case CustomAgentTransferError.unreadableFile = error else {
                return XCTFail("expected unreadableFile, got \(error)")
            }
        }
    }

    func testParseRejectsFutureFormatVersions() throws {
        let document = CustomAgentTransferDocument(agents: agents, version: 99)
        let data = try JSONEncoder().encode(document)

        XCTAssertThrowsError(try CustomAgentTransfer().parse(data)) { error in
            guard case CustomAgentTransferError.unsupportedFormat = error else {
                return XCTFail("expected unsupportedFormat, got \(error)")
            }
        }
    }
}
