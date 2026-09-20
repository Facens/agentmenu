// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// U1 / KTD1: `harness/image/build.sh` drives an hours-long, four-stage build
/// (a base install, two Packer stages, then `provision.sh` over SSH) and its
/// return value alone says nothing about which stage ran, what it passed to
/// Packer, or what it recorded about the image it built. So — the same style
/// `HarnessScriptTests.swift` uses for `run.sh` — every scenario here drives
/// the real `build.sh` with a stub `tart`, `packer`, `ssh` and `scp` on PATH
/// and inspects what it left behind: `state/vms/*`, the stub's own
/// `calls.log`, the sidecar JSON beside a cached base image, and the JSON
/// `provision.sh` prints on its way out. `expect`, `jq`, `shasum` and `curl`
/// are the real system tools throughout (never stubbed); `curl` is simply
/// never exercised, because every scenario passes `--ipsw` a local fixture
/// file.
///
/// This suite also lints `vanilla-tahoe.pkr.hcl`'s boot_command sequence
/// directly against the three rules the template's own header documents. A
/// violation there is invisible to `packer validate` — the plugin's own
/// `<wait 'text'>`/`<click 'text'>` waits never time out on their own — and
/// would otherwise only surface hours into a real Setup Assistant run.
///
/// This suite does not skip: a missing `harness/image/build.sh` is a failure
/// here, not a "(skipped)" pass.
func runImageRecipeTests(_ t: TestRunner) {
    t.suite("ImageRecipe")

    let root = repositoryRoot()
    let buildScript = root.appendingPathComponent("harness/image/build.sh").path
    guard FileManager.default.isExecutableFile(atPath: buildScript) else {
        t.expect(false, "harness/image/build.sh is missing or not executable at \(buildScript) — this suite fails rather than skipping")
        return
    }

    runImageSyntaxAndHelpTests(t, root)
    runTemplateLintTests(t, root)
    runImageBuildUsageErrorTests(t, root)
    runImageGoldenExistsTests(t, root)
    runImageHappyPathTests(t, root)
    runImageForceReuseTests(t, root)
    runImageTermsManualTests(t, root)
    runImageBaseOverrideTests(t, root)
    runImageMissingSidecarTests(t, root)
    runImageStageCapTests(t, root)
    runImagePackerFailureTests(t, root)
}

// MARK: - The scripts parse, and --help names their flags

private func runImageSyntaxAndHelpTests(_ t: TestRunner, _ root: URL) {
    let scripts = [
        "harness/image/build.sh",
        "harness/image/provision.sh",
        "harness/image/verify.sh",
        "harness/image/tcc-seed.sh",
    ]
    for script in scripts {
        let path = root.appendingPathComponent(script).path
        guard FileManager.default.fileExists(atPath: path) else {
            t.expect(false, "\(script) is missing")
            continue
        }
        let parsed = runProcess("/bin/bash", ["-n", path])
        t.expectEqual(parsed.status, 0, "\(script) parses — \(parsed.stderr)")
    }

    let buildHelp = runProcess(root.appendingPathComponent("harness/image/build.sh").path, ["--help"])
    t.expectEqual(buildHelp.status, 0, "build.sh --help exits 0")
    for phrase in ["--terms", "--base", "--rebuild-base", "--skip-verify"] {
        t.expect(buildHelp.stdout.contains(phrase), "build.sh --help names '\(phrase)' — got: \(buildHelp.stdout)")
    }
    t.expect(!buildHelp.stdout.contains("#!/bin/bash"), "build.sh --help strips the comment markers rather than dumping the file")

    let provisionHelp = runProcess(root.appendingPathComponent("harness/image/provision.sh").path, ["--help"])
    t.expectEqual(provisionHelp.status, 0, "provision.sh --help exits 0")
    t.expect(provisionHelp.stdout.contains("--terms-mode"), "provision.sh --help names '--terms-mode' — got: \(provisionHelp.stdout)")
}

// MARK: - vanilla-tahoe.pkr.hcl: a lint over plain text, no packer needed

/// Rule 2 of the template's own header: a fixed `<waitNs>` above ten seconds
/// is only safe directly under a `# loader: ...` comment — the one case
/// where the wait is not itself proof the guest is ready, because a loader
/// precedes a control that is already visible (so a click would otherwise
/// land on a disabled button). Everywhere else, a fixed wait that long is a
/// guess about a screen the plugin can already see for itself. Returns one
/// message per offending `<waitNs>`, naming the line.
private func lintLongFixedWaits(_ content: String) -> [String] {
    let lines = content.components(separatedBy: "\n")
    var violations: [String] = []
    for (index, line) in lines.enumerated() {
        for group in captureGroups(#"<wait(\d+)s>"#, in: line) {
            guard let seconds = Int(group), seconds > 10 else { continue }
            let previous = index > 0 ? lines[index - 1].trimmingCharacters(in: .whitespaces) : ""
            if !previous.hasPrefix("# loader:") {
                violations.append("line \(index + 1): <wait\(seconds)s> is over ten seconds with no '# loader: ...' line above it — got '\(previous)'")
            }
        }
    }
    return violations
}

