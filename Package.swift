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
        .testTarget(
            name: "SkillSelectorCoreTests",
            dependencies: ["SkillSelectorCore", "SkillSelector"]
        ),
    ]
)
