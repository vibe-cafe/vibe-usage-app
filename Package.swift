// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VibeUsage",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "VibeUsage",
            path: "VibeUsage",
            exclude: ["Info.plist"],
            resources: [
                .process("Resources")
            ]
        )
    ]
)
