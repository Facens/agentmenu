// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AgentMenuKit

/// U9: every R9 scenario as a file, plus the fixture builders they name
/// through `fixture <name> [args...]` (harness/lib/scenario.sh). This suite
/// never launches AgentMenu and never drives the screen — everything it
/// checks is either static (a script parses, carries the stranger-only
/// marker, is free of the maintainer's own username and home path) or a
/// real run of a fixture's `apply.sh` against a scratch `$HOME`, through
/// the real `fixture()` dispatch in the real harness/lib/scenario.sh
/// (sourced directly, the same idiom HarnessScenarioTests.swift uses for
/// its own rig), with `defaults` stubbed on `PATH` so `fx_activate_journal`
/// (harness/fixtures/agentmenu/_lib.sh) never reaches the real
/// `dev.facens.agentmenu` preferences domain on whatever machine runs this
/// suite — a real hazard this file's own author hit by hand while writing
/// it: `defaults write` resolves the account's preferences through the
/// operating system's own user record, not through a `$HOME` environment
/// override, so a fixture that called it unstubbed against a scratch `$HOME`
/// would silently edit the real developer's real AgentMenu preferences
/// instead.
///
/// What this suite does NOT attempt, and why: `install_app`'s own success
/// path ends in `mv` into the real `/Applications` and a real `open`
/// (harness/guest/install.sh), which HarnessScenarioTests.swift's own
/// header already rules out for the identical reason — no automated suite
/// may risk that on the machine it happens to run on — so nothing here
/// drives a scenario past its `fixture` step. Everything past that point
/// (AXIdentifier clicks, dialogs, journal events from a real running app)
/// needs the stranger-tier VM this unit's own ground rules say does not
/// exist yet; see this unit's own report for the full list of what still
/// needs it.
func runHarnessFixtureTests(_ t: TestRunner) {
    t.suite("HarnessFixture")

    let root = repositoryRoot()
    let harnessDir = root.appendingPathComponent("harness")
    let fixturesDir = harnessDir.appendingPathComponent("fixtures/agentmenu")
    let scenariosDir = harnessDir.appendingPathComponent("scenarios/agentmenu")

    guard FileManager.default.fileExists(atPath: fixturesDir.path) else {
        t.expect(false, "harness/fixtures/agentmenu is missing at \(fixturesDir.path) — this suite fails rather than skipping")
        return
    }

    hfix_testShellFilesParseAndAreExecutable(t, harnessDir: harnessDir, fixturesDir: fixturesDir, scenariosDir: scenariosDir)
    hfix_testScenariosAreStrangerOnly(t, scenariosDir: scenariosDir)
    hfix_testFixtureFilesAreSynthetic(t, fixturesDir: fixturesDir)
    hfix_testScenarioClicksNameKnownIdentifiers(t, scenariosDir: scenariosDir)
    hfix_testPathHash(t, harnessDir: harnessDir)
    hfix_testFirstRunFixture(t, harnessDir: harnessDir)
    hfix_testConfiguredTerminalFixture(t, harnessDir: harnessDir)
    hfix_testOwnedSessionFixture(t, harnessDir: harnessDir)
    hfix_testConfiguredProfileFixture(t, harnessDir: harnessDir)
    hfix_testNeedsLoginPromptFixture(t, harnessDir: harnessDir)
    hfix_testEveryConfigWritingFixturePinsKeepRunningOff(t, harnessDir: harnessDir, fixturesDir: fixturesDir)
    hfix_testEveryConfigWritingFixturePlantsNotificationsAsked(t, harnessDir: harnessDir, fixturesDir: fixturesDir)
    hfix_testPlantSessionHelper(t, fixturesDir: fixturesDir)
}

// MARK: - U5: the sessions-tab scenario's live session. `_plant-session.sh`
// starts a real idle process and writes the registry file that describes it;
// this runs it in a scratch HOME and reads the result back through the real
// `RegistryReader`, which is the only thing that can say the `procStart` it
// wrote (TZ=UTC `ps -o lstart=`) is one the reader accepts. The process is
// killed on the way out whatever happens.

