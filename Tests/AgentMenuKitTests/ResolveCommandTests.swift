// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AgentMenuKit

// MARK: - CLI integration: `agentmenu resolve`

func runResolveCommandTests(_ t: TestRunner) {
    t.suite("resolve (CLI)")

    guard let binary = agentMenuCLIBinary() else {
        print("   (skipped: .build/debug/AgentMenuCLI not built — run 'swift build' first)")
        return
    }

    let dir = TempDir("resolve-cli")
    defer { dir.cleanup() }

    let claudeDir = dir.path("claude")
    let projectDir = dir.path("project")
    try? FileManager.default.createDirectory(atPath: claudeDir, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(atPath: projectDir, withIntermediateDirectories: true)

    let configPath = dir.path("config.toml")
    let configText = """
    schema = 1
    active_profile = "work"

    [[profiles]]
    id = "work"
    name = "Work"
    config_dir = "\(claudeDir)"

    [[folders]]
    label = "Project"
    path = "\(projectDir)"
    profile = "work"
    model = "opus"

    [binaries]
    claude = "/usr/bin/true"
    """
    try? configText.write(toFile: configPath, atomically: true, encoding: .utf8)
    let env = ["AGENTMENU_CONFIG": configPath]

    // 1. resolve on a configured folder prints that folder's profile.
    do {
    let result = t.attempt("resolve --profile on a configured folder") {
        try runCLI(binary, ["resolve", projectDir, "--profile"], env: env)
    }
    if let result {
        t.expectEqual(result.status, 0, "exit 0 for a configured folder")
        t.expectEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "work", "prints the folder's profile id")
    }
    }

    do {
    let result = t.attempt("resolve --config-dir on a configured folder") {
        try runCLI(binary, ["resolve", projectDir, "--config-dir"], env: env)
    }
    if let result {
        t.expectEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), claudeDir, "prints the expanded config directory")
    }
    }

    // A trailing slash and a non-normalized form of the same path still match.
    do {
    let result = t.attempt("resolve --profile on the same folder with a trailing slash") {
        try runCLI(binary, ["resolve", projectDir + "/", "--profile"], env: env)
    }
    if let result {
        t.expectEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "work", "normalized-path matching applies here too")
    }
    }

    // 2. resolve on an unconfigured directory exits non-zero and prints
    // nothing on stdout.
    let unconfigured = dir.path("not-configured-at-all")
    try? FileManager.default.createDirectory(atPath: unconfigured, withIntermediateDirectories: true)
    do {
    let result = t.attempt("resolve on an unconfigured directory") {
        try runCLI(binary, ["resolve", unconfigured, "--profile"], env: env)
    }
    if let result {
        t.expect(result.status != 0, "non-zero exit for an unconfigured directory")
        t.expect(result.stdout.isEmpty, "nothing printed on stdout — a shell function must be able to fall back")
    }
    }

    // Usage error (bad flag) is a distinct exit code from "not configured".
    do {
    let result = t.attempt("resolve with a missing directory argument is a usage error") {
        try runCLI(binary, ["resolve", "--profile"], env: env)
    }
    if let result {
        t.expectEqual(result.status, 2, "usage errors exit 2, distinct from the 1 'not configured' uses")
    }
    }

    // 3. resolve --command prints exactly what CommandBuilder.build produces
    // for the same folder — the "launch parity" gate.
    do {
    let result = t.attempt("resolve --command") {
        try runCLI(binary, ["resolve", projectDir, "--command"], env: env)
    }
    if let result {
        let registry = ManifestRegistry(bundledRoot: ResourceRoot.bundled(), userRoot: nil)
        registry.load()
        if let agent = registry.agent(id: "claude-code") {
            let folderPreset = Preset(profile: "work", model: "opus")
            let resolved = PresetResolver.resolve(global: Preset(), folder: folderPreset, oneShot: Preset(), agent: agent)
            let profile = Profile(id: "work", name: "Work", configDirectory: claudeDir)
            let expected = t.attempt("building the same command directly through CommandBuilder") {
                try CommandBuilder.build(
                    agent: agent, resolved: resolved, profile: profile,
                    directory: projectDir, binaryPath: "/usr/bin/true"
                )
            }
            if let expected {
                t.expectEqual(
                    result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                    expected.shellCommand,
                    "resolve --command prints exactly LaunchCommand.shellCommand"
                )
            }
        } else {
            print("   (skipped launch-parity comparison: bundled claude-code manifest not found from the test binary)")
            t.expect(!result.stdout.isEmpty, "resolve --command printed something even though the manifest could not be re-loaded here")
        }
    }
    }

    // 3b. resolve --keep-running (R15) prints what the popover would carry for
    // the folder: `true`/`false`, or `n/a` when the terminal cannot keep a
    // session running. Existing modes' output is untouched (steps 1-3 above).
    do {
        let keepDirs = ["inherit", "off", "on"].map { dir.path("keep-\($0)") }
        for keepDir in keepDirs { try? FileManager.default.createDirectory(atPath: keepDir, withIntermediateDirectories: true) }
        func keepConfig(terminal: String?, extra: String = "") -> String {
            """
            schema = 1
            active_profile = "work"

            [defaults]
            agent = "claude-code"
            \(terminal.map { "terminal = \"\($0)\"" } ?? "")

            [[profiles]]
            id = "work"
            name = "Work"
            config_dir = "\(claudeDir)"

            [[folders]]
            label = "Inherit"
            path = "\(keepDirs[0])"

            [[folders]]
            label = "Off"
            path = "\(keepDirs[1])"
            keep_running = false

            [[folders]]
            label = "On"
            path = "\(keepDirs[2])"
            keep_running = true

            [binaries]
            claude = "/usr/bin/true"

            \(extra)
            """
        }

        func keepRunning(_ directory: String, config: String, label: String) -> String? {
            let path = dir.path("keep-\(label).toml")
            try? config.write(toFile: path, atomically: true, encoding: .utf8)
            let result = t.attempt("resolve --keep-running (\(label))") {
                try runCLI(binary, ["resolve", directory, "--keep-running"], env: ["AGENTMENU_CONFIG": path])
            }
            guard let result else { return nil }
            t.expectEqual(result.status, 0, "resolve --keep-running (\(label)) succeeds")
            return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let supported = keepConfig(terminal: "iterm2")
        t.expectEqual(keepRunning(keepDirs[0], config: supported, label: "supported"), "true", "no key anywhere resolves to the default, on")
        t.expectEqual(keepRunning(keepDirs[1], config: supported, label: "supported"), "false", "the folder's own off wins")
        t.expectEqual(keepRunning(keepDirs[2], config: supported, label: "supported"), "true", "the folder's own on")
        t.expectEqual(
            keepRunning(keepDirs[0], config: keepConfig(terminal: "ghostty"), label: "unsupported"), "n/a",
            "a terminal that cannot keep a session running is not applicable"
        )

        // What the popover would carry: the same resolver call over the same layers.
        let registry = ManifestRegistry(bundledRoot: ResourceRoot.bundled(), userRoot: nil)
        registry.load()
        if let agent = registry.agent(id: "claude-code") {
            let viaResolver = PresetResolver.resolve(
                global: Preset(agent: "claude-code", terminal: "iterm2"), folder: Preset(keepRunning: false),
                oneShot: Preset(), agent: agent
            )
            t.expectEqual(viaResolver.keepRunning, false, "the resolver the popover uses agrees with what the CLI printed for the off folder")
        }

        // With no terminal anywhere, the fallback is the first verified
        // terminal the CONFIG leaves enabled (the app's rule:
        // `terminalState[id]?.enabled ?? manifest.enabled`), not the first
        // the manifests enable.
        if let agent = registry.agent(id: "claude-code") {
            func expected(_ states: [String: Bool], folderKeep: Bool?) -> String {
                let terminalID = registry.terminals.first { (states[$0.id] ?? $0.enabled) && !$0.unverified }?.id
                let resolved = PresetResolver.resolve(
                    global: Preset(agent: "claude-code"), folder: Preset(keepRunning: folderKeep),
                    oneShot: Preset(), agent: agent, terminalID: terminalID
                )
                switch resolved.keepRunning {
                case .some(let value): return value ? "true" : "false"
                case .none: return "n/a"
                }
            }

            t.expectEqual(
                keepRunning(keepDirs[1], config: keepConfig(terminal: nil), label: "fallback-default"),
                expected([:], folderKeep: false),
                "no terminal anywhere: the fallback terminal is the resolver's answer for the first enabled, verified one"
            )

            // The config disables every terminal that could keep a session running.
            let offConfig = keepConfig(
                terminal: nil,
                extra: "[terminals.iterm2]\nenabled = false\n\n[terminals.terminal-app]\nenabled = false"
            )
            let printedOff = keepRunning(keepDirs[2], config: offConfig, label: "fallback-config-disables")
            t.expectEqual(
                printedOff, expected(["iterm2": false, "terminal-app": false], folderKeep: true),
                "a terminal the config disables is not a fallback candidate"
            )
            t.expectEqual(printedOff, "n/a", "with both supported terminals off in the config there is none, where the manifest flag alone printed true")

            // Enabling the one terminal that ships disabled does not rescue
            // it: Ghostty is also unverified, and the fallback skips those.
            let ghosttyOn = keepConfig(
                terminal: nil,
                extra: "[terminals.iterm2]\nenabled = false\n\n[terminals.terminal-app]\nenabled = false\n\n[terminals.ghostty]\nenabled = true"
            )
            t.expectEqual(
                keepRunning(keepDirs[2], config: ghosttyOn, label: "fallback-unverified-stays-out"),
                expected(["iterm2": false, "terminal-app": false, "ghostty": true], folderKeep: true),
                "an unverified terminal stays out of the fallback even when the config enables it"
            )
        }

        // The existing modes print exactly what they printed before the field.
        let path = dir.path("keep-supported.toml")
        let profileOut = t.attempt("resolve --profile beside keep_running") {
            try runCLI(binary, ["resolve", keepDirs[1], "--profile"], env: ["AGENTMENU_CONFIG": path])
        }
        t.expectEqual(profileOut?.stdout, "", "an unpinned folder still prints nothing for --profile: keep_running adds no output to it")
    }

    // 4. resolve --command on an UNPINNED folder must match
    // `PopoverModel.profileID(for:)` — `target.profileID ?? activeProfileID`
    // — and never fall back to `config.defaults.profile`, which the app
    // never consults when choosing which profile launches (only
    // `PresetResolver`'s merge of model/effort/etc. reads it). A config with
    // two profiles, `defaults.profile` pointing at the *second* one, no
    // `active_profile` set, and an unpinned folder isolates the two
    // fallback chains: the old code (`pinnedProfileID ?? activeProfileID`,
    // where `pinnedProfileID` already folded in `defaults.profile`) would
    // answer "personal"; the app — and the fixed CLI — answers "work", the
    // first configured profile, exactly like a freshly-launched
    // `PopoverModel` would compute from this same file.
    do {
    let workDir = dir.path("parity-work")
    let personalDir = dir.path("parity-personal")
    let unpinnedProjectDir = dir.path("parity-project")
    try? FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(atPath: personalDir, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(atPath: unpinnedProjectDir, withIntermediateDirectories: true)

    let parityConfigPath = dir.path("parity-config.toml")
    let parityConfigText = """
    schema = 1

    [defaults]
    profile = "personal"

    [[profiles]]
    id = "work"
    name = "Work"
    config_dir = "\(workDir)"

    [[profiles]]
    id = "personal"
    name = "Personal"
    config_dir = "\(personalDir)"

    [[folders]]
    label = "Unpinned"
    path = "\(unpinnedProjectDir)"

    [binaries]
    claude = "/usr/bin/true"
    """
    try? parityConfigText.write(toFile: parityConfigPath, atomically: true, encoding: .utf8)
    let parityEnv = ["AGENTMENU_CONFIG": parityConfigPath]

    let result = t.attempt("resolve --command on an unpinned folder with two profiles and no active_profile") {
        try runCLI(binary, ["resolve", unpinnedProjectDir, "--command"], env: parityEnv)
    }
    if let result {
        t.expectEqual(result.status, 0, "an unpinned folder still resolves — it falls back to the first profile, not to nothing")
        let registry = ManifestRegistry(bundledRoot: ResourceRoot.bundled(), userRoot: nil)
        registry.load()
        if let agent = registry.agent(id: "claude-code") {
            let resolved = PresetResolver.resolve(global: Preset(profile: "personal"), folder: Preset(), oneShot: Preset(), agent: agent)
            let workProfile = Profile(id: "work", name: "Work", configDirectory: workDir)
            let expected = t.attempt("building the expected command for the 'work' profile") {
                try CommandBuilder.build(
                    agent: agent, resolved: resolved, profile: workProfile,
                    directory: unpinnedProjectDir, binaryPath: "/usr/bin/true"
                )
            }
            if let expected {
                t.expectEqual(
                    result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                    expected.shellCommand,
                    "the first configured profile ('work') is used, never 'personal' from [defaults] — matching PopoverModel.profileID(for:), not a merged preset"
                )
                t.expect(
                    !result.stdout.contains(personalDir),
                    "the CLAUDE_CONFIG_DIR the popover would never choose here ('personal') does not leak into the printed command"
                )
            }
        } else {
            print("   (skipped launch-parity comparison: bundled claude-code manifest not found from the test binary)")
        }
    }
    }

    // 5. resolve --command refuses an unconfirmed user-overlay manifest that
    // shadows a bundled agent id (R44). Before this fix, `resolveCommand`
    // went straight from `ManifestRegistry.agent(id:)` to `BinaryResolver`
    // with no trust check at all, so a user manifest overlaying
    // "claude-code" (KTD3: same id, last-loaded wins) was used the moment
    // its binary happened to resolve — printed, and by extension run by
    // every caller of `resolve --command` — with no confirmation. The
    // AGENTMENU_MANIFESTS_USER_ROOT env var is this test's only way to point
    // the CLI at a scratch overlay directory instead of the maintainer's
    // real ~/.config/agentmenu/agents/.
    do {
    let overlayProjectDir = dir.path("untrusted-overlay-project")
    try? FileManager.default.createDirectory(atPath: overlayProjectDir, withIntermediateDirectories: true)

    let overlayConfigPath = dir.path("untrusted-overlay-config.toml")
    let overlayConfigText = """
    schema = 1

    [[folders]]
    label = "Overlaid Project"
    path = "\(overlayProjectDir)"
    agent = "claude-code"

    [binaries]
    claude = "/usr/bin/true"
    """
    try? overlayConfigText.write(toFile: overlayConfigPath, atomically: true, encoding: .utf8)

    let overlayManifestsRoot = dir.path("untrusted-overlay")
    t.expectNoThrow("write a user manifest shadowing the bundled 'claude-code' id") {
        try dir.write(
            "schema = 1\nid = \"claude-code\"\ndisplay_name = \"Claude Code (Overlay)\"\nbinary = \"claude\"\n",
            to: "untrusted-overlay/agents/claude-code.toml"
        )
    }

    let overlayEnv = [
        "AGENTMENU_CONFIG": overlayConfigPath,
        "AGENTMENU_MANIFESTS_USER_ROOT": overlayManifestsRoot,
    ]
    let result = t.attempt("resolve --command against an unconfirmed shadowing user manifest") {
        try runCLI(binary, ["resolve", overlayProjectDir, "--command"], env: overlayEnv)
    }
    if let result {
        t.expect(result.status != 0, "an unconfirmed shadowing manifest must not resolve a command")
        t.expect(result.stdout.isEmpty, "nothing is printed on stdout for an unavailable agent")
        t.expect(
            result.stderr.localizedCaseInsensitiveContains("confirm") || result.stderr.localizedCaseInsensitiveContains("not available"),
            "the failure names the reason (unconfirmed manifest), not a silent non-zero exit: \(result.stderr)"
        )
    }
    }
}
