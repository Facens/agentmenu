// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AgentMenuKit

/// Removing the bridge (R14): install then uninstall gives the file back, the
/// three files go, nothing else is touched, and a status line the user has
/// changed since is never clobbered. Every test works in temp directories —
/// nothing here goes near a real agent configuration.
func runStatuslineBridgeRemovalTests(_ t: TestRunner) {
    t.suite("StatuslineBridge removal")

    runRemovalRoundTripTests(t)
    runRemovalRefusalTests(t)
    runRemovalNoOpTests(t)
    runRemoveKeyTests(t)
    runRemovalRepointTests(t)
    runRemovalCLITests(t)
}

// MARK: - Fixtures

private struct Installed {
    let dir: TempDir
    let profile: URL
    let settings: URL
    let script: URL
    let snapshot: URL
    let history: URL
    let chain: String

    init(label: String, originalSettings: String?) {
        dir = TempDir(label)
        profile = dir.url.appendingPathComponent("claude")
        try? FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        settings = profile.appendingPathComponent("settings.json")
        script = profile.appendingPathComponent(StatuslineBridge.scriptFilename)
        snapshot = profile.appendingPathComponent(StatuslineBridge.snapshotFilename)
        history = profile.appendingPathComponent(UsageHistory.fileName)

        // The install path, driven through the same Kit functions the CLI calls.
        let original = originalSettings ?? "{}\n"
        if let originalSettings { try? originalSettings.write(to: settings, atomically: true, encoding: .utf8) }
        let update = try! StatuslineBridge.settingsUpdate( // fixture: known-valid settings
            original: original, scriptPath: script.path, existingBridgeScriptContents: nil
        )
        chain = update.chain
        let text = StatuslineBridge.bridgeScript(
            cliPath: "/opt/agentmenu/bin/agentmenu", profileDirectory: profile.path, chain: update.chain
        )
        try? text.write(to: script, atomically: true, encoding: .utf8)
        try? update.text.write(to: settings, atomically: true, encoding: .utf8)
        try? "{\"v\":1}".write(to: snapshot, atomically: true, encoding: .utf8)
        try? "{\"h\":1}\n".write(to: history, atomically: true, encoding: .utf8)
    }

    func settingsText() -> String? { try? String(contentsOf: settings, encoding: .utf8) }
    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    func snapshotOfDirectory() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: profile.path)) ?? []).sorted()
    }
}

private func jsonObject(_ text: String?) -> NSDictionary? {
    guard let text, let data = text.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return object as NSDictionary
}

// MARK: - Install, then uninstall

