// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "RecompHelper",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "RecompHelper", path: "Sources/RecompHelper"),
    ]
)
