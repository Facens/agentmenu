// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A saved account: an id AgentMenu's own data references, plus the config
/// directory the agent should be pointed at when this profile is active
/// (R14, R15).
public struct Profile: Equatable {
    public let id: String
    public var name: String
    /// As written in the file — may start with `~`. Never rewritten to an
    /// absolute path behind the user's back.
    public var configDirectory: String

    public init(id: String, name: String, configDirectory: String) {
        self.id = id
        self.name = name
        self.configDirectory = configDirectory
    }

    public var expandedConfigDirectory: URL {
        URL(fileURLWithPath: (configDirectory as NSString).expandingTildeInPath)
    }
}

/// A launch target: a folder plus the preset layer that overrides the global
/// default for launches into it (R8).
///
/// Several entries may name the same folder. That is the point: one row for
/// the Hub on the work account and another on the personal one, or the same
/// project on opus and on sonnet, differ in one preset value and nothing
/// else. So an entry's identity is its own `id`, never its path — see `id`.
public struct FolderTarget: Equatable {
    /// The entry's stable handle, written to the file as `id`.
    ///
    /// It exists because the path cannot do the job any more: `ConfigCodec`
    /// matches each in-memory entry against the table it was parsed from so a
    /// key this binary does not recognise survives a save, and with two
    /// entries on one path a path match collapses them and loses one side's
    /// unknown keys. Matching by position instead would break on reorder,
    /// which is a feature the folder list advertises. An id is the only
    /// handle that survives both.
    public let id: String
    public var label: String
    /// As written in the file — may start with `~`.
    public var path: String
    public var preset: Preset

    public init(
        id: String = FolderTarget.makeID(),
        label: String,
        path: String,
        profileID: String? = nil,
        preset: Preset = Preset()
    ) {
        self.id = id
        self.label = label
        self.path = path
        self.preset = preset
        self.preset.profile = self.preset.profile ?? profileID
    }

    /// A fresh id for an entry the user just created. Random, because nothing
    /// about a new row is stable enough to derive one from — two rows on one
    /// path with one preset difference would derive the same id.
    public static func makeID() -> String { UUID().uuidString.lowercased() }

    /// The id a hand-written entry with no `id` key is given on load.
    ///
    /// Derived from the path and a disambiguating index rather than random,
    /// so a file with no ids loads to the same ids every time — the settings
    /// selection and the popover's one-shot overrides are keyed by id, and
    /// ids that churned between loads would move both.
    public static func derivedID(path: String, taken: Set<String>) -> String {
        // The last component, not the whole path: these ids are read and
        // typed by whoever hand-edits the file, and a 48-character slug of an
        // absolute path is neither.
        let normalized = (normalize(path) as NSString).lastPathComponent
        let slug = normalized
            .lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { result, character in
                if character == "-" && result.hasSuffix("-") { return }
                result.append(character)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let base = slug.isEmpty ? "folder" : String(slug.prefix(48))
        if !taken.contains(base) { return base }
        var suffix = 2
        while taken.contains("\(base)-\(suffix)") { suffix += 1 }
        return "\(base)-\(suffix)"
    }

    /// `profileID` is not separate storage from `preset.profile` — the file
    /// format has exactly one `profile` key per folder entry, and it is one
    /// of the seven preset fields (KTD6: a folder's profile is just another
    /// value that can inherit from the global default). This forwards to
    /// `preset.profile` so there is one source of truth and no divergence
    /// case to reconcile on save.
    public var profileID: String? {
        get { preset.profile }
        set { preset.profile = newValue }
    }

    public var expandedPath: URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    /// The folder this entry points at: symlinks resolved where the path
    /// exists, trailing slash removed. Not the entry's identity — `~/Hub`,
    /// `/Users/me/Hub` and `/Users/me/Hub/` are one folder, and several
    /// entries are allowed to name it.
    public var normalizedPath: String { FolderTarget.normalize(path) }

    static func normalize(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        var resolved = URL(fileURLWithPath: expanded).resolvingSymlinksInPath().path
        if resolved.count > 1, resolved.hasSuffix("/") {
            resolved.removeLast()
        }
        return resolved
    }
}

/// User state for one agent or terminal manifest: whether the user has
/// enabled it (R19) or confirmed trust in an untrusted overlay manifest
/// (R44). `nil` in either field means "follow the manifest's own value" —
/// the user has not overridden it.
public struct ComponentState: Equatable {
    public var enabled: Bool?
    public var trusted: Bool?

