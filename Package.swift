// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "EnhancedFM",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "RadioDSP"),
        .executableTarget(name: "EnhancedFM", dependencies: ["RadioDSP"]),
        .testTarget(name: "RadioDSPTests", dependencies: ["RadioDSP"]),
    ]
)