private func runRemovalRoundTripTests(_ t: TestRunner) {
    // An original status line, in the compact form install writes: the
    // restored file is the original byte for byte.
    let original = """
    {
      "env": {
        "KEPT": "yes"
      },
      "model": "opus",
      "statusLine": {"command":"bash \\"/Users/x/.claude/statusline.sh\\"","type":"command"},
      "theme": "light"
    }

    """
    do {
        let fixture = Installed(label: "removal-original", originalSettings: original)
        defer { fixture.dir.cleanup() }
        t.expect(fixture.settingsText() != original, "fixture: install really did rewrite settings.json")
        t.expectEqual(fixture.chain, "bash \"/Users/x/.claude/statusline.sh\"", "fixture: install recorded the original command")

        let outcome = StatuslineBridge.uninstall(profileDirectory: fixture.profile, settingsURL: fixture.settings)
        t.expectEqual(
            outcome,
            .removed(
                restoredCommand: "bash \"/Users/x/.claude/statusline.sh\"",
                deleted: [fixture.script.path, fixture.snapshot.path, fixture.history.path]
            ),
            "removal reports the command it restored and each file it deleted"
        )
        t.expectEqual(fixture.settingsText(), original, "settings.json is restored to its pre-install bytes")
        t.expect(!fixture.exists(fixture.script), "the bridge script is deleted")
        t.expect(!fixture.exists(fixture.snapshot), "the snapshot is deleted")
        t.expect(!fixture.exists(fixture.history), "the history file is deleted")
        t.expectEqual(fixture.snapshotOfDirectory(), ["settings.json"], "nothing else is left or touched in the directory")
    }

    // The same, with the original written the way people write it — multi-line,
    // keys in their own order, a refreshInterval. Install had already
    // rewritten that one object, so bytes inside it cannot come back; every
    // byte outside it does, and the parsed file is the original.
    let pretty = """
    {
      "env": {
        "KEPT": "yes"
      },
      "statusLine": {
        "type": "command",
        "command": "/Users/x/bin/line",
        "refreshInterval": 60
      },
      "other": [1, 2,   3]
    }
    """
    do {
        let fixture = Installed(label: "removal-pretty", originalSettings: pretty)
        defer { fixture.dir.cleanup() }
        _ = StatuslineBridge.uninstall(profileDirectory: fixture.profile, settingsURL: fixture.settings)
        let restored = fixture.settingsText()
        t.expect(jsonObject(restored)?.isEqual(to: jsonObject(pretty) ?? [:]) ?? false,
                 "a hand-formatted settings.json parses to the same values after install and removal, refreshInterval included")
        t.expect(restored?.hasPrefix("{\n  \"env\": {\n    \"KEPT\": \"yes\"\n  },\n  \"statusLine\": ") ?? false,
                 "the bytes before statusLine are untouched")
        t.expect(restored?.hasSuffix(",\n  \"other\": [1, 2,   3]\n}") ?? false,
                 "the bytes after statusLine are untouched")
        t.expect(restored?.contains("\"command\":\"/Users/x/bin/line\"") ?? false,
                 "the command is written back unescaped, as the user wrote it")
    }

    // No status line before install: the key goes entirely.
    let noStatusLines = [
        "{\n  \"model\": \"opus\"\n}\n",
        "{\"a\":1}",
        "{}\n",
        "{\n  \"a\": {\"nested\": true},\n  \"b\": [1]\n}",
    ]
    for original in noStatusLines {
        let fixture = Installed(label: "removal-none", originalSettings: original)
        defer { fixture.dir.cleanup() }
        t.expect(fixture.settingsText()?.contains("statusLine") ?? false, "fixture: install added statusLine to \(original.debugDescription)")
        t.expectEqual(fixture.chain, "", "fixture: install had nothing to chain to")

        let outcome = StatuslineBridge.uninstall(profileDirectory: fixture.profile, settingsURL: fixture.settings)
        t.expectEqual(
            outcome,
            .removed(restoredCommand: nil, deleted: [fixture.script.path, fixture.snapshot.path, fixture.history.path]),
            "with no original status line, the key is removed"
        )
        t.expectEqual(fixture.settingsText(), original, "settings.json is restored to \(original.debugDescription)")
        t.expectEqual(fixture.snapshotOfDirectory(), ["settings.json"], "and the three files are gone")
    }

    // Install did not find a settings.json at all and wrote `{}`-plus-key.
    // Removal leaves `{}`; it cannot know there was no file before.
    do {
        let fixture = Installed(label: "removal-nofile", originalSettings: nil)
        defer { fixture.dir.cleanup() }
        _ = StatuslineBridge.uninstall(profileDirectory: fixture.profile, settingsURL: fixture.settings)
        t.expectEqual(fixture.settingsText(), "{}\n", "an install that created settings.json leaves an empty object behind")
    }

    // Other keys, deliberately including ones that look like statusLine, and
    // a statusLine *value* elsewhere.
    let tricky = """
    {
      "note": "statusLine",
      "nested": {"statusLine": "not the top level one"},
      "statusLine": {"command":"echo hi","type":"command"}
    }

    """
    do {
        let fixture = Installed(label: "removal-tricky", originalSettings: tricky)
        defer { fixture.dir.cleanup() }
        _ = StatuslineBridge.uninstall(profileDirectory: fixture.profile, settingsURL: fixture.settings)
        t.expectEqual(fixture.settingsText(), tricky, "only the top-level statusLine key is touched")
    }

    // Install again after removing: back to the same bridge, same chain.
    do {
        let original = "{\n  \"statusLine\": {\"command\":\"echo hi\",\"type\":\"command\"}\n}\n"
        let fixture = Installed(label: "removal-reinstall", originalSettings: original)
        defer { fixture.dir.cleanup() }
        _ = StatuslineBridge.uninstall(profileDirectory: fixture.profile, settingsURL: fixture.settings)
        let again = try? StatuslineBridge.settingsUpdate(
            original: fixture.settingsText() ?? "", scriptPath: fixture.script.path, existingBridgeScriptContents: nil
        )
        t.expectEqual(again?.chain, "echo hi", "installing again after a removal chains to the original, not to nothing")
        t.expectEqual(again?.alreadyInstalled, false, "and does not think it is still installed")
    }

    // A file that is already gone is not an error: the history file was
    // never written on a profile that never saw a rate limit.
    do {
        let fixture = Installed(label: "removal-missing-file", originalSettings: "{}\n")
        defer { fixture.dir.cleanup() }
        try? FileManager.default.removeItem(at: fixture.history)
        try? FileManager.default.removeItem(at: fixture.snapshot)
        let outcome = StatuslineBridge.uninstall(profileDirectory: fixture.profile, settingsURL: fixture.settings)
        t.expectEqual(outcome, .removed(restoredCommand: nil, deleted: [fixture.script.path]),
                      "files that were never written are skipped, and only what was deleted is reported")
    }

    // A dry run says the same and changes nothing.
    do {
        let fixture = Installed(label: "removal-dry", originalSettings: "{\n  \"a\": 1\n}\n")
        defer { fixture.dir.cleanup() }
        let before = fixture.settingsText()
        let listing = fixture.snapshotOfDirectory()
        let outcome = StatuslineBridge.uninstall(profileDirectory: fixture.profile, settingsURL: fixture.settings, dryRun: true)
        t.expectEqual(outcome, .removed(restoredCommand: nil, deleted: [fixture.script.path, fixture.snapshot.path, fixture.history.path]),
                      "a dry run reports what a real run would do")
        t.expectEqual(fixture.settingsText(), before, "a dry run leaves settings.json alone")
        t.expectEqual(fixture.snapshotOfDirectory(), listing, "a dry run deletes nothing")
    }
}

