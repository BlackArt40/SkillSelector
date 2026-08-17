import Foundation
import XCTest
@testable import SkillSelectorCore

final class DiagnosticExporterTests: XCTestCase {
    private let redactor = Redactor(
        homeDirectory: URL(fileURLWithPath: "/Users/alice"),
        projectDirectories: [URL(fileURLWithPath: "/Users/alice/Work/Secret")]
    )

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func makeInput() -> DiagnosticExportInput {
        DiagnosticExportInput(
            appVersion: "1.0 (/Users/alice/build)",
            macOSVersion: "14.5",
            registryIDs: ["zeta-agent", "alpha-agent"],
            roots: [
                DiagnosticRootSummary(
                    id: "/Users/alice/Work/Secret",
                    kind: .project,
                    isAvailable: true
                ),
                DiagnosticRootSummary(
                    id: "/Users/alice/.codex/skills",
                    kind: .home,
                    isAvailable: false
                ),
            ],
            diagnostics: [
                AppDiagnostic(
                    timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                    category: .scanning,
                    code: "diagnostic.scanFailed",
                    message: "Unable to scan /Users/alice/Work/Secret/.agents/skills"
                )
            ]
        )
    }

    func testArchiveRedactsSensitivePathsEverywhere() throws {
        let data = try DiagnosticExporter(redactor: redactor).archive(makeInput())
        let json = String(decoding: data, as: UTF8.self)

        XCTAssertFalse(json.contains("/Users/alice"))
        XCTAssertTrue(json.contains("<project:1>"))
        XCTAssertTrue(json.contains("<home>/.codex/skills"))
        XCTAssertTrue(json.contains("Unable to scan <project:1>/.agents/skills"))
    }

    func testArchiveSortsRegistryIDsAndRootsDeterministically() throws {
        let exporter = DiagnosticExporter(redactor: redactor)
        let first = try exporter.archive(makeInput())
        let second = try exporter.archive(makeInput())

        XCTAssertEqual(first, second)

        let decoded = try makeDecoder().decode(DiagnosticExportInput.self, from: first)
        XCTAssertEqual(decoded.registryIDs, ["alpha-agent", "zeta-agent"])
        XCTAssertEqual(
            decoded.roots.map(\.id),
            ["<home>/.codex/skills", "<project:1>"]
        )
        XCTAssertEqual(decoded.roots.map(\.kind), [.home, .project])
        XCTAssertEqual(decoded.roots.map(\.isAvailable), [false, true])
    }

    func testArchiveEncodesDatesAsISO8601() throws {
        let data = try DiagnosticExporter(redactor: redactor).archive(makeInput())
        let json = String(decoding: data, as: UTF8.self)

        XCTAssertTrue(json.contains("2023-11-14T22:13:20Z"))
    }

    func testWriteProducesReadableAtomicArchive() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: url) }

        try DiagnosticExporter(redactor: redactor).write(makeInput(), to: url)

        let data = try Data(contentsOf: url)
        let decoded = try makeDecoder().decode(DiagnosticExportInput.self, from: data)
        XCTAssertEqual(decoded.appVersion, "1.0 (<home>/build)")
        XCTAssertEqual(decoded.diagnostics.count, 1)
        XCTAssertEqual(decoded.diagnostics[0].category, .scanning)
    }

    /// The in-app viewer consumes `sanitized` directly; it must carry the
    /// same redaction the JSON archive does.
    func testSanitizedMatchesArchiveRedaction() throws {
        let exporter = DiagnosticExporter(redactor: redactor)
        let sanitized = exporter.sanitized(makeInput())

        XCTAssertEqual(sanitized.appVersion, "1.0 (<home>/build)")
        XCTAssertFalse(sanitized.diagnostics[0].message.contains("/Users/alice"))
        XCTAssertEqual(sanitized.diagnostics[0].message, "Unable to scan <project:1>/.agents/skills")
        XCTAssertEqual(sanitized.roots.map(\.id), ["<home>/.codex/skills", "<project:1>"])
    }
}
