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
    // U10 / R12: Sparkle is attached to the app executable alone, below.
    // 2.10.0 is the floor the plan pins; the package resolves an
    // XCFramework binary target, which `packaging/bundle.sh` copies into
    // Contents/Frameworks and signs bottom-up.
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .target(
            name: "AgentMenuKit",
            path: "Sources/AgentMenuKit"
        ),
        .executableTarget(
            name: "AgentMenu",
            // Sparkle is here and nowhere else: attaching it to
            // AgentMenuKit would pull AppKit into the CLI and the test
            // runner, which packaging/check-source.sh exists to prevent.
            dependencies: ["AgentMenuKit", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/AgentMenu",
            linkerSettings: [
                // The framework ships inside the bundle, so the executable
                // resolves @rpath/Sparkle.framework relative to itself.
                // Without this the app links here and dies at launch on any
                // machine, including this one.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
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
