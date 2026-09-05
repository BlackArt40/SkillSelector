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
        // textual 暂留，Task 6 移除
        .package(url: "https://github.com/gonzalezreal/textual", from: "0.5.0"),
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
                .product(name: "Textual", package: "textual"),
            ],
            resources: [
                .process("Resources"),
                // SVG bundle: agent brand marks, loaded as template images.
                .copy("AgentIcons"),
            ]
        ),
    ] + testTargets
)