// MARK: - Refusals

private func runRemovalRefusalTests(_ t: TestRunner) {
    func isRefused(_ outcome: StatuslineBridge.RemovalOutcome) -> String? {
        if case .refused(let reason) = outcome { return reason }
        return nil
    }

    // The user changed statusLine.command after install.
    do {
        let fixture = Installed(label: "refuse-changed", originalSettings: "{\n  \"a\": 1\n}\n")
        defer { fixture.dir.cleanup() }
        let changed = (fixture.settingsText() ?? "")
            .replacingOccurrences(of: fixture.script.path, with: "/Users/x/my-own-line.sh")
            .replacingOccurrences(of: fixture.script.path.replacingOccurrences(of: "/", with: "\\/"), with: "/Users/x/my-own-line.sh")
        try? changed.write(to: fixture.settings, atomically: true, encoding: .utf8)
        t.expect(!changed.contains(StatuslineBridge.scriptFilename), "fixture: statusLine.command no longer names the bridge")
        let listing = fixture.snapshotOfDirectory()

        let reason = isRefused(StatuslineBridge.uninstall(profileDirectory: fixture.profile, settingsURL: fixture.settings))
        t.expect(reason != nil, "removal refuses when statusLine.command was changed since install")
        t.expect(reason?.contains("no longer runs the AgentMenu bridge") ?? false, "and says why")
        t.expectEqual(fixture.settingsText(), changed, "settings.json is exactly as the user left it")
        t.expectEqual(fixture.snapshotOfDirectory(), listing, "no file is deleted")
        t.expect(fixture.exists(fixture.script) && fixture.exists(fixture.snapshot) && fixture.exists(fixture.history),
                 "the script, snapshot and history are all still there")
    }

    // The user removed statusLine altogether but the script is still there.
    do {
        let fixture = Installed(label: "refuse-removed-key", originalSettings: "{\n  \"a\": 1\n}\n")
        defer { fixture.dir.cleanup() }
        try? "{\n  \"a\": 1\n}\n".write(to: fixture.settings, atomically: true, encoding: .utf8)
        t.expect(isRefused(StatuslineBridge.uninstall(profileDirectory: fixture.profile, settingsURL: fixture.settings)) != nil,
                 "a settings.json that no longer has statusLine, with the script still on disk, is also a change since install")
        t.expect(fixture.exists(fixture.script), "and the script is left alone")
    }

    // statusLine runs a different profile's bridge.
    do {
        let fixture = Installed(label: "refuse-other-profile", originalSettings: "{\n  \"a\": 1\n}\n")
        defer { fixture.dir.cleanup() }
        let sibling = fixture.dir.url.appendingPathComponent("claude-personal")
        try? FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        // This profile's own script goes; its settings now name the sibling's.
        let siblingScript = sibling.appendingPathComponent(StatuslineBridge.scriptFilename)
        try? FileManager.default.moveItem(at: fixture.script, to: siblingScript)
        let text = (fixture.settingsText() ?? "")
            .replacingOccurrences(of: fixture.script.path.replacingOccurrences(of: "/", with: "\\/"), with: siblingScript.path)
            .replacingOccurrences(of: fixture.script.path, with: siblingScript.path)
        try? text.write(to: fixture.settings, atomically: true, encoding: .utf8)

        let reason = isRefused(StatuslineBridge.uninstall(profileDirectory: fixture.profile, settingsURL: fixture.settings))
        t.expect(reason?.contains("another profile's bridge") ?? false, "a status line that runs a sibling profile's bridge is refused, not taken apart")
        t.expectEqual(fixture.settingsText(), text, "and settings.json is untouched")
        t.expect(fixture.exists(siblingScript), "the sibling's script is untouched")
    }

    // The bridge is named but its script is gone: the original command is
    // unrecoverable, so nothing is guessed.
    do {
        let fixture = Installed(label: "refuse-script-gone", originalSettings: "{\"statusLine\":{\"command\":\"echo hi\",\"type\":\"command\"}}")
        defer { fixture.dir.cleanup() }
        try? FileManager.default.removeItem(at: fixture.script)
        let before = fixture.settingsText()
        let reason = isRefused(StatuslineBridge.uninstall(profileDirectory: fixture.profile, settingsURL: fixture.settings))
        t.expect(reason?.contains("cannot be recovered") ?? false, "a missing script means the original command is unrecoverable, and removal says so")
        t.expectEqual(fixture.settingsText(), before, "settings.json is not rewritten to chain to nothing")
        t.expect(fixture.exists(fixture.snapshot), "no file is deleted")
    }

    // A script that no longer carries a chain argument at all.
    do {
        let fixture = Installed(label: "refuse-no-chain", originalSettings: "{\"statusLine\":{\"command\":\"echo hi\",\"type\":\"command\"}}")
        defer { fixture.dir.cleanup() }
        try? "#!/bin/bash\nexit 0\n".write(to: fixture.script, atomically: true, encoding: .utf8)
        let before = fixture.settingsText()
        t.expect(isRefused(StatuslineBridge.uninstall(profileDirectory: fixture.profile, settingsURL: fixture.settings)) != nil,
                 "a script with no --chain argument is refused rather than read as 'no chain'")
        t.expectEqual(fixture.settingsText(), before, "and settings.json is untouched")
    }

    // Not JSON.
    do {
        let fixture = Installed(label: "refuse-malformed", originalSettings: "{}\n")
        defer { fixture.dir.cleanup() }
        try? "{ not json".write(to: fixture.settings, atomically: true, encoding: .utf8)
        t.expect(isRefused(StatuslineBridge.uninstall(profileDirectory: fixture.profile, settingsURL: fixture.settings)) != nil,
                 "a settings.json that does not parse is refused")
        t.expectEqual(fixture.settingsText(), "{ not json", "and is left as it was")
        t.expect(fixture.exists(fixture.script), "with the files kept")
    }

    // The pure function says the same for the same inputs.
    t.expectThrows("settingsRemoval on a text with no bridge command", { () -> Void in
        _ = try StatuslineBridge.settingsRemoval(
            original: "{\"statusLine\":{\"command\":\"echo hi\"}}", bridgeScriptContents: "--chain ''"
        )
    })
}

