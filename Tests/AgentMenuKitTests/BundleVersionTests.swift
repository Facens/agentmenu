// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// R20 / KTD10: `packaging/bundle.sh` stamps one `__VERSION__` placeholder into
/// both `CFBundleShortVersionString` and `CFBundleVersion`, and refuses any
/// version that is not dotted digits. Sparkle orders updates by
/// `CFBundleVersion`, numerically, and cannot downgrade — so a suffixed or
/// malformed version must fail the bundle step before a build is even started,
/// rather than stamping a number no client could order.
///
/// The rejection cases run the real script. They are fast because the check
/// sits before `swift build`; a rejection that took seconds would mean the
/// validation had drifted below the build and was no longer the gate.
func runBundleVersionTests(_ t: TestRunner) {
    t.suite("BundleVersion")

    let root = repositoryRoot()
    let script = root.appendingPathComponent("packaging/bundle.sh").path
    let template = root.appendingPathComponent("packaging/Info.plist").path
    guard FileManager.default.isExecutableFile(atPath: script),
          FileManager.default.isReadableFile(atPath: template) else {
        print("   (skipped: packaging/bundle.sh or packaging/Info.plist not found at \(root.path))")
        return
    }

    // Happy path: the one placeholder feeds both keys, so a release version
    // is the same string wherever it is read back.
    if let source = try? String(contentsOfFile: template, encoding: .utf8) {
        let rendered = source.replacingOccurrences(of: "__VERSION__", with: "0.2.0")
        let plist = (try? PropertyListSerialization.propertyList(
            from: Data(rendered.utf8), format: nil
        )) as? [String: Any]
        t.expectEqual(plist?["CFBundleShortVersionString"] as? String, "0.2.0", "display version is the tag's version")
        t.expectEqual(plist?["CFBundleVersion"] as? String, "0.2.0", "build version is the tag's version")
        t.expect(!rendered.contains("__VERSION__"), "no placeholder survives rendering")
    } else {
        t.expect(false, "packaging/Info.plist is readable")
    }

    // Rejection: a suffix (there are no pre-release tags), a leading v (the
    // workflow strips it, the script does not), too few or too many
    // components, and plain garbage. Each must exit non-zero, name the
    // problem, and leave no bundle behind.
    let rejected = ["0.2.0-rc1", "0.2.0-beta.1", "v0.2.0", "0.2", "1.2.3.4", "abc"]
    for version in rejected {
        let dist = TempDir("bundle-version")
        defer { dist.cleanup() }

        let started = Date()
        let result = runProcess(
            "/bin/bash", [script],
            environment: ["VERSION": version, "DIST": dist.url.path]
        )
        let elapsed = Date().timeIntervalSince(started)

        t.expect(result.status != 0, "VERSION=\(version) fails the bundle step")
        t.expect(result.stderr.contains("VERSION must be"), "VERSION=\(version) says what a version must look like")
        t.expect(!FileManager.default.fileExists(atPath: dist.path("AgentMenu.app")), "VERSION=\(version) produces no bundle")
        t.expect(elapsed < 5, "VERSION=\(version) is refused before anything is built (took \(Int(elapsed))s)")
    }
}

