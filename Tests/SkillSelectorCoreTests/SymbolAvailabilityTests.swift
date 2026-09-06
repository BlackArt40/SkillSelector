import XCTest

/// Guards the macOS 12 deployment floor: `Image(systemName:)` silently
/// renders nothing when the symbol is missing from the oldest supported
/// OS (M-acceptance defect: the sidebar Rules row was blank on 12.7).
/// The allowlist was verified against macOS 12's CoreGlyphs
/// `name_availability.plist` — every entry shipped macOS 12.0 or earlier.
/// To add a symbol, verify it exists on macOS 12 first, then extend the list.
final class SymbolAvailabilityTests: XCTestCase {
    private static let allowlist: Set<String> = [
        "arrow.clockwise",
        "arrow.left.arrow.right",
        "arrow.right",
        "arrow.up.arrow.down",
        "arrow.up.forward.app",
        "arrow.up.right",
        "arrow.up.circle",
        "checkmark",
        "checkmark.circle",
        "checkmark.circle.fill",
        "chevron.compact.left",
        "chevron.compact.right",
        "chevron.down",
        "chevron.left.forwardslash.chevron.right",
        "circle.dashed",
        "clock.arrow.circlepath",
        "doc",
        "doc.on.doc",
        "doc.on.doc.fill",
        "doc.text",
        "exclamationmark.triangle",
        "exclamationmark.triangle.fill",
        "externaldrive",
        "externaldrive.badge.xmark",
        "eye.slash",
        "folder",
        "folder.badge.plus",
        "folder.badge.questionmark",
        "gearshape",
        "globe",
        "house",
        "info.circle",
        "link",
        "magnifyingglass",
        "minus.circle",
        "plus",
        "plus.circle",
        "rectangle.connected.to.line.below",
        "rectangle.split.2x1",
        "safari",
        "sparkles",
        "square.stack.3d.up",
        "terminal",
        "xmark",
        "xmark.circle.fill",
    ]

    func testEveryReferencedSystemSymbolExistsOnMacOS12() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/SkillSelectorCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
        let sourcesRoot = repoRoot.appendingPathComponent("Sources")
        let patterns = [
            "systemName:\\s*\"([^\"]+)\"",
            "systemImage:\\s*\"([^\"]+)\"",
            "icon:\\s*\"([^\"]+)\"",
        ]
        let kindCasePattern = "case \\.[A-Za-z]+:\\s*\"([^\"]+)\""

        var referenced: [String: Set<String>] = [:]
        let enumerator = FileManager.default.enumerator(
            at: sourcesRoot,
            includingPropertiesForKeys: nil
        )
        let files = try XCTUnwrap(enumerator).compactMap { $0 as? URL }
        for file in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            let relative = String(file.path.dropFirst(sourcesRoot.path.count + 1))
            var regexes = try patterns.map { try NSRegularExpression(pattern: $0) }
            if file.lastPathComponent == "AuthorizedRootKind+SwiftUI.swift" {
                // `systemImage` returns bare literals inside a switch, so the
                // call-site patterns above cannot see them.
                regexes.append(try NSRegularExpression(pattern: kindCasePattern))
            }
            for regex in regexes {
                let range = NSRange(text.startIndex..., in: text)
                for match in regex.matches(in: text, range: range) {
                    let matchRange = Range(match.range(at: 1), in: text).unsafelyUnwrapped
                    referenced[String(text[matchRange]), default: []].insert(relative)
                }
            }
        }

        // Extraction sanity: if this drops, the regexes or the source
        // layout changed and the check below has gone vacuous.
        XCTAssertGreaterThanOrEqual(
            referenced.count, 40,
            "symbol extraction found almost nothing — check the patterns"
        )

        let violations = referenced
            .filter { !Self.allowlist.contains($0.key) }
            .map { name, files in
                "\(name) @ \(files.sorted().joined(separator: ", "))"
            }
            .sorted()
        XCTAssertTrue(
            violations.isEmpty,
            "SF Symbols not available on macOS 12.0 — pick a 12-available " +
                "equivalent or verify and allowlist:\n" +
                violations.joined(separator: "\n")
        )
    }
}
