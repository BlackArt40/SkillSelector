// swift-tools-version: 6.0
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
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SkillSelectorCore", targets: ["SkillSelectorCore"]),
        .executable(name: "SkillSelector", targets: ["SkillSelector"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.0.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        // Pinned exactly (GRDB precedent): MarkdownUI 2.4.1 is the newest tag
        // whose Package.swift still declares .macOS(.v12); a floating range
        // could pick up a release that raises the floor above 12.
        .package(
            url: "https://github.com/gonzalezreal/swift-markdown-ui",
            exact: "2.4.1"
        ),
    ],
    targets: [
        .target(
            name: "SkillSelectorCore",
            dependencies: ["Yams", .product(name: "GRDB", package: "GRDB.swift")]
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
            ]
        ),
    ] + testTargets
)
