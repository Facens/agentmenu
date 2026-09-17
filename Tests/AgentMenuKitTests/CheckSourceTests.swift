// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AgentMenuKit

/// R21: `packaging/check-source.sh` is the licence-header and Kit-purity gate
/// CI runs on every push and pull request. Each scenario runs the real
/// script against a scratch export of the tracked tree — `git archive HEAD`
/// piped into a `TempDir`, with the working-tree script and `Package.swift`
/// overlaid, so `swift package dump-package` has a manifest and a
/// `Sources`/`Tests` tree to inspect. No git repository is created here:
/// unlike the publish script, check-source.sh never touches git, so the
/// export alone is enough.
func runCheckSourceTests(_ t: TestRunner) {
    t.suite("CheckSource")

    let root = repositoryRoot()
    guard FileManager.default.isExecutableFile(atPath: root.appendingPathComponent("packaging/check-source.sh").path),
          FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else {
        print("   (skipped: packaging/check-source.sh or git not found)")
        return
    }

    // The file every mutating scenario edits — present in every checkout,
    // so there is nothing to look up before mutating it.
    let target = "Sources/AgentMenuKit/AgentMenuKit.swift"

    // 1. The untouched export passes.
    do {
        let scratch = TempDir("check-source-clean")
        defer { scratch.cleanup() }
        guard makeScratchSourceTree(from: root, at: scratch.url, t) else { return }

        let result = runProcess("/usr/bin/env", ["packaging/check-source.sh"], in: scratch.url)
        t.expectEqual(result.status, 0, "the untouched tree passes")
        t.expect(result.stdout.contains("source checks: ok"), "stdout says so")
    }

    // 2. A stray AppKit-family import under AgentMenuKit fails, naming the file.
    do {
        let scratch = TempDir("check-source-import")
        defer { scratch.cleanup() }
        guard makeScratchSourceTree(from: root, at: scratch.url, t) else { return }

        let targetURL = scratch.url.appendingPathComponent(target)
        guard let original = try? String(contentsOf: targetURL, encoding: .utf8) else {
            t.expect(false, "read \(target) before appending the stray import")
            return
        }
        t.expectNoThrow("appended an AppKit-family import to \(target)") {
            try (original + "\nimport Cocoa\n").write(to: targetURL, atomically: true, encoding: .utf8)
        }

        let result = runProcess("/usr/bin/env", ["packaging/check-source.sh"], in: scratch.url)
        t.expect(result.status != 0, "an AppKit-family import under AgentMenuKit fails the check")
        t.expect(result.stderr.contains(target), "stderr names the offending file")
    }

    // 3. A duplicated SPDX line fails, naming the count.
    do {
        let scratch = TempDir("check-source-spdx")
        defer { scratch.cleanup() }
        guard makeScratchSourceTree(from: root, at: scratch.url, t) else { return }

        let targetURL = scratch.url.appendingPathComponent(target)
        guard let original = try? String(contentsOf: targetURL, encoding: .utf8) else {
            t.expect(false, "read \(target) before duplicating its SPDX line")
            return
        }
        let spdx = "// SPDX-License-Identifier: GPL-3.0-or-later"
        let duplicated = original.replacingOccurrences(of: spdx, with: "\(spdx)\n\(spdx)")
        t.expect(duplicated != original, "the SPDX line was actually found and duplicated in \(target)")
        t.expectNoThrow("wrote a duplicated SPDX line into \(target)") {
            try duplicated.write(to: targetURL, atomically: true, encoding: .utf8)
        }

        let result = runProcess("/usr/bin/env", ["packaging/check-source.sh"], in: scratch.url)
        t.expect(result.status != 0, "a duplicated SPDX line fails the check")
        t.expect(result.stderr.contains("2 SPDX lines"), "stderr names the count")
    }
}

/// A throwaway export of the tracked tree with the working-tree
/// `check-source.sh` and `Package.swift` laid over it, so uncommitted edits
/// to either are what gets exercised. No git repository is created — the
/// script only reads files, never git state.
private func makeScratchSourceTree(from root: URL, at dir: URL, _ t: TestRunner) -> Bool {
    let export = runProcess(
        "/usr/bin/env",
        ["/bin/bash", "-c", "git -C \(ShellQuoting.singleQuoted(root.path)) archive HEAD | tar -x -C \(ShellQuoting.singleQuoted(dir.path))"],
        in: root
    )
    guard export.status == 0 else {
        t.expect(false, "exported the tracked tree into a scratch directory: \(export.stderr)")
        return false
    }
    for overlay in ["packaging/check-source.sh", "Package.swift"] {
        let source = root.appendingPathComponent(overlay)
        let overlayTarget = dir.appendingPathComponent(overlay)
        try? FileManager.default.removeItem(at: overlayTarget)
        do {
            try FileManager.default.copyItem(at: source, to: overlayTarget)
        } catch {
            t.expect(false, "copied \(overlay) into the scratch tree: \(error)")
            return false
        }
    }
    do {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: dir.appendingPathComponent("packaging/check-source.sh").path
        )
    } catch {
        t.expect(false, "made check-source.sh executable in the scratch tree: \(error)")
        return false
    }
    return true
}
