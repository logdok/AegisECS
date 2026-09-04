// swift-tools-version: 6.0
import PackageDescription

// A faithful Swift port of the Aegis ECS addon (originally pure GDScript for
// Godot 4). The behaviour is pinned by the ported test suite: swap-remove
// leaves the dense array unordered, detach_flagged performs the theoretical
// minimum of moves, an exhausted generation retires a slot forever, and so on.
let package = Package(
    name: "AegisECS",
    platforms: [
        // iOS 16 (not 15) because AegisECSInspectorUI's system-toggle row uses
        // the `View.underline(_:pattern:color:)` modifier, which only exists
        // from iOS 16 / macOS 13 on. SwiftPM has one platform floor per
        // package, not per target, so the plain AegisECS (core, no SwiftUI)
        // target is pinned to it too — matches CalmRoom's own floor anyway.
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "AegisECS", targets: ["AegisECS"]),
        // A SwiftUI dev/diagnostics panel, independent of any host app: it
        // needs nothing but a reference to an `Inspector`. Split into its own
        // product so a headless target (a CI budget check, a server) can
        // depend on plain `AegisECS` without pulling in SwiftUI.
        .library(name: "AegisECSInspectorUI", targets: ["AegisECSInspectorUI"]),
    ],
    targets: [
        .target(
            name: "AegisECS"
            // No unsafe compiler flags: a target that declares unsafeFlags
            // cannot be resolved by anyone as a version/branch/revision
            // SwiftPM dependency, only as a local path dependency. The hot
            // loops already index dense columns through raw pointers
            // (UnsafeMutableBufferPointer), which Swift never bounds-checks
            // regardless of build configuration — so this library stays fast
            // in release without needing -Ounchecked. See docs/en/09-performance.md §9.2.
        ),
        .target(
            name: "AegisECSInspectorUI",
            dependencies: ["AegisECS"]
        ),
        .testTarget(
            name: "AegisECSTests",
            dependencies: ["AegisECS"]
        ),
    ]
)
