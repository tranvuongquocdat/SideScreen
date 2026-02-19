// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SideScreen",
    platforms: [
        .macOS(.v14)  // Required for CGVirtualDisplay API
    ],
    products: [
        .executable(
            name: "SideScreen",
            targets: ["SideScreen"])
    ],
    targets: [
        .executableTarget(
            name: "SideScreen",
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
