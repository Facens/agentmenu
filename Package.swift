// swift-tools-version:5.9
import PackageDescription

// KTD8: three targets over one library. The two executable product names must
// differ by more than case — the default macOS filesystem is case-insensitive,
// so `AgentMenu` and `agentmenu` would collide in .build before either links.
// The CLI keeps the installed leaf name `agentmenu` (bundle.sh renames it).
let package = Package(
    name: "AgentMenu",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "AgentMenu", targets: ["AgentMenu"]),
        .executable(name: "AgentMenuCLI", targets: ["AgentMenuCLI"]),
        .library(name: "AgentMenuKit", targets: ["AgentMenuKit"]),
    ],
    targets: [
        .target(
            name: "AgentMenuKit",
            path: "Sources/AgentMenuKit"
        ),
        .executableTarget(
            name: "AgentMenu",
            dependencies: ["AgentMenuKit"],
            path: "Sources/AgentMenu"
        ),
        .executableTarget(
            name: "AgentMenuCLI",
            dependencies: ["AgentMenuKit"],
            path: "Sources/AgentMenuCLI"
        ),
        // The test runner is a plain executable, not a `.testTarget`.
        // XCTest and swift-testing are Xcode-only tooling: neither module
        // exists in a Command Line Tools install, and R32 forbids depending on
        // Xcode. `make test` runs this; see Tests/AgentMenuKitTests/Harness.swift.
        .executableTarget(
            name: "AgentMenuKitTests",
            dependencies: ["AgentMenuKit"],
            path: "Tests/AgentMenuKitTests"
        ),
    ]
)
