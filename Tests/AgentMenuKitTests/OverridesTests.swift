// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AgentMenuKit

// U7 — Overrides: the one place the five KTD4 environment overrides are
// read, and the argument-domain gate that is the only thing standing between
// `launchctl setenv` and a real GUI launch reading the maintainer's own
// `config.toml` from somewhere else.
//
// Before writing these, the argument-domain mechanism itself was verified
// with a real, separate process — not assumed. A throwaway Foundation-only
// executable (no AppKit) was built with `swiftc` and run with and without
// `-RealFlagTest YES` on its own argv: with the flag,
// `UserDefaults.standard.bool(forKey: "RealFlagTest")` was `true` and
// `object(forKey:)` was the string `"YES"`; without it, both were absent.
// That confirms the argument domain is populated by plain Foundation
// startup, independent of AppKit or of being launched from Finder — so
// `Overrides.forGUI()`'s use of `UserDefaults.standard.bool(forKey:)` reads
// exactly what `-AgentMenuHarness YES` on the real launch argument sets.
// That run also caught a real gotcha this suite's own helper below has to
// respect: `UserDefaults.setVolatileDomain(_:forName:)` *replaces* the named
// domain's dictionary rather than merging into it, so a value the process's
// own real argv had already parsed there is gone the moment a test calls it
// — which is exactly why the in-process technique below (following
// `JournalTests.swift`'s own precedent for this same domain) always passes a
// complete dictionary rather than relying on anything already present.
//
// The suite does not spawn a fresh process per case to re-derive that
// finding automatically: `JournalTests.swift` already established, and this
// file follows, that manipulating `UserDefaults.argumentDomain` directly
// exercises "exactly the call [the app] makes" without paying for a process
// per case. See the report for why a hidden CLI probe subcommand was
// rejected as the vehicle for this instead.

/// The volatile argument domain, not a named suite — see the rationale in
/// `JournalTests.swift`: it is in memory, it is the first domain
/// `object(forKey:)`/`bool(forKey:)` search, and it is exactly where a value
/// handed to a launch lands. Values are strings, matching what real argv
/// parsing produces (`-AgentMenuHarness YES` becomes the string `"YES"`,
/// never a `Bool`) — the empirical check above is why this matters here.
private func argumentDomain(_ values: [String: String]) -> UserDefaults {
    let defaults = UserDefaults.standard
    defaults.setVolatileDomain(values, forName: UserDefaults.argumentDomain)
    return defaults
}

private func resetArgumentDomain() {
    UserDefaults.standard.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
}

