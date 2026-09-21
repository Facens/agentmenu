// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Where a manifest came from: the app bundle, or the user's own overlay
/// directory. A `.bundled` manifest shipped with the app and is trusted by
/// construction; a `.user` manifest names a binary, an environment variable
/// and static arguments the app never wrote, so R44 marks it untrusted until
/// the user confirms it in settings.
public enum ManifestOrigin: Equatable, Sendable {
    case bundled
    case user
}

/// Everything that can go wrong parsing an agent or terminal manifest.
public enum ManifestError: Error, Equatable, CustomStringConvertible {
    /// The file is not valid TOML.
    case parse(TOMLError)
    /// A key the loader requires is missing. `id` is the manifest's own id
    /// when it was already known at the point of failure — nil when the
    /// missing key is `id` itself.
    case missingKey(String, id: String?)
    /// A key is present but its value is the wrong shape or an unknown enum.
    case invalidValue(key: String, value: String, reason: String)
    /// `schema` names a version newer than this binary understands.
    case unsupportedSchema(found: Int, supported: Int)
    /// R45: a static-argument field (`extra_args`, or `advisor.disable_args`
    /// — anything that appends verbatim arguments with no user-chosen value)
    /// contains a value also declared under `permission_mode.values` — a
    /// permission bypass may only reach the command through the structured
    /// field the dropdown marks (R37). `field` names which static field was
    /// the offender, so the message never claims `extra_args` when the real
    /// culprit is `advisor.disable_args`.
    case permissionValueInExtraArgs(field: String, argument: String, id: String)
    /// R45: another capability's flag (`model.flag`, `effort.flag`,
    /// `advisor.flag`, or `profile_flag`) is the exact same string as
    /// `permission_mode.flag`. Two capabilities sharing one CLI flag is
    /// never legitimate — it is what lets an unmarked value ride the flag
    /// the dropdown marks.
    case permissionFlagCollision(field: String, flag: String, id: String)

    public var description: String {
        switch self {
        case .parse(let error):
            return "manifest: \(error)"
        case .missingKey(let key, let id):
            if let id {
                return "\(id): missing required key '\(key)'"
            }
            return "missing required key '\(key)'"
        case .invalidValue(let key, let value, let reason):
            return "'\(key)' = \"\(value)\": \(reason)"
        case .unsupportedSchema(let found, let supported):
            return "schema \(found) is newer than the \(supported) this version supports"
        case .permissionValueInExtraArgs(let field, let argument, let id):
            return "\(id): \(field) contains \"\(argument)\", a value also declared under "
                + "permission_mode — a permission bypass may only arrive through that field (R45)"
        case .permissionFlagCollision(let field, let flag, let id):
            return "\(id): \(field) is \"\(flag)\", the same flag permission_mode declares — two "
                + "capabilities may not share one CLI flag (R45)"
        }
    }
}

/// A flag plus the values the agent accepts for it. An absent section on the
/// manifest means the agent does not have that capability (R13): the control
/// is hidden in the UI, not shown disabled or sent anyway.
public struct FlagSpec: Equatable, Sendable {
    public let flag: String
    public let values: [String]
    /// Key read from the profile's `settings_file` on first run, to seed the
    /// UI's default for this control. Nil when the manifest declares none.
    public let seedFromSettings: String?

    public init(flag: String, values: [String], seedFromSettings: String? = nil) {
        self.flag = flag
        self.values = values
        self.seedFromSettings = seedFromSettings
    }

    public func accepts(_ value: String) -> Bool {
        values.contains(value)
    }
}

/// The permission-mode capability: like `FlagSpec`, plus which of its values
/// count as "stops asking" for R37's warning marker.
public struct PermissionSpec: Equatable, Sendable {
    public let flag: String
    public let values: [String]
    public let bypassValues: [String]

    public init(flag: String, values: [String], bypassValues: [String] = []) {
        self.flag = flag
        self.values = values
        self.bypassValues = bypassValues
    }

    public func accepts(_ value: String) -> Bool {
        values.contains(value)
    }

