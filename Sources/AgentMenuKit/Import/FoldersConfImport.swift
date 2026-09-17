// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// One valid line from `~/.config/cc-launcher/folders.conf`:
/// `Label | /absolute/path | identity`. `identity` is nil when the line
/// omitted the third field — tolerated, not malformed (`claude-id` itself
/// falls through to its other precedence layers for such an entry, so the
/// import does the same rather than guessing a value).
public struct FoldersConfEntry: Equatable {
    public let label: String
    public let path: String
    public let identity: String?
    public let line: Int

    public init(label: String, path: String, identity: String?, line: Int) {
        self.label = label
        self.path = path
        self.identity = identity
        self.line = line
    }
}

/// A line that is neither a comment, blank, nor `Label | /path[ | identity]`
/// — missing the `|` separator entirely, or missing a label/path.
public struct FoldersConfMalformedLine: Equatable {
    public let line: Int
    public let text: String

    public init(line: Int, text: String) {
        self.line = line
        self.text = text
    }
}

/// What importing one entry would do to `Config`, computed but not yet
/// applied.
public enum FolderImportAction: Equatable {
    /// Adds `folder`. `createsProfile` names the profile id/config directory
    /// this entry is the first to need, when the import also has to create
    /// one rather than pointing at an existing profile.
    case add(FolderTarget, createsProfile: Profile?)
    case skip(reason: String)
}

public struct FolderImportPlanEntry: Equatable {
    public let entry: FoldersConfEntry
    public let action: FolderImportAction

    public init(entry: FoldersConfEntry, action: FolderImportAction) {
        self.entry = entry
        self.action = action
    }
}

/// What `FoldersConfImport.plan` would change, without changing it.
public struct FoldersConfImportPlan: Equatable {
    public let entries: [FolderImportPlanEntry]
    public let malformed: [FoldersConfMalformedLine]

    public init(entries: [FolderImportPlanEntry], malformed: [FoldersConfMalformedLine]) {
        self.entries = entries
        self.malformed = malformed
    }

    public var toAdd: [FolderImportPlanEntry] {
        entries.filter { if case .add = $0.action { return true }; return false }
    }

    public var toSkip: [FolderImportPlanEntry] {
        entries.filter { if case .skip = $0.action { return true }; return false }
    }
}

/// Parses `folders.conf` and turns the result into a plan against a `Config`
/// (R30/R31): shared by the CLI's `agentmenu import` and the app's first-run
/// flow, so there is exactly one place that understands the file's format
/// instead of two that can drift apart.
public enum FoldersConfImport {
    /// Where `cc-launcher` writes `folders.conf`, before tilde expansion —
    /// the one place this path is spelled out. The CLI's `--from` overrides
    /// it; the app's first-run flow uses it as-is.
    public static let defaultSourcePath = "~/.config/cc-launcher/folders.conf"

    /// Reads `path` (tilde-expanded) as UTF-8 text, or nil when the file
    /// cannot be read — absent, unreadable, not valid UTF-8. Callers decide
    /// what "nil" means for them: the app's first-run flow treats it as
    /// "nothing to import," the CLI treats it as a hard failure.
    public static func readSource(at path: String = defaultSourcePath) -> String? {
        let expandedPath = (path as NSString).expandingTildeInPath
        return try? String(contentsOfFile: expandedPath, encoding: .utf8)
    }

    public struct ParseResult: Equatable {
        /// Valid entries, in file order.
        public let entries: [FoldersConfEntry]
        public let malformed: [FoldersConfMalformedLine]

        public init(entries: [FoldersConfEntry], malformed: [FoldersConfMalformedLine]) {
            self.entries = entries
            self.malformed = malformed
        }
    }

    /// `Label | /absolute/path | identity` — `#` comments and blank lines
    /// are skipped, the third field may be missing, but a line that is
    /// neither of those and does not have at least a label and a path is
    /// reported as malformed with its 1-based line number.
    public static func parse(_ text: String) -> ParseResult {
        var entries: [FoldersConfEntry] = []
        var malformed: [FoldersConfMalformedLine] = []

        let lines = text.components(separatedBy: "\n")
        for (offset, rawLine) in lines.enumerated() {
            let lineNumber = offset + 1
            let trimmedLine = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmedLine.isEmpty || trimmedLine.hasPrefix("#") { continue }

            let fields = rawLine.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 2, !fields[0].isEmpty, !fields[1].isEmpty else {
                malformed.append(FoldersConfMalformedLine(line: lineNumber, text: rawLine))
                continue
            }

            let identity: String?
            if fields.count >= 3, !fields[2].isEmpty {
                // The identity becomes a filesystem path
                // (`configDirectory(forIdentity:)` -> `~/.claude-<identity>`,
                // written straight into `Profile.configDirectory` and handed
                // out as `CLAUDE_CONFIG_DIR`) with no further validation past
                // this point, so an identity containing path separators —
                // `../../../../tmp/evil`, from a `folders.conf` copied over
                // from a different, possibly compromised or malformed setup
                // — must be caught here, not silently accepted into a
                // directory outside `~`. Malformed, not merely skipped: the
                // rest of the line (a real label and path) is not trustworthy
                // enough to import with the identity silently dropped either.
                guard isValidIdentity(fields[2]) else {
                    malformed.append(FoldersConfMalformedLine(line: lineNumber, text: rawLine))
                    continue
                }
                identity = fields[2]
            } else {
                identity = nil
            }

            entries.append(FoldersConfEntry(label: fields[0], path: fields[1], identity: identity, line: lineNumber))
        }

        return ParseResult(entries: entries, malformed: malformed)
    }

