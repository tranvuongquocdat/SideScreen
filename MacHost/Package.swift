// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TabVirtualDisplay",
    platforms: [
        .macOS(.v14)  // Required for CGVirtualDisplay API
    ],
    products: [
        .executable(
            name: "TabVirtualDisplay",
            targets: ["TabVirtualDisplay"])
    ],
    targets: [
        .executableTarget(
            name: "TabVirtualDisplay",
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