private func hfix_testPlantSessionHelper(_ t: TestRunner, fixturesDir: URL) {
    let script = fixturesDir.appendingPathComponent("_plant-session.sh").path
    guard FileManager.default.fileExists(atPath: script) else {
        t.expect(false, "harness/fixtures/agentmenu/_plant-session.sh is missing")
        return
    }
    let home = TempDir("hf-plant-session")
    defer { home.cleanup() }
    let sessionID = "5d1c7e0a-3b6e-4d7a-9c21-0e0b7a4d1f33"
    let result = runProcess(
        "/bin/bash",
        [script, sessionID, ".claude-work", "dev/it's a project", "30"],
        environment: ["HOME": home.url.path]
    )
    t.expectEqual(result.status, 0, "_plant-session.sh runs in a scratch HOME — \(result.stderr)")
    guard let pid = Int32(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        t.expect(false, "_plant-session.sh prints the pid and nothing else — got '\(result.stdout)'")
        return
    }
    defer { kill(pid, SIGTERM) }

    let profileDirectory = home.url.appendingPathComponent(".claude-work")
    let file = profileDirectory.appendingPathComponent("sessions/\(pid).json")
    t.expect(FileManager.default.fileExists(atPath: file.path), "the registry file is named for the pid")
    t.expectEqual(
        ((try? FileManager.default.contentsOfDirectory(atPath: profileDirectory.appendingPathComponent("sessions").path)) ?? []).sorted(),
        ["\(pid).json"],
        "nothing else is left in the sessions directory, no temporary file"
    )

    let reader = RegistryReader(
        profiles: [RegistryProfile(id: "work", name: "Work", directory: profileDirectory)],
        terminalResolver: TerminalHostResolver(terminals: [])
    )
    let sessions = reader.refresh()
    t.expectEqual(sessions.count, 1, "the real reader lists the planted session — its procStart matches the running process")
    guard let session = sessions.first else { return }
    t.expectEqual(session.pid, pid, "it is the planted process")
    t.expectEqual(session.sessionId, sessionID, "with the session id it was given")
    t.expectEqual(session.status, .needsYou, "a permission prompt maps to Needs you, so the badge shows")
    t.expectEqual(session.profileID, "work", "attributed to the profile whose directory it sits in")
    t.expect(session.cwd?.hasSuffix("dev/it's a project") == true, "the working directory survives a space and an apostrophe — got \(session.cwd ?? "nil")")
    t.expect(session.isClaudeCode, "it is a Claude Code row")
}

// MARK: - R15 / KTD16: "keep running when window closes" is on by default, so
// every fixture that writes a config.toml pins it off in `[defaults]` — the
// scenarios written before the field existed test a plain launch, and must
// keep doing so. The one named exception is `owned-session`, which pins it ON
// so the hosted launch path has a scenario. Discovered by running each
// fixture rather than listed: a fixture added later that writes a config and
// forgets the key fails here, and one that writes none (first-run,
// journal-only) is not asked for it.

private func hfix_testEveryConfigWritingFixturePinsKeepRunningOff(_ t: TestRunner, harnessDir: URL, fixturesDir: URL) {
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: fixturesDir.path)) ?? []).sorted()
    var writers = 0
    var sawOwnedSession = false
    for name in names {
        let script = fixturesDir.appendingPathComponent("\(name)/apply.sh")
        guard FileManager.default.fileExists(atPath: script.path) else { continue }

        guard let rig = hfix_makeRig("hf-keep-running-\(name)", harnessDir: harnessDir, t: t) else { continue }
        defer { rig.dir.cleanup() }
        let result = hfix_runDriver(rig, "fixture agentmenu/\(name) \"nonce-kr\"")
        t.expectEqual(result.status, 0, "agentmenu/\(name) applied cleanly — \(result.stderr)")

        // A fixture that plants no config.toml (first-run, journal-only) is
        // not asked for the key: whether one is written is decided by
        // running it, not by reading its source.
        let configPath = rig.home + "/.config/agentmenu/config.toml"
        guard let config = try? String(contentsOfFile: configPath, encoding: .utf8) else { continue }
        writers += 1
        // Parsed by the real decoder, not grepped: the key must be in
        // `[defaults]`, not in a folder, or a comment, or a string.
        let url = URL(fileURLWithPath: configPath)
        // `owned-session` is the one named exception: it turns the session
        // host on so owned-launch.sh exercises the hosted launch path.
        let expected = (name == hfix_ownedSessionFixture)
        if let loaded = t.attempt("load agentmenu/\(name)'s config.toml", { try ConfigStore(url: url).load() }), let parsed = loaded {
            t.expectEqual(parsed.defaults.keepRunning, expected, "agentmenu/\(name) plants keep_running = \(expected) in [defaults]")
        }
        t.expect(config.contains("keep_running = \(expected)"), "agentmenu/\(name)'s config.toml spells the key the way the app reads it")
        if expected {
            sawOwnedSession = true
        } else {
            t.expect(!config.contains("keep_running = true"), "agentmenu/\(name) does not turn the session host on: only \(hfix_ownedSessionFixture) may")
        }
    }
    t.expect(writers >= 3, "the discovery found the config-writing fixtures (configured-terminal, configured-profile, needs-login-prompt) — got \(writers); an empty enumeration would make this check vacuous")
    t.expect(sawOwnedSession, "the discovery found \(hfix_ownedSessionFixture), the one fixture that must carry keep_running = true")
}