// MARK: - Not installed

private func runRemovalNoOpTests(_ t: TestRunner) {
    do {
        let dir = TempDir("noop-nothing")
        defer { dir.cleanup() }
        let settings = dir.url.appendingPathComponent("settings.json")
        let text = "{\n  \"statusLine\": {\"command\":\"echo hi\",\"type\":\"command\"},\n  \"a\": 1\n}\n"
        try? text.write(to: settings, atomically: true, encoding: .utf8)
        let outcome = StatuslineBridge.uninstall(profileDirectory: dir.url, settingsURL: settings)
        t.expectEqual(outcome, .notInstalled, "removing when the bridge was never installed is a no-op success")
        t.expectEqual(try? String(contentsOf: settings, encoding: .utf8), text, "settings.json is byte-identical")
    }

    do {
        let dir = TempDir("noop-nosettings")
        defer { dir.cleanup() }
        let outcome = StatuslineBridge.uninstall(
            profileDirectory: dir.url, settingsURL: dir.url.appendingPathComponent("settings.json")
        )
        t.expectEqual(outcome, .notInstalled, "no settings.json and no script is not installed either")
        t.expect(!FileManager.default.fileExists(atPath: dir.path("settings.json")), "and no file is created")
    }

    do {
        let fixture = Installed(label: "noop-twice", originalSettings: "{\n  \"a\": 1\n}\n")
        defer { fixture.dir.cleanup() }
        _ = StatuslineBridge.uninstall(profileDirectory: fixture.profile, settingsURL: fixture.settings)
        let after = fixture.settingsText()
        t.expectEqual(StatuslineBridge.uninstall(profileDirectory: fixture.profile, settingsURL: fixture.settings),
                      .notInstalled, "removing a second time is a no-op success")
        t.expectEqual(fixture.settingsText(), after, "and changes nothing")
    }
}

