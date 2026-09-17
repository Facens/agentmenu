// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AgentMenuKit

func runImportTests(_ t: TestRunner) {
    t.suite("Import")

    runFoldersConfParseTests(t)
    runFoldersConfPlanTests(t)
    runResolveCLITests(t)
    runImportCLITests(t)
}

// MARK: - Parsing (happy / edge / error)

private func runFoldersConfParseTests(_ t: TestRunner) {
    let fixture = """
    # cc-launcher folders
    # blank lines and comments are ignored

    Hub            | /Users/x/Hub          | work
    Compliance PU  | /Users/x/Compliance PU | work
    Home           | /Users/x                | personal
    Two Field Only | /Users/x/two-field
    BadLineNoSeparator
    No Path Here   |   | work
       | /Users/x/no-label | work
    """
    let result = FoldersConfImport.parse(fixture)

    t.expectEqual(result.entries.count, 4, "four well-formed entries parsed")
    t.expectEqual(result.malformed.count, 3, "three malformed lines reported")

    if result.entries.count >= 3 {
        t.expectEqual(result.entries[0].label, "Hub", "first entry's label")
        t.expectEqual(result.entries[0].path, "/Users/x/Hub", "first entry's path")
        t.expectEqual(result.entries[0].identity, "work", "first entry's identity")
        t.expectEqual(result.entries[0].line, 4, "first entry's 1-based line number")

        t.expectEqual(result.entries[2].label, "Home", "third entry's label")
        t.expectEqual(result.entries[2].identity, "personal", "third entry's identity")
    }

    // A two-field line (no third field at all) is a valid entry with a nil
    // identity — tolerated, not malformed — distinct from a line with a `|`
    // but an empty label or empty path, which is malformed.
    if let twoField = result.entries.first(where: { $0.label == "Two Field Only" }) {
        t.expectEqual(twoField.identity, nil, "a missing third field parses as no identity, not malformed")
        t.expectEqual(twoField.path, "/Users/x/two-field", "two-field entry's path")
    } else {
        t.expect(false, "the two-field line should have parsed as a valid entry")
    }

    let malformedTexts = result.malformed.map { $0.text }
    t.expect(
        malformedTexts.contains(where: { $0.contains("BadLineNoSeparator") }),
        "a line with no '|' at all is malformed"
    )
    t.expect(
        result.malformed.contains(where: { $0.line == 8 }),
        "the no-separator line is reported at its own line number (8)"
    )
    t.expect(
        result.malformed.contains(where: { $0.text.contains("No Path Here") }),
        "a line with an empty path field is malformed"
    )
    t.expect(
        result.malformed.contains(where: { $0.text.contains("no-label") }),
        "a line with an empty label field is malformed"
    )

    let empty = FoldersConfImport.parse("")
    t.expect(empty.entries.isEmpty && empty.malformed.isEmpty, "an empty file parses as nothing, not an error")

    let onlyComments = FoldersConfImport.parse("# just a comment\n\n# another\n")
    t.expect(onlyComments.entries.isEmpty && onlyComments.malformed.isEmpty, "a comments-only file parses as nothing")

    // An identity that would escape `~/.claude-<identity>` — the directory
    // `configDirectory(forIdentity:)` builds it into, and from there
    // `Profile.configDirectory`, the target `install-statusline` writes a
    // 0755 script into and the value handed out as `CLAUDE_CONFIG_DIR` — is
    // reported as malformed, not accepted into an entry with a dangerous
    // identity. `Work | /x | ../../../../tmp/evil` used to parse cleanly
    // (identity is accepted on non-emptiness alone) and become
    // `~/.claude-../../../../tmp/evil`.
    let pathTraversal = FoldersConfImport.parse("Work | /x | ../../../../tmp/evil")
    t.expect(pathTraversal.entries.isEmpty, "an identity with path-traversal segments is not accepted as a valid entry")
    t.expectEqual(pathTraversal.malformed.count, 1, "the whole line is reported as malformed")
    t.expect(
        pathTraversal.malformed.first?.text.contains("evil") ?? false,
        "the malformed report carries the original line text"
    )

    // A slash alone is just as dangerous and just as invalid.
    let slashIdentity = FoldersConfImport.parse("Work | /x | some/path")
    t.expect(slashIdentity.entries.isEmpty, "an identity containing a '/' is rejected")
    t.expectEqual(slashIdentity.malformed.count, 1, "reported as malformed")

    // Ordinary identities — including the "work" special case
    // `configDirectory(forIdentity:)` maps to `~/.claude` — still parse
    // as valid entries; the fix narrows what is accepted, it does not
    // narrow it to nothing.
    let ordinary = FoldersConfImport.parse("Work | /x | work\nPersonal | /y | personal-2\nDashed | /z | a-b_c")
    t.expectEqual(ordinary.entries.count, 3, "ordinary bare-word identities, including punctuation configDirectory already presumes, still parse")
    t.expectEqual(ordinary.malformed.count, 0, "none of them are malformed")
}

