// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CaptureTest",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "CaptureTest",
            targets: ["CaptureTest"])
    ],
    targets: [
        .executableTarget(
            name: "CaptureTest",
            dependencies: [],
            path: "Sources",
            cSettings: [
                .unsafeFlags(["-I", "Sources"])
            ],
            swiftSettings: [
                .unsafeFlags(["-Xcc", "-fmodule-map-file=Sources/module.modulemap"])
            ])
    ]
)