/// The one fixture whose config turns "keep running" on (U11): the hosted
/// launch path's scenario, `owned-launch`, runs on it.
private let hfix_ownedSessionFixture = "owned-session"

// MARK: - KTD15 / KTD16: AgentMenu asks macOS for notification permission on
// the first launch it makes or the first open of the Sessions tab, and that
// system prompt is one the shared dialog script cannot answer. A fixture that
// writes a config.toml therefore plants `notifications_asked = true`, so no
// scenario on it meets the prompt. Discovered by running each fixture, like
// the check above: one added later that writes a config and forgets the key
// fails here, and one that writes none (first-run, journal-only) is not asked.

private func hfix_testEveryConfigWritingFixturePlantsNotificationsAsked(_ t: TestRunner, harnessDir: URL, fixturesDir: URL) {
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: fixturesDir.path)) ?? []).sorted()
    var writers = 0
    for name in names {
        let script = fixturesDir.appendingPathComponent("\(name)/apply.sh")
        guard FileManager.default.fileExists(atPath: script.path) else { continue }

        guard let rig = hfix_makeRig("hf-notifications-asked-\(name)", harnessDir: harnessDir, t: t) else { continue }
        defer { rig.dir.cleanup() }
        let result = hfix_runDriver(rig, "fixture agentmenu/\(name) \"nonce-na\"")
        t.expectEqual(result.status, 0, "agentmenu/\(name) applied cleanly — \(result.stderr)")

        let configPath = rig.home + "/.config/agentmenu/config.toml"
        guard let config = try? String(contentsOfFile: configPath, encoding: .utf8) else { continue }
        writers += 1
        // Parsed by the real decoder: a key in a table, a comment or a string
        // would not count.
        let url = URL(fileURLWithPath: configPath)
        if let loaded = t.attempt("load agentmenu/\(name)'s config.toml", { try ConfigStore(url: url).load() }), let parsed = loaded {
            t.expectEqual(parsed.notificationsAsked, true, "agentmenu/\(name) plants notifications_asked = true")
            t.expectEqual(parsed.notifyNeedsYou, true, "and leaves the Needs-you toggle at its default, on")
        }
        t.expect(config.contains("notifications_asked = true"), "agentmenu/\(name)'s config.toml spells the key the way the app reads it")
    }
    t.expect(writers >= 3, "the discovery found the config-writing fixtures (configured-terminal, configured-profile, needs-login-prompt) — got \(writers); an empty enumeration would make this check vacuous")
}

// MARK: - Every new shell file parses under `bash -n`, and every apply.sh /
// scenario is executable. Mirrors HarnessScenarioTests.swift's own
// `hs_testSyntaxAndSmokeFiles`.

private func hfix_testShellFilesParseAndAreExecutable(
    _ t: TestRunner, harnessDir: URL, fixturesDir: URL, scenariosDir: URL
) {
    var files: [String] = [
        harnessDir.appendingPathComponent("lib/fixtures.sh").path,
        fixturesDir.appendingPathComponent("_lib.sh").path,
    ]
    for fixture in ["first-run", "configured-terminal", "configured-profile", "needs-login-prompt", hfix_ownedSessionFixture] {
        files.append(fixturesDir.appendingPathComponent("\(fixture)/apply.sh").path)
    }
    files.append(fixturesDir.appendingPathComponent("_plant-session.sh").path)
    for scenario in hfix_scenarioNames {
        files.append(scenariosDir.appendingPathComponent("\(scenario).sh").path)
    }

    for path in files {
        guard FileManager.default.fileExists(atPath: path) else {
            t.expect(false, "expected file is missing at \(path)")
            continue
        }
        let parsed = runProcess("/bin/bash", ["-n", path])
        t.expectEqual(parsed.status, 0, "\(path) parses — \(parsed.stderr)")
        t.expect(FileManager.default.isExecutableFile(atPath: path), "\(path) is executable")
    }
}

/// The seven R9 scenario names, in the same order the plan lists them, plus
/// `sessions-tab` and `owned-launch` (the session manager's two), plus
/// `launch-at-login-prompt` — the scenario that proves the existing-install
/// alert path `LaunchAtLoginPrompt.presentIfNeeded` raises, which none of
/// the original seven reach (`agentmenu/configured-profile` and
/// `agentmenu/configured-terminal` both now seed `launch_at_login_asked =
/// true` specifically so they don't).
private let hfix_scenarioNames = [
    "vanilla-first-run",
    "launch-terminal",
    "no-agent",
    "profile-work-only",
    "profile-personal-only",
    "profile-both",
    "bridge-install",
    "launch-at-login-prompt",
    "sessions-tab",
    "owned-launch",
]