    /// R37: true when `value` is one of the modes this manifest declares as
    /// bypassing — the row is marked before the click, inherited or not.
    public func isBypassing(_ value: String) -> Bool {
        bypassValues.contains(value)
    }
}

/// The advisor capability: a flag taking a model name, plus an optional way
/// to turn it off for one session.
public struct AdvisorSpec: Equatable, Sendable {
    public let flag: String
    public let values: [String]
    /// Static arguments that disable the advisor for one launch. Empty means
    /// the agent has no off switch — the advisor becomes enable-only and the
    /// UI hides the off control.
    public let disableArgs: [String]
    public let seedFromSettings: String?
    /// R50: the agent's models in ascending order of capability, weakest
    /// first. An agent that refuses to let a weaker model advise a stronger
    /// one declares the order here; an empty list means the agent accepts any
    /// pairing and no advisor is ever raised. A list, not a map of numbers,
    /// because the serializer promotes a nested table to its own `[section]`
    /// and a manifest must round-trip byte-identically.
    public let rankOrder: [String]

    public init(
        flag: String,
        values: [String],
        disableArgs: [String] = [],
        seedFromSettings: String? = nil,
        rankOrder: [String] = []
    ) {
        self.flag = flag
        self.values = values
        self.disableArgs = disableArgs
        self.seedFromSettings = seedFromSettings
        self.rankOrder = rankOrder
    }

    public func accepts(_ value: String) -> Bool {
        values.contains(value)
    }

    public var canDisable: Bool { !disableArgs.isEmpty }

    public func rank(of model: String) -> Int? { rankOrder.firstIndex(of: model) }

    /// R50: the advisor to send instead of `chosen` so the agent accepts the
    /// pairing, or nil when `chosen` already reaches `mainModel`'s class, when
    /// either side is unranked, or when no declared advisor reaches it.
    ///
    /// The main model itself is preferred when the agent accepts it as an
    /// advisor: a model always reaches its own class, and equal ranks were
    /// executed against the binary (`--model fable --advisor fable`, 2026-09-21)
    /// rather than inferred from the refusal's wording. Otherwise the weakest
    /// advisor that still reaches the class wins, so raising costs as little as
    /// the rule allows, with the name breaking a rank tie to keep the result
    /// deterministic.
    public func raised(_ chosen: String, toAtLeast mainModel: String) -> String? {
        guard let chosenRank = rank(of: chosen), let required = rank(of: mainModel), chosenRank < required else {
            return nil
        }
        if accepts(mainModel) { return mainModel }
        let candidates = values.compactMap { value -> (value: String, rank: Int)? in
            guard let rank = rank(of: value), rank >= required else { return nil }
            return (value, rank)
        }
        return candidates.min { lhs, rhs in
            lhs.rank == rhs.rank ? lhs.value < rhs.value : lhs.rank < rhs.rank
        }?.value
    }
}

/// How a profile (an account) reaches the agent: as an environment variable
/// holding the profile's directory, as a flag taking that directory, or not
/// at all when the agent has no notion of separate accounts.
public enum ProfileMechanism: Equatable, Sendable {
    case environment(String)
    case flag(String)
    case none
}

/// Whether the launch target's folder is passed to the agent as an argument.
public enum ProjectArgument: String, Equatable, Sendable {
    /// The folder is the terminal's working directory; the agent takes no
    /// project path of its own.
    case none
    /// The folder is passed as the agent's last argument.
    case positional
}