    /// A conservative shape for the third `folders.conf` field: what
    /// `configDirectory(forIdentity:)` and `profileName(forIdentity:)`
    /// already presume an identity looks like — a short bare word, nothing a
    /// path component needs to escape. Rejects path separators (so
    /// `../../../../tmp/evil` can never turn `~/.claude-<identity>` into a
    /// path outside the home directory), empty strings, and anything absurdly
    /// long.
    static func isValidIdentity(_ identity: String) -> Bool {
        guard !identity.isEmpty, identity.count <= 64 else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        return identity.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// The config directory `claude-id` maps an identity to: `work` ->
    /// `~/.claude`, any other identity `x` -> `~/.claude-x`.
    public static func configDirectory(forIdentity identity: String) -> String {
        identity == "work" ? "~/.claude" : "~/.claude-\(identity)"
    }

    /// A display name for a profile this import creates — capitalized
    /// identity, matching the pairs `FirstRunModel` seeds
    /// (`("work", "Work", "~/.claude")`, `("personal", "Personal", …)`) so
    /// import and first run never produce two spellings of the same account.
    public static func profileName(forIdentity identity: String) -> String {
        guard let first = identity.first else { return identity }
        return String(first).uppercased() + identity.dropFirst()
    }

    /// What importing `result` into `config` would change: a folder already
    /// present at its normalized path is skipped and says so; every other
    /// entry is added, creating the profile its identity names when `config`
    /// does not already have one with that id (matching by id, so importing
    /// the same file twice creates nothing a second time).
    public static func plan(_ result: ParseResult, into config: Config) -> FoldersConfImportPlan {
        var planEntries: [FolderImportPlanEntry] = []
        var knownProfileIDs = Set(config.profiles.map { $0.id })
        let existingPaths = Set(config.folders.map { $0.normalizedPath })
        // Tracked separately from `existingPaths` so two lines in the same
        // file that resolve to the same folder produce one add and one skip
        // instead of two adds — `Config`'s own decoder rejects two
        // `[[folders]]` entries at the same normalized path, so letting that
        // happen here would make the config this import writes unloadable.
        var pathsSeenThisImport: Set<String> = []

        for entry in result.entries {
            let normalized = FolderTarget.normalize(entry.path)
            if existingPaths.contains(normalized) {
                planEntries.append(FolderImportPlanEntry(
                    entry: entry, action: .skip(reason: "already configured")
                ))
                continue
            }
            if pathsSeenThisImport.contains(normalized) {
                planEntries.append(FolderImportPlanEntry(
                    entry: entry, action: .skip(reason: "duplicate path earlier in this file")
                ))
                continue
            }
            pathsSeenThisImport.insert(normalized)

            guard let identity = entry.identity else {
                // No identity declared for this entry — leave the folder's
                // profile unset, the same way claude-id defers to its other
                // precedence layers when folders.conf names none.
                let folder = FolderTarget(label: entry.label, path: entry.path, profileID: nil)
                planEntries.append(FolderImportPlanEntry(entry: entry, action: .add(folder, createsProfile: nil)))
                continue
            }

            // An identity names a configuration directory, and that directory
            // is what actually keeps two accounts apart — the id is just a
            // label for it. A configuration whose profile for `~/.claude` is
            // called something else (`default`, which is what first-run names
            // the suffix-less directory) would otherwise gain a second
            // profile, `work`, pointing at the very same directory: one
            // account shown twice in a switcher whose whole job is to keep
            // accounts apart. Match on the directory first, and only fall
            // back to creating one when no existing profile has it.
            let identityDirectory = configDirectory(forIdentity: identity)
            if let existing = config.profiles.first(where: {
                $0.expandedConfigDirectory.standardizedFileURL.path
                    == Profile(id: identity, name: identity, configDirectory: identityDirectory)
                        .expandedConfigDirectory.standardizedFileURL.path
            }) {
                let folder = FolderTarget(label: entry.label, path: entry.path, profileID: existing.id)
                planEntries.append(FolderImportPlanEntry(entry: entry, action: .add(folder, createsProfile: nil)))
                continue
            }

            var createsProfile: Profile?
            if !knownProfileIDs.contains(identity) {
                createsProfile = Profile(
                    id: identity,
                    name: profileName(forIdentity: identity),
                    configDirectory: identityDirectory
                )
                knownProfileIDs.insert(identity)
            }

            let folder = FolderTarget(label: entry.label, path: entry.path, profileID: identity)
            planEntries.append(FolderImportPlanEntry(entry: entry, action: .add(folder, createsProfile: createsProfile)))
        }

        return FoldersConfImportPlan(entries: planEntries, malformed: result.malformed)
    }

    /// Applies `plan` to `config` in place: appends the new folders and
    /// creates each missing profile at most once, even when several entries
    /// name the same new identity.
    public static func apply(_ plan: FoldersConfImportPlan, to config: inout Config) {
        var createdProfileIDs = Set<String>()
        for planEntry in plan.entries {
            guard case .add(let folder, let createsProfile) = planEntry.action else { continue }
            if let createsProfile,
               !createdProfileIDs.contains(createsProfile.id),
               config.profile(id: createsProfile.id) == nil {
                config.profiles.append(createsProfile)
                createdProfileIDs.insert(createsProfile.id)
            }
            config.folders.append(folder)
        }
    }
}