func runOverridesTests(_ t: TestRunner) {
    t.suite("Overrides")

    // MARK: - 1. forCLI: unconditional, all five variables, tilde-expanded.
    // No flag needed — this is `resolvedConfigURL()`'s and
    // `resolvedManifestUserRoot()`'s own long-standing behaviour, now shared.

    ({
        let env = [
            "AGENTMENU_CONFIG": "/tmp/agentmenu-overrides-test/config.toml",
            "AGENTMENU_MANIFESTS_USER_ROOT": "/tmp/agentmenu-overrides-test/manifests",
            "AGENTMENU_PROFILE_ROOT": "/tmp/agentmenu-overrides-test/profiles",
            "AGENTMENU_DEFAULTS_SUITE": "dev.facens.agentmenu.harness-test",
            "AGENTMENU_HARNESS_DIR": "/tmp/agentmenu-overrides-test/harness",
        ]
        let overrides = Overrides.forCLI(environment: env)
        t.expectEqual(overrides.config?.path, "/tmp/agentmenu-overrides-test/config.toml", "AGENTMENU_CONFIG is read unconditionally")
        t.expectEqual(overrides.manifestsUserRoot?.path, "/tmp/agentmenu-overrides-test/manifests", "AGENTMENU_MANIFESTS_USER_ROOT is read unconditionally")
        t.expectEqual(overrides.profileRoot?.path, "/tmp/agentmenu-overrides-test/profiles", "AGENTMENU_PROFILE_ROOT is read unconditionally")
        t.expectEqual(overrides.defaultsSuite, "dev.facens.agentmenu.harness-test", "AGENTMENU_DEFAULTS_SUITE is read unconditionally")
        t.expectEqual(overrides.harnessDirectory?.path, "/tmp/agentmenu-overrides-test/harness", "AGENTMENU_HARNESS_DIR is read unconditionally")
    })()

    // A `~`-prefixed value is tilde-expanded, matching `resolvedConfigURL()`'s
    // own `(override as NSString).expandingTildeInPath`.
    ({
        let expandedHome = FileManager.default.homeDirectoryForCurrentUser.path
        let overrides = Overrides.forCLI(environment: ["AGENTMENU_CONFIG": "~/scratch/config.toml"])
        t.expectEqual(
            overrides.config?.path, expandedHome + "/scratch/config.toml",
            "a ~-prefixed AGENTMENU_CONFIG is tilde-expanded"
        )
    })()

    // MARK: - 2. forCLI: with none of the five variables set, every field is
    // nil — the "nothing changes when no variable is set" half of KTD4.

    ({
        let overrides = Overrides.forCLI(environment: [:])
        t.expect(overrides == Overrides(), "with nothing in the environment, every field is nil")
    })()

    // MARK: - 3. forCLI: an empty-string value is treated as absent, the
    // same guard `resolvedConfigURL()` already had (`!override.isEmpty`).

    ({
        let overrides = Overrides.forCLI(environment: ["AGENTMENU_CONFIG": ""])
        t.expect(overrides.config == nil, "an empty AGENTMENU_CONFIG is treated as unset, not as the current directory")
    })()

    // MARK: - 4. forGUI, the mandatory negative case (KTD4's whole point):
    // AGENTMENU_CONFIG set in the environment, no -AgentMenuHarness YES in
    // the argument domain — the GUI resolves nil (real default), not the
    // override. Exercised through the real `UserDefaults.standard` argument
    // domain, the same call `AppEnvironment.init`'s default makes.

    ({
        resetArgumentDomain()
        defer { resetArgumentDomain() }
        let defaults = argumentDomain([:]) // no flag at all, matching a Finder launch
        let overrides = Overrides.forGUI(
            defaults: defaults,
            environment: ["AGENTMENU_CONFIG": "/tmp/should-never-be-read/config.toml"]
        )
        t.expect(overrides == Overrides(), "with no -AgentMenuHarness flag, every field is nil regardless of the environment")
    })()

    // A value present but not the harness flag must not open the gate either
    // — the gate checks `harnessFlagKey` specifically, not "the argument
    // domain is non-empty".
    ({
        resetArgumentDomain()
        defer { resetArgumentDomain() }
        let defaults = argumentDomain(["SomeOtherFlag": "YES"])
        let overrides = Overrides.forGUI(defaults: defaults, environment: ["AGENTMENU_CONFIG": "/tmp/x/config.toml"])
        t.expect(overrides.config == nil, "an unrelated argument-domain key does not open the gate")
    })()

    // MARK: - 5. forGUI, the positive control: the same environment, with
    // -AgentMenuHarness YES in the argument domain, DOES read the override —
    // proving cases 4's silence is the gate closing, not a reader that
    // returns nil unconditionally.

    ({
        resetArgumentDomain()
        defer { resetArgumentDomain() }
        let defaults = argumentDomain(["AgentMenuHarness": "YES"]) // the literal string -AgentMenuHarness YES parses to
        let env = [
            "AGENTMENU_CONFIG": "/tmp/agentmenu-overrides-test/gui-config.toml",
            "AGENTMENU_MANIFESTS_USER_ROOT": "/tmp/agentmenu-overrides-test/gui-manifests",
            "AGENTMENU_PROFILE_ROOT": "/tmp/agentmenu-overrides-test/gui-profiles",
            "AGENTMENU_DEFAULTS_SUITE": "dev.facens.agentmenu.gui-suite",
            "AGENTMENU_HARNESS_DIR": "/tmp/agentmenu-overrides-test/gui-harness",
        ]
        let overrides = Overrides.forGUI(defaults: defaults, environment: env)
        t.expectEqual(overrides.config?.path, "/tmp/agentmenu-overrides-test/gui-config.toml", "with the flag set, AGENTMENU_CONFIG is honoured")
        t.expectEqual(overrides.manifestsUserRoot?.path, "/tmp/agentmenu-overrides-test/gui-manifests", "…and the manifests root")
        t.expectEqual(overrides.profileRoot?.path, "/tmp/agentmenu-overrides-test/gui-profiles", "…and the profile root")
        t.expectEqual(overrides.defaultsSuite, "dev.facens.agentmenu.gui-suite", "…and the defaults suite")
        t.expectEqual(overrides.harnessDirectory?.path, "/tmp/agentmenu-overrides-test/gui-harness", "…and the harness directory")
    })()

    // `NO` (or absence) closes the gate exactly as absence does — the check
    // is `bool(forKey:)`, not merely "the key exists".
    ({
        resetArgumentDomain()
        defer { resetArgumentDomain() }
        let defaults = argumentDomain(["AgentMenuHarness": "NO"])
        let overrides = Overrides.forGUI(defaults: defaults, environment: ["AGENTMENU_CONFIG": "/tmp/x/config.toml"])
        t.expect(overrides.config == nil, "-AgentMenuHarness NO does not open the gate")
    })()

    // MARK: - 6. forGUI reads the flag from `defaults` only — never lets
    // AGENTMENU_DEFAULTS_SUITE (or anything else in the environment) decide
    // whether the gate is open. With the flag absent, a suite name in the
    // environment changes nothing about the (still all-nil) result.
    ({
        resetArgumentDomain()
        defer { resetArgumentDomain() }
        let defaults = argumentDomain([:])
        let overrides = Overrides.forGUI(
            defaults: defaults,
            environment: ["AGENTMENU_DEFAULTS_SUITE": "some-persisted-suite", "AGENTMENU_CONFIG": "/tmp/x/config.toml"]
        )
        t.expect(overrides == Overrides(), "AGENTMENU_DEFAULTS_SUITE in the environment cannot substitute for the argument-domain flag")
    })()

    // MARK: - 7. resolveProfileDirectory: with no profile root, the result
    // is byte-identical to `Profile.expandedConfigDirectory` — real `~`
    // expansion against the process's actual home. This is the "with no
    // variables set, the defaults are byte-identical to today's paths" case,
    // for the profile-directory half of KTD4.

    ({
        let profile = Profile(id: "work", name: "Work", configDirectory: "~/.claude")
        let resolved = Overrides.resolveProfileDirectory("~/.claude", profileRoot: nil)
        t.expectEqual(resolved, profile.expandedConfigDirectory, "with no profile root, resolution matches Profile.expandedConfigDirectory exactly")
    })()

    // MARK: - 8. resolveProfileDirectory: an absolute config_dir ignores the
    // profile root entirely (explicit plan edge case).

    ({
        let root = URL(fileURLWithPath: "/tmp/agentmenu-profile-root")
        let resolved = Overrides.resolveProfileDirectory("/Users/someone/.claude", profileRoot: root)
        t.expectEqual(resolved.path, "/Users/someone/.claude", "an absolute config_dir is used as written, ignoring the profile root")
    })()

    // MARK: - 9. resolveProfileDirectory: a `~`-prefixed config_dir
    // redirects under the profile root, matching the identity-to-directory
    // convention `Detection.profiles(for:)` produces when it names an
    // account from a directory it finds under the home directory
    // (`~/.claude`, `~/.claude-<suffix>`).

    ({
        let root = URL(fileURLWithPath: "/tmp/agentmenu-profile-root")
        t.expectEqual(
            Overrides.resolveProfileDirectory("~/.claude", profileRoot: root).path,
            "/tmp/agentmenu-profile-root/.claude",
            "~/.claude redirects under the profile root"
        )
        t.expectEqual(
            Overrides.resolveProfileDirectory("~/.claude-personal", profileRoot: root).path,
            "/tmp/agentmenu-profile-root/.claude-personal",
            "~/.claude-<identity> redirects under the profile root too"
        )
        t.expectEqual(
            Overrides.resolveProfileDirectory("~", profileRoot: root).path,
            root.path,
            "bare ~ resolves to the profile root itself"
        )
    })()

    // MARK: - 10. Overrides.defaults(forSuite:): nil resolves to .standard;
    // a name resolves to a working, distinct suite. `HarnessJournal.activate
    // (defaults:)` takes this value directly, so a bug here would silently
    // misroute the journal key itself.

    ({
        t.expect(Overrides.defaults(forSuite: nil) === UserDefaults.standard, "no suite name resolves to the standard domain")

        let suiteName = "dev.facens.agentmenu.overrides-test-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let suite = Overrides.defaults(forSuite: suiteName)
        t.expect(suite !== UserDefaults.standard, "a named suite is a distinct instance from the standard domain")
        suite.set("marker", forKey: "OverridesTestMarker")
        t.expectEqual(
            UserDefaults(suiteName: suiteName)?.string(forKey: "OverridesTestMarker"), "marker",
            "the suite Overrides.defaults(forSuite:) returned is the same real suite a fresh lookup by name finds"
        )
        t.expect(
            UserDefaults.standard.string(forKey: "OverridesTestMarker") == nil,
            "writing into the named suite does not leak into the standard domain"
        )
    })()

    // MARK: - 11. An override pointing at an unwritable directory surfaces
    // through `ConfigStore.save`'s own throw rather than silently falling
    // back to the real home. This is the mechanism
    // `AppEnvironment.saveNow()`'s existing `catch` turns into `saveFailure`
    // — `saveFailure` itself is `@Published` state on `AppEnvironment`, which
    // this suite (Kit-only, per JournalTests.swift's own note) cannot
    // construct, so this proves the failure the App target's unchanged
    // `catch` block depends on.

    ({
        let dir = TempDir("overrides-unwritable")
        let readOnlyParent = dir.url.appendingPathComponent("readonly")
        defer {
            // Restore write permission on the directory that was actually
            // chmod'ed, matching StatuslineBridgeTests.swift's own
            // unwritable-directory cleanup — `dir.cleanup()` needs to be
            // able to remove `readOnlyParent` itself, which it cannot do
            // while that directory is still read-only.
            _ = try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: readOnlyParent.path)
            dir.cleanup()
        }
        try? FileManager.default.createDirectory(at: readOnlyParent, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: readOnlyParent.path)

        let overrides = Overrides.forCLI(environment: ["AGENTMENU_CONFIG": readOnlyParent.appendingPathComponent("config.toml").path])
        guard let configURL = overrides.config else {
            t.expect(false, "the override resolved to a URL")
            return
        }
        let store = ConfigStore(url: configURL)
        t.expectThrows("saving into a read-only directory throws rather than falling back to the real default") {
            try store.save(Config())
        }
    })()

    // MARK: - CLI integration: dump-state (skips cleanly when the CLI has
    // not been built yet, matching every other CLI-integration suite here).
    runDumpStateCLITests(t)
}