/// An agent manifest, parsed from TOML. See `docs/adding-an-agent.md` for
/// the key-by-key contract this type implements — the two must never drift
/// apart.
public struct AgentManifest: Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let binary: String
    public let enabled: Bool
    public let unverified: Bool
    public let verifiedVersion: String?
    public let verifiedOn: String?
    public let projectArgument: ProjectArgument
    public let extraArgs: [String]
    public let profileMechanism: ProfileMechanism
    public let settingsFile: String?
    public let usageSnapshot: String?
    public let model: FlagSpec?
    public let effort: FlagSpec?
    public let permissionMode: PermissionSpec?
    public let advisor: AdvisorSpec?
    public let origin: ManifestOrigin

    public init(
        id: String,
        displayName: String,
        binary: String,
        enabled: Bool = true,
        unverified: Bool = false,
        verifiedVersion: String? = nil,
        verifiedOn: String? = nil,
        projectArgument: ProjectArgument = .none,
        extraArgs: [String] = [],
        profileMechanism: ProfileMechanism = .none,
        settingsFile: String? = nil,
        usageSnapshot: String? = nil,
        model: FlagSpec? = nil,
        effort: FlagSpec? = nil,
        permissionMode: PermissionSpec? = nil,
        advisor: AdvisorSpec? = nil,
        origin: ManifestOrigin
    ) {
        self.id = id
        self.displayName = displayName
        self.binary = binary
        self.enabled = enabled
        self.unverified = unverified
        self.verifiedVersion = verifiedVersion
        self.verifiedOn = verifiedOn
        self.projectArgument = projectArgument
        self.extraArgs = extraArgs
        self.profileMechanism = profileMechanism
        self.settingsFile = settingsFile
        self.usageSnapshot = usageSnapshot
        self.model = model
        self.effort = effort
        self.permissionMode = permissionMode
        self.advisor = advisor
        self.origin = origin
    }

    public static func parse(_ text: String, origin: ManifestOrigin) throws -> AgentManifest {
        let document: TOMLDocument
        do {
            document = try TOMLDocument.parse(text)
        } catch let error as TOMLError {
            throw ManifestError.parse(error)
        }
        let root = document.root

        let id = try ManifestParsing.idAndValidatedSchema(root)

        let displayName = try ManifestParsing.requiredString(root, "display_name", id: id)
        let binary = try ManifestParsing.requiredString(root, "binary", id: id)
        try ManifestParsing.validateBinaryName(binary, id: id)

        let enabled = try ManifestParsing.optionalBool(root, "enabled", default: true, id: id)
        let unverified = try ManifestParsing.optionalBool(root, "unverified", default: false, id: id)
        let verifiedVersion = ManifestParsing.optionalString(root, "verified_version")
        let verifiedOn = ManifestParsing.optionalString(root, "verified_on")

        let projectArgRaw = root["project_arg"]?.stringValue ?? ProjectArgument.none.rawValue
        guard let projectArgument = ProjectArgument(rawValue: projectArgRaw) else {
            throw ManifestError.invalidValue(
                key: "project_arg", value: projectArgRaw, reason: "must be \"none\" or \"positional\""
            )
        }

        let extraArgs = try ManifestParsing.optionalStringArray(root, "extra_args", default: [], id: id)

        let profileEnv = ManifestParsing.optionalString(root, "profile_env")
        let profileFlag = ManifestParsing.optionalString(root, "profile_flag")
        let profileMechanism: ProfileMechanism
        switch (profileEnv, profileFlag) {
        case (let env?, nil):
            profileMechanism = .environment(env)
        case (nil, let flag?):
            profileMechanism = .flag(flag)
        case (nil, nil):
            profileMechanism = .none
        case (.some, .some):
            throw ManifestError.invalidValue(
                key: "profile_env / profile_flag",
                value: "both set",
                reason: "declare exactly one of profile_env or profile_flag, or neither"
            )
        }

        let settingsFile = ManifestParsing.optionalString(root, "settings_file")
        let usageSnapshot = ManifestParsing.optionalString(root, "usage_snapshot")

        let model = try ManifestParsing.flagSpec(root, section: "model", id: id)
        let effort = try ManifestParsing.flagSpec(root, section: "effort", id: id)
        let permissionMode = try ManifestParsing.permissionSpec(root, id: id)
        let advisor = try ManifestParsing.advisorSpec(root, id: id)

        // R50: a declared rank order must cover every model that can be
        // compared against it — each advisor value and each main-model value.
        // A value ranked nowhere is a value the advisor rule silently skips,
        // which is how a pairing the agent refuses would reach the binary
        // again; missing coverage is a manifest error, not a quiet default.
        if let advisor, !advisor.rankOrder.isEmpty {
            let comparable = advisor.values + (model?.values ?? [])
            let unranked = comparable.filter { advisor.rank(of: $0) == nil }
            guard unranked.isEmpty else {
                throw ManifestError.invalidValue(
                    key: "advisor.rank_order",
                    value: Array(Set(unranked)).sorted().joined(separator: ", "),
                    reason: "must rank every advisor value and every model value"
                )
            }
        }

        // R45: a static-argument field may not smuggle a value declared
        // under permission_mode.values past the structured field the
        // dropdown marks — checked over every field that appends verbatim,
        // user-uncontrolled arguments, not just extra_args. Caught both as
        // an exact element ("bypassPermissions") and as the value half of a
        // "--flag=value" element, since both forms reach a real CLI's
        // parser. Also rejects a capability sharing permission_mode's own
        // flag: two capabilities emitted through one flag is how an
        // unmarked value would ride the marked one.
        if let permissionMode {
            for (field, args) in [("extra_args", extraArgs), ("advisor.disable_args", advisor?.disableArgs ?? [])] {
                for arg in args {
                    if ManifestParsing.staticArgumentSmugglesPermissionValue(arg, permissionValues: permissionMode.values) {
                        throw ManifestError.permissionValueInExtraArgs(field: field, argument: arg, id: id)
                    }
                }
            }

            let otherFlags: [(field: String, flag: String?)] = [
                ("model.flag", model?.flag),
                ("effort.flag", effort?.flag),
                ("advisor.flag", advisor?.flag),
                ("profile_flag", profileFlag),
            ]
            for (field, flag) in otherFlags {
                if let flag, flag == permissionMode.flag {
                    throw ManifestError.permissionFlagCollision(field: field, flag: flag, id: id)
                }
            }
        }

        return AgentManifest(
            id: id,
            displayName: displayName,
            binary: binary,
            enabled: enabled,
            unverified: unverified,
            verifiedVersion: verifiedVersion,
            verifiedOn: verifiedOn,
            projectArgument: projectArgument,
            extraArgs: extraArgs,
            profileMechanism: profileMechanism,
            settingsFile: settingsFile,
            usageSnapshot: usageSnapshot,
            model: model,
            effort: effort,
            permissionMode: permissionMode,
            advisor: advisor,
            origin: origin
        )
    }

    /// Expands the `{profile_dir}` placeholder in `settingsFile`. Nil when
    /// the manifest declared no `settings_file`.
    public func settingsFileURL(profileDirectory: URL) -> URL? {
        guard let settingsFile else { return nil }
        return URL(fileURLWithPath: settingsFile.replacingOccurrences(
            of: "{profile_dir}", with: profileDirectory.path
        ))
    }

    /// Expands the `{profile_dir}` placeholder in `usageSnapshot`. Nil when
    /// the manifest declared no `usage_snapshot` — the rate-limit readout is
    /// simply hidden for this agent.
    public func usageSnapshotPath(profileDirectory: URL) -> String? {
        guard let usageSnapshot else { return nil }
        return usageSnapshot.replacingOccurrences(of: "{profile_dir}", with: profileDirectory.path)
    }
}

