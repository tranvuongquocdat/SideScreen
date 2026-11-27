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
    dependencies: [
        // Auto-update. The framework is copied into Contents/Frameworks by the
        // build scripts; the rpath below is what makes the binary find it there.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.1")
    ],
    targets: [
        // libx264 is loaded at runtime (dlopen); only its header is needed to build.
        .target(
            name: "X264Shim",
            path: "Sources/X264Shim",
            cSettings: [
                .unsafeFlags(["-I/usr/local/include", "-I/opt/homebrew/include"])
            ]),
        .executableTarget(
            name: "SideScreen",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle"),
                "X264Shim"
            ],
            path: "Sources",
            exclude: ["X264Shim"],
            cSettings: [
                .unsafeFlags(["-I", sourcesPath])
            ],
            swiftSettings: [
                .unsafeFlags(["-Xcc", "-fmodule-map-file=\(sourcesPath)/module.modulemap"])
            ],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
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
