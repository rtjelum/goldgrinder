// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GoldGrinder",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "GoldGrinder",
            path: "Sources/GoldGrinder",
            resources: [.process("Resources")]
        )
    ]
)
