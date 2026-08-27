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
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SkillSelectorCore", targets: ["SkillSelectorCore"]),
        .executable(name: "SkillSelector", targets: ["SkillSelector"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.0.0"),
    ],
    targets: [
        .target(
            name: "SkillSelectorCore",
            dependencies: ["Yams"]
        ),
        .executableTarget(
            name: "SkillSelector",
            dependencies: ["SkillSelectorCore"],
            resources: [
                .process("Resources"),
                // SVG bundle: agent brand marks, loaded as template images.
                .copy("AgentIcons"),
            ]
        ),
    ] + testTargets
)