/// Rule 3's first half: a `# repeats: <label>` comment promises that the very
/// next non-comment line anchors that label, `<click '^<label>$'>`, so a
/// click whose word also occurs elsewhere on the same screen cannot land on
/// the wrong observation.
private func lintRepeatsAnnotations(_ content: String) -> [String] {
    let lines = content.components(separatedBy: "\n")
    var violations: [String] = []
    for (index, line) in lines.enumerated() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("# repeats:") else { continue }
        let label = trimmed.replacingOccurrences(of: "# repeats:", with: "").trimmingCharacters(in: .whitespaces)
        var next = index + 1
        while next < lines.count, lines[next].trimmingCharacters(in: .whitespaces).hasPrefix("#") {
            next += 1
        }
        let expected = "<click '^\(label)$'>"
        guard next < lines.count, lines[next].contains(expected) else {
            let got = next < lines.count ? lines[next].trimmingCharacters(in: .whitespaces) : "(end of file)"
            violations.append("line \(index + 1): '# repeats: \(label)' is not followed by \(expected) — got '\(got)'")
            continue
        }
    }
    return violations
}

/// Rule 3's second half: the plugin's own `<wait 'text'>`/`<click 'text'>`
/// parser stops at the FIRST apostrophe, so a label carrying one would
/// silently truncate rather than fail loudly. Flags a `<wait '`/`<click '`
/// whose first following apostrophe is not immediately closed by `>` — the
/// signature of a second apostrophe inside what should have been the whole
/// label. A plain single-quoted shell string elsewhere on the same line
/// (never preceded by `<wait '`/`<click '`) does not match this at all.
private func lintNoApostropheInLabels(_ content: String) -> [String] {
    let pattern = #"<(wait|click)\s*'[^']*'(?!>)"#
    var violations: [String] = []
    for (index, line) in content.components(separatedBy: "\n").enumerated() {
        if hasMatch(pattern, in: line) {
            violations.append("line \(index + 1): a <wait '...'>/<click '...'> label is not closed by an immediate '>' — an apostrophe inside it would truncate silently — got '\(line.trimmingCharacters(in: .whitespaces))'")
        }
    }
    return violations
}

