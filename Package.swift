// swift-tools-version: 6.0
import Foundation
import PackageDescription

// The test suite stays local-only (see .gitignore); a published checkout
// without Tests/ must still build, so the test target is conditional.
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
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
    ],
    targets: [
        .target(
            name: "SkillSelectorCore",
            dependencies: ["Yams"]
        ),
        .executableTarget(
            name: "SkillSelector",
            dependencies: ["SkillSelectorCore"],
            resources: [.process("Resources")]
        ),
    ] + testTargets
)