// MARK: - Every scenario clicks, so every scenario declares
// HARNESS_STRANGER_ONLY — the exact marker harness/run.sh greps for
// (`grep -q '^# HARNESS_STRANGER_ONLY'`) before it will refuse a scenario
// on the app-fresh tier.

private func hfix_testScenariosAreStrangerOnly(_ t: TestRunner, scenariosDir: URL) {
    for scenario in hfix_scenarioNames {
        let path = scenariosDir.appendingPathComponent("\(scenario).sh").path
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            t.expect(false, "could not read \(path)")
            continue
        }
        let hasMarker = content.split(separator: "\n", omittingEmptySubsequences: false)
            .contains { $0.hasPrefix("# HARNESS_STRANGER_ONLY") }
        t.expect(hasMarker, "\(scenario).sh declares # HARNESS_STRANGER_ONLY at the start of a line, matching harness/run.sh's own grep")
    }
}

// MARK: - Every fixture file is synthetic: none may contain the
// maintainer's own username or home directory.

private func hfix_testFixtureFilesAreSynthetic(_ t: TestRunner, fixturesDir: URL) {
    let realUsername = NSUserName()
    let realHome = FileManager.default.homeDirectoryForCurrentUser.path

    guard let subpaths = try? FileManager.default.subpathsOfDirectory(atPath: fixturesDir.path) else {
        t.expect(false, "could not list \(fixturesDir.path)")
        return
    }

    var checked = 0
    for subpath in subpaths {
        let fullPath = fixturesDir.appendingPathComponent(subpath).path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDirectory), !isDirectory.boolValue else {
            continue
        }
        guard let content = try? String(contentsOfFile: fullPath, encoding: .utf8) else {
            // A non-text file (there should be none under fixtures/) is not
            // this check's job to read; it would already have failed the
            // syntax check above if it claimed to be a shell script.
            continue
        }
        checked += 1
        // AGENTMENU_BUNDLE_ID ("dev.facens.agentmenu") is a required,
        // public, shipped constant that legitimately contains the
        // maintainer's own reverse-DNS handle as a substring — every
        // fixture file has to name it to work at all. Stripped out before
        // the username check below, so the real thing this rule guards
        // against (a fixture accidentally spelling the maintainer's own
        // home directory or account name as "realistic" content) still
        // fails loudly, without a false positive against the one string
        // that is supposed to be there.
        let withoutBundleID = content.replacingOccurrences(of: "dev.facens.agentmenu", with: "")
        t.expect(
            !withoutBundleID.contains(realUsername),
            "\(fullPath) contains the real username '\(realUsername)' outside the bundle id — every fixture file must be synthetic"
        )
        t.expect(
            !content.contains(realHome),
            "\(fullPath) contains the real home directory '\(realHome)' — every fixture file must be synthetic"
        )
    }
    t.expect(checked > 0, "at least one file was actually checked under \(fixturesDir.path) — an empty enumeration would make the two checks above vacuous")
}

// MARK: - A partial, static form of the plan's "Lint" test case: every
// literal identifier a scenario clicks matches a known AXIdentifier shape
// from AccessibilityID.swift. The full check — a scenario that names an
// identifier absent from the enum failing the harness self-check before any
// VM is cloned — is `harness/run.sh selfcheck --list-ids <bundle-id>`
// against a live, built app; that genuinely needs the VM (see this unit's
// own report). This is what can be proven without one: every `click
// "$BUNDLE_ID" "<literal>"` call in every one of the eight scenarios names
// something this file can show is shaped like a real identifier.

private func hfix_testScenarioClicksNameKnownIdentifiers(_ t: TestRunner, scenariosDir: URL) {
    // Every literal (non-interpolated) identifier the eight scenarios
    // click, plus the two computed shapes (`setup.folder.<hash>.toggle`,
    // `popover.row.<hash>.launch`) matched by prefix/suffix instead.
    // `launchAtLoginPrompt.accept` is launch-at-login-prompt.sh's: it
    // clicks the alert's button by identifier, because `dialog answer alert`
    // presses by position and the stacked layout puts Not Now last. And
    // `setup.launchAtLogin` is vanilla-first-run.sh's own addition
    // (`AccessibilityID.Setup.launchAtLogin`).
    let knownLiterals: Set<String> = [
        "setup.done",
        "setup.launchAtLogin",
        "popover.gear",
        "settings.tab.accounts",
        "settings.accounts.installBridge",
        "popover.profile.work",
        "popover.profile.personal",
        "launchAtLoginPrompt.accept",
        "popover.tab.sessions",
    ]

    for scenario in hfix_scenarioNames {
        let path = scenariosDir.appendingPathComponent("\(scenario).sh").path
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            t.expect(false, "could not read \(path)")
            continue
        }
        for identifier in hfix_clickedIdentifiers(in: content) {
            let recognized = knownLiterals.contains(identifier)
                || (identifier.hasPrefix("setup.folder.") && identifier.hasSuffix(".toggle"))
                || (identifier.hasPrefix("popover.row.") && identifier.hasSuffix(".launch"))
                || (identifier.hasPrefix("popover.sessions.live.") && identifier.hasSuffix(".row"))
            t.expect(recognized, "\(scenario).sh clicks '\(identifier)', which does not match a known AccessibilityID shape")
        }
    }
}

