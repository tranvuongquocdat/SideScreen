// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VirtualDisplayHost",
    platforms: [
        .macOS(.v14)  // Required for CGVirtualDisplay API
    ],
    products: [
        .executable(
            name: "VirtualDisplayHost",
            targets: ["VirtualDisplayHost"])
    ],
    targets: [
        .executableTarget(
            name: "VirtualDisplayHost",
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