/// Shared TOML-reading helpers for `AgentManifest` and `TerminalManifest`.
/// Internal (not `public`): callers only ever reach a manifest through
/// `.parse(_:origin:)`.
enum ManifestParsing {
    /// The id + schema preamble both `AgentManifest.parse` and
    /// `TerminalManifest.parse` open with: read `id` (throwing
    /// `missingKey("id", id: nil)` when it's absent, since there's no id yet
    /// to name the failure with), then validate `schema` is present, is an
    /// integer, and is no newer than this binary supports. Returns the id on
    /// success — the two parsers pick up right after this and use it to name
    /// every later error.
    static func idAndValidatedSchema(_ root: TOMLTable) throws -> String {
        let id = try requiredString(root, "id", id: nil)

        guard let schemaValue = root["schema"] else {
            throw ManifestError.missingKey("schema", id: id)
        }
        guard let schema = schemaValue.intValue else {
            throw ManifestError.invalidValue(
                key: "schema", value: describe(schemaValue), reason: "must be an integer"
            )
        }
        guard schema <= ManifestRegistry.schemaVersion else {
            throw ManifestError.unsupportedSchema(found: schema, supported: ManifestRegistry.schemaVersion)
        }

        return id
    }

    static func requiredString(_ table: TOMLTable, _ key: String, id: String?) throws -> String {
        guard let value = table[key]?.stringValue, !value.isEmpty else {
            throw ManifestError.missingKey(key, id: id)
        }
        return value
    }

