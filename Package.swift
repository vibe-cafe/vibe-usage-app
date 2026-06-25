// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VibeUsage",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .target(
            name: "VibeUsageCore",
            path: "VibeUsageCore"
        ),
        .executableTarget(
            name: "VibeUsage",
            dependencies: [
                "VibeUsageCore",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "VibeUsage",
            exclude: ["Info.plist"],
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "ThemeChecks",
            dependencies: ["VibeUsageCore"],
            path: "Tests/ThemeChecks"
        )
    ]
)
