// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// R6 / KTD16: `packaging/verify-signing.sh` exists to catch exactly the
/// defect its own header describes — a nested Mach-O that `codesign --verify
/// --strict --deep` waved through because `--deep` never looks in
/// `Contents/Resources`. That means the script's rejection paths are the
/// whole point of it, and none of them were ever proven to actually fail.
///
/// Every scenario here signs a scratch `Scratch.app` the same way
/// `packaging/bundle.sh` does — ad-hoc, `--options runtime`,
/// `--timestamp=none`, the nested CLI signed with its own identifier before
/// the app — then mutates exactly one thing about it and runs the real
/// script as a subprocess. No `swift build`, no certificate: the Mach-Os are
/// two freshly `clang`-compiled no-ops, which is exactly the "linker-signed"
/// ad-hoc shape the script exists to catch before anything is signed at all.
func runVerifySigningTests(_ t: TestRunner) {
    t.suite("VerifySigning")

    let root = repositoryRoot()
    let script = root.appendingPathComponent("packaging/verify-signing.sh").path
    guard FileManager.default.isExecutableFile(atPath: script),
          FileManager.default.isExecutableFile(atPath: "/usr/bin/clang"),
          FileManager.default.isExecutableFile(atPath: "/usr/bin/codesign") else {
        print("   (skipped: packaging/verify-signing.sh, clang or codesign not found)")
        return
    }

    // 1. Properly signed bundle: consistency passes and says so.
    do {
        let dir = TempDir("verify-signing-ok")
        defer { dir.cleanup() }
        guard let app = buildScratchAppSkeleton(in: dir, t) else { return }
        t.expectEqual(signCLI(app.cli).status, 0, "signed the nested CLI")
        t.expectEqual(signApp(app.app, entitlements: app.entitlements).status, 0, "signed the app")

        let result = runProcess(script, ["consistency", app.app.path])
        t.expectEqual(result.status, 0, "a properly signed bundle passes consistency")
        t.expect(result.stdout.contains("ok (2 Mach-O)"), "stdout reports both Mach-Os were checked")
    }

    // 2. The nested CLI replaced by a freshly compiled (linker-signed) binary
    // after the app was already signed.
    do {
        let dir = TempDir("verify-signing-linker-signed")
        defer { dir.cleanup() }
        guard let app = buildScratchAppSkeleton(in: dir, t) else { return }
        t.expectEqual(signCLI(app.cli).status, 0, "signed the nested CLI")
        t.expectEqual(signApp(app.app, entitlements: app.entitlements).status, 0, "signed the app")

        let recompiled = runProcess("/usr/bin/clang", ["-o", app.cli.path, dir.path("main.c")])
        t.expectEqual(recompiled.status, 0, "recompiled the CLI in place, leaving it linker-signed")

        let result = runProcess(script, ["consistency", app.app.path])
        t.expect(result.status != 0, "a linker-signed nested CLI fails consistency")
        t.expect(result.stderr.contains("linker-signed"), "stderr names the linker-signed flag")
        t.expect(result.stderr.contains("Contents/Resources/bin/agentmenu"), "stderr names the CLI's path")
    }

    // 3. The nested CLI re-signed ad-hoc WITHOUT --options runtime.
    do {
        let dir = TempDir("verify-signing-no-runtime")
        defer { dir.cleanup() }
        guard let app = buildScratchAppSkeleton(in: dir, t) else { return }
        t.expectEqual(signCLI(app.cli, hardenedRuntime: false).status, 0, "signed the CLI without the hardened runtime")
        t.expectEqual(signApp(app.app, entitlements: app.entitlements).status, 0, "signed the app")

        let result = runProcess(script, ["consistency", app.app.path])
        t.expect(result.status != 0, "a CLI signed without the hardened runtime fails consistency")
        t.expect(result.stderr.contains("hardened runtime not requested"), "stderr says why")
    }

    // 4. The CLI signed WITH the entitlements file — it must carry none.
    do {
        let dir = TempDir("verify-signing-cli-entitlements")
        defer { dir.cleanup() }
        guard let app = buildScratchAppSkeleton(in: dir, t) else { return }
        t.expectEqual(signCLI(app.cli, entitlements: app.entitlements).status, 0, "signed the CLI with entitlements")
        t.expectEqual(signApp(app.app, entitlements: app.entitlements).status, 0, "signed the app")

        let result = runProcess(script, ["consistency", app.app.path])
        t.expect(result.status != 0, "a CLI signed with entitlements fails consistency")
        t.expect(result.stderr.contains("nested CLI carries entitlements"), "stderr says why")
    }

    // 5. The app signed WITHOUT the entitlements file.
    do {
        let dir = TempDir("verify-signing-app-no-entitlements")
        defer { dir.cleanup() }
        guard let app = buildScratchAppSkeleton(in: dir, t) else { return }
        t.expectEqual(signCLI(app.cli).status, 0, "signed the nested CLI")
        t.expectEqual(signApp(app.app, entitlements: nil).status, 0, "signed the app without entitlements")

        let result = runProcess(script, ["consistency", app.app.path])
        t.expect(result.status != 0, "an app signed without the entitlement fails consistency")
        t.expect(
            result.stderr.contains("lacks the com.apple.security.automation.apple-events entitlement"),
            "stderr says why"
        )
    }

    // 6. A properly signed all-ad-hoc bundle: consistency's job is done, but
    // authority — the release gate — refuses it for having no Developer ID.
    do {
        let dir = TempDir("verify-signing-authority")
        defer { dir.cleanup() }
        guard let app = buildScratchAppSkeleton(in: dir, t) else { return }
        t.expectEqual(signCLI(app.cli).status, 0, "signed the nested CLI")
        t.expectEqual(signApp(app.app, entitlements: app.entitlements).status, 0, "signed the app")

        let result = runProcess(script, ["authority", app.app.path])
        t.expect(result.status != 0, "an ad-hoc signed bundle fails the authority check")
        t.expect(result.stderr.contains("no Developer ID Application authority"), "stderr names the missing authority")
        t.expect(result.stderr.contains("ad-hoc signed"), "stderr also flags the ad-hoc flag")
    }

    // 7. A bundle with no Mach-O at all — just an Info.plist.
    do {
        let dir = TempDir("verify-signing-no-macho")
        defer { dir.cleanup() }
        do {
            try dir.write(scratchInfoPlist, to: "Scratch.app/Contents/Info.plist")
        } catch {
            t.expect(false, "wrote a Mach-O-less bundle's Info.plist: \(error)")
            return
        }

        let result = runProcess(script, ["consistency", dir.path("Scratch.app")])
        t.expect(result.status != 0, "a bundle with no Mach-O fails")
        t.expect(result.stderr.contains("no Mach-O found"), "stderr says why")
    }

    // U8 / R17: the session host (tmux) is a third nested Mach-O, in
    // Contents/Helpers, under more than one name. Its name has a space in it,
    // as the shipped one does, so a script that splits paths on whitespace
    // fails here rather than in a release.

    // 8. Correctly signed helpers: both names, hardened runtime, no
    // entitlements. The count proves the script found them.
    do {
        let dir = TempDir("verify-signing-helpers-ok")
        defer { dir.cleanup() }
        guard let app = buildScratchAppSkeleton(in: dir, t) else { return }
        guard let helpers = addHelpers(to: app, in: dir, t) else { return }
        t.expectEqual(signCLI(app.cli).status, 0, "signed the nested CLI")
        for helper in helpers { t.expectEqual(signHelper(helper).status, 0, "signed \(helper.lastPathComponent)") }
        t.expectEqual(signApp(app.app, entitlements: app.entitlements).status, 0, "signed the app")

        let result = runProcess(script, ["consistency", app.app.path])
        t.expectEqual(result.status, 0, "a bundle with correctly signed helpers passes consistency")
        t.expect(result.stdout.contains("ok (4 Mach-O)"), "stdout reports the helpers were checked")
        t.expect(result.stdout.contains("Contents/Helpers/AgentMenu Session Host"), "the spaced name was inspected")
    }

    // 9. A helper signed WITH the entitlements file: it runs the user's
    // shells, and must not carry the app's Apple Events grant.
    do {
        let dir = TempDir("verify-signing-helper-entitlements")
        defer { dir.cleanup() }
        guard let app = buildScratchAppSkeleton(in: dir, t) else { return }
        guard let helpers = addHelpers(to: app, in: dir, t) else { return }
        t.expectEqual(signCLI(app.cli).status, 0, "signed the nested CLI")
        t.expectEqual(signHelper(helpers[0]).status, 0, "signed the first helper cleanly")
        t.expectEqual(signHelper(helpers[1], entitlements: app.entitlements).status, 0, "signed the second helper with entitlements")
        t.expectEqual(signApp(app.app, entitlements: app.entitlements).status, 0, "signed the app")

        let result = runProcess(script, ["consistency", app.app.path])
        t.expect(result.status != 0, "a helper that carries entitlements fails consistency")
        t.expect(result.stderr.contains("helper carries entitlements"), "stderr says why")
        t.expect(result.stderr.contains("Contents/Helpers/\(helpers[1].lastPathComponent)"), "stderr names the offending helper")
        t.expect(!result.stderr.contains("Contents/Helpers/\(helpers[0].lastPathComponent): helper carries"), "and not the clean one")
    }

    // 10. A helper whose signature is gone altogether.
    do {
        let dir = TempDir("verify-signing-helper-unsigned")
        defer { dir.cleanup() }
        guard let app = buildScratchAppSkeleton(in: dir, t) else { return }
        guard let helpers = addHelpers(to: app, in: dir, t) else { return }
        t.expectEqual(signCLI(app.cli).status, 0, "signed the nested CLI")
        for helper in helpers { t.expectEqual(signHelper(helper).status, 0, "signed \(helper.lastPathComponent)") }
        t.expectEqual(signApp(app.app, entitlements: app.entitlements).status, 0, "signed the app")
        t.expectEqual(
            runProcess("/usr/bin/codesign", ["--remove-signature", helpers[0].path]).status, 0,
            "stripped the first helper's signature"
        )

        let result = runProcess(script, ["consistency", app.app.path])
        t.expect(result.status != 0, "an unsigned helper fails consistency")
        t.expect(result.stderr.contains("not signed at all"), "stderr says why")
        t.expect(result.stderr.contains("Contents/Helpers/\(helpers[0].lastPathComponent)"), "stderr names the unsigned helper")
    }

    // 11. A helper that was freshly compiled and never signed by this
    // pipeline (linker-signed), next to correctly signed ones.
    do {
        let dir = TempDir("verify-signing-helper-linker-signed")
        defer { dir.cleanup() }
        guard let app = buildScratchAppSkeleton(in: dir, t) else { return }
        guard let helpers = addHelpers(to: app, in: dir, t) else { return }
        t.expectEqual(signCLI(app.cli).status, 0, "signed the nested CLI")
        t.expectEqual(signHelper(helpers[0]).status, 0, "signed the first helper")
        // The second helper is left exactly as the compiler made it.
        t.expectEqual(signApp(app.app, entitlements: app.entitlements).status, 0, "signed the app")

        let result = runProcess(script, ["consistency", app.app.path])
        t.expect(result.status != 0, "a helper nobody signed fails consistency")
        t.expect(result.stderr.contains("linker-signed"), "stderr names the linker-signed flag")
        t.expect(result.stderr.contains("Contents/Helpers/\(helpers[1].lastPathComponent)"), "stderr names the helper")
    }

    runTmuxBuildScriptScenarios(t, root: root)
}