/// The plugin's `headless` defaults to false; the template's own header says
/// this file must never set it to true, because `terms_mode = manual` needs
/// an interactive packer window for the maintainer to click into.
private func lintNoHeadless(_ content: String) -> [String] {
    hasMatch(#"headless\s*=\s*true"#, in: content)
        ? ["the template sets headless = true, which a manual terms_mode build needs to be false"]
        : []
}

/// `terms_mode`'s validation block should offer exactly click, voiceover and
/// manual — checked here as a second, independent proof that the `terms`
/// map actually defines a boot_command sequence for each one, not only that
/// the HCL `validation` block claims to accept it.
private func lintTermsModesPresent(_ content: String) -> [String] {
    ["click", "voiceover", "manual"].compactMap { mode in
        hasMatch(#"^\s*"# + mode + #"\s*=\s*\["#, in: content) ? nil : "no '\(mode) = [' key found in the terms map"
    }
}

/// The one documented click every non-manual build makes: Terms and
/// Conditions' own "Agree" label also occurs inside "Disagree" and in the
/// licence text, so the click mode must anchor it.
private func lintClickModeAgrees(_ content: String) -> [String] {
    content.contains("<click '^Agree$'>") ? [] : ["the click terms_mode never contains <click '^Agree$'>"]
}

private func runTemplateLintTests(_ t: TestRunner, _ root: URL) {
    let templatePath = root.appendingPathComponent("harness/image/vanilla-tahoe.pkr.hcl").path
    guard let template = try? String(contentsOfFile: templatePath, encoding: .utf8) else {
        t.expect(false, "harness/image/vanilla-tahoe.pkr.hcl is missing")
        return
    }

    // The real template already follows every rule its own header documents
    // — the suite's baseline, proving the lint does not cry wolf on the file
    // it exists to guard.
    t.expectEqual(lintLongFixedWaits(template), [], "the real template carries no un-annotated fixed wait over ten seconds")
    t.expectEqual(lintRepeatsAnnotations(template), [], "every '# repeats:' comment in the real template is followed by its anchored click")
    t.expectEqual(lintNoApostropheInLabels(template), [], "no <wait '...'>/<click '...'> label in the real template carries an apostrophe")
    t.expectEqual(lintNoHeadless(template), [], "the real template never sets headless = true")
    t.expectEqual(lintTermsModesPresent(template), [], "the real template offers all three terms_mode keys")
    t.expectEqual(lintClickModeAgrees(template), [], "the real template's click mode clicks '^Agree$'")

    // Deliberately broken fixtures, one per rule, prove the lint actually
    // fires rather than only ever agreeing with a compliant file. These are
    // small standalone strings, never edits to the real template.
    let unannotatedWait = "\"<wait 'Something'><wait15s><click 'Continue'>\""
    t.expect(!lintLongFixedWaits(unannotatedWait).isEmpty, "a bare <wait15s> with no '# loader:' line above it is flagged")

    let annotatedWait = "# loader: Something\n\"<wait 'Something'><wait15s><click 'Continue'>\""
    t.expect(lintLongFixedWaits(annotatedWait).isEmpty, "the same wait, annotated, is not flagged")

    let missingRepeatsAnchor = "# repeats: Agree\n\"<wait 'Terms'><click 'Agree'>\""
    t.expect(!lintRepeatsAnnotations(missingRepeatsAnchor).isEmpty, "a '# repeats:' comment not followed by its anchored click is flagged")

    let anchoredRepeats = "# repeats: Agree\n\"<wait 'Terms'><click '^Agree$'>\""
    t.expect(lintRepeatsAnnotations(anchoredRepeats).isEmpty, "the anchored click satisfies its own '# repeats:' comment")

    let apostropheInClick = "\"<click 'Don't Use'>\""
    t.expect(!lintNoApostropheInLabels(apostropheInClick).isEmpty, "an apostrophe inside a <click '...'> label is flagged")

    let terminalOneLiner = "\"<wait 'zsh'><wait2s>for c in 'enable system/com.openssh.sshd' 'bootstrap system /x.plist'; do echo admin | sudo -S launchctl $c; done<enter>\""
    t.expect(lintNoApostropheInLabels(terminalOneLiner).isEmpty, "the Terminal one-liner's own single quotes are never inside a <wait '...'>/<click '...'> token, so it passes")

    let headlessFixture = "source \"tart-cli\" \"tart\" {\n  headless = true\n}"
    t.expect(!lintNoHeadless(headlessFixture).isEmpty, "headless = true is flagged")

    let missingMode = "terms = {\n  click = [\"x\"]\n  manual = [\"y\"]\n}"
    t.expect(!lintTermsModesPresent(missingMode).isEmpty, "a terms map missing one of the three modes is flagged")

    let noAgreeClick = "terms = {\n  click = [\"<click 'Somewhere'>\"]\n}"
    t.expect(!lintClickModeAgrees(noAgreeClick).isEmpty, "a click mode that never clicks '^Agree$' is flagged")
}

// MARK: - Small regex helpers shared by the lint above

private func hasMatch(_ pattern: String, in text: String) -> Bool {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return false }
    return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
}

private func captureGroups(_ pattern: String, in text: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return [] }
    let nsText = text as NSString
    return regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)).compactMap { match -> String? in
        guard match.numberOfRanges > 1 else { return nil }
        let range = match.range(at: 1)
        guard range.location != NSNotFound else { return nil }
        return nsText.substring(with: range)
    }
}

private func allRanges(_ pattern: String, in text: String) -> [Range<String.Index>] {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return [] }
    let nsText = text as NSString
    return regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)).compactMap { Range($0.range, in: text) }
}

// MARK: - build.sh argument handling, driven for real against a stub rig

// MARK: Usage errors refuse before any tool call

private func runImageBuildUsageErrorTests(_ t: TestRunner, _ root: URL) {
    guard let rig = makeImageRig("image-usage", root, t) else { return }
    defer { rig.dir.cleanup() }

    let refusals: [(String, [String], [String: String], String)] = [
        ("--terms with an unknown mode", ["--skip-verify", "--ipsw", rig.ipswPath, "--terms", "bogus"], [:], "--terms must be"),
        ("--base and --rebuild-base together", ["--skip-verify", "--base", "x", "--rebuild-base"], [:], "contradict"),
        ("an unknown flag", ["--skip-verify", "--bogus"], [:], "unknown argument"),
        ("--terms with no value", ["--skip-verify", "--terms"], [:], "needs a value"),
        ("--base carrying a slash", ["--skip-verify", "--base", "foo/bar"], [:], "plain Tart VM name"),
        ("a non-numeric stage cap", ["--skip-verify", "--ipsw", rig.ipswPath], ["HARNESS_IMAGE_STAGE_CAP": "abc"], "must be a number"),
    ]
    for (what, args, env, expected) in refusals {
        let result = imageBuildRun(rig, args, extraEnvironment: env)
        t.expectEqual(result.status, 2, "\(what) is a usage error — stderr: \(result.stderr)")
        t.expect(result.stderr.contains(expected), "the refusal for \(what) says '\(expected)' — got: \(result.stderr)")
    }
    t.expectEqual(imageVMs(rig), [], "a refused start creates nothing under state/vms/")
    t.expect(!imageCallLog(rig).contains("packer build"), "a refused start never gets as far as packer build")
}