// MARK: - removeTopLevelKey on every position a key can have

private func runRemoveKeyTests(_ t: TestRunner) {
    func remove(_ text: String) -> String? { try? StatuslineBridge.removeTopLevelKey(in: text, key: "k") }
    t.expectEqual(remove("{\"k\": 1, \"a\": 2}"), "{\"a\": 2}", "first member, compact")
    t.expectEqual(remove("{\n  \"k\": {\"x\": [1, 2]},\n  \"a\": 2\n}"), "{\n  \"a\": 2\n}", "first member, pretty")
    t.expectEqual(remove("{\"a\": 1, \"k\": \"v,}\", \"b\": 2}"), "{\"a\": 1, \"b\": 2}", "middle member whose value holds commas and braces")
    t.expectEqual(remove("{\n  \"a\": 1,\n    \"k\": 2\n}"), "{\n  \"a\": 1\n}", "last member, pretty")
    t.expectEqual(remove("{\n  \"a\": 1,\n  \"k\": 2\n}"), "{\n  \"a\": 1}", "last member in exactly the shape install inserts it is taken out with its newline, so install-then-remove round-trips")
    t.expectEqual(remove("{\"a\": 1,\"k\":2}"), "{\"a\": 1}", "last member, compact")
    t.expectEqual(remove("{\n  \"k\": 1\n}\n"), "{}\n", "only member")
    t.expectEqual(remove("{\"a\": 1}"), "{\"a\": 1}", "absent key leaves the text as it was")
    t.expectEqual(remove("{\"a\": \"k\", \"b\": {\"k\": 1}}"), "{\"a\": \"k\", \"b\": {\"k\": 1}}", "a string value or a nested key named k is not the top-level key")
}

