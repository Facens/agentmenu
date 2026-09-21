// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Reads and writes `~/.config/agentmenu/config.toml`.
///
/// `ConfigStore` is a class, not a struct, because it retains the
/// `TOMLDocument` it last parsed. That retained document is how a key this
/// binary does not recognise survives a save: `save(_:)` starts from it and
/// overwrites only the keys `Config` models, leaving everything else where
/// it was. Do not "simplify" this into a struct or drop the retained state —
/// a store that only ever encoded `Config` from scratch would silently strip
/// a newer version's keys on every write, which is exactly what the format
/// promises hand-editing users it will not do.
///
/// A store that calls `save` without a prior successful `load` — or whose
/// file did not exist at the time of that load — has no retained document,
/// so it writes a fresh one built only from `Config`'s own fields.
public final class ConfigStore {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/agentmenu/config.toml")
    }

    public let url: URL

    private var lastLoadedDocument: TOMLDocument?

    public init(url: URL = ConfigStore.defaultURL) {
        self.url = url
    }

    public var exists: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// nil when the file does not exist — a first run, not an error. Throws
    /// on malformed TOML, a schema this binary does not support, or a file
    /// that parses but violates the config format's own rules. Never writes
    /// anything: a failed load leaves the file exactly as it was.
    public func load() throws -> Config? {
        guard exists else { return nil }
        let document: TOMLDocument
        do {
            document = try TOMLDocument.parse(contentsOf: url)
        } catch let error as TOMLError {
            throw ConfigError.parse(error)
        } catch {
            throw ConfigError.unreadable(underlying: String(describing: error))
        }
        let config = try ConfigCodec.decode(document.root)
        lastLoadedDocument = document
        return config
    }

    /// Writes atomically via `AtomicFile` — the same helper
    /// `StatuslineBridge.atomicWrite` uses — so a reader only ever sees the
    /// fully-old or fully-new file, never a partial one, and a failed write
    /// leaves the previous file untouched. Creates the parent directory when
    /// it is missing.
    public func save(_ config: Config) throws {
        let baseRoot = lastLoadedDocument?.root ?? TOMLTable()
        let newRoot = ConfigCodec.encode(config, into: baseRoot)
        let text = TOMLDocument(root: newRoot).serialized()

        guard let data = text.data(using: .utf8) else {
            throw ConfigError.write(underlying: "could not encode config.toml as UTF-8")
        }

        do {
            try AtomicFile.write(data, to: url)
        } catch {
            throw ConfigError.write(underlying: String(describing: error))
        }

        lastLoadedDocument = TOMLDocument(root: newRoot)
    }
}

/// The mapping between `Config` and the TOML tree. Kept separate from the
/// model types in Config.swift/Preset.swift so those stay plain data.
enum ConfigCodec {
    private static let presetStringKeys: [(String, WritableKeyPath<Preset, String?>)] = [
        ("agent", \Preset.agent),
        ("terminal", \Preset.terminal),
        ("profile", \Preset.profile),
        ("model", \Preset.model),
        ("effort", \Preset.effort),
        ("permission_mode", \Preset.permissionMode),
    ]

    // MARK: - Decode

    static func decode(_ root: TOMLTable) throws -> Config {
        if let schemaValue = root["schema"] {
            guard let schema = schemaValue.intValue else {
                throw ConfigError.invalid(reason: "'schema' must be an integer", line: nil)
            }
            if schema > Config.schemaVersion {
                throw ConfigError.unsupportedSchema(found: schema, supported: Config.schemaVersion)
            }
        }

        var config = Config()
        config.activeProfileID = root["active_profile"]?.stringValue
        config.firstRunCompleted = root["first_run_completed"]?.boolValue ?? false
        config.defaults = decodePreset(root["defaults"]?.tableValue ?? TOMLTable())
        config.betaUpdates = root["updates"]?.tableValue?["beta"]?.boolValue

        if let profilesArray = root["profiles"]?.arrayValue {
            config.profiles = try profilesArray.map { value in
                guard let table = value.tableValue else {
                    throw ConfigError.invalid(reason: "a [[profiles]] entry is not a table", line: nil)
                }
                return try decodeProfile(table)
            }
        }

        if let foldersArray = root["folders"]?.arrayValue {
            // Two entries on one path are allowed — one folder on two
            // accounts, or on two models, is the reason the id exists. What
            // has to be unique is the id, and a file that does not deliver
            // that is repaired rather than rejected: the format is meant to
            // be hand-edited (KTD2), and copy-pasting a [[folders]] block is
            // the obvious way to make a second entry by hand.
            var taken: Set<String> = []
            config.folders = try foldersArray.map { value in
                guard let table = value.tableValue else {
                    throw ConfigError.invalid(reason: "a [[folders]] entry is not a table", line: nil)
                }
                return try decodeFolder(table, taken: &taken)
            }
        }

        config.binaries = decodeStringTable(root["binaries"]?.tableValue)
        config.agentState = decodeComponentStates(root["agents"]?.tableValue)
        config.terminalState = decodeComponentStates(root["terminals"]?.tableValue)

        return config
    }