// MARK: - Planning / applying (happy / edge)

private func runFoldersConfPlanTests(_ t: TestRunner) {
    // Unknown identity creates the missing profile rather than dropping the folder.
    do {
        var config = Config()
        let result = FoldersConfImport.parse("Hub | /Users/x/Hub | personal")
        let plan = FoldersConfImport.plan(result, into: config)

        t.expectEqual(plan.toAdd.count, 1, "one entry to add")
        if case .add(let folder, let createsProfile) = plan.toAdd.first?.action {
            t.expectEqual(folder.profileID, "personal", "folder is assigned the identity's profile id")
            t.expectEqual(createsProfile?.id, "personal", "plan reports the profile it will create")
            t.expectEqual(createsProfile?.configDirectory, "~/.claude-personal", "non-work identity maps to ~/.claude-<identity>")
        } else {
            t.expect(false, "expected an .add action")
        }

        FoldersConfImport.apply(plan, to: &config)
        t.expectEqual(config.profiles.count, 1, "the missing profile was created")
        t.expectEqual(config.profile(id: "personal")?.configDirectory, "~/.claude-personal", "created profile's config dir")
        t.expectEqual(config.folders.count, 1, "the folder was added")
    }

    // "work" maps to ~/.claude, matching claude-id.
    do {
        var config = Config()
        let result = FoldersConfImport.parse("Hub | /Users/x/Hub | work")
        let plan = FoldersConfImport.plan(result, into: config)
        FoldersConfImport.apply(plan, to: &config)
        t.expectEqual(config.profile(id: "work")?.configDirectory, "~/.claude", "identity 'work' maps to ~/.claude")
        t.expectEqual(config.profile(id: "work")?.name, "Work", "capitalized display name")
    }

    // An entry with no identity gets no profile pinned at all — it defers to
    // claude-id's other precedence layers, the same as the shell script does.
    do {
        let config = Config()
        let result = FoldersConfImport.parse("Hub | /Users/x/Hub")
        let plan = FoldersConfImport.plan(result, into: config)
        if case .add(let folder, let createsProfile) = plan.toAdd.first?.action {
            t.expect(folder.profileID == nil, "no identity in the file means no profile pinned on the folder")
            t.expect(createsProfile == nil, "and so nothing is created for it")
        } else {
            t.expect(false, "expected an .add action")
        }
    }

    // An identity whose configuration directory already belongs to a profile
    // reuses that profile, whatever it is called. First run names the
    // suffix-less `~/.claude` "default"; folders.conf calls the same account
    // "work". Matching on the id alone produced two profiles pointing at one
    // directory — one account listed twice in a switcher that exists to keep
    // accounts apart.
    do {
        var config = Config()
        config.profiles = [Profile(id: "default", name: "Default", configDirectory: "~/.claude")]
        let result = FoldersConfImport.parse("Hub | /Users/x/Hub | work")
        let plan = FoldersConfImport.plan(result, into: config)
        if case .add(let folder, let createsProfile) = plan.toAdd.first?.action {
            t.expectEqual(folder.profileID, "default", "the folder points at the profile that already owns ~/.claude")
            t.expect(createsProfile == nil, "no second profile is created for the same directory")
        } else {
            t.expect(false, "expected an .add action")
        }

        FoldersConfImport.apply(plan, to: &config)
        t.expectEqual(config.profiles.count, 1, "the configuration still has exactly one profile for ~/.claude")
    }

    // An identity that already has a profile does not get a second one.
    do {
        var config = Config()
        config.profiles.append(Profile(id: "personal", name: "Personal (custom)", configDirectory: "~/.claude-custom"))
        let result = FoldersConfImport.parse("Hub | /Users/x/Hub | personal")
        let plan = FoldersConfImport.plan(result, into: config)
        if case .add(_, let createsProfile) = plan.toAdd.first?.action {
            t.expect(createsProfile == nil, "an existing profile for this identity is reused, not recreated")
        }
        FoldersConfImport.apply(plan, to: &config)
        t.expectEqual(config.profiles.count, 1, "still exactly one profile")
        t.expectEqual(config.profile(id: "personal")?.configDirectory, "~/.claude-custom", "the existing profile's config dir is untouched")
    }

    // Several entries naming the same new identity create the profile once.
    do {
        var config = Config()
        let result = FoldersConfImport.parse("""
        A | /Users/x/A | personal
        B | /Users/x/B | personal
        """)
        let plan = FoldersConfImport.plan(result, into: config)
        FoldersConfImport.apply(plan, to: &config)
        t.expectEqual(config.profiles.count, 1, "one profile created for two entries sharing an identity")
        t.expectEqual(config.folders.count, 2, "both folders still added")
    }

    // A folder already configured (by normalized path) is skipped and says so.
    do {
        var config = Config()
        config.folders.append(FolderTarget(label: "Existing", path: "/Users/x/Hub/"))
        let result = FoldersConfImport.parse("Hub | /Users/x/Hub | work") // no trailing slash — same normalized path
        let plan = FoldersConfImport.plan(result, into: config)
        t.expectEqual(plan.toAdd.count, 0, "nothing to add")
        t.expectEqual(plan.toSkip.count, 1, "the entry is skipped")
        if case .skip(let reason) = plan.entries.first?.action {
            t.expect(reason.contains("already configured"), "skip reason names the cause")
        }
    }

    // Two lines in the same file resolving to the same path: one add, one skip.
    do {
        var config = Config()
        let result = FoldersConfImport.parse("""
        First  | /Users/x/Dup | work
        Second | /Users/x/Dup/ | work
        """)
        let plan = FoldersConfImport.plan(result, into: config)
        t.expectEqual(plan.toAdd.count, 1, "only the first of two duplicate lines is added")
        t.expectEqual(plan.toSkip.count, 1, "the second is skipped rather than duplicated")
        FoldersConfImport.apply(plan, to: &config)
        t.expectEqual(config.folders.count, 1, "config ends up with exactly one folder for the duplicate path")
    }

    // Importing the same file twice, replanning against the updated config
    // each time, adds nothing the second time.
    do {
        var config = Config()
        let fixture = """
        Hub      | /Users/x/Hub      | work
        Personal | /Users/x/Personal | personal
        """
        let first = FoldersConfImport.plan(FoldersConfImport.parse(fixture), into: config)
        FoldersConfImport.apply(first, to: &config)
        t.expectEqual(config.folders.count, 2, "first import added both folders")
        t.expectEqual(config.profiles.count, 2, "first import created both profiles")

        let second = FoldersConfImport.plan(FoldersConfImport.parse(fixture), into: config)
        t.expectEqual(second.toAdd.count, 0, "second plan against the updated config adds nothing")
        t.expectEqual(second.toSkip.count, 2, "both entries are now reported as already configured")
        FoldersConfImport.apply(second, to: &config)
        t.expectEqual(config.folders.count, 2, "folder count unchanged after the second import")
        t.expectEqual(config.profiles.count, 2, "profile count unchanged after the second import")
    }
}

