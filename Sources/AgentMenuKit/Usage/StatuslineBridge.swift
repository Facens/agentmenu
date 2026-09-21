// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The Claude Code status-line bridge (R26, R47).
///
/// Claude Code hands rate-limit data to exactly one place: the stdin JSON of
/// whatever command `statusLine` names, under `rate_limits`. `install-
/// statusline` points that command at a small script this type generates,
/// which in turn execs the CLI's hidden `statusline-bridge` subcommand. The
/// functions here are the testable core of that subcommand plus of the
/// installer itself — `Sources/AgentMenuCLI/*` only wires stdin/stdout/argv
/// to them.
///
/// This is the one place in the whole project that writes into an agent's
/// configuration directory (R47): the snapshot file, the history file, the
/// bridge script, and one key of `settings.json` — nothing else, and only
/// when `install-statusline` runs.
public enum StatuslineBridge {
    /// Matches `UsageReader.supportedVersions` — the version this bridge
    /// stamps every snapshot it writes with.
    public static let snapshotVersion = 1
    /// Filename written into a profile's configuration directory, read back
    /// by `UsageReader`.
    public static let snapshotFilename = "tb-rate-snapshot.json"
    /// Filename the bridge script is installed as.
    public static let scriptFilename = "agentmenu-statusline.sh"
    /// Once-per-minute throttle on both the snapshot and history writes — a
    /// status line runs constantly, and Claude Code's own refresh cadence is
    /// far tighter than either file needs to track. Matches
    /// `UsageReader.defaultStaleAfter`'s reasoning on the read side.
    public static let throttleInterval: TimeInterval = 60

    /// The `settings_file` / `usage_snapshot` templates Claude Code's own
    /// manifest declares (`Resources/agents/claude-code.toml`). Used as a
    /// fallback when the CLI cannot locate the bundled manifest to read them
    /// from directly — the two must never drift apart from that file.
    public static let claudeCodeSettingsFileTemplate = "{profile_dir}/settings.json"
    public static let claudeCodeUsageSnapshotTemplate = "{profile_dir}/tb-rate-snapshot.json"

    // MARK: - Snapshot

    /// Builds the snapshot file's bytes from a `statusLine` command's raw
    /// stdin JSON, in exactly the shape `UsageReader` parses. Returns nil
    /// when the payload carries no `rate_limits` object, or neither window
    /// inside it — there is nothing to write, and the caller leaves any
    /// existing snapshot alone rather than overwrite it with an empty one.
    /// A window absent from `rate_limits` (or present but missing either
    /// field) is never synthesised as zero.
    ///
    /// `existing` is the snapshot already on disk, and a window the payload
    /// does not carry is taken from it rather than dropped — as long as that
    /// window has not passed its own `resets_at`, since a reading for a
    /// window that has since rolled over says nothing about the one running
    /// now.
    ///
    /// This is not politeness, it is the difference between a readout and no
    /// readout. Every session of an account writes this one file, and a
    /// payload carrying only `seven_day` is ordinary: an idle session whose
    /// last server contact predates the current 5-hour window sends exactly
    /// that. Rebuilding the file from each payload alone let any such
    /// session erase `five_hour` for the whole account a minute after an
    /// active session wrote it — observed on this machine as a personal
    /// account that showed a weekly bar and no 5-hour bar at all, for days
    /// (the history file was already merged per window; only the snapshot
    /// was not).
    ///
    /// What this deliberately does NOT do is arbitrate between two payloads
    /// that both carry a window: the newer write wins, even when its
    /// `used_percentage` is lower than the one already stored for the same
    /// `resets_at`. Preferring the higher value looks right — usage inside
    /// one window instance should only grow — and is wrong: these windows
    /// roll, so a reading legitimately falls as older usage ages out. In the
    /// two history files on this machine, 76 of 340 observations recorded a
    /// decrease inside a single `resets_at`. A max() rule would have pinned
    /// both accounts at their high-water mark and never let them recover.
    public static func snapshotJSON(from stdin: Data, existing: Data?, now: Date) -> Data? {
        guard let root = try? JSONSerialization.jsonObject(with: stdin) as? [String: Any],
              let rateLimits = root["rate_limits"] as? [String: Any] else { return nil }

        // Start from the file and overwrite only the keys this bridge owns —
        // the same rule `ConfigStore.save` follows for config.toml, and for
        // the same reason: this file has another writer. The team status-line
        // script (ai-recipes core pack) writes a `suggest` key here that
        // `hooks/tokensave.sh` reads to tell someone their quota has
        // recovered, and a snapshot rebuilt from scratch dropped it every
        // time this bridge won the minute — so the hook's advice blinked in
        // and out depending on which writer got there first.
        var out = (try? JSONSerialization.jsonObject(with: existing ?? Data())) as? [String: Any] ?? [:]
        out["v"] = snapshotVersion
        out["ts"] = Int(now.timeIntervalSince1970)

        var wroteAnyWindow = false
        for kind in UsageWindowKind.allCases {
            if let fields = windowFields(rateLimits, kind) {
                out[kind.rawValue] = ["used_percentage": fields.used, "resets_at": fields.resets]
                wroteAnyWindow = true
            } else if let carried = carriedWindow(existing, kind, now: now) {
                out[kind.rawValue] = carried
            } else {
                // Neither reported now nor worth keeping: a window past its
                // own reset describes an instance that no longer exists, and
                // leaving it in the file would present it as current.
                out.removeValue(forKey: kind.rawValue)
            }
        }
        guard wroteAnyWindow else { return nil }

        return try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
    }

