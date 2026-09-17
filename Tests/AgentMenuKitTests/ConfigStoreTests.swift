// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AgentMenuKit

/// `TempDir`'s path lives under `NSTemporaryDirectory()`, which on macOS is
/// `/var/folders/...` — and `/var` is a symlink to `/private/var`. Comparing
/// a raw `TempDir` path string against a value that went through
/// `FolderTarget.normalizedPath` (which resolves symlinks) fails for the
/// wrong reason unless both sides go through the same resolution.
private func resolvedPath(_ path: String) -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().path
}

private func readBytes(_ url: URL) -> Data? {
    try? Data(contentsOf: url)
}

func runConfigStoreTests(_ t: TestRunner) {
    t.suite("ConfigStore")

    // MARK: 1. Global default only, no folders, round-trips unchanged

    do {
        let dir = TempDir("configstore-roundtrip1")
        defer { dir.cleanup() }
        let store = ConfigStore(url: URL(fileURLWithPath: dir.path("config.toml")))

        var config = Config()
        config.defaults = Preset(agent: "claude-code", terminal: "iterm2", model: "opus", effort: "high")

        t.expectNoThrow("save config with only global default") { try store.save(config) }
        if let reloaded = t.attempt("reload after saving global-default-only config", { try store.load() }) {
            t.expectEqual(reloaded, config, "global-default-only config round-trips unchanged")
        }
    }

    // MARK: 2. Folder preset: model set, effort absent stays absent

    do {
        let dir = TempDir("configstore-roundtrip2")
        defer { dir.cleanup() }
        let store = ConfigStore(url: URL(fileURLWithPath: dir.path("config.toml")))

        var config = Config()
        var folder = FolderTarget(label: "Hub", path: "/tmp/hub-does-not-exist")
        folder.preset.model = "opus"
        config.folders = [folder]

        t.expectNoThrow("save config with a folder that sets model only") { try store.save(config) }
        if let reloaded = t.attempt("reload folder with model set", { try store.load() }) {
            t.expectEqual(reloaded?.folders.count, 1, "one folder came back")
            t.expectEqual(reloaded?.folders.first?.preset.model, "opus", "model round-tripped")
            t.expectEqual(reloaded?.folders.first?.preset.effort, nil, "effort is still absent, not defaulted")
        }
    }

    // MARK: 3. Unknown keys survive a save, in position — root, [defaults], and a [[folders]] entry

    do {
        let dir = TempDir("configstore-unknown-keys")
        defer { dir.cleanup() }
        let configURL = URL(fileURLWithPath: dir.path("config.toml"))
        let store = ConfigStore(url: configURL)

        let originalText = """
        schema = 1
        active_profile = "work"
        future_root_key = "kept"

        [defaults]
        agent = "claude-code"
        future_defaults_key = "kept-too"
        model = "opus"

        [[folders]]
        label = "Hub"
        path = "/tmp/hub-unknown-keys"
        future_folder_key = "kept-three"
        model = "sonnet"
        """
        t.expectNoThrow("write original config with unknown keys") { try dir.write(originalText, to: "config.toml") }

        guard let loadedOptional = t.attempt("load config with unknown keys", { try store.load() }),
              let loaded = loadedOptional else {
            t.expect(false, "load of unknown-keys config unexpectedly returned nil")
            return
        }
        var config = loaded
        // Change something real, to prove the unknown keys survive an actual
        // mutation-and-save, not just a no-op round trip.
        config.defaults.effort = "high"
        config.folders[0].preset.effort = "medium"

        t.expectNoThrow("save mutated config back") { try store.save(config) }

        guard let rewritten = t.attempt("re-parse the rewritten file directly", { try TOMLDocument.parse(contentsOf: configURL) }) else { return }

        t.expect(rewritten.root["future_root_key"]?.stringValue == "kept", "unknown root key value survived")
        t.expectEqual(
            rewritten.root.keys,
            ["schema", "active_profile", "future_root_key", "defaults", "folders"],
            "unknown root key kept its position among siblings"
        )

        let defaultsTable = rewritten.root["defaults"]?.tableValue
        t.expect(defaultsTable?["future_defaults_key"]?.stringValue == "kept-too", "unknown [defaults] key value survived")
        t.expectEqual(
            defaultsTable?.keys,
            ["agent", "future_defaults_key", "model", "effort"],
            "unknown [defaults] key kept its position; new 'effort' key appended"
        )

        let folderTable = rewritten.root["folders"]?.arrayValue?.first?.tableValue
        t.expect(folderTable?["future_folder_key"]?.stringValue == "kept-three", "unknown [[folders]] key value survived")
        t.expectEqual(
            folderTable?.keys,
            ["label", "path", "future_folder_key", "model", "id", "effort"],
            "unknown [[folders]] key kept its position; the migrated 'id' and the new 'effort' key are appended"
        )

        // And the values the app does understand actually changed.
        if let reloaded = t.attempt("reload after the mutation-and-save", { try store.load() }) {
            t.expectEqual(reloaded?.defaults.effort, "high", "the real mutation to [defaults] took effect")
            t.expectEqual(reloaded?.folders.first?.preset.effort, "medium", "the real mutation to the folder took effect")
        }
    }

    // MARK: 4. Malformed TOML is reported, and the file is left untouched

    do {
        let dir = TempDir("configstore-malformed")
        defer { dir.cleanup() }
        let configURL = URL(fileURLWithPath: dir.path("config.toml"))
        let store = ConfigStore(url: configURL)

        let malformed = "schema = 1\n[defaults\nagent = \"claude-code\"\n"
        t.expectNoThrow("write malformed config") { try dir.write(malformed, to: "config.toml") }
        let before = readBytes(configURL)

        t.expectThrows("load of malformed TOML throws") { try store.load() }

        do {
            _ = try store.load()
        } catch let error as ConfigError {
            if case .parse = error {
                t.expect(true, "malformed TOML is reported as ConfigError.parse")
            } else {
                t.expect(false, "malformed TOML reported the wrong ConfigError case: \(error)")
            }
        } catch {
            t.expect(false, "malformed TOML threw the wrong error type: \(error)")
        }

        let after = readBytes(configURL)
        t.expectEqual(after, before, "the file's bytes are unchanged after a failed load")
    }

    // MARK: 5. Concurrent writes never leave a partial file

    do {
        let dir = TempDir("configstore-concurrent")
        defer { dir.cleanup() }
        let configURL = URL(fileURLWithPath: dir.path("config.toml"))

        var configA = Config()
        configA.defaults = Preset(agent: "claude-code", model: "opus")
        var configB = Config()
        configB.defaults = Preset(agent: "codex", model: "sonnet")

        let iterations = 150
        let group = DispatchGroup()
        var readerFailures: [String] = []
        let readerFailuresLock = NSLock()

        // Each writer gets its own ConfigStore instance — `lastLoadedDocument`
        // is plain mutable state on the class, not synchronized, so two
        // queues must never share one instance.
        let storeA = ConfigStore(url: configURL)
        let storeB = ConfigStore(url: configURL)

        group.enter()
        DispatchQueue.global().async {
            for _ in 0..<iterations { try? storeA.save(configA) }
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            for _ in 0..<iterations { try? storeB.save(configB) }
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            let reader = ConfigStore(url: configURL)
            for _ in 0..<iterations {
                do {
                    if let loaded = try reader.load() {
                        if loaded != configA && loaded != configB {
                            readerFailuresLock.lock()
                            readerFailures.append("read a config matching neither writer's shape")
                            readerFailuresLock.unlock()
                        }
                    }
                    // A read before either writer has written yet — file
                    // absent — is a legal outcome too.
                } catch {
                    readerFailuresLock.lock()
                    readerFailures.append("load() threw during a concurrent write: \(error)")
                    readerFailuresLock.unlock()
                }
            }
            group.leave()
        }
        group.wait()

        t.expect(readerFailures.isEmpty, "no partial or corrupt read during concurrent saves: \(readerFailures.prefix(3))")
    }

    // MARK: 6. schema newer than supported is refused; schema absent is tolerated as 1

    do {
        let dir = TempDir("configstore-schema-high")
        defer { dir.cleanup() }
        let configURL = URL(fileURLWithPath: dir.path("config.toml"))
        let store = ConfigStore(url: configURL)
        t.expectNoThrow("write config with a future schema") { try dir.write("schema = 7\n", to: "config.toml") }

        do {
            _ = try store.load()
            t.expect(false, "loading a too-new schema should throw")
        } catch let error as ConfigError {
            if case .unsupportedSchema(let found, let supported) = error {
                t.expectEqual(found, 7, "unsupportedSchema names the version found")
                t.expectEqual(supported, Config.schemaVersion, "unsupportedSchema names the version supported")
            } else {
                t.expect(false, "wrong ConfigError case for a too-new schema: \(error)")
            }
        } catch {
            t.expect(false, "wrong error type for a too-new schema: \(error)")
        }
    }

    do {
        let dir = TempDir("configstore-schema-absent")
        defer { dir.cleanup() }
        let configURL = URL(fileURLWithPath: dir.path("config.toml"))
        let store = ConfigStore(url: configURL)
        t.expectNoThrow("write config with no schema key at all") {
            try dir.write("[defaults]\nagent = \"claude-code\"\n", to: "config.toml")
        }
        if let loaded = t.attempt("load config with schema absent", { try store.load() }) {
            t.expectEqual(loaded?.defaults.agent, "claude-code", "an absent schema key is tolerated as schema 1")
        }
    }

    // MARK: 7. advisor: absent, "off", and a model name

    do {
        let dir = TempDir("configstore-advisor")
        defer { dir.cleanup() }
        let store = ConfigStore(url: URL(fileURLWithPath: dir.path("config.toml")))

        var config = Config()
        config.defaults = Preset(agent: "claude-code")
        config.folders = [
            FolderTarget(label: "AbsentAdvisor", path: "/tmp/advisor-absent"),
            FolderTarget(label: "OffAdvisor", path: "/tmp/advisor-off", preset: Preset(advisor: .off)),
            FolderTarget(label: "ModelAdvisor", path: "/tmp/advisor-opus", preset: Preset(advisor: .model("opus"))),
        ]

        t.expectNoThrow("save advisor scenarios") { try store.save(config) }
        if let reloaded = t.attempt("reload advisor scenarios", { try store.load() }) {
            let byLabel = Dictionary(uniqueKeysWithValues: (reloaded?.folders ?? []).map { ($0.label, $0) })
            t.expectEqual(byLabel["AbsentAdvisor"]?.preset.advisor, nil, "advisor absent stays absent")
            t.expectEqual(byLabel["OffAdvisor"]?.preset.advisor, .off, "'off' decodes to .off")
            t.expectEqual(byLabel["ModelAdvisor"]?.preset.advisor, .model("opus"), "a model name decodes to .model(_)")
        }

        // And check the raw text: "off" writes back as the bare string "off".
        if let text = try? String(contentsOf: URL(fileURLWithPath: dir.path("config.toml")), encoding: .utf8) {
            t.expect(text.contains(#"advisor = "off""#), "off advisor is written back as the literal string \"off\"")
        }
    }

    // MARK: 8. `~` in config_dir and folder path

    do {
        let dir = TempDir("configstore-tilde")
        defer { dir.cleanup() }
        let store = ConfigStore(url: URL(fileURLWithPath: dir.path("config.toml")))

        var config = Config()
        config.profiles = [Profile(id: "work", name: "Work", configDirectory: "~/.claude")]
        config.folders = [FolderTarget(label: "Home", path: "~/some-project")]

        t.expectNoThrow("save config with tilde paths") { try store.save(config) }
        if let reloaded = t.attempt("reload config with tilde paths", { try store.load() }) {
            let profile = reloaded?.profiles.first
            t.expectEqual(profile?.configDirectory, "~/.claude", "config_dir is still written back with a literal ~")
            t.expectEqual(
                profile?.expandedConfigDirectory.path,
                (("~/.claude" as NSString).expandingTildeInPath),
                "expandedConfigDirectory expands ~ for reading"
            )

            let folder = reloaded?.folders.first
            t.expectEqual(folder?.path, "~/some-project", "folder path is still written back with a literal ~")
            t.expectEqual(
                folder?.expandedPath.path,
                (("~/some-project" as NSString).expandingTildeInPath),
                "expandedPath expands ~ for reading"
            )
        }
    }

    // MARK: 9. Two entries may name one folder, keep their own presets, and round-trip

    do {
        let dir = TempDir("configstore-duplicate-folders")
        defer { dir.cleanup() }
        let configURL = URL(fileURLWithPath: dir.path("config.toml"))
        let store = ConfigStore(url: configURL)

        // Hand-written: no ids at all, and the same folder twice — one entry
        // per account. This is the shape the feature exists for.
        let text = """
        [[folders]]
        label = "First"
        path = "/tmp/configstore-dup/project"
        profile = "work"
        model = "opus"

        [[folders]]
        label = "Second"
        path = "/tmp/configstore-dup/project/"
        profile = "personal"
        model = "sonnet"
        """
        t.expectNoThrow("write config with two folders at the same normalized path") { try dir.write(text, to: "config.toml") }

        guard let loadedOptional = t.attempt("load two entries for one folder", { try store.load() }),
              let loaded = loadedOptional else {
            t.expect(false, "two entries for one folder failed to load")
            return
        }

        t.expectEqual(loaded.folders.count, 2, "both entries for the one folder loaded")
        t.expectEqual(loaded.folders.first?.preset.model, "opus", "the first entry kept its own model")
        t.expectEqual(loaded.folders.last?.preset.model, "sonnet", "the second entry kept its own model")
        t.expectEqual(loaded.folders.first?.profileID, "work", "the first entry kept its own account")
        t.expectEqual(loaded.folders.last?.profileID, "personal", "the second entry kept its own account")
        t.expect(
            loaded.folders.first?.id != loaded.folders.last?.id,
            "entries with no written id are given distinct ids"
        )
        t.expect(
            !(loaded.folders.first?.id.isEmpty ?? true),
            "an entry with no written id is given one rather than an empty string"
        )

        // Ids derived from the file, not minted at random, so the same file
        // loads to the same ids every time — the settings selection and the
        // popover's one-shot overrides are keyed by them.
        if let again = t.attempt("load the same file a second time", { try store.load() }) {
            t.expectEqual(again?.folders.map(\.id), loaded.folders.map(\.id), "ids derived from the file are stable across loads")
        }

        // And the ids are written on the next save, so the entries stop
        // depending on the derivation at all.
        var mutated = loaded
        mutated.folders[1].preset.effort = "high"
        t.expectNoThrow("save the two entries back") { try store.save(mutated) }

        if let rewritten = t.attempt("re-parse the file with two entries", { try TOMLDocument.parse(contentsOf: configURL) }) {
            let tables = rewritten.root["folders"]?.arrayValue?.compactMap { $0.tableValue } ?? []
            t.expectEqual(tables.count, 2, "both entries were written back")
            t.expectEqual(tables.first?["id"]?.stringValue, loaded.folders.first?.id, "the first entry's id was written")
            t.expectEqual(tables.last?["id"]?.stringValue, loaded.folders.last?.id, "the second entry's id was written")
            t.expectEqual(tables.first?["model"]?.stringValue, "opus", "the first entry's preset was not overwritten by the second's")
            t.expectEqual(tables.last?["effort"]?.stringValue, "high", "the edit landed on the second entry")
            t.expect(tables.first?["effort"] == nil, "the edit did not leak onto the first entry")
        }
    }

    // A file whose entries carry the same id is repaired rather than rejected:
    // copy-pasting a [[folders]] block is how a second entry gets made by hand.
    do {
        let dir = TempDir("configstore-duplicate-ids")
        defer { dir.cleanup() }
        let store = ConfigStore(url: URL(fileURLWithPath: dir.path("config.toml")))

        let text = """
        [[folders]]
        id = "same"
        label = "First"
        path = "/tmp/configstore-dup-id/project"

        [[folders]]
        id = "same"
        label = "Second"
        path = "/tmp/configstore-dup-id/project"
        """
        t.expectNoThrow("write config with two entries sharing an id") { try dir.write(text, to: "config.toml") }

        if let loaded = t.attempt("load config with a duplicate id", { try store.load() }) {
            t.expectEqual(loaded?.folders.count, 2, "both entries loaded")
            t.expectEqual(loaded?.folders.first?.id, "same", "the first entry kept the written id")
            t.expect(loaded?.folders.last?.id != "same", "the second entry was given a fresh id")
        }
    }

    do {
        let dir = TempDir("configstore-folder-lookup")
        defer { dir.cleanup() }
        let store = ConfigStore(url: URL(fileURLWithPath: dir.path("config.toml")))

        let projectPath = dir.path("project")
        try? FileManager.default.createDirectory(atPath: projectPath, withIntermediateDirectories: true)

        var config = Config()
        config.folders = [FolderTarget(label: "Project", path: projectPath)]
        t.expectNoThrow("save config for folder lookup") { try store.save(config) }

        if let reloaded = t.attempt("reload config for folder lookup", { try store.load() }) {
            t.expect(reloaded?.folder(forPath: projectPath + "/") != nil, "folder(forPath:) matches with a trailing slash")
            t.expect(reloaded?.folder(forPath: resolvedPath(projectPath)) != nil, "folder(forPath:) matches the resolved path")
            t.expect(reloaded?.folder(forPath: "/tmp/definitely-not-it") == nil, "folder(forPath:) is nil for an unrelated path")
        }
    }

    // MARK: 10. Preset.overlaid(with:)

    do {
        let lower = Preset(agent: "claude-code", model: "sonnet", effort: "medium")
        let upper = Preset(model: "opus", advisor: .model("opus"))
        let merged = lower.overlaid(with: upper)
        t.expectEqual(merged.agent, "claude-code", "a field absent in the upper layer inherits from the lower one")
        t.expectEqual(merged.model, "opus", "a field set in the upper layer wins")
        t.expectEqual(merged.effort, "medium", "another absent-in-upper field still inherits")
        t.expectEqual(merged.advisor, .model("opus"), "a field only the upper layer sets comes through")

        let unchanged = lower.overlaid(with: Preset())
        t.expectEqual(unchanged, lower, "overlaying an empty preset changes nothing")

        let explicitOff = lower.overlaid(with: Preset(advisor: .off))
        t.expectEqual(explicitOff.advisor, .off, "an explicit .off in the upper layer wins over an absent lower value")
    }

    // MARK: 11. Saving a Config() built in memory, with no prior load

    do {
        let dir = TempDir("configstore-fresh-save")
        defer { dir.cleanup() }
        let store = ConfigStore(url: URL(fileURLWithPath: dir.path("config.toml")))

        var config = Config()
        config.activeProfileID = "work"
        config.defaults = Preset(agent: "claude-code")
        config.profiles = [Profile(id: "work", name: "Work", configDirectory: "~/.claude")]
        config.binaries = ["claude": "/usr/local/bin/claude"]

        t.expectNoThrow("save a fresh in-memory Config with no prior load") { try store.save(config) }
        if let reloaded = t.attempt("reload the freshly-saved config", { try store.load() }) {
            t.expectEqual(reloaded, config, "a Config() built in memory writes a file that loads back equal")
        }
    }

    // MARK: 11b. save() with no prior load, over a file that already exists,

    // discards keys this binary does not model — proving the retained-state
    // doc comment on ConfigStore: only a *loaded* document's keys survive.
    do {
        let dir = TempDir("configstore-no-prior-load")
        defer { dir.cleanup() }
        let configURL = URL(fileURLWithPath: dir.path("config.toml"))

        let text = """
        schema = 1
        some_future_key = "would survive a save after load"

        [defaults]
        agent = "claude-code"
        """
        t.expectNoThrow("write pre-existing config with an unrecognised key") { try dir.write(text, to: "config.toml") }

        // A brand-new store, no load() call.
        let store = ConfigStore(url: configURL)
        var config = Config()
        config.defaults = Preset(agent: "codex")
        t.expectNoThrow("save without ever loading first") { try store.save(config) }

        if let rewritten = t.attempt("re-parse after save-without-load", { try TOMLDocument.parse(contentsOf: configURL) }) {
            t.expectEqual(
                rewritten.root["some_future_key"], nil,
                "save() with no prior load has no retained document, so an unmodeled key is not carried forward"
            )
        }
    }

    // MARK: 12. Required-key errors: folder missing path, profile missing id

    do {
        let dir = TempDir("configstore-missing-path")
        defer { dir.cleanup() }
        let store = ConfigStore(url: URL(fileURLWithPath: dir.path("config.toml")))
        t.expectNoThrow("write folder entry missing path") {
            try dir.write("[[folders]]\nlabel = \"No Path\"\n", to: "config.toml")
        }
        do {
            _ = try store.load()
            t.expect(false, "a [[folders]] entry missing path should throw")
        } catch let error as ConfigError {
            if case .invalid(let reason, _) = error {
                t.expect(reason.localizedCaseInsensitiveContains("path"), "reason names the missing 'path' key: \(reason)")
            } else {
                t.expect(false, "wrong ConfigError case for a folder missing path: \(error)")
            }
        } catch {
            t.expect(false, "wrong error type for a folder missing path: \(error)")
        }
    }

    do {
        let dir = TempDir("configstore-missing-id")
        defer { dir.cleanup() }
        let store = ConfigStore(url: URL(fileURLWithPath: dir.path("config.toml")))
        t.expectNoThrow("write profile entry missing id") {
            try dir.write("[[profiles]]\nname = \"No Id\"\n", to: "config.toml")
        }
        do {
            _ = try store.load()
            t.expect(false, "a [[profiles]] entry missing id should throw")
        } catch let error as ConfigError {
            if case .invalid(let reason, _) = error {
                t.expect(reason.localizedCaseInsensitiveContains("id"), "reason names the missing 'id' key: \(reason)")
            } else {
                t.expect(false, "wrong ConfigError case for a profile missing id: \(error)")
            }
        } catch {
            t.expect(false, "wrong error type for a profile missing id: \(error)")
        }
    }

    // MARK: 12b. A profile with no config_dir is rejected rather than
    // silently defaulting to "" -> URL(fileURLWithPath: "") -> the
    // process's own current directory (Config.swift). Before this fix,
    // install-statusline could write settings.json and its script into an
    // arbitrary working directory and exit 0, and the usage readout would
    // silently read from the wrong place too — both because a profile with
    // an absent or empty config_dir loaded without complaint.

    do {
        let dir = TempDir("configstore-missing-config-dir")
        defer { dir.cleanup() }
        let store = ConfigStore(url: URL(fileURLWithPath: dir.path("config.toml")))
        t.expectNoThrow("write a profile entry with an id but no config_dir at all") {
            try dir.write("[[profiles]]\nid = \"work\"\nname = \"Work\"\n", to: "config.toml")
        }
        do {
            _ = try store.load()
            t.expect(false, "a [[profiles]] entry missing config_dir should throw")
        } catch let error as ConfigError {
            if case .invalid(let reason, _) = error {
                t.expect(reason.localizedCaseInsensitiveContains("config_dir"), "reason names the missing 'config_dir' key: \(reason)")
                t.expect(reason.contains("work"), "reason names the offending profile: \(reason)")
            } else {
                t.expect(false, "wrong ConfigError case for a profile missing config_dir: \(error)")
            }
        } catch {
            t.expect(false, "wrong error type for a profile missing config_dir: \(error)")
        }

        let dir2 = TempDir("configstore-empty-config-dir")
        defer { dir2.cleanup() }
        let store2 = ConfigStore(url: URL(fileURLWithPath: dir2.path("config.toml")))
        t.expectNoThrow("write a profile entry with config_dir explicitly empty") {
            try dir2.write("[[profiles]]\nid = \"work\"\nname = \"Work\"\nconfig_dir = \"\"\n", to: "config.toml")
        }
        t.expectThrows("an explicitly empty config_dir is rejected the same as an absent one") {
            _ = try store2.load()
        }
    }

    // MARK: 13. Parent directory is created when missing

    do {
        let dir = TempDir("configstore-missing-parent")
        defer { dir.cleanup() }
        let nestedURL = URL(fileURLWithPath: dir.path("nested/does/not/exist/config.toml"))
        let store = ConfigStore(url: nestedURL)

        var config = Config()
        config.defaults = Preset(agent: "claude-code")
        t.expectNoThrow("save into a config path whose parent directories do not exist yet") { try store.save(config) }
        t.expect(FileManager.default.fileExists(atPath: nestedURL.path), "the file was created along with its parent directories")
    }

    // MARK: 13b. A destination that is a symlink is followed, not replaced

    // Two profile directories sharing one settings.json through a symlink is
    // an ordinary setup, and `replaceItemAt` on the link itself fails with a
    // "file doesn't exist" error naming a file that plainly does exist —
    // which is how `install-statusline --profile personal` failed on the
    // maintainer's machine. Writing through the link is also what keeps the
    // arrangement intact: a new regular file swapped into the link's place
    // would silently split the two profiles apart.
    do {
        let dir = TempDir("configstore-symlinked-destination")
        defer { dir.cleanup() }

        let realURL = URL(fileURLWithPath: dir.path("real/config.toml"))
        let linkURL = URL(fileURLWithPath: dir.path("link.toml"))
        t.expectNoThrow("create the real config and the link pointing at it") {
            try FileManager.default.createDirectory(
                at: realURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try "schema = 1\n".write(to: realURL, atomically: true, encoding: .utf8)
            try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: realURL)
        }

        var config = Config()
        config.defaults = Preset(agent: "claude-code", model: "opus")
        let store = ConfigStore(url: linkURL)
        t.expectNoThrow("save through the symlink") { try store.save(config) }

        let type = (try? FileManager.default.attributesOfItem(atPath: linkURL.path))?[.type] as? FileAttributeType
        t.expectEqual(type, .typeSymbolicLink, "the symlink is still a symlink, not a regular file")
        let written = try? String(contentsOf: realURL, encoding: .utf8)
        t.expect(written?.contains("model = \"opus\"") == true, "the file the link points at is what was written")
    }

    // MARK: 14. Empty Preset and default permission mode

    do {
        t.expect(Preset().isEmpty, "a freshly-initialized Preset is empty")
        t.expect(!Preset(model: "opus").isEmpty, "a Preset with one field set is not empty")
        t.expectEqual(Config().defaults.permissionMode, nil, "the shipped global default does not seed a permission mode")
    }
}
