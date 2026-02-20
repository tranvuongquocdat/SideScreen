// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "StreamTest",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "StreamTest",
            targets: ["StreamTest"])
    ],
    targets: [
        .executableTarget(
            name: "StreamTest",
            dependencies: [],
            path: "Sources")
    ]
)