    /// One window of an existing snapshot, when it is still worth carrying:
    /// the file parses, the window is there in the shape this module writes,
    /// and its `resets_at` has not passed.
    private static func carriedWindow(
        _ existing: Data?, _ kind: UsageWindowKind, now: Date
    ) -> [String: Any]? {
        guard let existing,
              let root = try? JSONSerialization.jsonObject(with: existing) as? [String: Any],
              let window = root[kind.rawValue] as? [String: Any],
              let used = window["used_percentage"] as? NSNumber, !isJSONBoolean(used),
              let resets = window["resets_at"] as? NSNumber, !isJSONBoolean(resets),
              resets.doubleValue > now.timeIntervalSince1970 else { return nil }
        return ["used_percentage": used, "resets_at": resets]
    }

    /// One window's raw `used_percentage`/`resets_at` pair out of a
    /// `rate_limits` payload, validated exactly once. `snapshotJSON` and
    /// `historyRow` both read the same payload and used to guard it
    /// separately — `historyRow` was missing the JSON-boolean check
    /// `snapshotJSON` applies, so a boolean field produced no snapshot
    /// window (correct) but *did* produce a history observation with
    /// `used = 1.0` against a 1970 reset epoch, folded straight into the
    /// permanent 28-day file and the learned burn rate (finding #6). One
    /// function now, so the two callers cannot diverge again.
    private static func windowFields(
        _ rateLimits: [String: Any], _ kind: UsageWindowKind
    ) -> (used: NSNumber, resets: NSNumber)? {
        guard let window = rateLimits[kind.rawValue] as? [String: Any],
              let used = window["used_percentage"] as? NSNumber, !isJSONBoolean(used),
              let resets = window["resets_at"] as? NSNumber, !isJSONBoolean(resets) else { return nil }
        return (used, resets)
    }

    /// True when a write should proceed: no existing snapshot, one this
    /// reader cannot make sense of, or one old enough that the once-per-60s
    /// throttle has elapsed. The same gate covers the history write — there
    /// is one throttle, not two independently-timed ones.
    public static func shouldWrite(existing: Data?, now: Date) -> Bool {
        guard let existing else { return true }
        guard let object = try? JSONSerialization.jsonObject(with: existing) as? [String: Any],
              let ts = object["ts"] as? NSNumber else { return true }
        let age = now.timeIntervalSince1970 - ts.doubleValue
        // A `ts` in the future — a clock correction, a restored backup, a
        // file copied from a machine with a skewed clock — makes `age`
        // negative. Nothing about that means "wait longer than usual"; if
        // anything it means the existing file can't be trusted, so treat it
        // the same as a snapshot that is already stale rather than let a
        // skewed clock freeze every future write until real time catches up
        // (finding #9).
        return age >= throttleInterval || age < 0
    }

