// swift-tools-version: 5.10
import Foundation
import PackageDescription

// The test target stays conditional so source-only exports without Tests/
// still build; normal checkouts always carry the suite (Tests/ is tracked).
let testTargets: [Target] = FileManager.default.fileExists(atPath: "Tests")
    ? [
        .testTarget(
            name: "SkillSelectorCoreTests",
            dependencies: ["SkillSelectorCore", "SkillSelector"]
        ),
    ]
    : []

let package = Package(
    name: "SkillSelector",
    defaultLocalization: "en",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "SkillSelectorCore", targets: ["SkillSelectorCore"]),
        .executable(name: "SkillSelector", targets: ["SkillSelector"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.0.0"),
        // tools 6.0+ since GRDB 7.0; 6.29.3 is the last tools-5.x release.
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "6.29.3"),
        // Pinned exactly (GRDB precedent): MarkdownUI 2.4.1 is the newest tag
        // whose Package.swift still declares .macOS(.v12); a floating range
        // could pick up a release that raises the floor above 12.
        .package(
            url: "https://github.com/gonzalezreal/swift-markdown-ui",
            exact: "2.4.1"
        ),
        // MarkdownUI's test-only transitive dependency; pin to the last
        // tools-5.x release, otherwise resolution picks 1.19.4 (tools 6.0).
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", exact: "1.17.0"),
    ],
    targets: [
        .target(
            name: "SkillSelectorCore",
            dependencies: ["Yams", .product(name: "GRDB", package: "GRDB.swift")],
            // tools 5.10 builds in the Swift 5 language mode, so restore the
            // strict-concurrency diagnostics CI's Xcode 16 would skip. Core
            // has no SwiftUI macros, so make every diagnostic fatal there.
            swiftSettings: [
                .unsafeFlags(["-strict-concurrency=complete", "-warnings-as-errors"]),
            ]
        ),
        .executableTarget(
            name: "SkillSelector",
            dependencies: [
                "SkillSelectorCore",
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
            ],
            resources: [
                .process("Resources"),
                // SVG bundle: agent brand marks, loaded as template images.
                .copy("AgentIcons"),
            ],
            // Strict concurrency without -warnings-as-errors: SwiftUI's
            // macro expansion emits warnings outside our control.
            swiftSettings: [
                .unsafeFlags(["-strict-concurrency=complete"]),
            ]
        ),
    ] + testTargets
)