// MARK: An existing first-run-golden is refused without --force

private func runImageGoldenExistsTests(_ t: TestRunner, _ root: URL) {
    guard let rig = makeImageRig("image-golden-exists", root, t) else { return }
    defer { rig.dir.cleanup() }

    imageSeedVM(rig, "first-run-golden")
    let result = imageBuildRun(rig, ["--skip-verify"])
    t.expectEqual(result.status, 2, "an existing first-run-golden without --force is a usage error — stderr: \(result.stderr)")
    t.expect(result.stderr.contains("already exists"), "the refusal says so — got: \(result.stderr)")
    t.expect(!imageCallLog(rig).contains("packer build"), "the refusal never calls packer build")
}

// MARK: Happy path: stage 0 through the final clone, exit 0

private func runImageHappyPathTests(_ t: TestRunner, _ root: URL) {
    guard let rig = makeImageRig("image-happy", root, t) else { return }
    defer { rig.dir.cleanup() }

    let result = imageBuildRun(rig, ["--ipsw", rig.ipswPath, "--skip-verify"])
    t.expectEqual(result.status, 0, "the happy path exits 0 — stdout: \(result.stdout) stderr: \(result.stderr)")

    let calls = imageCallLog(rig)
    t.expectEqual(calls.components(separatedBy: "tart create").count - 1, 1, "exactly one tart create — first-run-base")
    t.expect(imageVMs(rig).contains("first-run-golden"), "first-run-golden exists — got: \(imageVMs(rig))")
    t.expect(imageVMs(rig).contains("first-run-base"), "first-run-base was kept, not deleted")

    guard let sidecar = imageSidecar(rig) else {
        t.expect(false, "the sidecar first-run-base.json is readable JSON")
        return
    }
    t.expectEqual(sidecar["ipsw_sha256"] as? String, rig.ipswSHA256, "the sidecar's ipsw_sha256 matches the fixture IPSW's real hash")

    t.expect(calls.contains("-on-error=abort"), "stage 1's packer build carries -on-error=abort — got: \(calls)")
    t.expect(calls.contains("-var vm_base_name=first-run-base"), "stage 1's packer build names the base VM — got: \(calls)")
    t.expect(calls.contains("-var terms_mode=click"), "stage 1's packer build passes the default terms mode — got: \(calls)")
    t.expect(!allRanges(#"-var vm_name=first-run-golden-[0-9]+"#, in: calls).isEmpty, "stage 1's packer build names the per-build VM — got: \(calls)")
    t.expectEqual(calls.components(separatedBy: "packer build").count - 1, 2, "packer build ran twice — Setup Assistant, then SIP off")

    t.expect(calls.contains("automationmodetool"), "provision.sh enabled Automation Mode over the ssh stub — got: \(calls)")
    t.expect(!allRanges(#"tart clone first-run-golden-[0-9]+ first-run-golden"#, in: calls).isEmpty, "the build ends by cloning the per-build VM to first-run-golden — got: \(calls)")

    guard let json = imageLastProvisionJSON(result.stdout) else {
        t.expect(false, "provision.sh's own JSON is on stdout — got: \(result.stdout)")
        return
    }
    t.expectEqual(json["manual_steps"] as? String, "", "the default terms mode records no manual step")
}

// MARK: --force reuses the cached base and replaces the old golden image

private func runImageForceReuseTests(_ t: TestRunner, _ root: URL) {
    guard let rig = makeImageRig("image-force-reuse", root, t) else { return }
    defer { rig.dir.cleanup() }

    let first = imageBuildRun(rig, ["--ipsw", rig.ipswPath, "--skip-verify"])
    t.expectEqual(first.status, 0, "the first build exits 0 — stderr: \(first.stderr)")

    // BUILD_ID has one-second resolution and a build's own per-build VM is
    // kept, never deleted; without this, a second run inside the same
    // wall-clock second collides with the first build's own name and fails
    // with "already exists (a build already ran this second)".
    Thread.sleep(forTimeInterval: 1.1)

    let second = imageBuildRun(rig, ["--ipsw", rig.ipswPath, "--skip-verify", "--force"])
    t.expectEqual(second.status, 0, "the second build with --force exits 0 — stderr: \(second.stderr)")

    let calls = imageCallLog(rig)
    t.expectEqual(calls.components(separatedBy: "tart create").count - 1, 1, "first-run-base was created once, across both builds, then reused")
    t.expect(imageVMs(rig).contains("first-run-golden"), "first-run-golden exists after the second build")

    let clones = allRanges(#"tart clone first-run-golden-[0-9]+ first-run-golden"#, in: calls)
    t.expectEqual(clones.count, 2, "each build cloned its own per-build VM to first-run-golden — got: \(calls)")
    guard let lastClone = clones.last, let deleteRange = calls.range(of: "tart delete first-run-golden\n") else {
        t.expect(false, "the log carries a delete of the old first-run-golden and both clones — got: \(calls)")
        return
    }
    t.expect(deleteRange.lowerBound < lastClone.lowerBound, "the old first-run-golden was deleted before the new one was cloned — got: \(calls)")
    t.expectEqual(calls.components(separatedBy: "tart delete first-run-golden\n").count - 1, 1, "only the second build deletes the old first-run-golden")
}

// MARK: --terms manual carries terms_mode through and records a manual step

private func runImageTermsManualTests(_ t: TestRunner, _ root: URL) {
    guard let rig = makeImageRig("image-terms-manual", root, t) else { return }
    defer { rig.dir.cleanup() }

    let result = imageBuildRun(rig, ["--ipsw", rig.ipswPath, "--skip-verify", "--terms", "manual"])
    t.expectEqual(result.status, 0, "a manual-terms build exits 0 — stderr: \(result.stderr)")
    t.expect(imageCallLog(rig).contains("-var terms_mode=manual"), "stage 1's packer build passes terms_mode=manual — got: \(imageCallLog(rig))")

    guard let json = imageLastProvisionJSON(result.stdout) else {
        t.expect(false, "provision.sh's own JSON is on stdout — got: \(result.stdout)")
        return
    }
    let manualSteps = json["manual_steps"] as? String ?? ""
    t.expect(!manualSteps.isEmpty, "manual mode records a manual step")
    t.expect(manualSteps.contains("Terms and Conditions"), "the manual step names Terms and Conditions — got: \(manualSteps)")
}

// MARK: --base <vm> skips stage 0 and clones from the named VM instead

private func runImageBaseOverrideTests(_ t: TestRunner, _ root: URL) {
    guard let rig = makeImageRig("image-base-override", root, t) else { return }
    defer { rig.dir.cleanup() }

    imageSeedVM(rig, "other-base")
    let result = imageBuildRun(rig, ["--skip-verify", "--base", "other-base"])
    t.expectEqual(result.status, 0, "a build against --base other-base exits 0 — stderr: \(result.stderr)")

    t.expect(!imageCallLog(rig).contains("tart create"), "no base was installed — --base skips stage 0")
    t.expect(imageCallLog(rig).contains("-var vm_base_name=other-base"), "packer clones from the named base — got: \(imageCallLog(rig))")

    guard let json = imageLastProvisionJSON(result.stdout) else {
        t.expect(false, "provision.sh's own JSON is on stdout — got: \(result.stdout)")
        return
    }
    let ipswSHA256 = json["ipsw_sha256"] as? String ?? ""
    t.expect(ipswSHA256.hasPrefix("unrecorded"), "no IPSW hash is claimed for an unrecognised base — got: \(ipswSHA256)")
}

// MARK: A base VM with no sidecar refuses rather than guessing its IPSW

private func runImageMissingSidecarTests(_ t: TestRunner, _ root: URL) {
    guard let rig = makeImageRig("image-missing-sidecar", root, t) else { return }
    defer { rig.dir.cleanup() }

    imageSeedVM(rig, "first-run-base")
    let result = imageBuildRun(rig, ["--skip-verify"])
    t.expectEqual(result.status, 3, "a base VM with no sidecar is a tooling error — stderr: \(result.stderr)")
    t.expect(result.stderr.contains("--rebuild-base"), "the refusal points at --rebuild-base — got: \(result.stderr)")
    t.expect(!imageCallLog(rig).contains("packer build"), "the refusal never reaches packer")
}

// MARK: The stage-1 wall-clock cap: stopped and kept, not cloned

private func runImageStageCapTests(_ t: TestRunner, _ root: URL) {
    guard let rig = makeImageRig("image-stage-cap", root, t) else { return }
    defer { rig.dir.cleanup() }

    // The packer stub never returns on its own once PACKER_STUB_HANG is set,
    // so this scenario genuinely runs for about cap (3s) + the 20s grace
    // build.sh gives packer between stopping the guest and sending SIGTERM —
    // call it 25s, not a hang in this suite.
    let result = imageBuildRun(
        rig,
        ["--ipsw", rig.ipswPath, "--skip-verify"],
        extraEnvironment: ["HARNESS_IMAGE_STAGE_CAP": "3", "PACKER_STUB_HANG": "1"]
    )
    t.expectEqual(result.status, 3, "a stage 1 that never finishes hits the cap and exits 3 — stdout: \(result.stdout) stderr: \(result.stderr)")
    t.expect(result.stderr.lowercased().contains("cap"), "the refusal names the cap — got: \(result.stderr)")
    t.expect(result.stderr.contains("Terms and Conditions"), "the refusal names the last screen packer was looking for — got: \(result.stderr)")

    let calls = imageCallLog(rig)
    t.expect(!allRanges(#"tart stop first-run-golden-[0-9]+"#, in: calls).isEmpty, "the capped build VM was stopped — got: \(calls)")
    t.expect(!calls.contains("tart delete first-run-golden-"), "the capped build VM was kept, not deleted — got: \(calls)")
    t.expect(!calls.contains("tart clone"), "a capped build never reaches the final clone — got: \(calls)")
}

// MARK: A stage-1 packer failure is a tooling error, not a hang

private func runImagePackerFailureTests(_ t: TestRunner, _ root: URL) {
    guard let rig = makeImageRig("image-packer-fail", root, t) else { return }
    defer { rig.dir.cleanup() }

    let result = imageBuildRun(
        rig,
        ["--ipsw", rig.ipswPath, "--skip-verify"],
        extraEnvironment: ["PACKER_STUB_FAIL": "1"]
    )
    t.expectEqual(result.status, 3, "a stage 1 packer build that fails is a tooling error — stdout: \(result.stdout) stderr: \(result.stderr)")
    t.expect(result.stderr.contains("stage 1") && result.stderr.contains("failed"), "the refusal says stage 1 failed — got: \(result.stderr)")
    t.expect(!imageCallLog(rig).contains("tart clone"), "a failed stage 1 never reaches the final clone")
}

// MARK: - The rig: stub tart, packer, ssh and scp on PATH, a fixture IPSW

private struct ImageRig {
    let dir: TempDir
    let root: URL
    let buildScript: String
    let environment: [String: String]
    let state: String
    let tartHome: String
    let ipswPath: String
    let ipswSHA256: String
}

/// A stub `tart` with just enough memory to be worth asserting against: one
/// file per VM under `vms/`, holding that VM's state, so `list --quiet`
/// (which build.sh's own `vm_exists` greps with `-x`) reports bare names, one
/// per line, exactly the way the real `--quiet` flag does. Every invocation
/// is appended to `calls.log`. `run` blocks while the VM is "running" and
/// returns once it is stopped or deleted, the way the real one does.
///
/// `list` builds its whole answer into one string and prints it with a
/// single `printf` — not one `echo`/`basename` per file — deliberately: with
/// several VMs on record and `vm_exists()`'s own
/// `tart list ... | grep -qx "$1"`, a per-line write lets `grep -q` close
/// the pipe the instant it matches, and build.sh's `set -o pipefail` then
/// turns tart's own SIGPIPE on its next write into vm_exists() reporting
/// "does not exist" for a VM that plainly does — reproduced empirically
/// (100% of the time, for a name that is not the last one printed) before
/// landing on a single write here. A real, compiled `tart` binary produces
/// its output the same way (one buffered write, not many), so this keeps
/// the stub honest rather than dodging the bug.
private let imageTartStub = #"""
#!/bin/bash
STATE="${TART_STUB_STATE:?}"
mkdir -p "$STATE/vms"
printf 'tart %s\n' "$*" >> "$STATE/calls.log"
cmd="${1:-}"; shift || true
case "$cmd" in
  --version) echo "2.37.0" ;;
  list)
    names=""
    for f in "$STATE"/vms/*; do
      [ -e "$f" ] || continue
      names="$names${f##*/}
"
    done
    printf '%s' "$names"
    ;;
  create)
    name="$1"
    echo stopped > "$STATE/vms/$name"
    ;;
  clone)
    if [ -f "$STATE/clone-fail-once" ]; then
      rm -f "$STATE/clone-fail-once"
      echo "tart: the clone failed (stub)" >&2
      exit 1
    fi
    echo stopped > "$STATE/vms/$2"
    ;;
  run)
    name=""
    for a in "$@"; do case "$a" in -*) ;; *) name="$a" ;; esac; done
    echo running > "$STATE/vms/$name"
    while [ -f "$STATE/vms/$name" ] && [ "$(cat "$STATE/vms/$name")" = "running" ]; do sleep 1; done
    exit 0
    ;;
  ip) echo "127.0.0.1" ;;
  stop) if [ -f "$STATE/vms/$1" ]; then echo stopped > "$STATE/vms/$1"; fi ;;
  delete) rm -f "$STATE/vms/$1" ;;
  *) echo "tart stub: unknown subcommand $cmd" >&2; exit 1 ;;