// MARK: - The launch-time stale re-point never resurrects a removed bridge

private func runRemovalRepointTests(_ t: TestRunner) {
    // `AppEnvironment.revalidateStatuslineBridges` decides whether a profile
    // "has a bridge" with `StatuslineBridge.bridgeState(profileDirectory:…)`,
    // and re-installs only on `.stale`.
    let fixture = Installed(label: "repoint", originalSettings: "{\"statusLine\":{\"command\":\"echo hi\",\"type\":\"command\"}}")
    defer { fixture.dir.cleanup() }
    let movedApp = "/Applications/Moved/AgentMenu.app/Contents/Resources/bin/agentmenu"

    let before = StatuslineBridge.bridgeState(profileDirectory: fixture.profile, expectedCLIPath: movedApp, fileExists: { _ in true })
    if case .stale = before {
        t.expect(true, "an installed bridge whose CLI path has moved is stale — the launch re-points it")
    } else {
        t.expect(false, "expected an installed bridge pointing at an old CLI path to be stale, got \(before)")
    }

    _ = StatuslineBridge.uninstall(profileDirectory: fixture.profile, settingsURL: fixture.settings)
    t.expectEqual(
        StatuslineBridge.bridgeState(profileDirectory: fixture.profile, expectedCLIPath: movedApp, fileExists: { _ in true }),
        .absent, "after removal there is nothing installed, so the launch-time re-point finds nothing to rewrite"
    )
    t.expectEqual(
        StatuslineBridge.bridgeState(profileDirectory: fixture.profile, expectedCLIPath: movedApp),
        .absent, "and the same with the real executable check"
    )
}

// MARK: - The CLI