    public init(enabled: Bool? = nil, trusted: Bool? = nil) {
        self.enabled = enabled
        self.trusted = trusted
    }
}

/// Everything `ConfigStore` reads from and writes to `config.toml`.
public struct Config: Equatable {
    /// The schema version this binary understands. Not a stored field on
    /// `Config` itself — the file's `schema` key is validated against this on
    /// load and always stamped with this value on save; there is nothing for
    /// `Config` to carry between the two.
    public static let schemaVersion = 1

    public var activeProfileID: String?
    public var firstRunCompleted: Bool
    public var defaults: Preset
    public var profiles: [Profile]
    public var folders: [FolderTarget]
    /// Binary name -> resolved absolute path (R22, KTD5).
    public var binaries: [String: String]
    public var agentState: [String: ComponentState]
    public var terminalState: [String: ComponentState]
    /// `[updates] beta` — whether this copy is offered beta releases (KTD20).
    ///
    /// Sparkle keeps no channel preference of its own, so this is the only
    /// copy of the answer, and it is deliberately tri-state: nil means the
    /// user has never said, and then `UpdatePolicy.defaultBetaPreference`
    /// derives it from the running build — on for a beta, off otherwise. A
    /// beta tester is already on that channel, and defaulting them off would
    /// hide the one update they are actually waiting for.
    ///
    /// Storing the derived answer instead would be the mirroring KTD8
    /// forbids: the file would then say "beta = true" for a copy that is
    /// only on betas because of the build it happens to be, and would keep
    /// saying it after that copy updated to a final.
    public var betaUpdates: Bool?

    /// The shipped empty configuration: no profiles, no folders, an empty
    /// global default. In particular `defaults.permissionMode` is nil, not
    /// seeded with a bypassing value — R7 says a bypassing mode is only ever
    /// a value the user sets.
    public init() {
        activeProfileID = nil
        firstRunCompleted = false
        defaults = Preset()
        profiles = []
        folders = []
        binaries = [:]
        agentState = [:]
        terminalState = [:]
        betaUpdates = nil
    }

    public func profile(id: String) -> Profile? {
        profiles.first { $0.id == id }
    }

    /// Matches on normalized path, so `~/Hub`, `/Users/me/Hub`, and
    /// `/Users/me/Hub/` all find the same entry.
    ///
    /// Several entries may name one folder, and this deliberately answers
    /// with the first of them in menu order: its caller (`agentmenu resolve`)
    /// is given a directory and nothing else, so there is no second key to
    /// disambiguate with, and the first row is the one the menu shows first.
    /// A caller that knows which entry it means asks `folder(id:)`.
    public func folder(forPath path: String) -> FolderTarget? {
        let target = FolderTarget.normalize(path)
        return folders.first { $0.normalizedPath == target }
    }

    public func folder(id: String) -> FolderTarget? {
        folders.first { $0.id == id }
    }
}

/// Everything that can go wrong reading or writing `config.toml`.
public enum ConfigError: Error, CustomStringConvertible {
    /// The file is not valid TOML.
    case parse(TOMLError)
    /// The file's `schema` key names a version newer than this binary
    /// understands.
    case unsupportedSchema(found: Int, supported: Int)
    /// The file parses as TOML but violates a rule of the config format —
    /// a required key is missing, or two folders share a normalized path.
    /// `line` is nil when the violation is structural rather than tied to a
    /// single line of source (the parsed document carries no line info).
    case invalid(reason: String, line: Int?)
    /// The file could not be read for a reason other than malformed TOML.
    case unreadable(underlying: String)
    /// The file could not be written.
    case write(underlying: String)

    public var description: String {
        switch self {
        case .parse(let error):
            return "config.toml: \(error)"
        case .unsupportedSchema(let found, let supported):
            return "config.toml: schema \(found) is newer than the \(supported) this version supports"
        case .invalid(let reason, let line):
            if let line {
                return "config.toml line \(line): \(reason)"
            }
            return "config.toml: \(reason)"
        case .unreadable(let underlying):
            return "config.toml could not be read: \(underlying)"
        case .write(let underlying):
            return "config.toml could not be written: \(underlying)"
        }
    }
}
