import Foundation
import XCTest
@testable import SkillSelectorCore

final class StructuredDiagnosticTests: XCTestCase {
    func testLocalizationKeyMatchesRawValue() {
        for code in DiagnosticCode.allCases {
            XCTAssertEqual(code.localizationKey, code.rawValue)
            XCTAssertTrue(code.rawValue.hasPrefix("diagnostic."))
        }
    }

    func testEveryCodeProducesNonEmptyFallbackMessage() {
        for code in DiagnosticCode.allCases {
            let diagnostic = StructuredDiagnostic(code: code, arguments: ["first", "second"])
            XCTAssertFalse(
                diagnostic.fallbackMessage.isEmpty,
                "\(code) should produce a fallback message"
            )
        }
    }

    func testParameterizedFallbacksInterpolateArguments() {
        XCTAssertEqual(
            StructuredDiagnostic(
                code: .missingRequiredFrontmatterField,
                arguments: ["name"]
            ).fallbackMessage,
            "Missing required frontmatter field: name"
        )
        XCTAssertEqual(
            StructuredDiagnostic(
                code: .unableToReadEntry,
                arguments: ["SKILL.md", "permission denied"]
            ).fallbackMessage,
            "Unable to read SKILL.md: permission denied"
        )
        XCTAssertEqual(
            StructuredDiagnostic(
                code: .unableToInspectAuthorizedDirectory,
                arguments: ["/root"]
            ).fallbackMessage,
            "Unable to inspect authorized directory: /root"
        )
    }

    func testParameterizedFallbacksTolerateMissingArguments() {
        XCTAssertEqual(
            StructuredDiagnostic(code: .missingRequiredFrontmatterField).fallbackMessage,
            "Missing required frontmatter field: "
        )
        XCTAssertEqual(
            StructuredDiagnostic(code: .unableToReadEntry, arguments: ["SKILL.md"]).fallbackMessage,
            "Unable to read SKILL.md: "
        )
    }

    func testStaticFallbacksIgnoreArguments() {
        XCTAssertEqual(
            StructuredDiagnostic(
                code: .missingFrontmatterBoundary,
                arguments: ["ignored"]
            ).fallbackMessage,
            "Missing frontmatter boundary"
        )
    }

    func testCodableRoundTrip() throws {
        let diagnostic = StructuredDiagnostic(
            code: .scanFailed,
            arguments: ["i/o error"]
        )
        let decoded = try JSONDecoder().decode(
            StructuredDiagnostic.self,
            from: JSONEncoder().encode(diagnostic)
        )

        XCTAssertEqual(decoded, diagnostic)
    }
}
