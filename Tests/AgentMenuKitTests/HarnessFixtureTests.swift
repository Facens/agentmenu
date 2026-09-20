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

    hf_testShellFilesParseAndAreExecutable(t, harnessDir: harnessDir, fixturesDir: fixturesDir, scenariosDir: scenariosDir)
    hf_testScenariosAreStrangerOnly(t, scenariosDir: scenariosDir)
    hf_testFixtureFilesAreSynthetic(t, fixturesDir: fixturesDir)
    hf_testScenarioClicksNameKnownIdentifiers(t, scenariosDir: scenariosDir)
    hf_testPathHash(t, harnessDir: harnessDir)
    hf_testFirstRunFixture(t, harnessDir: harnessDir)
    hf_testConfiguredTerminalFixture(t, harnessDir: harnessDir)
    hf_testConfiguredProfileFixture(t, harnessDir: harnessDir)
}

// MARK: - Every new shell file parses under `bash -n`, and every apply.sh /
// scenario is executable. Mirrors HarnessScenarioTests.swift's own
// `hs_testSyntaxAndSmokeFiles`.

private func hf_testShellFilesParseAndAreExecutable(
    _ t: TestRunner, harnessDir: URL, fixturesDir: URL, scenariosDir: URL
) {
    var files: [String] = [
        harnessDir.appendingPathComponent("lib/fixtures.sh").path,
        fixturesDir.appendingPathComponent("_lib.sh").path,
    ]
    for fixture in ["first-run", "configured-terminal", "configured-profile"] {
        files.append(fixturesDir.appendingPathComponent("\(fixture)/apply.sh").path)
    }
    for scenario in hf_scenarioNames {
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

/// The seven R9 scenario names, in the same order the plan lists them.
private let hf_scenarioNames = [
    "vanilla-first-run",
    "launch-terminal",
    "no-agent",
    "profile-work-only",
    "profile-personal-only",
    "profile-both",
    "bridge-install",
]

// MARK: - Every scenario clicks, so every scenario declares
// HARNESS_STRANGER_ONLY — the exact marker harness/run.sh greps for
// (`grep -q '^# HARNESS_STRANGER_ONLY'`) before it will refuse a scenario
// on the app-fresh tier.

private func hf_testScenariosAreStrangerOnly(_ t: TestRunner, scenariosDir: URL) {
    for scenario in hf_scenarioNames {
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

private func hf_testFixtureFilesAreSynthetic(_ t: TestRunner, fixturesDir: URL) {
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
// "$BUNDLE_ID" "<literal>"` call in every one of the seven scenarios names
// something this file can show is shaped like a real identifier.

private func hf_testScenarioClicksNameKnownIdentifiers(_ t: TestRunner, scenariosDir: URL) {
    // Every literal (non-interpolated) identifier the seven scenarios click,
    // plus the two computed shapes (`setup.folder.<hash>.toggle`,
    // `popover.row.<hash>.launch`) matched by prefix/suffix instead.
    let knownLiterals: Set<String> = [
        "setup.done",
        "popover.gear",
        "settings.tab.accounts",
        "settings.accounts.installBridge",
        "popover.profile.work",
        "popover.profile.personal",
    ]

    for scenario in hf_scenarioNames {
        let path = scenariosDir.appendingPathComponent("\(scenario).sh").path
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            t.expect(false, "could not read \(path)")
            continue
        }
        for identifier in hf_clickedIdentifiers(in: content) {
            let recognized = knownLiterals.contains(identifier)
                || (identifier.hasPrefix("setup.folder.") && identifier.hasSuffix(".toggle"))
                || (identifier.hasPrefix("popover.row.") && identifier.hasSuffix(".launch"))
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
private func hf_clickedIdentifiers(in content: String) -> [String] {
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

private func hf_testPathHash(_ t: TestRunner, harnessDir: URL) {
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

private func hf_makeRig(_ label: String, harnessDir: URL, t: TestRunner) -> HFRig? {
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
private func hf_runDriver(_ rig: HFRig, _ body: String) -> CLIResult {
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

private func hf_testFirstRunFixture(_ t: TestRunner, harnessDir: URL) {
    guard let rig = hf_makeRig("hf-first-run", harnessDir: harnessDir, t: t) else { return }
    defer { rig.dir.cleanup() }

    let result = hf_runDriver(rig, #"""
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
    guard let rigTwo = hf_makeRig("hf-first-run-no-agent", harnessDir: harnessDir, t: t) else { return }
    defer { rigTwo.dir.cleanup() }
    try? FileManager.default.createDirectory(atPath: rigTwo.home + "/.local/bin", withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: rigTwo.home + "/.local/bin/claude", contents: Data("stand-in".utf8))
    let noAgentResult = hf_runDriver(rigTwo, #"fixture agentmenu/first-run "nonce-2" --no-agent"#)
    t.expectEqual(noAgentResult.status, 0, "agentmenu/first-run --no-agent applied cleanly — \(noAgentResult.stderr)")
    t.expect(!FileManager.default.fileExists(atPath: rigTwo.home + "/.local/bin/claude"), "--no-agent removed ~/.local/bin/claude")

    // A malformed --profile spec is refused (exit 2), never silently
    // half-applied.
    guard let rigThree = hf_makeRig("hf-first-run-bad-profile", harnessDir: harnessDir, t: t) else { return }
    defer { rigThree.dir.cleanup() }
    let badProfile = hf_runDriver(rigThree, #"fixture agentmenu/first-run "nonce-3" --profile not-well-formed"#)
    t.expect(badProfile.status != 0, "a malformed --profile spec is refused rather than silently accepted — got exit \(badProfile.status)")
}

// MARK: - agentmenu/configured-terminal: config.toml, the user's
// terminal-app.toml overlay, and the profile it references.

private func hf_testConfiguredTerminalFixture(_ t: TestRunner, harnessDir: URL) {
    guard let rig = hf_makeRig("hf-configured-terminal", harnessDir: harnessDir, t: t) else { return }
    defer { rig.dir.cleanup() }

    let result = hf_runDriver(rig, #"fixture agentmenu/configured-terminal "nonce-4""#)
    t.expectEqual(result.status, 0, "agentmenu/configured-terminal applied cleanly — \(result.stderr)")

    let configPath = rig.home + "/.config/agentmenu/config.toml"
    guard let config = try? String(contentsOfFile: configPath, encoding: .utf8) else {
        t.expect(false, "config.toml was written at \(configPath)")
        return
    }
    t.expect(config.contains("first_run_completed = true"), "config.toml marks first run completed, so the popover skips the setup card")
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

// MARK: - agentmenu/configured-profile: one account, no folders, no agent.

private func hf_testConfiguredProfileFixture(_ t: TestRunner, harnessDir: URL) {
    guard let rig = hf_makeRig("hf-configured-profile", harnessDir: harnessDir, t: t) else { return }
    defer { rig.dir.cleanup() }

    let result = hf_runDriver(rig, #"fixture agentmenu/configured-profile "nonce-5""#)
    t.expectEqual(result.status, 0, "agentmenu/configured-profile applied cleanly — \(result.stderr)")

    let configPath = rig.home + "/.config/agentmenu/config.toml"
    guard let config = try? String(contentsOfFile: configPath, encoding: .utf8) else {
        t.expect(false, "config.toml was written at \(configPath)")
        return
    }
    t.expect(config.contains("first_run_completed = true"), "config.toml marks first run completed")
    t.expect(config.contains("id = \"work\""), "config.toml carries the one account bridge-install.sh expects Settings to select by default")
    t.expect(!config.contains("[[folders]]"), "no folder is configured — bridge-install.sh never launches anything")

    let profileDir = rig.home + "/.claude-work"
    var isDirectory: ObjCBool = false
    t.expect(
        FileManager.default.fileExists(atPath: profileDir, isDirectory: &isDirectory) && isDirectory.boolValue,
        "the profile's own configuration directory exists, so install-statusline has somewhere to write"
    )
}