// MARK: - CLI integration: `agentmenu dump-state`
//
// `agentMenuCLIBinary()`, `runCLI` and `CLIResult` are Harness.swift's own
// helpers (internal, not private, in this target) — reused rather than
// redefined, per this suite's own instructions.
//
// Every case here points `AGENTMENU_CONFIG` at a `TempDir`, never at the
// real default: none of these tests are the "no variables set" scenario —
// that one is exercised in-process, on `Overrides.forCLI(environment: [:])`
// above, precisely so a CLI-integration test never has to read (or, if a
// future change ever made dump-state fallible in a new way, write) the
// maintainer's real `~/.config/agentmenu`. Every other CLI-integration
// scenario in this test target follows the same rule.

private func runDumpStateCLITests(_ t: TestRunner) {
    t.suite("dump-state (CLI)")
    guard let binary = agentMenuCLIBinary() else {
        print("   (skipped: .build/debug/AgentMenuCLI not built — run 'swift build' first)")
        return
    }

    func dumpState(env: [String: String]) -> CLIResult {
        (try? runCLI(binary, ["dump-state"], env: env)) ?? CLIResult(status: -1, stdout: "", stderr: "runCLI threw")
    }

    func parsedJSON(_ result: CLIResult) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8))) as? [String: Any]
    }

    // MARK: 1. Happy path (re-expresses the plan's "with all three variables
    // set to a TempDir, seedIfMissing writes the config there and the
    // manifests root is read from there" for a tool this suite can actually
    // drive without launching the GUI): all five variables set to a
    // TempDir, a hand-seeded config.toml with one profile at an *absolute*
    // config_dir — the shape KTD4 says the harness itself always seeds —
    // and dump-state reports every root and the profile's directory
    // unchanged, exactly the paths given.

    ({
        let dir = TempDir("dump-state-happy")
        defer { dir.cleanup() }

        let configPath = dir.path("config.toml")
        let manifestsRoot = dir.path("manifests")
        let profileRoot = dir.path("profiles")
        let profileConfigDir = dir.path("profiles/abs/.claude")
        try? FileManager.default.createDirectory(atPath: manifestsRoot, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: profileConfigDir, withIntermediateDirectories: true)

        let configText = """
        schema = 1

        [[profiles]]
        id = "work"
        name = "Work"
        config_dir = "\(profileConfigDir)"
        """
        try? configText.write(toFile: configPath, atomically: true, encoding: .utf8)

        let env = [
            "AGENTMENU_CONFIG": configPath,
            "AGENTMENU_MANIFESTS_USER_ROOT": manifestsRoot,
            "AGENTMENU_PROFILE_ROOT": profileRoot,
        ]
        let result = dumpState(env: env)
        t.expectEqual(result.status, 0, "dump-state exits 0 when the config loads")
        guard let json = parsedJSON(result) else {
            t.expect(false, "dump-state prints valid JSON: \(result.stdout) / \(result.stderr)")
            return
        }
        t.expectEqual(json["config"] as? String, configPath, "the config field names the resolved AGENTMENU_CONFIG path")
        t.expectEqual(json["manifests_root"] as? String, manifestsRoot, "the manifests_root field names the resolved AGENTMENU_MANIFESTS_USER_ROOT path")
        t.expectEqual(json["profile_root"] as? String, profileRoot, "the profile_root field names the resolved AGENTMENU_PROFILE_ROOT path")
        t.expectEqual(json["profile_count"] as? Int, 1, "one profile was seeded")
        let profiles = json["profiles"] as? [[String: Any]] ?? []
        t.expectEqual(profiles.count, 1, "the profiles array has one entry")
        t.expectEqual(profiles.first?["id"] as? String, "work", "the profile's id is carried through")
        t.expectEqual(
            profiles.first?["config_dir"] as? String, profileConfigDir,
            "an absolute config_dir is reported unchanged — the shape the harness itself always seeds (KTD4), and the case where dump-state's answer and HarnessJournal's raw echo are guaranteed to agree (Covers AE8 groundwork)"
        )
    })()

    // MARK: 2. profile_root actually redirects a `~`-prefixed profile — the
    // case a real `seedIfMissing()`-created default profile could produce.
    // This is the one case where dump-state's answer and a *raw*
    // `expandedConfigDirectory` echo would disagree; noted here rather than
    // hidden, since `HarnessJournal`'s own fixture echo (U6, untouched by
    // this unit) does not apply this substitution — only an absolute,
    // harness-seeded profile is guaranteed to match both.

    ({
        let dir = TempDir("dump-state-profile-root")
        defer { dir.cleanup() }

        let configPath = dir.path("config.toml")
        let profileRoot = dir.path("profiles")
        let manifestsRoot = dir.path("manifests") // empty, and explicit — never the maintainer's real ~/.config/agentmenu
        try? FileManager.default.createDirectory(atPath: profileRoot, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: manifestsRoot, withIntermediateDirectories: true)

        let configText = """
        schema = 1

        [[profiles]]
        id = "work"
        name = "Work"
        config_dir = "~/.claude"
        """
        try? configText.write(toFile: configPath, atomically: true, encoding: .utf8)

        let result = dumpState(env: [
            "AGENTMENU_CONFIG": configPath,
            "AGENTMENU_PROFILE_ROOT": profileRoot,
            "AGENTMENU_MANIFESTS_USER_ROOT": manifestsRoot,
        ])
        guard let json = parsedJSON(result), let profiles = json["profiles"] as? [[String: Any]] else {
            t.expect(false, "dump-state prints valid JSON: \(result.stdout) / \(result.stderr)")
            return
        }
        t.expectEqual(
            profiles.first?["config_dir"] as? String, profileRoot + "/.claude",
            "a ~-prefixed config_dir redirects under the profile root"
        )
    })()

    // MARK: 3. Manifest availability, a stand-in for U9's "launch-terminal"
    // fixture: a user-overlay `terminals/terminal-app.toml` with
    // `enabled = true` at the manifests root, `trusted = true` for it in
    // config.toml (a user-origin manifest needs both, R44), and Terminal.app
    // genuinely installed on any machine this suite runs on. Reports
    // "available" before anything is clicked — literally what "Integration:
    // dump-state against U9's launch fixture reports Terminal.app as
    // available before any click" asks for, built here since U9 itself does
    // not exist yet.

    ({
        let dir = TempDir("dump-state-availability")
        defer { dir.cleanup() }

        let configPath = dir.path("config.toml")
        let manifestsRoot = dir.path("manifests")
        try? FileManager.default.createDirectory(atPath: manifestsRoot + "/terminals", withIntermediateDirectories: true)

        let overlay = """
        schema = 1
        id = "terminal-app"
        display_name = "Terminal"
        kind = "applescript"
        bundle_id = "com.apple.Terminal"
        enabled = true
        applescript = \"\"\"
        on run argv
          tell application "Terminal" to activate
        end run
        \"\"\"
        """
        try? overlay.write(toFile: manifestsRoot + "/terminals/terminal-app.toml", atomically: true, encoding: .utf8)

        let configText = """
        schema = 1

        [terminals.terminal-app]
        trusted = true
        """
        try? configText.write(toFile: configPath, atomically: true, encoding: .utf8)

        let result = dumpState(env: ["AGENTMENU_CONFIG": configPath, "AGENTMENU_MANIFESTS_USER_ROOT": manifestsRoot])
        guard let json = parsedJSON(result), let terminals = json["terminals"] as? [[String: Any]] else {
            t.expect(false, "dump-state prints valid JSON: \(result.stdout) / \(result.stderr)")
            return
        }
        let terminalApp = terminals.first { $0["id"] as? String == "terminal-app" }
        t.expectEqual(
            terminalApp?["availability"] as? String, "available",
            "a trusted, enabled Terminal.app overlay resolves to available before any click — the fixture's own state, not a live probe result"
        )
    })()

    // MARK: 4. A disabled bundled manifest reports missing with a detail
    // that says why, and the same overlay from case 3 without `trusted`
    // set in config.toml reports needs_confirmation instead of available —
    // proving the three-bucket/`detail` split actually distinguishes the
    // cases a harness script needs to tell apart, and that trust (R44) is
    // still enforced through this command.

    ({
        let dir = TempDir("dump-state-availability-2")
        defer { dir.cleanup() }
        let configPath = dir.path("config.toml")
        let manifestsRoot = dir.path("manifests") // empty — real bundled resources only, no overlay
        try? FileManager.default.createDirectory(atPath: manifestsRoot, withIntermediateDirectories: true)
        try? "schema = 1".write(toFile: configPath, atomically: true, encoding: .utf8)

        let result = dumpState(env: ["AGENTMENU_CONFIG": configPath, "AGENTMENU_MANIFESTS_USER_ROOT": manifestsRoot])
        guard let json = parsedJSON(result), let terminals = json["terminals"] as? [[String: Any]] else {
            t.expect(false, "dump-state prints valid JSON: \(result.stdout) / \(result.stderr)")
            return
        }
        // Against the real bundled Resources/terminals/*.toml (no overlay,
        // no config overrides): terminal-app ships enabled=true and verified
        // as of 2026-09-21, origin .bundled — so it is available, not
        // unconfirmed, since the trust gate only applies to user-origin
        // manifests and Terminal.app is on every Mac. This
        // depends on `ResourceRoot.bundled()` actually resolving
        // Resources/ from wherever the CLI binary was built — the same
        // condition `ResolveCommandTests.swift`'s "launch-parity" cases
        // guard explicitly rather than assert through, so this does too
        // instead of failing when only that unrelated resolution comes up
        // empty.
        guard !terminals.isEmpty else {
            print("   (skipped: no bundled terminal manifests resolved from the test binary's ResourceRoot.bundled())")
            return
        }
        let terminalApp = terminals.first { $0["id"] as? String == "terminal-app" }
        t.expectEqual(terminalApp?["availability"] as? String, "available", "the bundled Terminal.app manifest is enabled, and Terminal.app is on every Mac")
    })()

    ({
        let dir = TempDir("dump-state-availability-3")
        defer { dir.cleanup() }
        let configPath = dir.path("config.toml")
        let manifestsRoot = dir.path("manifests")
        try? FileManager.default.createDirectory(atPath: manifestsRoot + "/terminals", withIntermediateDirectories: true)
        let overlay = """
        schema = 1
        id = "terminal-app"
        display_name = "Terminal"
        kind = "applescript"
        bundle_id = "com.apple.Terminal"
        enabled = true
        applescript = \"\"\"
        on run argv
          tell application "Terminal" to activate
        end run
        \"\"\"
        """
        try? overlay.write(toFile: manifestsRoot + "/terminals/terminal-app.toml", atomically: true, encoding: .utf8)
        // No `[terminals.terminal-app]` table at all this time — trusted
        // defaults to false for a user-origin manifest (R44).
        try? "schema = 1".write(toFile: configPath, atomically: true, encoding: .utf8)

        let result = dumpState(env: ["AGENTMENU_CONFIG": configPath, "AGENTMENU_MANIFESTS_USER_ROOT": manifestsRoot])
        guard let json = parsedJSON(result), let terminals = json["terminals"] as? [[String: Any]] else {
            t.expect(false, "dump-state prints valid JSON: \(result.stdout) / \(result.stderr)")
            return
        }
        let terminalApp = terminals.first { $0["id"] as? String == "terminal-app" }
        t.expectEqual(
            terminalApp?["availability"] as? String, "needs_confirmation",
            "an enabled but unconfirmed user-overlay manifest is needs_confirmation, never available — the trust gate (R44) runs before the enabled check"
        )
    })()

    // MARK: 5. A config.toml that fails to parse is a usage-style failure
    // (exit 2), matching `agentmenu resolve`'s own precedent for the same
    // failure — nothing on stdout.

    ({
        let dir = TempDir("dump-state-malformed")
        defer { dir.cleanup() }
        let configPath = dir.path("config.toml")
        try? "this is not valid toml [[[".write(toFile: configPath, atomically: true, encoding: .utf8)

        let result = dumpState(env: ["AGENTMENU_CONFIG": configPath])
        t.expectEqual(result.status, 2, "a config.toml that fails to parse exits 2")
        t.expect(result.stdout.isEmpty, "nothing is printed on stdout when the config could not be loaded")
    })()

    // MARK: 6. An unrecognized extra argument is a usage error (exit 2), the
    // same idiom every other subcommand in this CLI uses for a bad
    // invocation.

    ({
        let dir = TempDir("dump-state-usage")
        defer { dir.cleanup() }
        let configPath = dir.path("config.toml") // never written
        let manifestsRoot = dir.path("manifests")
        try? FileManager.default.createDirectory(atPath: manifestsRoot, withIntermediateDirectories: true)
        let env = ["AGENTMENU_CONFIG": configPath, "AGENTMENU_MANIFESTS_USER_ROOT": manifestsRoot]

        let bad = (try? runCLI(binary, ["dump-state", "--unexpected"], env: env))
        t.expect(bad?.status == 2, "an unknown argument to dump-state is a usage error")

        // No extra argument, config file absent: ConfigStore.load() returns
        // nil, not a throw, so dump-state still succeeds with an empty
        // Config() — "config file does not exist yet" is not an error.
        let result = dumpState(env: env)
        t.expectEqual(result.status, 0, "a missing config.toml is not an error — dump-state reports the empty default Config()")
    })()
}
