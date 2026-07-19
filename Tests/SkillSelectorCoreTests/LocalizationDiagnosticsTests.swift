import Foundation
import SwiftData
import XCTest
@testable import SkillSelectorCore

final class LocalizationDiagnosticsTests: XCTestCase {
    func testParserEmitsStableCodesAndUntranslatedArguments() throws {
        let withoutBoundary = FrontmatterParser.parse("# Demo")
        let missingRequired = FrontmatterParser.parse("---\nname: demo\n---")

        let boundary = try XCTUnwrap(withoutBoundary.issues.first { issue in
            issue.diagnostic?.code == .missingFrontmatterBoundary
        })
        let required = try XCTUnwrap(missingRequired.issues.first { issue in
            issue.diagnostic?.code == .missingRequiredFrontmatterField
        })

        XCTAssertEqual(boundary.diagnostic?.arguments, [])
        XCTAssertEqual(required.diagnostic?.arguments, ["description"])
    }

    func testIndexPersistsStructuredUnavailableDiagnostic() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: SkillRecord.self,
            AuthorizedRootRecord.self,
            configurations: configuration
        )
        let index = SkillIndex(container: container)
        let skill = ScannedSkill(
            installation: SkillInstallation(path: URL(fileURLWithPath: "/tmp/demo")),
            document: ParsedSkillDocument(name: "demo", description: "Demo"),
            agentIDsByRoot: ["project": ["cursor"]],
            entryFilename: "SKILL.md"
        )
        try index.apply(
            report: ScanReport(
                installations: [skill],
                roots: [
                    ScannedRoot(
                        id: "project",
                        url: URL(fileURLWithPath: "/tmp"),
                        availability: .available
                    ),
                ]
            )
        )

        let diagnostic = StructuredDiagnostic(
            code: .unableToInspectAuthorizedDirectory,
            arguments: ["NSCocoaErrorDomain 257"]
        )
        try index.apply(
            report: ScanReport(
                roots: [
                    ScannedRoot(
                        id: "project",
                        url: URL(fileURLWithPath: "/tmp"),
                        availability: .unavailable(reason: "Unable to inspect authorized directory"),
                        unavailableDiagnostic: diagnostic
                    ),
                ]
            )
        )

        XCTAssertEqual(try index.skills().first?.unavailableDiagnostic, diagnostic)
    }

    func testLocalizationSelectionMatchesLanguageVariantsAndFallsBackToEnglish() {
        let available = ["zh-Hans", "en"]

        XCTAssertEqual(
            LocalizationSelection.preferredLocalization(
                available: available,
                preferredLanguages: ["zh-Hans-HK"]
            ),
            "zh-Hans"
        )
        XCTAssertEqual(
            LocalizationSelection.preferredLocalization(
                available: available,
                preferredLanguages: ["zh-CN"]
            ),
            "zh-Hans"
        )
        XCTAssertEqual(
            LocalizationSelection.preferredLocalization(
                available: available,
                preferredLanguages: ["fr-FR"]
            ),
            "en"
        )
    }

    func testEveryStructuredDiagnosticHasEnglishAndChineseResources() throws {
        let resources = localizationResources()
        let english = try stringsDictionary(at: resources.appending(path: "en.lproj/Localizable.strings"))
        let chinese = try stringsDictionary(at: resources.appending(path: "zh-Hans.lproj/Localizable.strings"))
        let diagnosticKeys = Set(DiagnosticCode.allCases.map(\.localizationKey))

        XCTAssertTrue(diagnosticKeys.isSubset(of: Set(english.keys)))
        XCTAssertTrue(diagnosticKeys.isSubset(of: Set(chinese.keys)))
        XCTAssertEqual(Set(english.keys), Set(chinese.keys))
        XCTAssertEqual(english["SkillSelector Settings"], "SkillSelector Settings")
        XCTAssertEqual(chinese["SkillSelector Settings"], "SkillSelector 设置")
    }

    func testLegacyParseIssueWithoutStructuredDiagnosticStillDecodes() throws {
        let data = Data(#"[{"line":1,"message":"Legacy diagnostic"}]"#.utf8)

        let issues = try JSONDecoder().decode([ParseIssue].self, from: data)

        XCTAssertEqual(issues, [ParseIssue(line: 1, message: "Legacy diagnostic")])
        XCTAssertNil(issues.first?.diagnostic)
    }

    private func localizationResources() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/SkillSelector/Resources")
    }

    private func stringsDictionary(at url: URL) throws -> [String: String] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
        )
    }
}
