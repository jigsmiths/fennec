// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Fennec",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "FennecCore"),
        .executableTarget(name: "Fennec", dependencies: ["FennecCore"]),
        .testTarget(name: "FennecCoreTests", dependencies: ["FennecCore"]),    ]
)
