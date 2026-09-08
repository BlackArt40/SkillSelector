import Foundation
import XCTest

/// Guards format-placeholder parity between the en and zh-Hans string
/// tables. L10nParityTests already proves the key sets match; this file
/// proves the *values* keep the same placeholders (%@, %d, %lld, …) so a
/// translation can no longer drop or add an argument and crash
/// `String(format:)` at runtime. Reads the .strings files straight from
/// the package sources (same approach as DocsDriftTests) — offline and
/// deterministic.
final class L10nPlaceholderParityTests: XCTestCase {
    private var resourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/SkillSelector/Resources")
    }

    private func table(_ locale: String) throws -> [String: String] {
        let url = resourcesRoot.appendingPathComponent("\(locale).lproj/Localizable.strings")
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return try XCTUnwrap(
            plist as? [String: String],
            "unexpected .strings plist shape for \(locale)"
        )
    }

    /// printf-style conversion tokens, including positional ("%1$@") and
    /// length-modified ("%lld") forms. Extracted as sorted multisets so a
    /// translation may reorder arguments (via positional specifiers) but
    /// never change the argument multiset. Escaped percent signs ("%%",
    /// a literal "%") are stripped first — otherwise "%% similar" pairs
    /// the second "%" with the following " s" into a bogus "% s" token.
    private static func placeholders(in value: String) -> [String] {
        let cleaned = value.replacingOccurrences(of: "%%", with: "\u{F8FF}")
        let pattern = #"%(\d+\$)?[-+ 0#']*\d*(?:\.\d+)?(?:hh|h|ll|l|L|q|z|t|j)?[@dDuUfFeEgGxXoOcsPaA]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(cleaned.startIndex..., in: cleaned)
        return regex.matches(in: cleaned, range: range).compactMap {
            Range($0.range, in: cleaned).map { String(cleaned[$0]) }
        }
    }

    func testPlaceholderMultisetsMatchAcrossLanguages() throws {
        let english = try table("en")
        let chinese = try table("zh-Hans")

        // Re-checked here so a placeholder regression cannot hide behind a
        // key-set failure message.
        XCTAssertEqual(Set(english.keys), Set(chinese.keys))

        for key in english.keys.sorted() {
            let englishTokens = Self.placeholders(in: english[key] ?? "").sorted()
            let chineseTokens = Self.placeholders(in: chinese[key] ?? "").sorted()
            XCTAssertEqual(
                englishTokens,
                chineseTokens,
                "placeholder mismatch for key: \(key)"
            )
        }
    }
}