    private static func decodePreset(_ table: TOMLTable) -> Preset {
        var preset = Preset()
        for (key, path) in presetStringKeys {
            preset[keyPath: path] = table[key]?.stringValue
        }
        if let advisorValue = table["advisor"]?.stringValue {
            preset.advisor = advisorValue == "off" ? .off : .model(advisorValue)
        }
        return preset
    }

    private static func decodeProfile(_ table: TOMLTable) throws -> Profile {
        guard let id = table["id"]?.stringValue else {
            throw ConfigError.invalid(reason: "a [[profiles]] entry is missing required key 'id'", line: nil)
        }
        // An absent or empty config_dir used to default to "" -> the
        // process's own current directory (Config.swift:
        // `URL(fileURLWithPath: "")`), so a profile with no configuration
        // directory silently redirected every write (install-statusline's
        // settings.json / statusline script) and every read (the usage
        // snapshot) into wherever AgentMenu happened to be launched from,
        // exiting 0 either way. A profile must name one explicitly, the same
        // way a [[folders]] entry must name a path.
        guard let configDirectory = table["config_dir"]?.stringValue, !configDirectory.isEmpty else {
            throw ConfigError.invalid(
                reason: "profile '\(id)' is missing required key 'config_dir'", line: nil
            )
        }
        return Profile(
            id: id,
            name: table["name"]?.stringValue ?? "",
            configDirectory: configDirectory
        )
    }

    private static func decodeFolder(_ table: TOMLTable, taken: inout Set<String>) throws -> FolderTarget {
        guard let path = table["path"]?.stringValue else {
            throw ConfigError.invalid(reason: "a [[folders]] entry is missing required key 'path'", line: nil)
        }
        let written = table["id"]?.stringValue
        let id: String
        if let written, !written.isEmpty, !taken.contains(written) {
            id = written
        } else {
            id = FolderTarget.derivedID(path: path, taken: taken)
        }
        taken.insert(id)
        let label = table["label"]?.stringValue ?? ""
        let preset = decodePreset(table)
        return FolderTarget(id: id, label: label, path: path, preset: preset)
    }

    private static func decodeStringTable(_ table: TOMLTable?) -> [String: String] {
        guard let table else { return [:] }
        var result: [String: String] = [:]
        for key in table.keys {
            if let value = table[key]?.stringValue {
                result[key] = value
            }
        }
        return result
    }

    private static func decodeComponentStates(_ table: TOMLTable?) -> [String: ComponentState] {
        guard let table else { return [:] }
        var result: [String: ComponentState] = [:]
        for id in table.keys {
            guard let sub = table[id]?.tableValue else { continue }
            result[id] = ComponentState(enabled: sub["enabled"]?.boolValue, trusted: sub["trusted"]?.boolValue)
        }
        return result
    }

    // MARK: - Encode

    static func encode(_ config: Config, into baseRoot: TOMLTable) -> TOMLTable {
        var root = baseRoot

        root.set(.integer(Config.schemaVersion), at: ["schema"])
        setOrRemove(&root, "active_profile", config.activeProfileID.map(TOMLValue.string))

        if config.firstRunCompleted {
            root.set(.boolean(true), at: ["first_run_completed"])
        } else {
            root.removeValue(forKey: "first_run_completed")
        }

        var defaultsTable = root["defaults"]?.tableValue ?? TOMLTable()
        encodePreset(config.defaults, into: &defaultsTable)
        setOrRemoveTable(&root, "defaults", defaultsTable)

        // Written once the user has said either way, and absent until then
        // — the file records a decision, not a derived default, so a fresh
        // config carries no `[updates]` section at all and a beta build's
        // on-by-default behaviour stays a property of the build rather than
        // of the file (KTD20). `setOrRemoveTable` drops the section when the
        // key goes.
        var updatesTable = root["updates"]?.tableValue ?? TOMLTable()
        if let beta = config.betaUpdates {
            updatesTable.set(.boolean(beta), at: ["beta"])
        } else {
            updatesTable.removeValue(forKey: "beta")
        }
        setOrRemoveTable(&root, "updates", updatesTable)

        if config.profiles.isEmpty {
            root.removeValue(forKey: "profiles")
        } else {
            let existing = root["profiles"]?.arrayValue ?? []
            root.set(.array(encodeProfiles(config.profiles, existing: existing)), at: ["profiles"])
        }

        if config.folders.isEmpty {
            root.removeValue(forKey: "folders")
        } else {
            let existing = root["folders"]?.arrayValue ?? []
            root.set(.array(encodeFolders(config.folders, existing: existing)), at: ["folders"])
        }

        let binariesTable = encodeStringTable(config.binaries, into: root["binaries"]?.tableValue ?? TOMLTable())
        setOrRemoveTable(&root, "binaries", binariesTable)

        let agentsTable = encodeComponentStates(config.agentState, into: root["agents"]?.tableValue ?? TOMLTable())
        setOrRemoveTable(&root, "agents", agentsTable)

        let terminalsTable = encodeComponentStates(config.terminalState, into: root["terminals"]?.tableValue ?? TOMLTable())
        setOrRemoveTable(&root, "terminals", terminalsTable)

        return root
    }