// MARK: - CLI integration: `agentmenu resolve`

/// Where `swift build` puts the CLI, resolved relative to this source file
/// rather than the process's working directory (which `make test` may run
/// from anywhere). Nil — and every CLI-level scenario below skipped cleanly,
/// never failed — when the binary has not been built yet.
func agentMenuCLIBinary(file: StaticString = #filePath) -> String? {
    let thisFile = URL(fileURLWithPath: "\(file)")
    let repoRoot = thisFile
        .deletingLastPathComponent() // ImportTests.swift -> AgentMenuKitTests/
        .deletingLastPathComponent() // AgentMenuKitTests/ -> Tests/
        .deletingLastPathComponent() // Tests/ -> repo root
    let candidate = repoRoot.appendingPathComponent(".build/debug/AgentMenuCLI")
    return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate.path : nil
}

struct CLIResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

/// Runs the built CLI as a real subprocess — `AGENTMENU_CONFIG` in `env`
/// points it at a `TempDir`'s `config.toml` rather than the maintainer's
/// real one.
func runCLI(_ binary: String, _ args: [String], env: [String: String] = [:], stdin: Data? = nil) throws -> CLIResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = args
    var environment = ProcessInfo.processInfo.environment
    for (key, value) in env { environment[key] = value }
    process.environment = environment

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    let stdinPipe = Pipe()
    process.standardInput = stdinPipe

    try process.run()

    let writer = stdinPipe.fileHandleForWriting
    DispatchQueue.global().async {
        if let stdin { writer.write(stdin) }
        try? writer.close()
    }

    let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    return CLIResult(
        status: process.terminationStatus,
        stdout: String(data: outData, encoding: .utf8) ?? "",
        stderr: String(data: errData, encoding: .utf8) ?? ""
    )
}

