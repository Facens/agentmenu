// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AgentMenuKit

/// R8 / KTD6: `packaging/publish-public.sh` replaces the public checkout's
/// working tree wholesale with a snapshot of the private tree minus the
/// exclude list. Two things have to hold for that to be safe. The tree that
/// goes out must contain nothing private — asserted positively, against
/// patterns, because an exclude list only proves it fires on the paths
/// already in it. And the public checkout must be on `main`: the update feed
/// lives on `gh-pages`, and a sync pointed there would delete what every
/// installed copy reads.
///
/// Each scenario runs the real script from the working tree inside a scratch
/// clone of the tracked tree, so the script under test is the one about to be
/// committed, and nothing here touches the maintainer's own checkouts.
func runPublishScriptTests(_ t: TestRunner) {
    t.suite("PublishScript")

    let root = repositoryRoot()
    guard FileManager.default.isExecutableFile(atPath: root.appendingPathComponent("packaging/publish-public.sh").path),
          FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else {
        print("   (skipped: packaging/publish-public.sh or git not found)")
        return
    }

    // A clean dry run lists the tree and nothing on the exclude list.
    do {
        let scratch = TempDir("publish-clean")
        defer { scratch.cleanup() }
        guard makeScratchPrivateRepo(from: root, at: scratch.url, t) else { return }

        let result = shell(["packaging/publish-public.sh", "--dry-run"], in: scratch.url)
        t.expectEqual(result.status, 0, "a clean tree publishes (dry run)")
        t.expect(result.stdout.contains("would publish this tree:"), "the dry run lists the tree")
        t.expect(result.stdout.contains("Package.swift\n"), "the listing carries the package manifest")
        for excluded in ["docs/plans", "docs/releasing.md", "docs/research-notes.md", "docs/spike-menubar", "docs/design-mockup", "packaging/publish-public.sh", "packaging/publish-exclude.txt"] {
            t.expect(!result.stdout.contains(excluded), "\(excluded) is not in the published tree")
        }
        t.expect(!result.stdout.contains("build and suite"), "a dry run does not run the build gate")
    }

    // A plan filed at a path the exclude list does not name is caught by the
    // positive pattern check rather than sailing through.
    do {
        let scratch = TempDir("publish-leak")
        defer { scratch.cleanup() }
        guard makeScratchPrivateRepo(from: root, at: scratch.url, t) else { return }

        let leak = "docs/notes/2026-10-01-feat-something-plan.md"
        try? scratch.write("# a plan that nobody listed\n", to: leak)
        _ = shell(["git", "add", "-A"], in: scratch.url)
        _ = gitCommit("file a plan somewhere new", in: scratch.url)

        let result = shell(["packaging/publish-public.sh", "--dry-run"], in: scratch.url)
        t.expect(result.status != 0, "an unlisted plan path fails the dry run")
        t.expect(result.stderr.contains("private material"), "the refusal says why")
        t.expect(result.stderr.contains(leak), "the refusal names the leaking path")
        t.expect(!result.stdout.contains("would publish"), "nothing is listed as publishable")
    }

    // A broader sweep of PRIVATE_PATTERNS: the plans pattern's case
    // insensitivity, the singular "plan.md", the free-text "runbook" and
    // "secret" patterns, an ssh key by its filename prefix, a certificate by
    // its extension, an environment file, and the agent-configuration
    // directory. One path is deliberately relocated off "docs/plans": that
    // directory is already tracked in this repository, and this filesystem
    // is case-insensitive, so writing "docs/Plans/..." here would silently
    // land inside the existing "docs/plans" (same inode, original case
    // wins) rather than exercise a differently-cased path at all.
    do {
        let scratch = TempDir("publish-leak-sweep")
        defer { scratch.cleanup() }
        guard makeScratchPrivateRepo(from: root, at: scratch.url, t) else { return }

        let leaks = [
            "notes/Plans/2026-x.md",                       // plans DIRECTORY pattern, differently cased; the filename must not itself end in "-plan.md", or a leak here would not distinguish this pattern from the separate "*-plan.md" one
            "docs/RUNBOOK.md",                            // runbook pattern, upper case
            "docs/plan.md",                                // plans pattern, singular + extension
            "Sources/AgentMenuKit/SecretsManager.swift",   // the free-text "secret" pattern
            "keys/id_ed25519",                             // an ssh private key
            "certs/dev.p12",                                // key material, by extension
            ".env.local",                                   // an environment file
            ".claude/settings.json",                        // agent configuration
        ]
        for leak in leaks {
            t.expectNoThrow("wrote the leak fixture at \(leak)") {
                try scratch.write("private\n", to: leak)
            }
        }
        _ = shell(["git", "add", "-A"], in: scratch.url)
        _ = gitCommit("file a sweep of private-pattern leaks", in: scratch.url)

        let result = shell(["packaging/publish-public.sh", "--dry-run"], in: scratch.url)
        t.expect(result.status != 0, "a tree carrying one of each private pattern fails the dry run")
        for leak in leaks {
            t.expect(result.stderr.contains(leak), "the refusal names \(leak)")
        }
    }

    // The script refuses a public checkout that is not on main, and does so
    // before the build gate would have run.
    do {
        let scratch = TempDir("publish-branch")
        defer { scratch.cleanup() }
        guard makeScratchPrivateRepo(from: root, at: scratch.url, t) else { return }

        // A sibling directory, not a subdirectory: inside the private scratch
        // repository it would show up as an untracked path and trip the
        // uncommitted-changes check first.
        let publicScratch = TempDir("publish-branch-public")
        defer { publicScratch.cleanup() }
        let publicDir = publicScratch.url
        _ = shell(["git", "init", "-q", "-b", "main"], in: publicDir)
        try? publicScratch.write("feed\n", to: "index.html")
        _ = shell(["git", "add", "-A"], in: publicDir)
        _ = gitCommit("placeholder", in: publicDir)
        _ = shell(["git", "checkout", "-q", "-b", "gh-pages"], in: publicDir)

        let started = Date()
        let result = shell(["packaging/publish-public.sh", "--public-dir", publicDir.path], in: scratch.url)
        let elapsed = Date().timeIntervalSince(started)
        t.expect(result.status != 0, "a public checkout on gh-pages is refused")
        t.expect(result.stderr.contains("gh-pages") && result.stderr.contains("not main"), "the refusal names the branch")
        t.expect(elapsed < 5, "the refusal happens before the build gate (took \(Int(elapsed))s)")
        let stillThere = FileManager.default.fileExists(atPath: publicDir.appendingPathComponent("index.html").path)
        t.expect(stillThere, "the gh-pages tree was not touched")
    }
}

