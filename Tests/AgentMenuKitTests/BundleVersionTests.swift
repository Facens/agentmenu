// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// R20 / KTD10 (as amended): `packaging/bundle.sh` sources `packaging/version.sh`
/// to turn `VERSION` into a channel (stable, beta or alpha) and a derived
/// `CFBundleVersion`, then stamps both the `__VERSION__` and `__BUILD__`
/// placeholders. Sparkle's comparator (`SUStandardVersionComparator`) stops
/// reading a version at the first "-", so `CFBundleShortVersionString` and
/// `CFBundleVersion` can no longer be the same string — a beta and its final
/// release would tie and a beta install could never be offered the final. A
/// version outside the grammar must fail the bundle step before a build is
/// even started, rather than stamping a build number no client could order.
///
/// The rejection cases run the real script. They are fast because the check
/// sits before `swift build`; a rejection that took seconds would mean the
/// validation had drifted below the build and was no longer the gate.
func runBundleVersionTests(_ t: TestRunner) {
    t.suite("BundleVersion")

    let root = repositoryRoot()
    let script = root.appendingPathComponent("packaging/bundle.sh").path
    let versionScript = root.appendingPathComponent("packaging/version.sh").path
    let template = root.appendingPathComponent("packaging/Info.plist").path
    guard FileManager.default.isExecutableFile(atPath: script),
          FileManager.default.isReadableFile(atPath: versionScript),
          FileManager.default.isReadableFile(atPath: template) else {
        print("   (skipped: packaging/bundle.sh, packaging/version.sh or packaging/Info.plist not found at \(root.path))")
        return
    }

    // Happy path: the two placeholders feed the two keys independently — the
    // short version is the human string as written, the build number is
    // derived (beta.3 -> the fourth component 3).
    if let source = try? String(contentsOfFile: template, encoding: .utf8) {
        let rendered = source
            .replacingOccurrences(of: "__VERSION__", with: "0.2.0-beta.3")
            .replacingOccurrences(of: "__BUILD__", with: "0.2.0.3")
        let plist = (try? PropertyListSerialization.propertyList(
            from: Data(rendered.utf8), format: nil
        )) as? [String: Any]
        t.expectEqual(plist?["CFBundleShortVersionString"] as? String, "0.2.0-beta.3", "display version is the human version string")
        t.expectEqual(plist?["CFBundleVersion"] as? String, "0.2.0.3", "build version is the derived four-component number")
        t.expect(!rendered.contains("__VERSION__"), "no __VERSION__ placeholder survives rendering")
        t.expect(!rendered.contains("__BUILD__"), "no __BUILD__ placeholder survives rendering")
    } else {
        t.expect(false, "packaging/Info.plist is readable")
    }

    // The table from packaging/version.sh's own header comment: each accepted
    // form prints its channel, then its derived build number, on stdout.
    let table: [(version: String, channel: String, build: String)] = [
        ("0.2.0", "stable", "0.2.0.100"),
        ("0.2.0-beta.1", "beta", "0.2.0.1"),
        ("0.2.0-beta.99", "beta", "0.2.0.99"),
        ("0.2.0-alpha", "alpha", "0.2.0.0"),
    ]
    for entry in table {
        let result = runProcess(
            "/bin/bash",
            ["-c", "source packaging/version.sh && version_channel \"$1\" && version_build \"$1\"", "_", entry.version],
            in: root
        )
        let lines = result.stdout.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        t.expectEqual(result.status, 0, "\(entry.version) is accepted by version.sh")
        t.expect(lines.count == 2, "\(entry.version) prints exactly two stdout lines, got \(lines.count)")
        if lines.count == 2 {
            t.expectEqual(lines[0], entry.channel, "\(entry.version) reports channel \(entry.channel)")
            t.expectEqual(lines[1], entry.build, "\(entry.version) reports build \(entry.build)")
        }
    }

    // Rejection: a beta number of 0 or over 99, a suffix outside the grammar,
    // an alpha with a number, a leading v (the workflow strips it, the script
    // does not), too few or too many components, and plain garbage. Each
    // must exit non-zero, name the problem, and leave no bundle behind.
    let rejected = ["0.2.0-beta.0", "0.2.0-beta.100", "0.2.0-rc1", "0.2.0-alpha.1", "v0.2.0", "0.2", "1.2.3.4", "abc"]
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