    private static func encodePreset(_ preset: Preset, into table: inout TOMLTable) {
        for (key, path) in presetStringKeys {
            setOrRemove(&table, key, preset[keyPath: path].map(TOMLValue.string))
        }
        switch preset.advisor {
        case nil:
            table.removeValue(forKey: "advisor")
        case .off:
            table.set(.string("off"), at: ["advisor"])
        case .model(let model):
            table.set(.string(model), at: ["advisor"])
        }
    }

    /// Matches existing array-of-tables entries to the in-memory list by id
    /// so a table an entry already had keeps any key this binary does not
    /// recognise; entries with no match in `existing` start from a fresh
    /// table.
    private static func encodeProfiles(_ profiles: [Profile], existing: [TOMLValue]) -> [TOMLValue] {
        var byID: [String: TOMLTable] = [:]
        for element in existing {
            if case .table(let table) = element, let id = table["id"]?.stringValue {
                byID[id] = table
            }
        }
        return profiles.map { profile in
            var table = byID[profile.id] ?? TOMLTable()
            table.set(.string(profile.id), at: ["id"])
            table.set(.string(profile.name), at: ["name"])
            table.set(.string(profile.configDirectory), at: ["config_dir"])
            return .table(table)
        }
    }

    /// Folders match by id, with one fallback: a table carrying no `id` at
    /// all is matched by path, first unclaimed one wins. That fallback is
    /// what carries a file written before ids existed through its first save
    /// — the ids were minted in memory at load, so the retained document's
    /// tables have none, and an id-only match would treat every folder as
    /// new and drop the unrecognised keys this whole mechanism exists to
    /// keep.
    private static func encodeFolders(_ folders: [FolderTarget], existing: [TOMLValue]) -> [TOMLValue] {
        var byID: [String: TOMLTable] = [:]
        var idlessByPath: [String: [TOMLTable]] = [:]
        for element in existing {
            guard case .table(let table) = element else { continue }
            if let id = table["id"]?.stringValue, !id.isEmpty {
                byID[id] = table
            } else if let path = table["path"]?.stringValue {
                idlessByPath[FolderTarget.normalize(path), default: []].append(table)
            }
        }
        return folders.map { folder in
            var table: TOMLTable
            if let matched = byID[folder.id] {
                table = matched
            } else if var candidates = idlessByPath[folder.normalizedPath], !candidates.isEmpty {
                table = candidates.removeFirst()
                idlessByPath[folder.normalizedPath] = candidates
            } else {
                table = TOMLTable()
            }
            table.set(.string(folder.id), at: ["id"])
            table.set(.string(folder.label), at: ["label"])
            table.set(.string(folder.path), at: ["path"])
            encodePreset(folder.preset, into: &table)
            return .table(table)
        }
    }

    private static func encodeStringTable(_ values: [String: String], into base: TOMLTable) -> TOMLTable {
        var table = base
        for key in table.keys where values[key] == nil {
            table.removeValue(forKey: key)
        }
        for key in values.keys.sorted() {
            table.set(.string(values[key]!), at: [key])
        }
        return table
    }

    private static func encodeComponentStates(_ states: [String: ComponentState], into base: TOMLTable) -> TOMLTable {
        var table = base
        for id in table.keys where states[id] == nil {
            table.removeValue(forKey: id)
        }
        for id in states.keys.sorted() {
            var sub = table[id]?.tableValue ?? TOMLTable()
            let state = states[id]!
            setOrRemove(&sub, "enabled", state.enabled.map(TOMLValue.boolean))
            setOrRemove(&sub, "trusted", state.trusted.map(TOMLValue.boolean))
            table.set(.table(sub), at: [id])
        }
        return table
    }

    // MARK: - Helpers

    private static func setOrRemove(_ table: inout TOMLTable, _ key: String, _ value: TOMLValue?) {
        if let value {
            table.set(value, at: [key])
        } else {
            table.removeValue(forKey: key)
        }
    }

    /// A section that ended up with no keys at all — no known field set, no
    /// unrecognised key carried over — is dropped rather than written as an
    /// empty `[section]`, so a fresh config doesn't ship clutter the user
    /// never asked for.
    private static func setOrRemoveTable(_ root: inout TOMLTable, _ key: String, _ table: TOMLTable) {
        if table.isEmpty {
            root.removeValue(forKey: key)
        } else {
            root.set(.table(table), at: [key])
        }
    }
}
