// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SkillSelector",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SkillSelectorCore", targets: ["SkillSelectorCore"]),
        .executable(name: "SkillSelector", targets: ["SkillSelector"]),
    ],
    targets: [
        .target(name: "SkillSelectorCore"),
        .executableTarget(
            name: "SkillSelector",
            dependencies: ["SkillSelectorCore"]
        ),
        .testTarget(name: "SkillSelectorCoreTests", dependencies: ["SkillSelectorCore"]),
    ]
)
