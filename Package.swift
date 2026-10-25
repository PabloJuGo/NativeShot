// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NativeShot",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "NativeShot", targets: ["NativeShot"]),
        .library(name: "NativeShotKit", targets: ["NativeShotKit"]),
        .executable(name: "nsbench", targets: ["nsbench"]),
    ],
    targets: [
        // Domain + infrastructure without UI: testable without a window server.
        .target(
            name: "NativeShotKit",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // AppKit/SwiftUI shell, panels and ScreenCaptureKit adapters.
        .executableTarget(
            name: "NativeShot",
            dependencies: ["NativeShotKit"]
        ),
        // Release-only measurements of the Kit (scripts/bench.sh). Not shipped in the app bundle.
        .executableTarget(
            name: "nsbench",
            dependencies: ["NativeShotKit"],
            path: "Benchmarks"
        ),
        .testTarget(
            name: "NativeShotKitTests",
            dependencies: ["NativeShotKit"]
        ),
    ]
)