    /// True when `stdin` carries a window the existing snapshot does not
    /// have — which is a reason to write even inside the throttle.
    ///
    /// The throttle exists to stop sixty pointless rewrites a minute, not to
    /// hold back information the file does not have yet. Without this the
    /// account's readout is decided by a phase race: every session renders
    /// its status line about once a minute, so whichever one happens to fire
    /// first after each 60-second boundary wins every round, and if that
    /// session is an idle one carrying `seven_day` alone the file never
    /// learns the 5-hour window at all — carrying forward cannot help when
    /// there is nothing stored to carry. A session that knows more writes
    /// immediately; one that knows the same or less still waits its turn.
    public static func carriesNewWindow(stdin: Data, existing: Data?, now: Date) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: stdin) as? [String: Any],
              let rateLimits = root["rate_limits"] as? [String: Any] else { return false }
        for kind in UsageWindowKind.allCases where windowFields(rateLimits, kind) != nil {
            if carriedWindow(existing, kind, now: now) == nil { return true }
        }
        return false
    }

    // MARK: - History

    /// Builds one history observation from the same stdin JSON `snapshotJSON`
    /// reads, as a first-and-last-equal `UsageHistoryRow` for the local
    /// clock hour containing `now` — `mergeHistory` is what turns repeated
    /// observations inside one hour into a single first/last row. Nil when
    /// the payload carries no window at all, same as `snapshotJSON`.
    public static func historyRow(from stdin: Data, now: Date) -> UsageHistoryRow? {
        guard let root = try? JSONSerialization.jsonObject(with: stdin) as? [String: Any],
              let rateLimits = root["rate_limits"] as? [String: Any] else { return nil }

        var windows: [UsageWindowKind: WindowObservation] = [:]
        for kind in UsageWindowKind.allCases {
            guard let fields = windowFields(rateLimits, kind) else { continue }
            let used = fields.used.doubleValue
            let resetDate = Date(timeIntervalSince1970: fields.resets.doubleValue)
            windows[kind] = WindowObservation(
                usedFirst: used, usedLast: used, resetFirst: resetDate, resetLast: resetDate
            )
        }
        guard !windows.isEmpty else { return nil }
        return UsageHistoryRow(hourStart: localHourStart(for: now), windows: windows)
    }

    /// Folds `row` into `existing` history text: a row for the same local
    /// hour is updated in place (`usedLast`/`resetLast` move, `usedFirst`/
    /// `resetFirst` stay put; a window `row` does not carry is left
    /// untouched); any other hour is unaffected; a row older than 28 days as
    /// of `now` is dropped. Returns the full replacement file contents —
    /// there is no in-place patch, so the caller always rewrites the whole
    /// file (atomically, like the snapshot).
    public static func mergeHistory(existing: String?, row: UsageHistoryRow, now: Date) -> String {
        var rows = UsageHistory.parse(existing ?? "", now: now).rows

        if let index = rows.firstIndex(where: { $0.hourStart == row.hourStart }) {
            var merged = rows[index].windows
            for (kind, observation) in row.windows {
                if let current = merged[kind] {
                    merged[kind] = WindowObservation(
                        usedFirst: current.usedFirst,
                        usedLast: observation.usedLast,
                        resetFirst: current.resetFirst,
                        resetLast: observation.resetLast
                    )
                } else {
                    merged[kind] = observation
                }
            }
            rows[index] = UsageHistoryRow(hourStart: rows[index].hourStart, windows: merged)
        } else {
            rows.append(row)
        }

        let cutoff = now.addingTimeInterval(-UsageHistory.retention)
        rows.removeAll { $0.hourStart < cutoff }
        rows.sort { $0.hourStart < $1.hourStart }

        guard !rows.isEmpty else { return "" }
        return rows.map(serializeHistoryRow).joined(separator: "\n") + "\n"
    }

    private static func localHourStart(for date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        return calendar.dateInterval(of: .hour, for: date)?.start ?? date
    }

    private static func serializeHistoryRow(_ row: UsageHistoryRow) -> String {
        var object: [String: Any] = ["h": Int(row.hourStart.timeIntervalSince1970)]
        for kind in UsageWindowKind.allCases {
            guard let observation = row.windows[kind] else { continue }
            object[kind.rawValue] = [
                observation.usedFirst,
                observation.usedLast,
                Int(observation.resetFirst.timeIntervalSince1970),
                Int(observation.resetLast.timeIntervalSince1970),
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    // MARK: - Atomic write

    /// Writes `data` to `url` atomically — see `AtomicFile`, the shared
    /// helper this and `ConfigStore.save` both call.
    public static func atomicWrite(_ data: Data, to url: URL) throws {
        try AtomicFile.write(data, to: url)
    }

    // MARK: - Bridge script

    /// The two-line script `install-statusline` writes: it execs the CLI's
    /// hidden `statusline-bridge` subcommand rather than parsing JSON in
    /// shell, passing the profile directory and whatever command it is
    /// chaining to (empty when there was none configured).
    /// The script the agent's status line runs.
    ///
    /// The profile directory is resolved **at run time**, from the agent's own
    /// `CLAUDE_CONFIG_DIR`, with the directory this was installed for as the
    /// fallback. Baking the path in was wrong in a way that only shows up on a
    /// machine like the one this was written on: two accounts can share a
    /// single `settings.json` (a symlink between profile directories is an
    /// ordinary thing to do), and then one status-line command serves both —
    /// so a session on the second account wrote its rate-limit data into the
    /// first account's directory, silently mixing two accounts' usage into one
    /// history that the projection then read as one person's rhythm.
    public static func bridgeScript(cliPath: String, profileDirectory: String, chain: String) -> String {
        "#!/bin/bash\n"
            + "# The profile is whatever the running session says it is; the\n"
            + "# installed directory is only the fallback.\n"
            + "profile_dir=\"${CLAUDE_CONFIG_DIR:-\(profileDirectory)}\"\n"
            + "exec \(ShellQuoting.singleQuoted(cliPath)) statusline-bridge"
            + " --profile-dir \"$profile_dir\""
            + " --chain \(ShellQuoting.singleQuoted(chain))\n"
    }

    /// True when `command` is (or invokes) a bridge script this module
    /// wrote — matched by filename, so a difference in quoting style never
    /// stops it from being recognised.
    public static func isBridgeCommand(_ command: String) -> Bool {
        command.contains(scriptFilename)
    }

    /// The path of the bridge script a `statusLine.command` actually runs,
    /// or nil when it runs none.
    ///
    /// The path matters because it need not be the one being installed: two
    /// profiles can share a `settings.json`, and one profile's settings can
    /// simply name another's script — the installed script resolves its
    /// profile from `CLAUDE_CONFIG_DIR` at run time, so pointing at a
    /// sibling's copy works and is an easy thing to end up with. The chain
    /// then lives in *that* file, and reading it from the path being
    /// installed to finds nothing (the file is not there at all) and reports
    /// the chain as unrecoverable — refusing an install that is perfectly
    /// recoverable. Found on this machine: the personal profile's settings
    /// named the work profile's script, and `install-statusline --profile
    /// personal` refused every time.
    ///
    /// Extracted by scanning out from the filename to the nearest shell or
    /// quote boundary, which covers the forms a command takes in practice:
    /// `"/path/x.sh"`, `bash "/path/x.sh"`, `'/path/x.sh'`, bare.
    public static func bridgeScriptPath(inCommand command: String) -> String? {
        guard let range = command.range(of: scriptFilename) else { return nil }
        let boundaries: Set<Character> = ["\"", "'", " ", "\t", "\n"]
        var start = range.lowerBound
        while start > command.startIndex {
            let previous = command.index(before: start)
            if boundaries.contains(command[previous]) { break }
            start = previous
        }
        let path = String(command[start..<range.upperBound])
        return path.isEmpty ? nil : path
    }

    /// Recovers the chain a previously-installed bridge script already
    /// wraps, from its own `--chain '...'` argument (reversing
    /// `ShellQuoting.singleQuoted`) — so installing again over an existing
    /// bridge chains to what it already chained to, instead of nesting a
    /// bridge inside a bridge.
    public static func existingChain(inScript contents: String) -> String? {
        guard let marker = contents.range(of: "--chain '") else { return nil }
        var result = ""
        var index = marker.upperBound
        while index < contents.endIndex {
            if contents[index] == "'" {
                let remainder = contents[index...]
                if remainder.hasPrefix("'\\''") {
                    result.append("'")
                    index = contents.index(index, offsetBy: 4)
                    continue
                }
                break
            }
            result.append(contents[index])
            index = contents.index(after: index)
        }
        return result
    }

    // MARK: - Re-validation (U10)

    /// Recovers the CLI path a previously-installed bridge script's `exec`
    /// line invokes, reversing `ShellQuoting.singleQuoted` the same way
    /// `existingChain(inScript:)` already reverses it for `--chain` — same
    /// escape dance, same tolerance, so the two parsers cannot drift apart
    /// on what counts as a valid single-quoted argument.
    public static func installedCLIPath(inScript contents: String) -> String? {
        guard let marker = contents.range(of: "exec '") else { return nil }
        var result = ""
        var index = marker.upperBound
        while index < contents.endIndex {
            if contents[index] == "'" {
                let remainder = contents[index...]
                if remainder.hasPrefix("'\\''") {
                    result.append("'")
                    index = contents.index(index, offsetBy: 4)
                    continue
                }
                break
            }
            result.append(contents[index])
            index = contents.index(after: index)
        }
        return result
    }

    /// Whether an installed bridge script still points at a CLI this launch
    /// can actually run.
    ///
    /// `absent` means there is nothing installed for this profile — not an
    /// error, just nothing to re-validate. `current` means the script's own
    /// `exec` line already names `expectedCLIPath` and that path is still on
    /// disk. Everything else is `stale`, which deliberately covers two
    /// different causes with one case: a path that no longer matches (the
    /// bundle moved, or a translocation mount from a previous launch is
    /// gone) and a path that still matches textually but no longer resolves
    /// to a file (the same translocation mount, still named, already
    /// unmounted). Both mean the same thing to a caller — the script cannot
    /// be trusted to run — and `StatuslineBridgeTests` covers both, but
    /// nothing downstream needs to tell them apart, so they are not split
    /// into separate cases.
    public enum BridgeState: Equatable {
        case absent
        case current
        case stale(installed: String, expected: String)
    }

    /// Computes a `BridgeState` from a script's own text (nil when nothing
    /// is installed for the profile) and the CLI path this launch would
    /// write if it installed fresh.
    ///
    /// `fileExists` is a `(String) -> Bool` probe rather than a plain
    /// `Bool` the caller computes up front, so the function stays pure in
    /// its own body — a test drives "the path parses fine but the file is
    /// gone" without touching the real filesystem, by handing in a stub
    /// that always answers `false`. It defaults to a real check
    /// (`FileManager.isExecutableFile`, matching the guard
    /// `install-statusline` itself applies to a freshly resolved CLI path)
    /// so an ordinary caller does not have to wire one up just to get the
    /// real answer.
    public static func bridgeState(
        scriptContents: String?,
        expectedCLIPath: String,
        fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> BridgeState {
        guard let scriptContents else { return .absent }
        // A script this parser cannot make sense of at all resolves to the
        // empty string here, which can never equal a real `expectedCLIPath`
        // — so an unparseable script falls out of the same guard as a
        // parseable-but-wrong one, rather than needing its own branch.
        let installed = installedCLIPath(inScript: scriptContents) ?? ""
        guard installed == expectedCLIPath, fileExists(installed) else {
            return .stale(installed: installed, expected: expectedCLIPath)
        }
        return .current
    }

    // MARK: - settings.json update

    /// The outcome of computing a `settings.json` update: the file's new
    /// full text, the command the bridge should chain to, and whether the
    /// current `statusLine.command` was already this bridge (so the
    /// installer can say "already installed" instead of claiming it changed
    /// something).
    public struct SettingsUpdate: Equatable {
        public let text: String
        public let chain: String
        public let alreadyInstalled: Bool
    }

    public enum SettingsUpdateError: Error, CustomStringConvertible {
        case malformedJSON
        case notAnObject
        /// The surgical edit touched a byte outside the `statusLine` key —
        /// refused rather than written, so a parser edge case reads as an
        /// error instead of silently corrupting every other setting.
        case wouldChangeOtherKeys
        /// `settings.json` says the bridge is already installed, but its
        /// script could not be read (finding #3). Once `statusLine.command`
        /// points at the bridge, the user's original status-line command
        /// exists in exactly one place — the `--chain '…'` argument inside
        /// that script — so a missing or unreadable script makes it
        /// unrecoverable. Silently treating that as "nothing to chain to"
        /// discards it permanently the moment this install writes a fresh
        /// script; refuse instead. `path` is the script the *command* names,
        /// which is not always the one being installed — see
        /// `bridgeScriptPath(inCommand:)`.
        case bridgeScriptUnreadable(path: String)

        public var description: String {
            switch self {
            case .malformedJSON:
                return "settings.json is not valid JSON"
            case .notAnObject:
                return "settings.json root is not a JSON object"
            case .wouldChangeOtherKeys:
                return "the edit would have changed a key other than statusLine — refusing to write"
            case .bridgeScriptUnreadable(let path):
                return "settings.json says the agentmenu bridge is already installed, but its script at "
                    + "\(path) could not be read — refusing to overwrite it with one that chains to nothing. "
                    + "If the original status-line command is truly gone, clear statusLine in settings.json "
                    + "(or reinstall the command you want the bridge to chain to at that path) and run "
                    + "install-statusline again."
            }
        }
    }

    /// Computes the new `settings.json` text with `statusLine` set to
    /// invoke the bridge script at `scriptPath`, preserving every other key
    /// byte-for-byte (verified by re-parsing both the old and new text and
    /// comparing everything but `statusLine`; a mismatch throws instead of
    /// writing). `existingBridgeScriptContents` is the contents of the
    /// bridge script `statusLine.command` currently names — which is the
    /// script at *its own* path, not necessarily `scriptPath` (see
    /// `bridgeScriptPath(inCommand:)`) — used to recover the chain it
    /// already wraps.
    public static func settingsUpdate(
        original: String,
        scriptPath: String,
        existingBridgeScriptContents: String?
    ) throws -> SettingsUpdate {
        guard let originalData = original.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: originalData) else {
            throw SettingsUpdateError.malformedJSON
        }
        guard let object = root as? [String: Any] else {
            throw SettingsUpdateError.notAnObject
        }

        var chain = ""
        var alreadyInstalled = false
        if let statusLine = object["statusLine"] as? [String: Any],
           let command = statusLine["command"] as? String {
            if isBridgeCommand(command) {
                alreadyInstalled = true
                guard let existingBridgeScriptContents else {
                    throw SettingsUpdateError.bridgeScriptUnreadable(
                        path: bridgeScriptPath(inCommand: command) ?? scriptPath
                    )
                }
                chain = existingChain(inScript: existingBridgeScriptContents) ?? ""
            } else {
                chain = command
            }
        }

        // Every other key of the existing statusLine object rides along —
        // refreshInterval is the one that exists today, and rebuilding the
        // object from scratch silently reset it. One key changes; the rest is
        // the user's.
        var statusLineValue: [String: Any] = (object["statusLine"] as? [String: Any]) ?? [:]
        statusLineValue["type"] = statusLineValue["type"] ?? "command"
        statusLineValue["command"] = "\"\(scriptPath)\""
        guard let valueData = try? JSONSerialization.data(withJSONObject: statusLineValue, options: [.sortedKeys]),
              let valueLiteral = String(data: valueData, encoding: .utf8) else {
            throw SettingsUpdateError.malformedJSON
        }

        let newText = try replaceTopLevelKey(in: original, key: "statusLine", withRawValue: valueLiteral)

        guard let newData = newText.data(using: .utf8),
              let newRoot = (try? JSONSerialization.jsonObject(with: newData)) as? [String: Any] else {
            throw SettingsUpdateError.malformedJSON
        }
        var oldCompare = object
        var newCompare = newRoot
        oldCompare.removeValue(forKey: "statusLine")
        newCompare.removeValue(forKey: "statusLine")
        guard NSDictionary(dictionary: oldCompare).isEqual(to: newCompare) else {
            throw SettingsUpdateError.wouldChangeOtherKeys
        }

        return SettingsUpdate(text: newText, chain: chain, alreadyInstalled: alreadyInstalled)
    }

    /// Replaces the value of a top-level (depth-1) key in raw JSON `text`
    /// with `rawValue`, or inserts `"key": rawValue` into the root object
    /// when the key is absent. Does not attempt to understand the value it
    /// replaces beyond finding its span — it just balances brackets and
    /// string quoting while scanning, which is all a byte-preserving splice
    /// needs. `settingsUpdate` re-parses and diffs the result, so a text
    /// this scanner gets wrong throws there rather than shipping silently.
    static func replaceTopLevelKey(in text: String, key: String, withRawValue rawValue: String) throws -> String {
        let chars = Array(text)
        let keyChars = Array(key)

        func matchesKey(at i: Int) -> Bool {
            guard i + keyChars.count + 1 < chars.count else { return false }
            for (offset, keyChar) in keyChars.enumerated() where chars[i + 1 + offset] != keyChar {
                return false
            }
            guard chars[i + 1 + keyChars.count] == "\"" else { return false }
            // A depth-1 string *value* equal to `key` (e.g. `"someKey":
            // "statusLine"`) closes its quote the same way a key's does —
            // the only thing that tells them apart is what follows: a key's
            // closing quote is always followed (after whitespace) by `:`, a
            // value's never is (finding #8).
            var j = i + 1 + keyChars.count + 1
            while j < chars.count, chars[j].isWhitespace { j += 1 }
            return j < chars.count && chars[j] == ":"
        }

        var depth = 0
        var inString = false
        var escaped = false
        var rootStart: Int?
        var rootEnd: Int?
        var keyStart: Int?
        var keyEnd: Int?

        var index = 0
        while index < chars.count {
            let c = chars[index]
            if inString {
                if escaped {
                    escaped = false
                } else if c == "\\" {
                    escaped = true
                } else if c == "\"" {
                    inString = false
                }
                index += 1
                continue
            }
            switch c {
            case "\"":
                if depth == 1, keyStart == nil, matchesKey(at: index) {
                    keyStart = index
                    keyEnd = index + 1 + keyChars.count + 1
                }
                inString = true
            case "{", "[":
                if c == "{", depth == 0 { rootStart = index }
                depth += 1
            case "}", "]":
                depth -= 1
                if c == "}", depth == 0, rootEnd == nil { rootEnd = index }
            default:
                break
            }
            index += 1
        }

        guard let rootStart, let rootEnd, rootEnd > rootStart else {
            throw SettingsUpdateError.notAnObject
        }

        if let keyStart, let keyEnd {
            guard let valueRange = scanValue(chars, from: keyEnd) else {
                throw SettingsUpdateError.malformedJSON
            }
            let prefix = String(chars[0..<keyStart])
            // `valueRange.upperBound` is the index of the value's own last
            // character (inclusive) — the suffix starts one past it, or the
            // same byte gets duplicated into both the replacement and what
            // follows it.
            let suffix = String(chars[(valueRange.upperBound + 1)...])
            return prefix + "\"\(key)\": " + rawValue + suffix
        }

        let insideStart = rootStart + 1
        let hasExistingKeys = chars[insideStart..<rootEnd].contains { !$0.isWhitespace }
        let prefix = String(chars[0..<rootEnd])
        let suffix = String(chars[rootEnd...])
        let separator = hasExistingKeys ? ",\n  " : ""
        return prefix + separator + "\"\(key)\": " + rawValue + "\n" + suffix
    }

    /// Scans forward from `colonSearchStart` (just past a key's closing
    /// quote) past the `:` and any whitespace, then returns the index range
    /// of the value itself — a balanced object/array, a string, or a bare
    /// token (number/bool/null) ended by the next unquoted `,`, `}`, or `]`.
    private static func scanValue(_ chars: [Character], from colonSearchStart: Int) -> ClosedRange<Int>? {
        var i = colonSearchStart
        while i < chars.count, chars[i] != ":" { i += 1 }
        guard i < chars.count else { return nil }
        i += 1
        while i < chars.count, chars[i].isWhitespace { i += 1 }
        guard i < chars.count else { return nil }

        let valueStart = i
        let first = chars[i]

        if first == "{" || first == "[" {
            let open = first
            let close: Character = first == "{" ? "}" : "]"
            var depth = 0
            var inString = false
            var escaped = false
            while i < chars.count {
                let c = chars[i]
                if inString {
                    if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
                } else if c == "\"" {
                    inString = true
                } else if c == open {
                    depth += 1
                } else if c == close {
                    depth -= 1
                    if depth == 0 { return valueStart...i }
                }
                i += 1
            }
            return nil
        }

        if first == "\"" {
            var inString = true
            var escaped = false
            i += 1
            while i < chars.count, inString {
                let c = chars[i]
                if escaped {
                    escaped = false
                } else if c == "\\" {
                    escaped = true
                } else if c == "\"" {
                    inString = false
                }
                i += 1
            }
            return valueStart...(i - 1)
        }

        // Bare token: number, true, false, null.
        var end = i
        while end < chars.count, !",}]\n".contains(chars[end]) {
            end += 1
        }
        var last = end - 1
        while last > valueStart, chars[last].isWhitespace { last -= 1 }
        guard last >= valueStart else { return nil }
        return valueStart...last
    }
}
