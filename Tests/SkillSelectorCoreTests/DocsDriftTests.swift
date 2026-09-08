import XCTest
@testable import SkillSelectorCore

/// Guards the mechanical facts docs and code must agree on: the READMEs'
/// built-in agent list mirrors `BuiltInAgentRegistry`. The spec drift the
/// 2026-08 review surfaced (docs promising what the build no longer does)
/// started exactly here — a count updated in code but not in prose.
final class DocsDriftTests: XCTestCase {
    /// `#filePath` is …/Tests/SkillSelectorCoreTests/DocsDriftTests.swift;
    /// three levels up is the package root, independent of the test cwd.
    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func readme(_ name: String) throws -> String {
        let url = packageRoot.appendingPathComponent(name)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            // A missing README is itself a drift signal, not a skip: these
            // guards exist to fail loudly when docs and code diverge. (A
            // rename would otherwise have silenced the whole suite.)
            XCTFail("\(name) not present in this checkout")
            return ""
        }
        return text
    }

    func testChineseReadmeAgentCountMatchesRegistry() throws {
        let readme = try readme("README.md")
        let counts = Self.agentCountMatches(in: readme, pattern: #"内置\s*(\d+)\s*个"#)
        // Exactly one count phrase is expected: a second occurrence of the
        // wording fails the guard on purpose — every count mention must be
        // updated in lockstep with the registry.
        XCTAssertEqual(counts, [BuiltInAgentRegistry.make().definitions.count])
    }

    func testEnglishReadmeAgentCountMatchesRegistry() throws {
        let readme = try readme("README.en.md")
        let counts = Self.agentCountMatches(in: readme, pattern: #"(?i)\b(\d+)\s+built\s+in\b"#)
        XCTAssertEqual(counts, [BuiltInAgentRegistry.make().definitions.count])
    }

    private static func agentCountMatches(in text: String, pattern: String) -> [Int] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        return matches.compactMap { match -> Int? in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            return Int(text[range])
        }
    }

    func testReadmesListEveryBuiltInAgent() throws {
        let readmes = try ["README.md": readme("README.md"), "README.en.md": readme("README.en.md")]
        for definition in BuiltInAgentRegistry.make().definitions {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: definition.displayName))\\b"
            let regex = try NSRegularExpression(pattern: pattern)
            for (name, text) in readmes {
                XCTAssertNotNil(
                    regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                    "\(definition.id) missing from \(name)'s built-in agent list"
                )
            }
        }
    }
}