/// Every string literal (or `"prefix$VAR.suffix"` interpolation, reduced to
/// its literal parts) that `click "$BUNDLE_ID" "..."` names, across a
/// scenario's whole text. Deliberately simple — a line-oriented regex, not
/// a shell parser — because the seven scenarios this file owns are the only
/// input it ever has to handle, and each one calls `click` with a plain
/// double-quoted second argument.
private func hfix_clickedIdentifiers(in content: String) -> [String] {
    var found: [String] = []
    let pattern = #"click\s+"\$BUNDLE_ID"\s+"([^"]+)""#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    for line in content.split(separator: "\n") {
        let text = String(line)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in regex.matches(in: text, range: range) {
            guard let group = Range(match.range(at: 1), in: text) else { continue }
            // Collapse a `$VAR` interpolation to a `<hash>`-shaped
            // placeholder so `setup.folder.$FOLDER_HASH.toggle` reduces to
            // `setup.folder.<hash>.toggle`, comparable against the
            // prefix/suffix check above.
            let literal = text[group].replacingOccurrences(
                of: #"\$[A-Za-z_][A-Za-z0-9_]*"#, with: "<hash>", options: .regularExpression
            )
            found.append(literal)
        }
    }
    return found
}

// MARK: - fixtures_path_hash reproduces AccessibilityID.pathHash exactly:
// SHA-256, hex, first 12 characters, computed on the caller's own
// already-expanded input.

private func hfix_testPathHash(_ t: TestRunner, harnessDir: URL) {
    let cases: [(input: String, expected: String)] = [
        ("harness-checkout", "e8ef402c571d"),
        ("hub", "08d33503ee27"),
    ]
    for (input, expected) in cases {
        let result = runProcess("/bin/bash", [
            "-c",
            "set -euo pipefail; . \(ShellQuoting.singleQuoted(harnessDir.path))/lib/fixtures.sh; fixtures_path_hash \(ShellQuoting.singleQuoted(input))",
        ])
        t.expectEqual(result.status, 0, "fixtures_path_hash ran for '\(input)' — \(result.stderr)")
        t.expectEqual(
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            expected,
            "fixtures_path_hash('\(input)') matches AccessibilityID.pathHash's own algorithm (SHA-256, first 12 hex characters)"
        )
    }
}

// MARK: - The fixture rig: a scratch $HOME, `defaults` stubbed on PATH so
// fx_activate_journal never reaches real CFPreferences, and the real
// harness/lib/scenario.sh + harness/lib/fixtures.sh sourced for real — the
// same idiom HarnessScenarioTests.swift's own rig uses, minus the
// osascript/screencapture/sips stubs this suite never needs: nothing here
// calls a screen-driving helper.

private struct HFRig {
    let dir: TempDir
    let home: String
    let defaultsLog: String
    let environment: [String: String]
}