    /// Like `requiredString`, but for a key nested inside a capability
    /// section — the error names the dotted path (`"model.flag"`) so a bad
    /// manifest points straight at the offending line.
    static func requiredTableString(_ table: TOMLTable, _ key: String, section: String, id: String) throws -> String {
        guard let value = table[key]?.stringValue, !value.isEmpty else {
            throw ManifestError.missingKey("\(section).\(key)", id: id)
        }
        return value
    }

    static func requiredTableStringArray(
        _ table: TOMLTable, _ key: String, section: String, id: String
    ) throws -> [String] {
        guard let value = table[key] else {
            throw ManifestError.missingKey("\(section).\(key)", id: id)
        }
        guard let array = value.stringArrayValue else {
            throw ManifestError.invalidValue(
                key: "\(section).\(key)", value: describe(value), reason: "must be an array of strings"
            )
        }
        return array
    }

    static func optionalTableStringArray(
        _ table: TOMLTable, _ key: String, section: String, id: String, default def: [String]
    ) throws -> [String] {
        guard let value = table[key] else { return def }
        guard let array = value.stringArrayValue else {
            throw ManifestError.invalidValue(
                key: "\(section).\(key)", value: describe(value), reason: "must be an array of strings"
            )
        }
        return array
    }

    static func optionalString(_ table: TOMLTable, _ key: String) -> String? {
        table[key]?.stringValue
    }

    static func optionalBool(_ table: TOMLTable, _ key: String, default def: Bool, id: String) throws -> Bool {
        guard let value = table[key] else { return def }
        guard let boolean = value.boolValue else {
            throw ManifestError.invalidValue(key: key, value: describe(value), reason: "must be a boolean")
        }
        return boolean
    }

    static func optionalStringArray(
        _ table: TOMLTable, _ key: String, default def: [String], id: String
    ) throws -> [String] {
        guard let value = table[key] else { return def }
        guard let array = value.stringArrayValue else {
            throw ManifestError.invalidValue(key: key, value: describe(value), reason: "must be an array of strings")
        }
        return array
    }

