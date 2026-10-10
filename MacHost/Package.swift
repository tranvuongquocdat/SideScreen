// swift-tools-version: 5.9
import Foundation
import PackageDescription

// Swift Build can invoke the compiler from outside the package directory.
// Resolve custom compiler paths relative to this manifest instead of its working directory.
let sourcesPath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Sources")
    .path

let package = Package(
    name: "SideScreen",
    platforms: [
        // Floor is ScreenCaptureKit basics (12.3) + OSAllocatedUnfairLock /
        // SCStreamConfiguration.capturesAudio (13.0). CGVirtualDisplay is a
        // private API present well before 13 — it does NOT require 14.
        .macOS(.v13)
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
                .unsafeFlags(["-I", sourcesPath])
            ],
            swiftSettings: [
                .unsafeFlags(["-Xcc", "-fmodule-map-file=\(sourcesPath)/module.modulemap"])
            ]),
        .testTarget(
            name: "SideScreenTests",
            dependencies: ["SideScreen"],
            path: "Tests/SideScreenTests",
            cSettings: [
                .unsafeFlags(["-I", sourcesPath])
            ],
            swiftSettings: [
                .unsafeFlags(["-Xcc", "-fmodule-map-file=\(sourcesPath)/module.modulemap"])
            ]
        )
    ]
)