private func runRemovalCLITests(_ t: TestRunner) {
    guard let binary = agentMenuCLIBinary() else {
        print("   (skipped: .build/debug/AgentMenuCLI not built — run 'swift build' first)")
        return
    }

    let dir = TempDir("remove-statusline-cli")
    defer { dir.cleanup() }
    let claudeDir = dir.path("claude")
    try? FileManager.default.createDirectory(atPath: claudeDir, withIntermediateDirectories: true)

    let original = "{\n  \"env\": {\"KEPT\": \"yes\"},\n  \"statusLine\": {\"command\":\"echo original\",\"type\":\"command\"},\n  \"z\": 1\n}\n"
    let settingsPath = dir.path("claude/settings.json")
    try? original.write(toFile: settingsPath, atomically: true, encoding: .utf8)

    let configPath = dir.path("config.toml")
    try? """
    schema = 1
    active_profile = "work"

    [[profiles]]
    id = "work"
    name = "Work"
    config_dir = "\(claudeDir)"
    """.write(toFile: configPath, atomically: true, encoding: .utf8)
    let env = ["AGENTMENU_CONFIG": configPath]
    let scriptPath = dir.path("claude/\(StatuslineBridge.scriptFilename)")

    // Nothing installed yet: a no-op success that creates nothing.
    if let nothing = t.attempt("install-statusline --remove with nothing installed", { try runCLI(binary, ["install-statusline", "--remove"], env: env) }) {
        t.expectEqual(nothing.status, 0, "removing what is not installed exits 0")
        t.expect(nothing.stdout.contains("nothing to remove"), "and says so")
        t.expectEqual(try? String(contentsOfFile: settingsPath, encoding: .utf8), original, "settings.json is untouched")
    }

    _ = t.attempt("install-statusline", { try runCLI(binary, ["install-statusline"], env: env) })
    try? "{\"v\":1}".write(toFile: dir.path("claude/\(StatuslineBridge.snapshotFilename)"), atomically: true, encoding: .utf8)
    try? "{\"h\":1}\n".write(toFile: dir.path("claude/\(UsageHistory.fileName)"), atomically: true, encoding: .utf8)
    let installedText = try? String(contentsOfFile: settingsPath, encoding: .utf8)
    t.expect(FileManager.default.fileExists(atPath: scriptPath), "fixture: the CLI installed the bridge")

    // Dry run: names the key and every file, changes nothing.
    if let dry = t.attempt("install-statusline --remove --dry-run", { try runCLI(binary, ["install-statusline", "--remove", "--dry-run"], env: env) }) {
        t.expectEqual(dry.status, 0, "a dry run exits 0")
        t.expect(dry.stdout.contains(settingsPath) && dry.stdout.contains("statusLine.command"), "names settings.json and the key before changing anything")
        for name in StatuslineBridge.installedFilenames() {
            t.expect(dry.stdout.contains(dir.path("claude/\(name)")), "names \(name) before deleting it")
        }
        t.expect(dry.stdout.contains("echo original"), "says which status line it would restore")
        t.expect(FileManager.default.fileExists(atPath: scriptPath), "a dry run deletes nothing")
        t.expectEqual(try? String(contentsOfFile: settingsPath, encoding: .utf8), installedText, "a dry run leaves settings.json alone")
    }

    // The real removal.
    if let removal = t.attempt("install-statusline --remove", { try runCLI(binary, ["install-statusline", "--remove", "--profile", "work"], env: env) }) {
        t.expectEqual(removal.status, 0, "removal exits 0")
        t.expect(removal.stdout.contains("deleted \(scriptPath)"), "reports the script it deleted")
        t.expectEqual(try? String(contentsOfFile: settingsPath, encoding: .utf8), original, "settings.json is back to what it was before install, byte for byte")
        let left = ((try? FileManager.default.contentsOfDirectory(atPath: claudeDir)) ?? []).sorted()
        t.expectEqual(left, ["settings.json"], "the script, snapshot and history are gone")
    }

    // And again: idempotent.
    if let again = t.attempt("install-statusline --remove, twice", { try runCLI(binary, ["install-statusline", "--remove"], env: env) }) {
        t.expectEqual(again.status, 0, "a second removal is a no-op success")
    }

    // A status line changed since install is refused with a non-zero exit.
    _ = t.attempt("install-statusline again", { try runCLI(binary, ["install-statusline"], env: env) })
    let edited = (try? String(contentsOfFile: settingsPath, encoding: .utf8))?
        .replacingOccurrences(of: "\"command\": \"", with: "\"command\": \"echo changed # ")
    // Install writes `"command":"…"` without a space after the colon; the
    // replacement above only fires on a hand-formatted file, so fall back.
    let changedText = (edited != nil && edited != (try? String(contentsOfFile: settingsPath, encoding: .utf8)))
        ? edited!
        : "{\n  \"statusLine\": {\"command\":\"echo changed\",\"type\":\"command\"}\n}\n"
    try? changedText.write(toFile: settingsPath, atomically: true, encoding: .utf8)
    if let refused = t.attempt("install-statusline --remove after the status line changed", { try runCLI(binary, ["install-statusline", "--remove"], env: env) }) {
        t.expectEqual(refused.status, 1, "removal exits 1 when the status line was changed since install")
        t.expect(refused.stderr.contains("no longer runs the AgentMenu bridge"), "and says why on stderr")
        t.expectEqual(try? String(contentsOfFile: settingsPath, encoding: .utf8), changedText, "settings.json is exactly as the user left it")
        t.expect(FileManager.default.fileExists(atPath: scriptPath), "and the script is still there")
    }
}
