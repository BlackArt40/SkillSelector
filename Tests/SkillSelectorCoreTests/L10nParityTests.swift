import XCTest

/// Guards the localization contract: every user-facing key must exist in
/// BOTH language files. A missing key surfaces as the raw English key in
/// the localized UI (the acceptance run shipped "No Duplicates
/// Description" leaking into the Chinese duplicates empty state).
final class L10nParityTests: XCTestCase {
    private func keys(in file: URL) throws -> Set<String> {
        let text = try String(contentsOf: file, encoding: .utf8)
        let regex = try NSRegularExpression(
            pattern: "^\"((?:[^\"\\\\]|\\\\.)*)\"\\s*=",
            options: [.anchorsMatchLines]
        )
        var keys = Set<String>()
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: range) {
            let matchRange = Range(match.range(at: 1), in: text).unsafelyUnwrapped
            keys.insert(String(text[matchRange]))
        }
        return keys
    }

    func testEveryKeyExistsInBothLanguages() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/SkillSelectorCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
        let resources = repoRoot
            .appendingPathComponent("Sources/SkillSelector/Resources")
        let english = try keys(
            in: resources.appendingPathComponent("en.lproj/Localizable.strings")
        )
        let chinese = try keys(
            in: resources.appendingPathComponent("zh-Hans.lproj/Localizable.strings")
        )

        // Extraction sanity: the regex must see the real key population.
        XCTAssertGreaterThan(english.count, 200, "key extraction broke — check the pattern")
        XCTAssertGreaterThan(chinese.count, 200, "key extraction broke — check the pattern")

        let missingFromChinese = english.subtracting(chinese).sorted()
        let missingFromEnglish = chinese.subtracting(english).sorted()
        XCTAssertTrue(
            missingFromChinese.isEmpty,
            "keys missing from zh-Hans: \(missingFromChinese)"
        )
        XCTAssertTrue(
            missingFromEnglish.isEmpty,
            "keys missing from en: \(missingFromEnglish)"
        )
    }

    /// Every `L10n.string("...")` literal in the app sources must resolve —
    /// an undefined key renders as the raw key text in the UI. Dynamic
    /// (interpolated) keys are invisible here, same caveat as the symbol
    /// allowlist test.
    func testEveryReferencedKeyIsDefined() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/SkillSelectorCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
        let sources = repoRoot.appendingPathComponent("Sources")
        let stringsFile = repoRoot
            .appendingPathComponent("Sources/SkillSelector/Resources/en.lproj/Localizable.strings")
        let defined = try keys(in: stringsFile)

        let pattern = try NSRegularExpression(pattern: "L10n\\.string\\(\\s*\"([^\"]+)\"")
        var referenced = Set<String>()
        let files = FileManager.default.enumerator(
            at: sources,
            includingPropertiesForKeys: nil
        )
        let swiftFiles = try XCTUnwrap(files).compactMap { $0 as? URL }
        for file in swiftFiles where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            for match in pattern.matches(in: text, range: range) {
                let matchRange = Range(match.range(at: 1), in: text).unsafelyUnwrapped
                referenced.insert(String(text[matchRange]))
            }
        }

        XCTAssertGreaterThan(referenced.count, 20, "key extraction broke — check the pattern")
        let undefined = referenced.subtracting(defined).sorted()
        XCTAssertTrue(
            undefined.isEmpty,
            "L10n.string references undefined keys (render as raw key text): \(undefined)"
        )
    }
}
