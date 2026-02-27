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
        .executableTarget(
            name: "VibeUsage",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "VibeUsage",
            exclude: ["Info.plist"],
            resources: [
                .process("Resources")
            ]
        )
    ]
)