// MARK: - packaging/tmux/build.sh

/// U8 / KTD2: the tmux build downloads pinned tarballs, and the whole point of
/// pinning them is that a tarball whose bytes differ is refused before
/// anything is unpacked. Exercised offline: the "downloads" are `file://` URLs
/// to scratch files, the checksum file is a doctored copy in a temp dir, and
/// the cache is a temp dir too, so nothing here touches the real build cache,
/// the network, or a compiler.
private func runTmuxBuildScriptScenarios(_ t: TestRunner, root: URL) {
    let script = root.appendingPathComponent("packaging/tmux/build.sh").path
    guard FileManager.default.isExecutableFile(atPath: script),
          FileManager.default.isExecutableFile(atPath: "/usr/bin/shasum") else {
        print("   (skipped: packaging/tmux/build.sh or shasum not found)")
        return
    }
    // The script itself refuses anything but an Apple Silicon Mac; on another
    // machine it says so before it reads a checksum, and there is nothing
    // here to assert.
    var uts = utsname()
    uname(&uts)
    let machine = withUnsafeBytes(of: &uts.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    guard machine == "arm64" else {
        print("   (skipped: packaging/tmux/build.sh builds on arm64 only)")
        return
    }

    let components = [
        ("tmux", "tmux-9.9z.tar.gz"),
        ("libevent", "libevent-9.9.9-stable.tar.gz"),
        ("ncurses", "ncurses-9.9.tar.gz"),
        ("utf8proc", "utf8proc-9.9.9.tar.gz"),
        ("jemalloc", "jemalloc-9.9.9.tar.bz2"),
    ]

    /// Writes one scratch "tarball" per component and a checksum file naming
    /// them by `file://` URL. `hash` decides what each line claims.
    func fixture(in dir: TempDir, omitting omitted: String? = nil, hash: (String) -> String) -> [String: String]? {
        var lines = ["# a doctored checksum file"]
        for (name, file) in components where name != omitted {
            let source = "sources/\(file)"
            do { try dir.write("not a tarball: \(name)\n", to: source) } catch { return nil }
            let real = runProcess("/usr/bin/shasum", ["-a", "256", dir.path(source)]).stdout
                .split(separator: " ").first.map(String.init) ?? ""
            lines.append("\(hash(real))  \(file)  file://\(dir.path(source))")
        }
        do { try dir.write(lines.joined(separator: "\n") + "\n", to: "sources.sha256") } catch { return nil }
        return [
            "AM_TMUX_SOURCES": dir.path("sources.sha256"),
            "AM_TMUX_CACHE": dir.path("cache"),
        ]
    }

    // A. Every line claims a hash the file does not have: refused, naming the
    // file, with nothing unpacked, built or left in the download cache.
    do {
        let dir = TempDir("tmux-build-mismatch")
        defer { dir.cleanup() }
        guard let env = fixture(in: dir, hash: { _ in String(repeating: "0", count: 64) }) else {
            t.expect(false, "wrote the doctored fixture")
            return
        }
        let result = runProcess(script, [], environment: env)
        t.expect(result.status != 0, "a tarball whose checksum differs fails the build")
        t.expect(result.stderr.contains("checksum mismatch for tmux-9.9z.tar.gz"), "stderr names the file and the mismatch")
        t.expect(!result.stderr.contains("libevent\n") && !result.stderr.contains("tmux: ncurses"), "no component was built")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dir.path("cache/downloads"))) ?? []
        t.expect(leftovers.isEmpty, "the refused file is not kept in the download cache: \(leftovers)")
        let built = (try? FileManager.default.contentsOfDirectory(atPath: dir.path("cache"))) ?? []
        t.expectEqual(built.filter { $0 != "downloads" }.count, 0, "no build directory was created")
    }

    // B. Only one tarball is wrong: the others being right does not rescue it.
    do {
        let dir = TempDir("tmux-build-one-mismatch")
        defer { dir.cleanup() }
        guard let env = fixture(in: dir, hash: { $0 }) else {
            t.expect(false, "wrote the fixture")
            return
        }
        // Corrupt the jemalloc source after its hash was recorded.
        do { try dir.write("tampered after the fact\n", to: "sources/jemalloc-9.9.9.tar.bz2") } catch {
            t.expect(false, "tampered with the jemalloc fixture: \(error)")
            return
        }
        let result = runProcess(script, [], environment: env)
        t.expect(result.status != 0, "one tampered tarball fails the build")
        t.expect(result.stderr.contains("checksum mismatch for jemalloc-9.9.9.tar.bz2"), "stderr names the tampered file")
        t.expect(!result.stderr.contains("checksum mismatch for tmux"), "and only that one")
    }

    // C. A checksum file that does not list every component is refused before
    // any download.
    do {
        let dir = TempDir("tmux-build-missing")
        defer { dir.cleanup() }
        guard let env = fixture(in: dir, omitting: "jemalloc", hash: { $0 }) else {
            t.expect(false, "wrote the fixture")
            return
        }
        let result = runProcess(script, [], environment: env)
        t.expect(result.status != 0, "a checksum file without jemalloc fails the build")
        t.expect(result.stderr.contains("lists 0 sources for jemalloc"), "stderr says which component is missing")
        t.expect(!result.stderr.contains("downloading"), "nothing was downloaded first")
    }

    // D. Control: the same fixtures with honest hashes get past verification
    // (and fail later, because the "tarballs" are not tarballs). Without this,
    // A and B would pass for a script that refuses everything.
    do {
        let dir = TempDir("tmux-build-honest")
        defer { dir.cleanup() }
        guard let env = fixture(in: dir, hash: { $0 }) else {
            t.expect(false, "wrote the fixture")
            return
        }
        let result = runProcess(script, [], environment: env)
        t.expect(result.status != 0, "scratch files are not tarballs, so the build still fails")
        t.expect(!result.stderr.contains("checksum mismatch"), "but not on a checksum")
        t.expect(result.stderr.contains("downloading tmux-9.9z.tar.gz"), "it got as far as fetching and verifying")
    }
}

