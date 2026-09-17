// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AgentMenuKit

/// What is already on this machine.
///
/// First run should open with what it found, not with an empty form and a
/// button called "Find". Everything here is a probe of the user's own disk, run
/// off the main thread, and nothing it returns is applied without the user
/// seeing it.
enum Detection {
    struct AgentHit: Identifiable, Equatable {
        let manifest: AgentManifest
        let path: String?
        var id: String { manifest.id }
        var found: Bool { path != nil }
    }

    /// Resolves a set of binary names to paths.
    ///
    /// Takes plain values rather than the registry: the registry is a mutable
    /// class the main actor owns, and reading it from a background queue while
    /// it can be reloaded is a race, not a warning to silence. The caller
    /// snapshots what it needs on the main thread and matches the answers back
    /// up by id.
    ///
    /// Blocking — call it off the main thread; every miss costs one login-shell
    /// spawn.
    static func binaries(
        for probes: [(id: String, binary: String)],
        cache: [String: String]
    ) -> [String: String] {
        let resolver = BinaryResolver()
        var found: [String: String] = [:]
        for probe in probes {
            if let path = try? resolver.resolve(probe.binary, cached: cache[probe.binary]) {
                found[probe.id] = path
            }
        }
        return found
    }

    struct TerminalHit: Identifiable, Equatable {
        let manifest: TerminalManifest
        let installed: Bool
        var id: String { manifest.id }
    }

    static func terminals(in registry: ManifestRegistry, config: Config) -> [TerminalHit] {
        registry.terminals.map { manifest in
            let path = manifest.binary.flatMap { config.binaries[$0] }
            let availability = registry.availability(of: manifest, config: config, binaryPath: path)
            // An unconfirmed or disabled manifest is still *installed*; that is
            // a different question from whether it may be used, and first run
            // is asking the first one.
            let installed: Bool
            switch availability {
            case .applicationMissing, .binaryMissing: installed = false
            default: installed = true
            }
            return TerminalHit(manifest: manifest, installed: installed)
        }
    }

    /// The accounts this machine actually has.
    ///
    /// An account is a configuration directory the agent can run against, and
    /// the only honest way to find them is to look: the agent's own default
    /// directory, plus any sibling of the form `<default>-<something>`. The
    /// names come from the directories themselves — "work" and "personal" are
    /// one person's arrangement, not a concept the app should impose on
    /// everyone. Most machines have exactly one, and then there is nothing to
    /// ask and no switch to show (R16).
    static func profiles(
        for agent: AgentManifest?,
        fileManager: FileManager = .default
    ) -> [Profile] {
        let home = fileManager.homeDirectoryForCurrentUser
        // Where an agent keeps its configuration is not in the manifest, and
        // guessing from a display name is worse than guessing from the id: the
        // id is what the manifest author controls. `claude-code` keeps
        // `~/.claude`, `opencode` keeps `~/.opencode` — the leading word.
        let defaultLeaf = agent.map { "." + ($0.id.split(separator: "-").first.map(String.init) ?? $0.id) } ?? ".claude"

        guard let entries = try? fileManager.contentsOfDirectory(atPath: home.path) else {
            return [Profile(id: "default", name: "Default", configDirectory: "~/\(defaultLeaf)")]
        }

        var found: [Profile] = []
        for leaf in entries.sorted() where leaf == defaultLeaf || leaf.hasPrefix(defaultLeaf + "-") {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: home.appendingPathComponent(leaf).path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            let suffix = leaf == defaultLeaf ? "" : String(leaf.dropFirst(defaultLeaf.count + 1))
            let id = suffix.isEmpty ? "default" : suffix
            found.append(Profile(id: id, name: displayName(for: id), configDirectory: "~/\(leaf)"))
        }

        return found.isEmpty
            ? [Profile(id: "default", name: "Default", configDirectory: "~/\(defaultLeaf)")]
            : found
    }

    /// `personal` -> `Personal`. A name the user can change, not a category the
    /// app decided they belong to.
    private static func displayName(for id: String) -> String {
        id == "default" ? "Default" : id.prefix(1).uppercased() + id.dropFirst()
    }

    /// Whether the launcher this app replaces left a list worth importing.
    /// Nobody else has this file, so nobody else should be asked about it.
    static func foldersConfExists(fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: NSString(string: FoldersConfImport.defaultSourcePath).expandingTildeInPath)
    }

    /// R11: model and advisor read once from the agent's own settings file, so
    /// the app starts on the values already in use rather than on ours.
    static func seedPreset(_ preset: Preset, from agent: AgentManifest, profile: Profile) -> Preset {
        var seeded = preset
        guard let url = agent.settingsFileURL(profileDirectory: profile.expandedConfigDirectory),
              let data = try? Data(contentsOf: url),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return seeded }

        if let key = agent.model?.seedFromSettings,
           let value = json[key] as? String,
           agent.model?.accepts(value) == true {
            seeded.model = value
        }
        if let key = agent.advisor?.seedFromSettings, let value = json[key] as? String {
            seeded.advisor = value.isEmpty ? .off : .model(value)
        }
        return seeded
    }

    /// Folders worth offering: a git checkout one level under the places people
    /// actually keep code, plus whatever Finder has in front.
    ///
    /// One level only, and capped — walking a home directory is how a setup
    /// screen becomes a spinner, and a list of forty checkboxes is the blank
    /// page in a different costume.
    static func projectFolders(
        limit: Int = 12,
        fileManager: FileManager = .default
    ) -> [String] {
        let home = fileManager.homeDirectoryForCurrentUser
        let roots = ["dev", "Developer", "Projects", "projects", "code", "src", "work"]
            .map { home.appendingPathComponent($0) }

        var found: [String] = []
        for root in roots {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  let entries = try? fileManager.contentsOfDirectory(
                      at: root,
                      includingPropertiesForKeys: [.isDirectoryKey],
                      options: [.skipsHiddenFiles]
                  ) else { continue }

            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard found.count < limit else { break }
                let git = entry.appendingPathComponent(".git")
                if fileManager.fileExists(atPath: git.path) {
                    found.append(PathDisplay.abbreviated(entry.path))
                }
            }
        }
        return found
    }
}
