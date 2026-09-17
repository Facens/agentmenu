// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AgentMenuKit

/// Root of the repository's `Resources/` directory, computed from this
/// file's own path rather than from `ResourceRoot.bundled()` — that helper
/// depends on how the test binary was invoked (`CommandLine.arguments.first`)
/// and on `.build/<config>` sitting exactly three levels under the repo
/// root; scenario 10 is about the six shipped manifests, not about proving
/// out resource discovery, so it should not be able to fail for that reason.
private var repositoryResourcesRoot: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // ManifestRegistryTests.swift -> AgentMenuKitTests
        .deletingLastPathComponent()  // -> Tests
        .deletingLastPathComponent()  // -> repository root
        .appendingPathComponent("Resources")
}

/// The result of building a launch command from a manifest, for scenario 8's
/// abstraction-pressure proof.
private struct DemoCommand: Equatable {
    var environment: [String: String]
    var argv: [String]
}

/// Builds a command using only the manifest's own declared shape — the only
/// switches are over `profileMechanism` and `projectArgument`, the two enums
/// a manifest sets about itself. No branch anywhere reads `manifest.id` or
/// any other agent-specific string. If a real agent's shape ever needed a
/// third branch here, that would be the finding scenario 8 exists to surface.
private func demoCommand(for manifest: AgentManifest, projectPath: String, profileDirectory: URL?) -> DemoCommand {
    var environment: [String: String] = [:]
    var argv = [manifest.binary]

    switch manifest.profileMechanism {
    case .environment(let key):
        if let profileDirectory { environment[key] = profileDirectory.path }
    case .flag(let flag):
        if let profileDirectory {
            argv.append(flag)
            argv.append(profileDirectory.path)
        }
    case .none:
        break
    }

    argv.append(contentsOf: manifest.extraArgs)

    if manifest.projectArgument == .positional {
        argv.append(projectPath)
    }

    return DemoCommand(environment: environment, argv: argv)
}

