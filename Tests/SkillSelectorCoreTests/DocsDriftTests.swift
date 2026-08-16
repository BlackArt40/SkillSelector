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
            throw XCTSkip("\(name) not present in this checkout")
        }
        return text
    }

    func testChineseReadmeAgentCountMatchesRegistry() throws {
        let readme = try readme("README.md")
        let regex = try NSRegularExpression(pattern: #"内置\s*(\d+)\s*个"#)
        let matches = regex.matches(in: readme, range: NSRange(readme.startIndex..., in: readme))
        let counts = matches.compactMap { match -> Int? in
            guard let range = Range(match.range(at: 1), in: readme) else { return nil }
            return Int(readme[range])
        }
        XCTAssertEqual(counts, [BuiltInAgentRegistry.make().definitions.count])
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