// MARK: - Scratch bundle

private let scratchInfoPlist = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Scratch</string>
    <key>CFBundleIdentifier</key>
    <string>dev.facens.scratch</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleName</key>
    <string>Scratch</string>
</dict>
</plist>
"""

private let scratchEntitlementsPlist = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.automation.apple-events</key>
    <true/>
</dict>
</plist>
"""

private struct ScratchApp {
    let app: URL
    let cli: URL
    let entitlements: URL
}

/// Builds an unsigned scratch `Scratch.app` — `Contents/MacOS/Scratch`,
/// `Contents/Resources/bin/agentmenu`, `Contents/Info.plist`,
/// `Contents/PkgInfo` — plus the entitlements file scenarios sign with. The
/// two Mach-Os are freshly `clang`-compiled, so before either is signed by
/// this file they carry the linker's own ad-hoc signature
/// (`flags=0x20002(adhoc,linker-signed)`), matching a real unsigned build
/// product.
private func buildScratchAppSkeleton(in dir: TempDir, _ t: TestRunner) -> ScratchApp? {
    do {
        try FileManager.default.createDirectory(
            at: dir.url.appendingPathComponent("Scratch.app/Contents/MacOS"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: dir.url.appendingPathComponent("Scratch.app/Contents/Resources/bin"),
            withIntermediateDirectories: true
        )
    } catch {
        t.expect(false, "created the scratch bundle's directories: \(error)")
        return nil
    }

    do {
        try dir.write(scratchInfoPlist, to: "Scratch.app/Contents/Info.plist")
        try dir.write("APPL????", to: "Scratch.app/Contents/PkgInfo")
        try dir.write(scratchEntitlementsPlist, to: "entitlements.plist")
        try dir.write("int main(void) { return 0; }\n", to: "main.c")
    } catch {
        t.expect(false, "wrote the scratch bundle's fixed files: \(error)")
        return nil
    }

    let mainExecutable = dir.path("Scratch.app/Contents/MacOS/Scratch")
    let cli = dir.path("Scratch.app/Contents/Resources/bin/agentmenu")
    for out in [mainExecutable, cli] {
        let compiled = runProcess("/usr/bin/clang", ["-o", out, dir.path("main.c")])
        guard compiled.status == 0 else {
            t.expect(false, "compiled a trivial Mach-O with clang: \(compiled.stderr)")
            return nil
        }
    }

    return ScratchApp(
        app: dir.url.appendingPathComponent("Scratch.app"),
        cli: URL(fileURLWithPath: cli),
        entitlements: dir.url.appendingPathComponent("entitlements.plist")
    )
}

/// Signs the nested CLI the way `packaging/bundle.sh` does: ad-hoc, its own
/// identifier, and (by default) the hardened runtime. Parameters let a
/// scenario deviate from that shape in exactly the one way it needs to.
@discardableResult
private func signCLI(_ cli: URL, hardenedRuntime: Bool = true, entitlements: URL? = nil) -> CLIResult {
    var args = ["--force"]
    if hardenedRuntime { args += ["--options", "runtime"] }
    args += ["--sign", "-", "--timestamp=none"]
    if let entitlements { args += ["--entitlements", entitlements.path] }
    args += ["--identifier", "dev.facens.scratch.cli", cli.path]
    return runProcess("/usr/bin/codesign", args)
}

/// Signs the app the way `packaging/bundle.sh` does: ad-hoc, the hardened
/// runtime, and (normally) the automation entitlement.
@discardableResult
private func signApp(_ app: URL, entitlements: URL?) -> CLIResult {
    var args = ["--force", "--options", "runtime", "--sign", "-", "--timestamp=none"]
    if let entitlements { args += ["--entitlements", entitlements.path] }
    args.append(app.path)
    return runProcess("/usr/bin/codesign", args)
}

/// Adds the session host's two helpers to the scratch bundle: freshly compiled
/// Mach-Os in `Contents/Helpers`, one under the plain name and one under a name
/// with spaces, as `packaging/bundle.sh` ships them. Left linker-signed, like
/// every other fresh compile here.
private func addHelpers(to app: ScratchApp, in dir: TempDir, _ t: TestRunner) -> [URL]? {
    let helpersDir = dir.url.appendingPathComponent("Scratch.app/Contents/Helpers")
    do {
        try FileManager.default.createDirectory(at: helpersDir, withIntermediateDirectories: true)
    } catch {
        t.expect(false, "created Contents/Helpers: \(error)")
        return nil
    }
    var helpers: [URL] = []
    for name in ["tmux", "AgentMenu Session Host"] {
        let url = helpersDir.appendingPathComponent(name)
        let compiled = runProcess("/usr/bin/clang", ["-o", url.path, dir.path("main.c")])
        guard compiled.status == 0 else {
            t.expect(false, "compiled the helper \(name): \(compiled.stderr)")
            return nil
        }
        helpers.append(url)
    }
    return helpers
}

/// Signs a helper the way `packaging/bundle.sh` does: ad-hoc, its own
/// identifier, the hardened runtime and, unless a scenario says otherwise, no
/// entitlements.
@discardableResult
private func signHelper(_ helper: URL, entitlements: URL? = nil) -> CLIResult {
    var args = ["--force", "--options", "runtime", "--sign", "-", "--timestamp=none"]
    if let entitlements { args += ["--entitlements", entitlements.path] }
    let slug = helper.lastPathComponent.lowercased().replacingOccurrences(of: " ", with: "-")
    args += ["--identifier", "dev.facens.scratch.helper.\(slug)", helper.path]
    return runProcess("/usr/bin/codesign", args)
}