private func runResolveCLITests(_ t: TestRunner) {
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

// MARK: - CLI integration: `agentmenu import`

private func runImportCLITests(_ t: TestRunner) {
    guard let binary = agentMenuCLIBinary() else {
        print("   (skipped: .build/debug/AgentMenuCLI not built — run 'swift build' first)")
        return
    }

    let dir = TempDir("import-cli")
    defer { dir.cleanup() }

    let hubDir = dir.path("Hub")
    let personalDir = dir.path("Personal")
    try? FileManager.default.createDirectory(atPath: hubDir, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(atPath: personalDir, withIntermediateDirectories: true)

    let confPath = dir.path("folders.conf")
    let confText = """
    # fixture
    Hub      | \(hubDir)      | work
    Personal | \(personalDir) | personal
    BadLineNoSeparator
    """
    try? confText.write(toFile: confPath, atomically: true, encoding: .utf8)

    let configPath = dir.path("config.toml")
    let env = ["AGENTMENU_CONFIG": configPath]

    // 4. Reads the valid entries and reports the malformed one with its line number.
    do {
    let dryRun = t.attempt("import --dry-run reports entries and the malformed line") {
        try runCLI(binary, ["import", "--from", confPath, "--dry-run"], env: env)
    }
    if let dryRun {
        t.expectEqual(dryRun.status, 0, "dry run exits 0")
        t.expect(dryRun.stdout.contains("Hub"), "reports the Hub entry")
        t.expect(dryRun.stdout.contains("Personal"), "reports the Personal entry")
        t.expect(dryRun.stderr.contains("line 4"), "reports the malformed line's 1-based line number")
        t.expect(!FileManager.default.fileExists(atPath: configPath), "a dry run writes nothing")
    }
    }

    // 5. An unknown identity creates the missing profile rather than dropping the folder.
    do {
    let real = t.attempt("import writes config.toml") {
        try runCLI(binary, ["import", "--from", confPath], env: env)
    }
    if let real {
        t.expectEqual(real.status, 0, "import exits 0")
        let store = ConfigStore(url: URL(fileURLWithPath: configPath))
        let config = t.attempt("loading the config written by import") { try store.load() }
        if let config {
            t.expectEqual(config?.folders.count, 2, "both valid entries were imported")
            t.expectEqual(config?.profile(id: "work")?.configDirectory, "~/.claude", "work profile created")
            t.expectEqual(config?.profile(id: "personal")?.configDirectory, "~/.claude-personal", "personal profile created")
        }
    }
    }

    // 6. Importing the same file twice adds nothing the second time.
    do {
    let second = t.attempt("importing the same file again") {
        try runCLI(binary, ["import", "--from", confPath], env: env)
    }
    if let second {
        t.expect(second.stdout.contains("0 imported"), "the second import reports zero new folders")
        let store = ConfigStore(url: URL(fileURLWithPath: configPath))
        let config = t.attempt("reloading config after the second import") { try store.load() }
        if let config {
            t.expectEqual(config?.folders.count, 2, "folder count unchanged after importing twice")
        }
    }
    }
}