// MARK: - Scratch repositories

/// A throwaway private repository: the tracked tree of the real one, with the
/// working-tree publish script and exclude list laid over it so uncommitted
/// edits to either are what gets exercised.
private func makeScratchPrivateRepo(from root: URL, at dir: URL, _ t: TestRunner) -> Bool {
    let export = shell(["/bin/bash", "-c", "git -C \(ShellQuoting.singleQuoted(root.path)) archive HEAD | tar -x -C \(ShellQuoting.singleQuoted(dir.path))"], in: root)
    guard export.status == 0 else {
        t.expect(false, "exported the tracked tree into a scratch directory: \(export.stderr)")
        return false
    }
    for overlay in ["packaging/publish-public.sh", "packaging/publish-exclude.txt"] {
        let source = root.appendingPathComponent(overlay)
        let target = dir.appendingPathComponent(overlay)
        try? FileManager.default.removeItem(at: target)
        do {
            try FileManager.default.copyItem(at: source, to: target)
        } catch {
            t.expect(false, "copied \(overlay) into the scratch repository: \(error)")
            return false
        }
    }
    _ = shell(["git", "init", "-q", "-b", "main"], in: dir)
    _ = shell(["git", "add", "-A"], in: dir)
    let commit = gitCommit("snapshot", in: dir)
    guard commit.status == 0 else {
        t.expect(false, "committed the scratch snapshot: \(commit.stderr)")
        return false
    }
    return true
}

private func gitCommit(_ message: String, in dir: URL) -> CLIResult {
    // No signing and a fixed identity: the scratch commit must not depend on
    // the maintainer's git configuration, or on 1Password being up.
    shell(["git", "-c", "commit.gpgsign=false", "-c", "user.name=tests", "-c", "user.email=tests@example.invalid", "commit", "-q", "-m", message], in: dir)
}

/// This file's own thin wrapper over the shared `runProcess`: every call
/// here goes through `/usr/bin/env` (so a bare command name like `"git"` is
/// resolved from `PATH`) with `GIT_CONFIG_NOSYSTEM=1` (so a scratch commit
/// never depends on the maintainer's own git configuration).
private func shell(_ arguments: [String], in dir: URL) -> CLIResult {
    runProcess("/usr/bin/env", arguments, in: dir, environment: ["GIT_CONFIG_NOSYSTEM": "1"])
}