    /// R4/KTD5: `binary` is handed to `BinaryResolver`, which runs
    /// `zsh -ilc 'whence -p -- "$1"'` with `binary` as the value of `$1` —
    /// safe from shell injection because it is a positional parameter, never
    /// spliced into the script text. This is the second half of that fix:
    /// even as a positional parameter, `binary` is still passed to
    /// `Process.executableURL` unquoted when it is an absolute path
    /// (`AgentManifest`/`TerminalManifest`'s own launch path), so a manifest
    /// — including an unconfirmed user manifest in
    /// `~/.config/agentmenu/agents/` — is refused outright if it names
    /// anything else. Allowed: an absolute path (`/usr/local/bin/claude`),
    /// or a plain name of letters, digits, `.`, `_`, `+`, `-` — everything a
    /// real binary name or a login shell's function/alias needs, nothing a
    /// shell would treat as a separator or metacharacter.
    static func validateBinaryName(_ binary: String, id: String) throws {
        if binary.hasPrefix("/") { return }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._+-")
        guard binary.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw ManifestError.invalidValue(
                key: "binary", value: binary,
                reason: "must be an absolute path or a plain name matching ^[A-Za-z0-9._+-]+$ (R4)"
            )
        }
    }

    /// R45: true when `argument` — either exactly, or as the value half of a
    /// `"--flag=value"` element — equals one of `permissionValues`. Both
    /// forms reach a real CLI's parser, so a static-argument field is
    /// checked against both.
    static func staticArgumentSmugglesPermissionValue(_ argument: String, permissionValues: [String]) -> Bool {
        if permissionValues.contains(argument) { return true }
        if let equals = argument.firstIndex(of: "=") {
            let value = String(argument[argument.index(after: equals)...])
            if permissionValues.contains(value) { return true }
        }
        return false
    }

    static func describe(_ value: TOMLValue) -> String {
        switch value {
        case .string(let string): return string
        case .integer(let int): return String(int)
        case .double(let double): return String(double)
        case .boolean(let bool): return String(bool)
        case .array: return "[array]"
        case .table: return "[table]"
        }
    }

    // MARK: - Capability sections

    static func flagSpec(_ root: TOMLTable, section: String, id: String) throws -> FlagSpec? {
        guard let sectionValue = root[section] else { return nil }
        guard let table = sectionValue.tableValue else {
            throw ManifestError.invalidValue(key: section, value: describe(sectionValue), reason: "must be a table")
        }
        let flag = try requiredTableString(table, "flag", section: section, id: id)
        let values = try requiredTableStringArray(table, "values", section: section, id: id)
        let seed = optionalString(table, "seed_from_settings")
        return FlagSpec(flag: flag, values: values, seedFromSettings: seed)
    }

    static func permissionSpec(_ root: TOMLTable, id: String) throws -> PermissionSpec? {
        let section = "permission_mode"
        guard let sectionValue = root[section] else { return nil }
        guard let table = sectionValue.tableValue else {
            throw ManifestError.invalidValue(key: section, value: describe(sectionValue), reason: "must be a table")
        }
        let flag = try requiredTableString(table, "flag", section: section, id: id)
        let values = try requiredTableStringArray(table, "values", section: section, id: id)

        // Absent `bypass_values` defaults to *every* declared value, not to
        // none: a value added to `values` and forgotten in `bypass_values`
        // must never be launchable-but-unmarked by construction (R37). A
        // manifest that means to mark nothing says so explicitly with
        // `bypass_values = []`, which is what `table["bypass_values"] !=
        // nil` below distinguishes from "the key was never written."
        let bypassValuesDeclared = table["bypass_values"] != nil
        let bypassValues = try optionalTableStringArray(
            table, "bypass_values", section: section, id: id, default: values
        )
        if bypassValuesDeclared {
            let unknown = bypassValues.filter { !values.contains($0) }
            guard unknown.isEmpty else {
                throw ManifestError.invalidValue(
                    key: "\(section).bypass_values", value: unknown.joined(separator: ", "),
                    reason: "must be a subset of \(section).values"
                )
            }
        }

        return PermissionSpec(flag: flag, values: values, bypassValues: bypassValues)
    }

    static func advisorSpec(_ root: TOMLTable, id: String) throws -> AdvisorSpec? {
        let section = "advisor"
        guard let sectionValue = root[section] else { return nil }
        guard let table = sectionValue.tableValue else {
            throw ManifestError.invalidValue(key: section, value: describe(sectionValue), reason: "must be a table")
        }
        let flag = try requiredTableString(table, "flag", section: section, id: id)
        let values = try requiredTableStringArray(table, "values", section: section, id: id)
        let disableArgs = try optionalTableStringArray(
            table, "disable_args", section: section, id: id, default: []
        )
        let seed = optionalString(table, "seed_from_settings")
        // R50: `rank_order = ["sonnet", "opus", "fable"]` — the agent's models
        // weakest first. Absent means the agent accepts any advisor for any
        // model; an empty list says the same thing explicitly.
        let rankOrder = try optionalTableStringArray(
            table, "rank_order", section: section, id: id, default: []
        )
        let duplicates = Set(rankOrder.filter { name in rankOrder.filter { $0 == name }.count > 1 })
        guard duplicates.isEmpty else {
            throw ManifestError.invalidValue(
                key: "\(section).rank_order",
                value: duplicates.sorted().joined(separator: ", "),
                reason: "names a model twice — a model has one rank"
            )
        }
        return AdvisorSpec(
            flag: flag, values: values, disableArgs: disableArgs, seedFromSettings: seed, rankOrder: rankOrder
        )
    }
}