func runManifestRegistryTests(_ t: TestRunner) {
    t.suite("ManifestRegistry")

    // MARK: 1. Bundled + user manifest with the same id resolve to the user's (KTD3)

    do {
        let dir = TempDir("manifest-overlay")
        defer { dir.cleanup() }

        let bundledAgent = """
        schema = 1
        id = "claude-code"
        display_name = "Claude Code (bundled)"
        binary = "claude"
        """
        let userAgent = """
        schema = 1
        id = "claude-code"
        display_name = "Claude Code (overlaid)"
        binary = "claude-custom"
        """
        t.expectNoThrow("write bundled claude-code manifest") { try dir.write(bundledAgent, to: "bundled/agents/claude-code.toml") }
        t.expectNoThrow("write user claude-code manifest") { try dir.write(userAgent, to: "user/agents/claude-code.toml") }

        let registry = ManifestRegistry(
            bundledRoot: dir.url.appendingPathComponent("bundled"),
            userRoot: dir.url.appendingPathComponent("user")
        )
        registry.load()

        t.expectEqual(registry.agents.count, 1, "the user manifest replaced the bundled one, not added alongside it")
        t.expectEqual(registry.agent(id: "claude-code")?.displayName, "Claude Code (overlaid)", "the user's values won")
        t.expectEqual(registry.agent(id: "claude-code")?.binary, "claude-custom", "the user's binary won")
        t.expectEqual(registry.agent(id: "claude-code")?.origin, .user, "the resolved manifest is marked user-origin, not bundled")
    }

    // MARK: 2. A manifest missing a required key is rejected, named, and the rest still load

    do {
        let dir = TempDir("manifest-missing-key")
        defer { dir.cleanup() }

        let good = """
        schema = 1
        id = "good-agent"
        display_name = "Good Agent"
        binary = "good"
        """
        let missingBinary = """
        schema = 1
        id = "bad-agent"
        display_name = "Bad Agent"
        """
        t.expectNoThrow("write good manifest") { try dir.write(good, to: "agents/a-good.toml") }
        t.expectNoThrow("write manifest missing binary") { try dir.write(missingBinary, to: "agents/b-bad.toml") }

        let registry = ManifestRegistry(bundledRoot: dir.url, userRoot: nil)
        registry.load()

        t.expectEqual(registry.agents.count, 1, "the good manifest loaded despite its sibling's failure")
        t.expectEqual(registry.agent(id: "good-agent")?.id, "good-agent", "the good manifest is the one that survived")
        t.expectEqual(registry.failures.count, 1, "one failure recorded")
        if case .missingKey(let key, let id)? = registry.failures.first?.error {
            t.expectEqual(key, "binary", "the missing key is named")
            t.expectEqual(id, "bad-agent", "the failure names which manifest")
        } else {
            t.expect(false, "wrong error case for a missing key: \(String(describing: registry.failures.first?.error))")
        }
    }

    // MARK: 3. A manifest with no [effort] section produces an agent whose effort capability is absent

    do {
        let text = """
        schema = 1
        id = "no-effort"
        display_name = "No Effort"
        binary = "noeffort"

        [model]
        flag = "--model"
        values = ["a", "b"]
        """
        if let manifest = t.attempt("parse a manifest with no [effort] section", { try AgentManifest.parse(text, origin: .bundled) }) {
            t.expect(manifest.effort == nil, "effort capability is absent, not present-and-disabled")
            t.expect(manifest.model != nil, "model capability, which the manifest does declare, is present")
        }
    }

    // MARK: 4. An agent whose binary cannot be resolved reports unavailable

    do {
        let manifest = AgentManifest(id: "unresolved", displayName: "Unresolved", binary: "unresolvedbin", origin: .bundled)
        let registry = ManifestRegistry(bundledRoot: nil, userRoot: nil)
        t.expectEqual(
            registry.availability(of: manifest, config: Config(), binaryPath: nil),
            .binaryMissing("unresolvedbin"),
            "a nil binaryPath reports binaryMissing, naming the binary"
        )
        t.expectEqual(
            registry.availability(of: manifest, config: Config(), binaryPath: "/usr/local/bin/unresolvedbin"),
            .available,
            "a resolved binaryPath makes the same manifest available"
        )
    }

    // MARK: 5. A disabled manifest is listed but cannot be selected

    do {
        let dir = TempDir("manifest-disabled-listed")
        defer { dir.cleanup() }
        let disabledText = """
        schema = 1
        id = "disabled-agent"
        display_name = "Disabled Agent"
        binary = "disabledbin"
        enabled = false
        """
        t.expectNoThrow("write disabled manifest") { try dir.write(disabledText, to: "agents/disabled.toml") }

        let registry = ManifestRegistry(bundledRoot: dir.url, userRoot: nil)
        registry.load()

        t.expect(registry.agent(id: "disabled-agent") != nil, "the disabled manifest is still listed")
        if let manifest = registry.agent(id: "disabled-agent") {
            t.expectEqual(
                registry.availability(of: manifest, config: Config(), binaryPath: "/usr/local/bin/disabledbin"),
                .disabledByManifest,
                "listed, but not selectable — even with a resolved binary"
            )
        }

        // A user override can also disable an otherwise-enabled manifest.
        let enabledManifest = AgentManifest(id: "was-enabled", displayName: "Was Enabled", binary: "e", enabled: true, origin: .bundled)
        var config = Config()
        config.agentState["was-enabled"] = ComponentState(enabled: false)
        t.expectEqual(
            registry.availability(of: enabledManifest, config: config, binaryPath: "/usr/local/bin/e"),
            .disabledByManifest,
            "the user's enabled=false override also produces disabledByManifest"
        )
    }

    // MARK: 6. A user-overlay manifest is untrusted; selecting it requires confirmation (R44)

    do {
        let manifest = AgentManifest(id: "user-agent", displayName: "User Agent", binary: "u", origin: .user)
        let registry = ManifestRegistry(bundledRoot: nil, userRoot: nil)

        t.expectEqual(
            registry.availability(of: manifest, config: Config(), binaryPath: "/usr/local/bin/u"),
            .needsConfirmation,
            "an unconfirmed user manifest needs confirmation before anything else is even checked"
        )

        var confirmed = Config()
        confirmed.agentState["user-agent"] = ComponentState(trusted: true)
        t.expectEqual(
            registry.availability(of: manifest, config: confirmed, binaryPath: "/usr/local/bin/u"),
            .available,
            "confirming trust clears the block"
        )

        // A bundled-origin manifest never needs confirmation, regardless of agentState.
        let bundledManifest = AgentManifest(id: "bundled-agent", displayName: "Bundled Agent", binary: "b", origin: .bundled)
        t.expectEqual(
            registry.availability(of: bundledManifest, config: Config(), binaryPath: "/usr/local/bin/b"),
            .available,
            "a bundled manifest is trusted by construction"
        )

        // Same rule, terminal side.
        let userTerm = TerminalManifest(id: "user-term", displayName: "User Term", kind: .applescript, bundleID: "com.installed.app", origin: .user)
        let terminalRegistry = ManifestRegistry(bundledRoot: nil, userRoot: nil, applicationProbe: { _ in true })
        t.expectEqual(
            terminalRegistry.availability(of: userTerm, config: Config(), binaryPath: nil),
            .needsConfirmation,
            "a user-overlay terminal manifest needs confirmation too"
        )
        var trustedTerminalConfig = Config()
        trustedTerminalConfig.terminalState["user-term"] = ComponentState(trusted: true)
        t.expectEqual(
            terminalRegistry.availability(of: userTerm, config: trustedTerminalConfig, binaryPath: nil),
            .available,
            "confirming trust clears the block for a terminal too"
        )
    }

    // MARK: 7. R45 — extra_args smuggling a declared permission_mode value is rejected

    do {
        let exactForm = """
        schema = 1
        id = "r45-exact"
        display_name = "R45 Exact"
        binary = "r"
        extra_args = ["bypassPermissions"]

        [permission_mode]
        flag = "--permission-mode"
        values = ["manual", "bypassPermissions"]
        """
        do {
            _ = try AgentManifest.parse(exactForm, origin: .bundled)
            t.expect(false, "extra_args containing an exact declared permission value should be rejected")
        } catch let error as ManifestError {
            if case .permissionValueInExtraArgs(let field, let argument, let id) = error {
                t.expectEqual(field, "extra_args", "the offending field is named")
                t.expectEqual(argument, "bypassPermissions", "the offending argument is named exactly")
                t.expectEqual(id, "r45-exact", "the offending manifest is named")
            } else {
                t.expect(false, "wrong error case for R45 (exact form): \(error)")
            }
        } catch {
            t.expect(false, "wrong error type for R45 (exact form): \(error)")
        }

        let equalsForm = """
        schema = 1
        id = "r45-equals"
        display_name = "R45 Equals"
        binary = "r"
        extra_args = ["--permission-mode=bypassPermissions"]

        [permission_mode]
        flag = "--permission-mode"
        values = ["manual", "bypassPermissions"]
        """
        do {
            _ = try AgentManifest.parse(equalsForm, origin: .bundled)
            t.expect(false, "a \"--flag=value\" element smuggling the value should also be rejected")
        } catch let error as ManifestError {
            if case .permissionValueInExtraArgs(let field, let argument, let id) = error {
                t.expectEqual(field, "extra_args", "the offending field is named")
                t.expectEqual(argument, "--permission-mode=bypassPermissions", "the whole offending element is named")
                t.expectEqual(id, "r45-equals", "the offending manifest is named")
            } else {
                t.expect(false, "wrong error case for R45 (\"--flag=value\" form): \(error)")
            }
        } catch {
            t.expect(false, "wrong error type for R45 (\"--flag=value\" form): \(error)")
        }

        let safe = """
        schema = 1
        id = "r45-safe"
        display_name = "R45 Safe"
        binary = "r"
        extra_args = ["--verbose"]

        [permission_mode]
        flag = "--permission-mode"
        values = ["manual", "bypassPermissions"]
        """
        t.expectNoThrow("an extra arg unrelated to any declared permission value is not rejected") {
            _ = try AgentManifest.parse(safe, origin: .bundled)
        }
    }

    // MARK: 7b. R45 extended — advisor.disable_args is the exact analogue of
    // extra_args (static, verbatim, no user-chosen value): claude-code.toml
    // itself uses disable_args, so this shape is proven live, not synthetic.

    do {
        let advisorExact = """
        schema = 1
        id = "r45-advisor-exact"
        display_name = "R45 Advisor Exact"
        binary = "r"

        [permission_mode]
        flag = "--permission-mode"
        values = ["manual", "bypassPermissions"]

        [advisor]
        flag = "--advisor"
        values = ["opus"]
        disable_args = ["bypassPermissions"]
        """
        do {
            _ = try AgentManifest.parse(advisorExact, origin: .bundled)
            t.expect(false, "advisor.disable_args containing an exact declared permission value should be rejected")
        } catch let error as ManifestError {
            if case .permissionValueInExtraArgs(let field, let argument, let id) = error {
                t.expectEqual(field, "advisor.disable_args", "the offending field is named as advisor.disable_args, not extra_args")
                t.expectEqual(argument, "bypassPermissions", "the offending argument is named exactly")
                t.expectEqual(id, "r45-advisor-exact", "the offending manifest is named")
            } else {
                t.expect(false, "wrong error case for R45 (advisor.disable_args exact form): \(error)")
            }
        } catch {
            t.expect(false, "wrong error type for R45 (advisor.disable_args exact form): \(error)")
        }

        let advisorEquals = """
        schema = 1
        id = "r45-advisor-equals"
        display_name = "R45 Advisor Equals"
        binary = "r"

        [permission_mode]
        flag = "--permission-mode"
        values = ["manual", "bypassPermissions"]

        [advisor]
        flag = "--advisor"
        values = ["opus"]
        disable_args = ["--permission-mode=bypassPermissions"]
        """
        do {
            _ = try AgentManifest.parse(advisorEquals, origin: .bundled)
            t.expect(false, "advisor.disable_args smuggling a \"--flag=value\" element should also be rejected")
        } catch let error as ManifestError {
            if case .permissionValueInExtraArgs(let field, _, let id) = error {
                t.expectEqual(field, "advisor.disable_args", "the offending field is named")
                t.expectEqual(id, "r45-advisor-equals", "the offending manifest is named")
            } else {
                t.expect(false, "wrong error case for R45 (advisor.disable_args \"--flag=value\" form): \(error)")
            }
        } catch {
            t.expect(false, "wrong error type for R45 (advisor.disable_args \"--flag=value\" form): \(error)")
        }

        // The shipped claude-code.toml's own disable_args, proving the fix
        // does not false-positive on a JSON-string element containing no
        // declared permission value.
        let shippedShape = """
        schema = 1
        id = "r45-advisor-safe"
        display_name = "R45 Advisor Safe"
        binary = "r"

        [permission_mode]
        flag = "--permission-mode"
        values = ["manual", "bypassPermissions"]

        [advisor]
        flag = "--advisor"
        values = ["opus"]
        disable_args = ["--settings", "{\\"advisorModel\\":\\"\\"}"]
        """
        t.expectNoThrow("claude-code.toml's own disable_args shape is not rejected") {
            _ = try AgentManifest.parse(shippedShape, origin: .bundled)
        }
    }

    // MARK: 7c. R45 extended — a capability sharing permission_mode's own
    // flag is rejected, whichever capability it is: an unmarked value could
    // otherwise ride the marked flag.

    do {
        let collisions: [(field: String, toml: String)] = [
            ("model.flag", """
            schema = 1
            id = "r45-collide-model"
            display_name = "R45 Collide Model"
            binary = "r"
            [permission_mode]
            flag = "--permission-mode"
            values = ["manual", "bypassPermissions"]
            [model]
            flag = "--permission-mode"
            values = ["opus"]
            """),
            ("effort.flag", """
            schema = 1
            id = "r45-collide-effort"
            display_name = "R45 Collide Effort"
            binary = "r"
            [permission_mode]
            flag = "--permission-mode"
            values = ["manual", "bypassPermissions"]
            [effort]
            flag = "--permission-mode"
            values = ["high"]
            """),
            ("advisor.flag", """
            schema = 1
            id = "r45-collide-advisor"
            display_name = "R45 Collide Advisor"
            binary = "r"
            [permission_mode]
            flag = "--permission-mode"
            values = ["manual", "bypassPermissions"]
            [advisor]
            flag = "--permission-mode"
            values = ["opus"]
            """),
            ("profile_flag", """
            schema = 1
            id = "r45-collide-profile"
            display_name = "R45 Collide Profile"
            binary = "r"
            profile_flag = "--permission-mode"
            [permission_mode]
            flag = "--permission-mode"
            values = ["manual", "bypassPermissions"]
            """),
        ]
        for (field, toml) in collisions {
            do {
                _ = try AgentManifest.parse(toml, origin: .bundled)
                t.expect(false, "\(field) sharing permission_mode's flag should be rejected")
            } catch let error as ManifestError {
                if case .permissionFlagCollision(let errorField, let flag, _) = error {
                    t.expectEqual(errorField, field, "the colliding field is named")
                    t.expectEqual(flag, "--permission-mode", "the shared flag is named")
                } else {
                    t.expect(false, "wrong error case for \(field) collision: \(error)")
                }
            } catch {
                t.expect(false, "wrong error type for \(field) collision: \(error)")
            }
        }

        // No permission_mode section at all: the collision check must be a
        // no-op, not a crash on an absent PermissionSpec.
        let noPermissionMode = """
        schema = 1
        id = "r45-no-permission-mode"
        display_name = "R45 No Permission Mode"
        binary = "r"
        [model]
        flag = "--model"
        values = ["opus"]
        """
        t.expectNoThrow("the flag-collision check is a no-op when the manifest declares no permission_mode") {
            _ = try AgentManifest.parse(noPermissionMode, origin: .bundled)
        }
    }

    // MARK: 7d. bypass_values defaults to every declared value when absent,
    // and is rejected when it names a value outside `values`.

    do {
        let defaulted = """
        schema = 1
        id = "r45-bypass-default"
        display_name = "R45 Bypass Default"
        binary = "r"
        [permission_mode]
        flag = "--permission-mode"
        values = ["manual", "auto", "bypassPermissions"]
        """
        if let manifest = t.attempt("parse a manifest with no bypass_values declared", { try AgentManifest.parse(defaulted, origin: .bundled) }) {
            t.expectEqual(
                manifest.permissionMode?.bypassValues, ["manual", "auto", "bypassPermissions"],
                "absent bypass_values defaults to every declared value, not to none"
            )
        }

        let explicitEmpty = """
        schema = 1
        id = "r45-bypass-explicit-empty"
        display_name = "R45 Bypass Explicit Empty"
        binary = "r"
        [permission_mode]
        flag = "--permission-mode"
        values = ["manual", "auto"]
        bypass_values = []
        """
        if let manifest = t.attempt("parse a manifest with bypass_values explicitly empty", { try AgentManifest.parse(explicitEmpty, origin: .bundled) }) {
            t.expectEqual(
                manifest.permissionMode?.bypassValues, [],
                "an explicit empty bypass_values is honored as \"mark nothing,\" not defaulted"
            )
        }

        let outOfRange = """
        schema = 1
        id = "r45-bypass-out-of-range"
        display_name = "R45 Bypass Out Of Range"
        binary = "r"
        [permission_mode]
        flag = "--permission-mode"
        values = ["manual", "auto"]
        bypass_values = ["bypassPermissions"]
        """
        t.expectThrows("bypass_values naming a value outside permission_mode.values is rejected") {
            try AgentManifest.parse(outOfRange, origin: .bundled)
        }

        let emptyValuesOutOfRange = """
        schema = 1
        id = "r45-bypass-empty-values"
        display_name = "R45 Bypass Empty Values"
        binary = "r"
        [permission_mode]
        flag = "--permission-mode"
        values = []
        bypass_values = ["bypassPermissions"]
        """
        t.expectThrows("a declared bypass_values is rejected even when permission_mode.values is itself empty") {
            try AgentManifest.parse(emptyValuesOutOfRange, origin: .bundled)
        }
    }

    // MARK: 8. Abstraction pressure — a fixture shaped deliberately unlike Claude Code

    do {
        let claudeCodeURL = repositoryResourcesRoot.appendingPathComponent("agents/claude-code.toml")
        guard let claudeCodeText = try? String(contentsOf: claudeCodeURL, encoding: .utf8) else {
            t.expect(false, "could not read Resources/agents/claude-code.toml at \(claudeCodeURL.path)")
            return
        }
        let claudeCode = t.attempt("parse the real claude-code manifest") { try AgentManifest.parse(claudeCodeText, origin: .bundled) }

        let alienText = """
        schema = 1
        id = "alien"
        display_name = "Alien Agent"
        binary = "alien"
        project_arg = "positional"

        profile_flag = "--config-dir"

        [model]
        flag = "--model"
        values = ["small", "large"]
        """
        let alien = t.attempt("parse the alien fixture manifest") { try AgentManifest.parse(alienText, origin: .bundled) }

        if let claudeCode {
            t.expectEqual(claudeCode.projectArgument, .none, "sanity: claude-code takes no project argument")
            if case .environment = claudeCode.profileMechanism {
                t.expect(true, "sanity: claude-code's profile is an environment variable")
            } else {
                t.expect(false, "sanity check failed: claude-code.toml's profile mechanism changed shape")
            }

            let command = demoCommand(
                for: claudeCode,
                projectPath: "/Users/x/project",
                profileDirectory: URL(fileURLWithPath: "/Users/x/.claude")
            )
            t.expectEqual(command.argv, ["claude"], "no project argument, no extra args")
            t.expectEqual(
                command.environment, ["CLAUDE_CONFIG_DIR": "/Users/x/.claude"],
                "the profile reaches claude-code as an environment variable"
            )
        }

        if let alien {
            t.expect(alien.effort == nil, "the alien fixture declares no effort flag at all")
            t.expectEqual(alien.projectArgument, .positional, "the alien fixture takes a positional project path")
            t.expectEqual(alien.profileMechanism, .flag("--config-dir"), "the alien fixture's profile is a config-file flag")

            let command = demoCommand(
                for: alien,
                projectPath: "/Users/x/project",
                profileDirectory: URL(fileURLWithPath: "/Users/x/.alien")
            )
            t.expectEqual(
                command.argv, ["alien", "--config-dir", "/Users/x/.alien", "/Users/x/project"],
                "a positional project path and a profile-as-flag both show up with no Swift change"
            )
            t.expectEqual(command.environment, [:], "the alien fixture's profile never touches the environment")
        }
    }

    // MARK: 9. A terminal whose application is not installed reports unavailable

    do {
        let installed = TerminalManifest(id: "installed-term", displayName: "Installed", kind: .applescript, bundleID: "com.installed.app", origin: .bundled)
        let missing = TerminalManifest(id: "missing-term", displayName: "Missing", kind: .applescript, bundleID: "com.missing.app", origin: .bundled)
        let registry = ManifestRegistry(bundledRoot: nil, userRoot: nil, applicationProbe: { $0 == "com.installed.app" })

        t.expectEqual(registry.availability(of: installed, config: Config(), binaryPath: nil), .available, "the installed application's terminal is available")
        t.expectEqual(
            registry.availability(of: missing, config: Config(), binaryPath: nil),
            .applicationMissing("com.missing.app"),
            "the missing application's terminal reports unavailable, naming its bundle id"
        )

        let argvTerm = TerminalManifest(id: "argv-term", displayName: "Argv", kind: .argv, binary: "sometool", args: ["-e", "{command}"], origin: .bundled)
        t.expectEqual(
            registry.availability(of: argvTerm, config: Config(), binaryPath: nil),
            .binaryMissing("sometool"),
            "an argv terminal with no resolved binary also reports unavailable"
        )
    }

    // MARK: 10. All six shipped manifests load; the four unverified ones report unavailable;
    // every documented key is actually read by the loader.

    do {
        let registry = ManifestRegistry(bundledRoot: repositoryResourcesRoot, userRoot: nil)
        registry.load()

        t.expectEqual(registry.failures.count, 0, "no shipped manifest fails to load: \(registry.failures.map(\.file))")
        t.expectEqual(registry.agents.count, 3, "three shipped agents: claude-code, opencode, codex")
        t.expectEqual(registry.terminals.count, 3, "three shipped terminals: iterm2, terminal-app, ghostty")

        for id in ["opencode", "codex"] {
            if let manifest = registry.agent(id: id) {
                t.expect(manifest.unverified, "\(id) ships marked unverified")
                t.expectEqual(
                    registry.availability(of: manifest, config: Config(), binaryPath: "/usr/local/bin/\(id)"),
                    .disabledByManifest,
                    "\(id) ships disabled, so it reports unavailable even with a resolved binary"
                )
            } else {
                t.expect(false, "\(id) did not load from Resources/agents")
            }
        }
        for id in ["terminal-app", "ghostty"] {
            if let manifest = registry.terminal(id: id) {
                t.expect(manifest.unverified, "\(id) ships marked unverified")
                t.expectEqual(
                    registry.availability(of: manifest, config: Config(), binaryPath: "/usr/local/bin/\(id)"),
                    .disabledByManifest,
                    "\(id) ships disabled, so it reports unavailable even with a resolved binary"
                )
            } else {
                t.expect(false, "\(id) did not load from Resources/terminals")
            }
        }

        if let claudeCode = registry.agent(id: "claude-code") {
            t.expect(!claudeCode.unverified, "claude-code ships verified")
            t.expectEqual(
                registry.availability(of: claudeCode, config: Config(), binaryPath: nil),
                .binaryMissing("claude"),
                "claude-code with no resolved binary path reports unavailable, but not disabled"
            )
        } else {
            t.expect(false, "claude-code did not load from Resources/agents")
        }
        if let iterm2 = registry.terminal(id: "iterm2") {
            t.expect(!iterm2.unverified, "iterm2 ships verified")
        } else {
            t.expect(false, "iterm2 did not load from Resources/terminals")
        }

        // A manifest that sets every key docs/adding-an-agent.md documents —
        // proof each one actually lands on the parsed value, not just that
        // the file parses.
        let everyKeyText = """
        schema = 1
        id = "every-key"
        display_name = "Every Key"
        binary = "everykeybin"
        enabled = false
        unverified = true
        verified_version = "9.9.9"
        verified_on = "2026-01-01"

        project_arg = "positional"
        extra_args = ["--flag-a", "value-a"]

        profile_flag = "--config-dir"

        settings_file = "{profile_dir}/settings.json"
        usage_snapshot = "{profile_dir}/usage.json"

        [model]
        flag = "--model"
        values = ["small", "large"]
        seed_from_settings = "model"

        [effort]
        flag = "--effort"
        values = ["low", "high"]

        [permission_mode]
        flag = "--permission-mode"
        values = ["ask", "bypass"]
        bypass_values = ["bypass"]

        [advisor]
        flag = "--advisor"
        values = ["opus", "sonnet"]
        disable_args = ["--no-advisor"]
        seed_from_settings = "advisorModel"
        """
        if let manifest = t.attempt("parse a manifest setting every documented key", { try AgentManifest.parse(everyKeyText, origin: .bundled) }) {
            t.expectEqual(manifest.id, "every-key", "id landed")
            t.expectEqual(manifest.displayName, "Every Key", "display_name landed")
            t.expectEqual(manifest.binary, "everykeybin", "binary landed")
            t.expectEqual(manifest.enabled, false, "enabled landed")
            t.expectEqual(manifest.unverified, true, "unverified landed")
            t.expectEqual(manifest.verifiedVersion, "9.9.9", "verified_version landed")
            t.expectEqual(manifest.verifiedOn, "2026-01-01", "verified_on landed")
            t.expectEqual(manifest.projectArgument, .positional, "project_arg landed")
            t.expectEqual(manifest.extraArgs, ["--flag-a", "value-a"], "extra_args landed")
            t.expectEqual(manifest.profileMechanism, .flag("--config-dir"), "profile_flag landed")
            t.expectEqual(manifest.settingsFile, "{profile_dir}/settings.json", "settings_file landed")
            t.expectEqual(manifest.usageSnapshot, "{profile_dir}/usage.json", "usage_snapshot landed")
            t.expectEqual(
                manifest.model, FlagSpec(flag: "--model", values: ["small", "large"], seedFromSettings: "model"),
                "[model] landed, including seed_from_settings"
            )
            t.expectEqual(
                manifest.effort, FlagSpec(flag: "--effort", values: ["low", "high"]),
                "[effort] landed"
            )
            t.expectEqual(
                manifest.permissionMode,
                PermissionSpec(flag: "--permission-mode", values: ["ask", "bypass"], bypassValues: ["bypass"]),
                "[permission_mode] landed, including bypass_values"
            )
            t.expectEqual(
                manifest.advisor,
                AdvisorSpec(flag: "--advisor", values: ["opus", "sonnet"], disableArgs: ["--no-advisor"], seedFromSettings: "advisorModel"),
                "[advisor] landed, including disable_args and seed_from_settings"
            )

            let profileDir = URL(fileURLWithPath: "/Users/x/.config/every-key")
            t.expectEqual(
                manifest.settingsFileURL(profileDirectory: profileDir)?.path,
                "/Users/x/.config/every-key/settings.json",
                "{profile_dir} expands in settings_file"
            )
            t.expectEqual(
                manifest.usageSnapshotPath(profileDirectory: profileDir),
                "/Users/x/.config/every-key/usage.json",
                "{profile_dir} expands in usage_snapshot"
            )
        }
    }

    // MARK: 11. settingsFileURL / usageSnapshotPath are nil when the manifest declares neither

    do {
        let manifest = AgentManifest(id: "no-settings", displayName: "No Settings", binary: "n", origin: .bundled)
        t.expect(
            manifest.settingsFileURL(profileDirectory: URL(fileURLWithPath: "/tmp/x")) == nil,
            "settingsFileURL is nil when the manifest declares no settings_file"
        )
        t.expect(
            manifest.usageSnapshotPath(profileDirectory: URL(fileURLWithPath: "/tmp/x")) == nil,
            "usageSnapshotPath is nil when the manifest declares no usage_snapshot"
        )
    }

    // MARK: 12. Malformed TOML (not a missing key) is reported as .parse, with a line; the rest still load

    do {
        let dir = TempDir("manifest-malformed-toml")
        defer { dir.cleanup() }

        let good = """
        schema = 1
        id = "good-two"
        display_name = "Good Two"
        binary = "goodtwo"
        """
        let malformed = "schema = 1\nid = \"bad-toml\"\n[model\nflag = \"--model\"\n"
        t.expectNoThrow("write good manifest") { try dir.write(good, to: "agents/a-good.toml") }
        t.expectNoThrow("write malformed manifest") { try dir.write(malformed, to: "agents/b-malformed.toml") }

        let registry = ManifestRegistry(bundledRoot: dir.url, userRoot: nil)
        registry.load()

        t.expectEqual(registry.agents.count, 1, "the well-formed manifest still loaded")
        t.expectEqual(registry.failures.count, 1, "one failure recorded for the malformed file")
        if case .parse(let tomlError)? = registry.failures.first?.error {
            t.expect(tomlError.line > 0, "the TOML error names a source line")
        } else {
            t.expect(false, "wrong error case for malformed TOML: \(String(describing: registry.failures.first?.error))")
        }
    }

    // MARK: 13. schema newer than supported is refused

    do {
        let text = """
        schema = 2
        id = "future-schema"
        display_name = "Future"
        binary = "future"
        """
        do {
            _ = try AgentManifest.parse(text, origin: .bundled)
            t.expect(false, "schema 2 should be rejected")
        } catch let error as ManifestError {
            if case .unsupportedSchema(let found, let supported) = error {
                t.expectEqual(found, 2, "unsupportedSchema names the version found")
                t.expectEqual(supported, ManifestRegistry.schemaVersion, "unsupportedSchema names the version supported")
            } else {
                t.expect(false, "wrong error case for a too-new schema: \(error)")
            }
        } catch {
            t.expect(false, "wrong error type for a too-new schema: \(error)")
        }
    }

    // MARK: 14. A non-.toml file in a manifest directory is silently skipped, not reported as a failure

    do {
        let dir = TempDir("manifest-non-toml")
        defer { dir.cleanup() }
        t.expectNoThrow("write the one real manifest") {
            try dir.write("schema = 1\nid = \"only-one\"\ndisplay_name = \"Only One\"\nbinary = \"only\"\n", to: "agents/only.toml")
        }
        t.expectNoThrow("write a stray non-manifest file") { try dir.write("junk", to: "agents/.DS_Store") }

        let registry = ManifestRegistry(bundledRoot: dir.url, userRoot: nil)
        registry.load()

        t.expectEqual(registry.agents.count, 1, "only the .toml file was loaded")
        t.expectEqual(registry.failures.count, 0, "the non-manifest file was skipped, not reported as a failure")
    }

    // MARK: 14b. A .toml file that cannot be read (unlike .DS_Store above,
    // this WAS a manifest attempt — permissions, a bad symlink, a mid-write
    // truncation) is reported as a failure rather than silently vanishing:
    // `tomlFiles`'s old `try? String(contentsOf:...)` dropped it with
    // nothing recorded anywhere, so it neither loaded nor showed up in
    // `failures` — the settings pane would show nothing at all for it.

    do {
        let dir = TempDir("manifest-unreadable")
        let lockedPath = dir.path("agents/locked.toml")
        defer {
            // Restore permissions first — TempDir.cleanup can't remove a
            // file it can't read, even though removing only needs write
            // permission on the *directory*; be defensive either way.
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: lockedPath)
            dir.cleanup()
        }
        t.expectNoThrow("write one readable manifest") {
            try dir.write("schema = 1\nid = \"readable\"\ndisplay_name = \"Readable\"\nbinary = \"readable\"\n", to: "agents/readable.toml")
        }
        t.expectNoThrow("write a manifest file that will be made unreadable") {
            try dir.write("schema = 1\nid = \"locked\"\ndisplay_name = \"Locked\"\nbinary = \"locked\"\n", to: "agents/locked.toml")
        }
        t.expectNoThrow("strip all permissions from the second file") {
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: lockedPath)
        }

        let registry = ManifestRegistry(bundledRoot: dir.url, userRoot: nil)
        registry.load()

        t.expectEqual(registry.agents.count, 1, "the readable manifest still loaded — one bad file does not stop the rest")
        t.expectEqual(registry.failures.count, 1, "the unreadable file is reported, not silently dropped")
        if let failure = registry.failures.first {
            t.expect(failure.file.hasSuffix("locked.toml"), "the failure names the unreadable file: \(failure.file)")
        }
    }

    // MARK: 15. FlagSpec / PermissionSpec / AdvisorSpec predicates

    do {
        let permission = PermissionSpec(flag: "--permission-mode", values: ["manual", "auto", "bypassPermissions"], bypassValues: ["bypassPermissions"])
        t.expect(permission.accepts("manual"), "accepts() is true for a declared value")
        t.expect(!permission.accepts("unknown"), "accepts() is false for an undeclared value")
        t.expect(permission.isBypassing("bypassPermissions"), "isBypassing() is true for a declared bypass value")
        t.expect(!permission.isBypassing("manual"), "isBypassing() is false for a non-bypass value, even a declared one")

        let flag = FlagSpec(flag: "--model", values: ["opus", "sonnet"])
        t.expect(flag.accepts("opus"), "FlagSpec.accepts() works the same way")
        t.expect(!flag.accepts("haiku"), "FlagSpec.accepts() rejects an undeclared value")

        let advisorNoOff = AdvisorSpec(flag: "--advisor", values: ["opus"], disableArgs: [])
        t.expect(!advisorNoOff.canDisable, "no disable_args means the advisor has no off switch")
        let advisorWithOff = AdvisorSpec(flag: "--advisor", values: ["opus"], disableArgs: ["--off"])
        t.expect(advisorWithOff.canDisable, "disable_args present means the advisor can be turned off")
    }

    // MARK: 16. Terminal-specific required-key errors

    do {
        let missingArgs = """
        schema = 1
        id = "argv-missing-args"
        display_name = "Argv Missing Args"
        kind = "argv"
        binary = "sometool"
        """
        do {
            _ = try TerminalManifest.parse(missingArgs, origin: .bundled)
            t.expect(false, "an argv terminal missing args should throw")
        } catch let error as ManifestError {
            if case .missingKey(let key, let id) = error {
                t.expectEqual(key, "args", "the missing key is named")
                t.expectEqual(id, "argv-missing-args", "the offending manifest is named")
            } else {
                t.expect(false, "wrong error case for argv terminal missing args: \(error)")
            }
        } catch {
            t.expect(false, "wrong error type for argv terminal missing args: \(error)")
        }

        let missingBundleID = """
        schema = 1
        id = "applescript-missing-bundle-id"
        display_name = "Missing Bundle Id"
        kind = "applescript"
        applescript = "on run argv\\nend run"
        """
        do {
            _ = try TerminalManifest.parse(missingBundleID, origin: .bundled)
            t.expect(false, "an applescript terminal missing bundle_id should throw")
        } catch let error as ManifestError {
            if case .missingKey(let key, let id) = error {
                t.expectEqual(key, "bundle_id", "the missing key is named")
                t.expectEqual(id, "applescript-missing-bundle-id", "the offending manifest is named")
            } else {
                t.expect(false, "wrong error case for applescript terminal missing bundle_id: \(error)")
            }
        } catch {
            t.expect(false, "wrong error type for applescript terminal missing bundle_id: \(error)")
        }
    }

    // MARK: 17. profile_env and profile_flag both set is rejected — declare exactly one, or neither

    do {
        let text = """
        schema = 1
        id = "both-profile-mechanisms"
        display_name = "Both"
        binary = "b"
        profile_env = "SOME_ENV"
        profile_flag = "--some-flag"
        """
        t.expectThrows("declaring both profile_env and profile_flag is rejected") {
            try AgentManifest.parse(text, origin: .bundled)
        }
    }
}
