// swift-tools-version:5.9
//
// FrameStack is a SwiftPM package so it can be opened directly in Xcode
// (File > Open… > Package.swift, or `open Package.swift`) and built/tested
// from the command line with `swift build` / `swift test`.
// See README.md and DECISIONS.md (D-002) for why there is no .xcodeproj yet.

import PackageDescription

let package = Package(
    name: "FrameStack",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "FrameStack", targets: ["FrameStack"]),
        .library(name: "FrameStackCore", targets: ["FrameStackCore"]),
        .library(name: "FrameStackMedia", targets: ["FrameStackMedia"]),
    ],
    targets: [
        // Pure, framework-light engine: time model, sampling, compositing
        // math, color transfer functions, geometry helpers.
        .target(name: "FrameStackCore"),

        // macOS media layer: AVFoundation decode, Core Image color
        // conversion, ImageIO export.
        .target(
            name: "FrameStackMedia",
            dependencies: ["FrameStackCore"]
        ),

        // SwiftUI application.
        .executableTarget(
            name: "FrameStack",
            dependencies: ["FrameStackCore", "FrameStackMedia"]
        ),

        .testTarget(
            name: "FrameStackCoreTests",
            dependencies: ["FrameStackCore"]
        ),
        .testTarget(
            name: "FrameStackMediaTests",
            dependencies: ["FrameStackCore", "FrameStackMedia"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