esac
"""#

/// A stub `packer`. `init` always succeeds. `build` succeeds instantly unless
/// told otherwise: `PACKER_STUB_FAIL` makes it fail immediately, and
/// `PACKER_STUB_HANG` makes it print the one line build.sh's own
/// `last_looked_for` greps for (to both its stdout and `PACKER_LOG_PATH`,
/// the way the real plugin logs to both packer's own stdout and its
/// separate log file) and then hang until SIGTERM — which build.sh sends
/// only after its wall-clock cap plus a 20s grace period, exercising that
/// exact path in `runImageStageCapTests`.
private let imagePackerStub = #"""
#!/bin/bash
STATE="${TART_STUB_STATE:?}"
printf 'packer %s\n' "$*" >> "$STATE/calls.log"
case "${1:-}" in
  init) exit 0 ;;
  build)
    if [ -n "${PACKER_STUB_FAIL:-}" ]; then
      echo "packer stub: forced failure" >&2
      exit 1
    fi
    if [ -n "${PACKER_STUB_HANG:-}" ]; then
      msg="Looking for 'Terms and Conditions'..."
      echo "$msg"
      if [ -n "${PACKER_LOG_PATH:-}" ]; then printf '%s\n' "$msg" >> "$PACKER_LOG_PATH"; fi
      trap 'exit 0' TERM
      while sleep 1; do :; done
    fi
    echo "packer build ok"
    exit 0
    ;;
  *) echo "packer stub: unknown subcommand ${1:-}" >&2; exit 1 ;;