private func hfix_makeRig(_ label: String, harnessDir: URL, t: TestRunner) -> HFRig? {
    let dir = TempDir(label)
    do {
        try FileManager.default.createDirectory(atPath: dir.path("home"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: dir.path("rundir/screenshots"), withIntermediateDirectories: true)
        for file in ["steps.ndjson", "findings.list", "journal.ndjson", "evidence.ndjson"] {
            FileManager.default.createFile(atPath: dir.path("rundir/\(file)"), contents: Data())
        }
        // A stub `defaults`: fx_activate_journal (harness/fixtures/agentmenu/_lib.sh)
        // calls the real binary otherwise, which resolves the account's
        // preferences through the operating system's own user record, not
        // through $HOME — see this file's own header for how that was found.
        try dir.write(
            "#!/bin/bash\necho \"defaults $*\" >> \"$DEFAULTS_LOG\"\nexit 0\n",
            to: "bin/defaults"
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path("bin/defaults"))
    } catch {
        t.expect(false, "built the fixture rig: \(error)")
        dir.cleanup()
        return nil
    }

    let existingPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    let environment: [String: String] = [
        "HARNESS_DIR": harnessDir.path,
        "HARNESS_GUEST_TRANSPORT": "local",
        "HARNESS_GUEST_IP": "local",
        "HARNESS_GUEST_USER": "nobody",
        "HARNESS_GUEST_HOME": ".harness",
        "HARNESS_SHOT_DIR": dir.path("rundir/screenshots"),
        "HARNESS_STEPS": dir.path("rundir/steps.ndjson"),
        "HARNESS_FINDINGS": dir.path("rundir/findings.list"),
        "HARNESS_JOURNAL": dir.path("rundir/journal.ndjson"),
        "HARNESS_EVIDENCE": dir.path("rundir/evidence.ndjson"),
        "HARNESS_STEP_TIMEOUT": "10",
        "HOME": dir.path("home"),
        "DEFAULTS_LOG": dir.path("defaults.log"),
        "PATH": dir.path("bin") + ":" + existingPath,
    ]
    FileManager.default.createFile(atPath: dir.path("defaults.log"), contents: Data())
    return HFRig(dir: dir, home: dir.path("home"), defaultsLog: dir.path("defaults.log"), environment: environment)
}

/// Runs `body` (real scenario.sh + fixtures.sh calls) in the rig, exactly
/// the way `harness/scenarios/agentmenu/*.sh` do.
private func hfix_runDriver(_ rig: HFRig, _ body: String) -> CLIResult {
    let driverPath = rig.dir.path("driver.sh")
    let script = """
    #!/bin/bash
    set -euo pipefail
    . \(ShellQuoting.singleQuoted(rig.environment["HARNESS_DIR"]!))/lib/scenario.sh
    . \(ShellQuoting.singleQuoted(rig.environment["HARNESS_DIR"]!))/lib/fixtures.sh
    \(body)
    """
    do {
        try script.write(toFile: driverPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: driverPath)
    } catch {
        return CLIResult(status: -1, stdout: "", stderr: "could not write the driver script: \(error)")
    }
    return runProcess("/bin/bash", [driverPath], environment: rig.environment)
}

// MARK: - agentmenu/first-run: journal activation, the synthetic checkout,
// and --no-agent / --profile.

private func hfix_testFirstRunFixture(_ t: TestRunner, harnessDir: URL) {
    guard let rig = hfix_makeRig("hf-first-run", harnessDir: harnessDir, t: t) else { return }
    defer { rig.dir.cleanup() }

    let result = hfix_runDriver(rig, #"""
    fixture agentmenu/first-run "nonce-1" --profile work:opus:sonnet --profile personal:fable:opus
    """#)
    t.expectEqual(result.status, 0, "agentmenu/first-run applied cleanly — \(result.stderr)")

    let defaultsLog = (try? String(contentsOfFile: rig.defaultsLog, encoding: .utf8)) ?? ""
    t.expect(defaultsLog.contains("harnessJournal -string run.ndjson"), "the fixture turns the journal on with the leaf name every scenario passes to journal_at — got: \(defaultsLog)")
    t.expect(defaultsLog.contains("harnessNonce -string nonce-1"), "the fixture echoes the run nonce into harnessNonce — got: \(defaultsLog)")

    let checkoutGit = rig.home + "/dev/harness-project/.git"
    t.expect(FileManager.default.fileExists(atPath: checkoutGit), "a synthetic .git marker was planted under ~/dev/harness-project for Detection.projectFolders to find")

    for (id, model, advisor) in [("work", "opus", "sonnet"), ("personal", "fable", "opus")] {
        let settingsPath = rig.home + "/.claude-\(id)/settings.json"
        guard let data = FileManager.default.contents(atPath: settingsPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            t.expect(false, "~/.claude-\(id)/settings.json exists and is valid JSON")
            continue
        }
        t.expectEqual(json["model"] as? String, model, "~/.claude-\(id)/settings.json carries the model key claude-code.toml names as model.seed_from_settings")
        t.expectEqual(json["advisorModel"] as? String, advisor, "~/.claude-\(id)/settings.json carries advisorModel, matching advisor.seed_from_settings")
    }

    // --no-agent removes the golden image's own stand-in claude binary.
    guard let rigTwo = hfix_makeRig("hf-first-run-no-agent", harnessDir: harnessDir, t: t) else { return }
    defer { rigTwo.dir.cleanup() }
    try? FileManager.default.createDirectory(atPath: rigTwo.home + "/.local/bin", withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: rigTwo.home + "/.local/bin/claude", contents: Data("stand-in".utf8))
    let noAgentResult = hfix_runDriver(rigTwo, #"fixture agentmenu/first-run "nonce-2" --no-agent"#)
    t.expectEqual(noAgentResult.status, 0, "agentmenu/first-run --no-agent applied cleanly — \(noAgentResult.stderr)")
    t.expect(!FileManager.default.fileExists(atPath: rigTwo.home + "/.local/bin/claude"), "--no-agent removed ~/.local/bin/claude")

    // A malformed --profile spec is refused (exit 2), never silently
    // half-applied.
    guard let rigThree = hfix_makeRig("hf-first-run-bad-profile", harnessDir: harnessDir, t: t) else { return }
    defer { rigThree.dir.cleanup() }
    let badProfile = hfix_runDriver(rigThree, #"fixture agentmenu/first-run "nonce-3" --profile not-well-formed"#)
    t.expect(badProfile.status != 0, "a malformed --profile spec is refused rather than silently accepted — got exit \(badProfile.status)")
}

// MARK: - agentmenu/configured-terminal: config.toml, the user's
// terminal-app.toml overlay, and the profile it references.

private func hfix_testConfiguredTerminalFixture(_ t: TestRunner, harnessDir: URL) {
    guard let rig = hfix_makeRig("hf-configured-terminal", harnessDir: harnessDir, t: t) else { return }
    defer { rig.dir.cleanup() }

    let result = hfix_runDriver(rig, #"fixture agentmenu/configured-terminal "nonce-4""#)
    t.expectEqual(result.status, 0, "agentmenu/configured-terminal applied cleanly — \(result.stderr)")

    let configPath = rig.home + "/.config/agentmenu/config.toml"
    guard let config = try? String(contentsOfFile: configPath, encoding: .utf8) else {
        t.expect(false, "config.toml was written at \(configPath)")
        return
    }
    t.expect(config.contains("first_run_completed = true"), "config.toml marks first run completed, so the popover skips the setup card")
    t.expect(config.contains("launch_at_login_asked = true"), "config.toml marks the login-item question already asked, so LaunchAtLoginPrompt does not block this scenario's launch behind an unanswered alert")
    t.expect(config.contains("id = \"harness-checkout\""), "config.toml carries the folder id the scenario computes its rowKey from")
    t.expect(config.contains("[terminals.terminal-app]") && config.contains("trusted = true"), "config.toml trusts the user-origin terminal-app manifest directly, so the launch scenario stays click-free")
    t.expect(config.contains("claude = \"\(rig.home)/.local/bin/claude\""), "config.toml's [binaries] entry is a real absolute path under the fixture's own $HOME, not a literal ~")
    t.expect(!config.contains("~/.local/bin/claude"), "the binaries entry is expanded, never left as a literal ~ path (AppEnvironment.isUsable reads it as-is)")

    let overlayPath = rig.home + "/.config/agentmenu/terminals/terminal-app.toml"
    guard let overlay = try? String(contentsOfFile: overlayPath, encoding: .utf8) else {
        t.expect(false, "the user overlay terminals/terminal-app.toml was written at \(overlayPath)")
        return
    }
    for requiredKey in ["schema = 1", "id = \"terminal-app\"", "display_name = \"Terminal\"", "kind = \"applescript\"", "bundle_id = \"com.apple.Terminal\"", "applescript = \"\"\""] {
        t.expect(overlay.contains(requiredKey), "the overlay carries '\(requiredKey)' — TerminalManifest.parse requires every one of these, or the whole file fails to parse and the bundled, disabled manifest stays in charge")
    }
    t.expect(overlay.contains("enabled = true"), "the overlay flips enabled to true, unlike the bundled manifest it was copied from")
}

// MARK: - agentmenu/owned-session: configured-terminal's twin with the session
// host turned on. Same folder, profile, binaries, overlay and trust, so the
// only thing that differs between owned-launch and launch-terminal is the host.

private func hfix_testOwnedSessionFixture(_ t: TestRunner, harnessDir: URL) {
    guard let rig = hfix_makeRig("hf-owned-session", harnessDir: harnessDir, t: t) else { return }
    defer { rig.dir.cleanup() }
    let result = hfix_runDriver(rig, #"fixture agentmenu/owned-session "nonce-os""#)
    t.expectEqual(result.status, 0, "agentmenu/owned-session applied cleanly — \(result.stderr)")

    let configPath = rig.home + "/.config/agentmenu/config.toml"
    guard let config = try? String(contentsOfFile: configPath, encoding: .utf8) else {
        t.expect(false, "config.toml was written at \(configPath)")
        return
    }
    t.expect(config.contains("keep_running = true"), "config.toml turns the session host on")
    for line in ["first_run_completed = true", "launch_at_login_asked = true", "notifications_asked = true", "id = \"harness-checkout\"", "trusted = true"] {
        t.expect(config.contains(line), "config.toml carries '\(line)', like configured-terminal's")
    }
    // It must be configured-terminal's config with that one line changed.
    let siblingRig = hfix_makeRig("hf-owned-session-sibling", harnessDir: harnessDir, t: t)
    defer { siblingRig?.dir.cleanup() }
    if let siblingRig {
        let sibling = hfix_runDriver(siblingRig, #"fixture agentmenu/configured-terminal "nonce-os""#)
        t.expectEqual(sibling.status, 0, "agentmenu/configured-terminal applied cleanly — \(sibling.stderr)")
        let siblingConfig = (try? String(contentsOfFile: siblingRig.home + "/.config/agentmenu/config.toml", encoding: .utf8)) ?? ""
        t.expectEqual(
            siblingConfig.replacingOccurrences(of: "keep_running = false", with: "keep_running = true")
                .replacingOccurrences(of: siblingRig.home, with: rig.home),
            config,
            "owned-session's config.toml is configured-terminal's with only keep_running flipped"
        )
        let overlay = (try? String(contentsOfFile: rig.home + "/.config/agentmenu/terminals/terminal-app.toml", encoding: .utf8)) ?? ""
        let siblingOverlay = (try? String(contentsOfFile: siblingRig.home + "/.config/agentmenu/terminals/terminal-app.toml", encoding: .utf8)) ?? ""
        t.expect(!overlay.isEmpty, "owned-session plants the terminal-app overlay")
        t.expectEqual(overlay, siblingOverlay, "and it is the same overlay configured-terminal plants")
        t.expect(!overlay.contains("in window") && overlay.contains("do script cmd"), "the overlay opens a new window every time")
    }
}

// MARK: - agentmenu/configured-profile: one account, no folders, no agent.

private func hfix_testConfiguredProfileFixture(_ t: TestRunner, harnessDir: URL) {
    guard let rig = hfix_makeRig("hf-configured-profile", harnessDir: harnessDir, t: t) else { return }
    defer { rig.dir.cleanup() }

    let result = hfix_runDriver(rig, #"fixture agentmenu/configured-profile "nonce-5""#)
    t.expectEqual(result.status, 0, "agentmenu/configured-profile applied cleanly — \(result.stderr)")

    let configPath = rig.home + "/.config/agentmenu/config.toml"
    guard let config = try? String(contentsOfFile: configPath, encoding: .utf8) else {
        t.expect(false, "config.toml was written at \(configPath)")
        return
    }
    t.expect(config.contains("first_run_completed = true"), "config.toml marks first run completed")
    t.expect(config.contains("launch_at_login_asked = true"), "config.toml marks the login-item question already asked, so LaunchAtLoginPrompt does not block this scenario's launch behind an unanswered alert")
    t.expect(config.contains("id = \"work\""), "config.toml carries the one account bridge-install.sh expects Settings to select by default")
    t.expect(!config.contains("[[folders]]"), "no folder is configured — bridge-install.sh never launches anything")

    let profileDir = rig.home + "/.claude-work"
    var isDirectory: ObjCBool = false
    t.expect(
        FileManager.default.fileExists(atPath: profileDir, isDirectory: &isDirectory) && isDirectory.boolValue,
        "the profile's own configuration directory exists, so install-statusline has somewhere to write"
    )
}

// MARK: - agentmenu/needs-login-prompt: first run completed, the
// login-item question never asked — the one shape `LaunchAtLoginPrompt.
// presentIfNeeded` actually raises its alert for.

private func hfix_testNeedsLoginPromptFixture(_ t: TestRunner, harnessDir: URL) {
    guard let rig = hfix_makeRig("hf-needs-login-prompt", harnessDir: harnessDir, t: t) else { return }
    defer { rig.dir.cleanup() }

    let result = hfix_runDriver(rig, #"fixture agentmenu/needs-login-prompt "nonce-6""#)
    t.expectEqual(result.status, 0, "agentmenu/needs-login-prompt applied cleanly — \(result.stderr)")

    let configPath = rig.home + "/.config/agentmenu/config.toml"
    guard let config = try? String(contentsOfFile: configPath, encoding: .utf8) else {
        t.expect(false, "config.toml was written at \(configPath)")
        return
    }
    t.expect(config.contains("first_run_completed = true"), "config.toml marks first run completed — the setup card must not reappear")
    t.expect(!config.contains("launch_at_login_asked"), "config.toml carries no launch_at_login_asked key at all — the exact shape a config.toml written before this question existed has, and the one LaunchAtLoginPrompt.presentIfNeeded's guard (`!config.launchAtLoginAsked`) is written to catch")
}