esac
"""#

/// `provision.sh` spawns `ssh` through the real `/usr/bin/expect`, which is
/// what actually execs this stub — verified directly against this exact
/// transport before being trusted here. It answers by pattern on its own
/// argv, joined: the three `sw_vers`/`claude --version` reads provision.sh
/// makes, and otherwise silently succeeds, the way a guest that already has
/// everything provision.sh asks for would.
private let imageSSHStub = #"""
#!/bin/bash
printf 'ssh %s\n' "$*" >> "${TART_STUB_STATE:?}/calls.log"
case "$*" in
  *"csrutil status"*) echo "System Integrity Protection status: disabled." ;;
  # build.sh shuts the guest down from inside and waits for the VM process
  # to exit, the way a real `shutdown -h now` makes `tart run` return.
  *"shutdown -h now"*)
    for f in "${TART_STUB_STATE:?}"/vms/*; do
      [ -f "$f" ] && [ "$(cat "$f")" = "running" ] && echo stopped > "$f"
    done ;;
  *"sw_vers -productVersion"*) echo "26.6.2" ;;
  *"sw_vers -buildVersion"*) echo "25G83" ;;
  *"claude --version"*) echo "2.1.0 (Claude Code)" ;;
  *"first-run-golden.json"*) : ;;
  *) : ;;
esac
exit 0
"""#

private let imageSCPStub = #"""
#!/bin/bash
printf 'scp %s\n' "$*" >> "${TART_STUB_STATE:?}/calls.log"
exit 0
"""#

private func makeImageRig(_ label: String, _ root: URL, _ t: TestRunner) -> ImageRig? {
    let dir = TempDir(label)
    do {
        for (name, body) in [("bin/tart", imageTartStub), ("bin/packer", imagePackerStub), ("bin/ssh", imageSSHStub), ("bin/scp", imageSCPStub)] {
            try dir.write(body + "\n", to: name)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path(name))
        }
        try FileManager.default.createDirectory(atPath: dir.path("state/vms"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: dir.path("tart"), withIntermediateDirectories: true)
        // Stands in for a multi-gigabyte IPSW: build.sh hashes whatever
        // bytes it is actually given, so a few bytes here are enough to
        // prove the sidecar's ipsw_sha256 tracks the real file rather than
        // being hardcoded.
        try dir.write("this is not really an IPSW, just enough bytes for shasum to hash\n", to: "fake.ipsw")
    } catch {
        t.expect(false, "built the image stub rig: \(error)")
        dir.cleanup()
        return nil
    }

    let ipswPath = dir.path("fake.ipsw")
    let hashed = runProcess("/usr/bin/shasum", ["-a", "256", ipswPath])
    let ipswSHA256 = hashed.stdout.split(separator: " ").first.map(String.init) ?? ""
    guard ipswSHA256.count == 64 else {
        t.expect(false, "hashed the fixture IPSW with shasum — got stdout '\(hashed.stdout)' stderr '\(hashed.stderr)'")
        dir.cleanup()
        return nil
    }

    let existingPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    let environment = [
        "PATH": dir.path("bin") + ":" + existingPath,
        "TART_STUB_STATE": dir.path("state"),
        "TART_HOME": dir.path("tart"),
    ]
    return ImageRig(
        dir: dir,
        root: root,
        buildScript: root.appendingPathComponent("harness/image/build.sh").path,
        environment: environment,
        state: dir.path("state"),
        tartHome: dir.path("tart"),
        ipswPath: ipswPath,
        ipswSHA256: ipswSHA256
    )
}

/// Runs the real build.sh against the rig. Two things beyond a plain
/// `runProcess` call:
///
/// build.sh's stage-1 cap watchdog is a backgrounded subshell
/// (`( sleep "$STAGE_CAP"; ... ) &`) that build.sh only ever *kills*, never
/// waits out, on the fast path every scenario but the cap test itself takes.
/// Killing that subshell does not kill the `sleep` it was blocked in —
/// that keeps running, orphaned, holding this process's own stdout/stderr
/// open for the rest of `HARNESS_IMAGE_STAGE_CAP` seconds (1800 for
/// `--terms manual` by default). `runProcess` drains stdout/stderr with
/// `readDataToEndOfFile()` *before* `waitUntilExit()`, and a pipe's read end
/// only sees EOF once every process holding its write end has closed it —
/// so capturing build.sh's output through a live pipe would block on that
/// orphan even though build.sh itself already exited (confirmed empirically
/// before writing this suite). Routing build.sh's own stdout/stderr to two
/// files instead, via `exec` (which replaces this process image in place, so
/// the files are already open on fds 1/2 before build.sh or any of its
/// children exist), sidesteps the pipe entirely; the orphan then holds a
/// file open, which blocks nobody.
///
/// Second, every call defaults `HARNESS_IMAGE_STAGE_CAP` to a small number
/// unless the scenario overrides it, purely so that harmless orphan does not
/// sit in the background for up to half an hour after a suite run that took
/// a few seconds; every stub `packer build` used here finishes in well under
/// a second, so the cap itself is never actually reached except in
/// `runImageStageCapTests`.
private func imageBuildRun(_ rig: ImageRig, _ arguments: [String], extraEnvironment: [String: String] = [:]) -> CLIResult {
    var environment = rig.environment
    if environment["HARNESS_IMAGE_STAGE_CAP"] == nil {
        environment["HARNESS_IMAGE_STAGE_CAP"] = "30"
    }
    for (key, value) in extraEnvironment { environment[key] = value }

    let outPath = rig.dir.path("build.stdout")
    let errPath = rig.dir.path("build.stderr")
    FileManager.default.createFile(atPath: outPath, contents: nil)
    FileManager.default.createFile(atPath: errPath, contents: nil)
    environment["IMAGE_TEST_STDOUT"] = outPath
    environment["IMAGE_TEST_STDERR"] = errPath

    let wrapper = "exec \"$0\" \"$@\" >\"$IMAGE_TEST_STDOUT\" 2>\"$IMAGE_TEST_STDERR\""
    let outcome = runProcess("/bin/bash", ["-c", wrapper, rig.buildScript] + arguments, in: rig.root, environment: environment)
    let stdout = (try? String(contentsOfFile: outPath, encoding: .utf8)) ?? ""
    let stderr = (try? String(contentsOfFile: errPath, encoding: .utf8)) ?? ""
    return CLIResult(status: outcome.status, stdout: stdout, stderr: stderr)
}

private func imageCallLog(_ rig: ImageRig) -> String {
    (try? String(contentsOfFile: "\(rig.state)/calls.log", encoding: .utf8)) ?? ""
}

private func imageVMs(_ rig: ImageRig) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: "\(rig.state)/vms")) ?? []).sorted()
}

private func imageSeedVM(_ rig: ImageRig, _ name: String, state: String = "stopped") {
    try? "\(state)\n".write(toFile: "\(rig.state)/vms/\(name)", atomically: true, encoding: .utf8)
}

private func imageSidecar(_ rig: ImageRig) -> [String: Any]? {
    guard let data = FileManager.default.contents(atPath: "\(rig.tartHome)/harness-image-cache/first-run-base.json"),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    return object
}

/// `provision.sh` builds its report with `jq -n` and no `-c`, so it is
/// pretty-printed across several lines (confirmed empirically), not the
/// single compact line a naive "read the last line of stdout" would assume
/// — and build.sh keeps printing its own lines afterward (the clone, the
/// Time Machine exclusion, "build.sh: ok"), so the JSON is not even the
/// tail of the whole capture. This instead finds the `{`/`}` that bracket
/// the object printed right after provision.sh's own "provision.sh: ok"
/// line, by simple depth counting (safe here: none of this JSON's values
/// ever contain a brace), and parses exactly that.
private func imageLastProvisionJSON(_ stdout: String) -> [String: Any]? {
    guard let markerRange = stdout.range(of: "provision.sh: ok") else { return nil }
    let after = stdout[markerRange.upperBound...]
    guard let openBrace = after.firstIndex(of: "{") else { return nil }
    var depth = 0
    var index = openBrace
    var closeIndex: String.Index?
    while index < after.endIndex {
        let character = after[index]
        if character == "{" { depth += 1 } else if character == "}" {
            depth -= 1
            if depth == 0 { closeIndex = index; break }
        }
        index = after.index(after: index)
    }
    guard let close = closeIndex, let data = String(after[openBrace...close]).data(using: .utf8) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}
