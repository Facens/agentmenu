// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Taking the bridge back out (R14, R47).
///
/// Install is the one write AgentMenu makes into an agent's configuration, so
/// it has to be undoable by the same tool that did it. Everything install
/// recorded is recoverable from what it left behind: the user's original
/// `statusLine.command` is the `--chain '…'` argument of the bridge script
/// (empty when there was none), so removal needs no state of its own.
extension StatuslineBridge {
    /// What `uninstall` did, or declined to do.
    public enum RemovalOutcome: Equatable {
        /// `restoredCommand` is the command `statusLine.command` was set back
        /// to, or nil when there was no status line before install and the
        /// whole `statusLine` key was taken out. `deleted` names each file
        /// that was (or, in a dry run, would be) deleted.
        case removed(restoredCommand: String?, deleted: [String])
        /// Nothing of the bridge's is installed here. A success with no
        /// effect, so removing twice is safe.
        case notInstalled
        /// Nothing was changed, and the reason says why. Never a guess about
        /// what the user would want: a status line that is no longer ours is
        /// theirs to deal with.
        case refused(String)
        /// Something went wrong while writing or deleting. When `settings.json`
        /// had already been put back the message says so; nothing is ever
        /// deleted before it has been.
        case failed(String)
    }

    /// The outcome of computing the `settings.json` text with the bridge taken
    /// out: the full new text, and the command `statusLine.command` was put
    /// back to (nil when the key was removed instead).
    public struct SettingsRemoval: Equatable {
        public let text: String
        public let restoredCommand: String?
    }

    /// Computes the new `settings.json` text with the bridge removed.
    /// `bridgeScriptContents` is the script `statusLine.command` names — the
    /// only place the user's original command still exists.
    ///
    /// With a chain, `statusLine.command` becomes exactly that chain (install
    /// stored it verbatim, so it is not re-quoted) and every other key of
    /// the `statusLine` object rides along. With none, the whole `statusLine`
    /// key goes: install created it, and a `statusLine` without a command is
    /// not a status line. Every other top-level key is left as it is, and a
    /// result that would change one throws instead of being written, the same
    /// check `settingsUpdate` makes.
    public static func settingsRemoval(
        original: String, bridgeScriptContents: String
    ) throws -> SettingsRemoval {
        guard let originalData = original.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: originalData) else {
            throw SettingsUpdateError.malformedJSON
        }
        guard let object = root as? [String: Any] else { throw SettingsUpdateError.notAnObject }
        guard let statusLine = object["statusLine"] as? [String: Any],
              let command = statusLine["command"] as? String,
              isBridgeCommand(command) else {
            throw SettingsUpdateError.notBridgeCommand
        }
        guard let chain = existingChain(inScript: bridgeScriptContents) else {
            throw SettingsUpdateError.bridgeChainUnrecoverable(
                path: bridgeScriptPath(inCommand: command) ?? scriptFilename
            )
        }

        let newText: String
        if chain.isEmpty {
            newText = try removeTopLevelKey(in: original, key: "statusLine")
        } else {
            var restored = statusLine
            restored["command"] = chain
            guard let data = try? JSONSerialization.data(
                      withJSONObject: restored, options: [.sortedKeys, .withoutEscapingSlashes]
                  ),
                  let literal = String(data: data, encoding: .utf8) else {
                throw SettingsUpdateError.malformedJSON
            }
            newText = try replaceTopLevelKey(in: original, key: "statusLine", withRawValue: literal)
        }

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
        let newCommand = (newRoot["statusLine"] as? [String: Any])?["command"] as? String
        guard newCommand == (chain.isEmpty ? nil : chain) else {
            throw SettingsUpdateError.wouldChangeOtherKeys
        }

        return SettingsRemoval(text: newText, restoredCommand: chain.isEmpty ? nil : chain)
    }

    /// The three files the bridge leaves in a profile's directory.
    public static func installedFilenames() -> [String] {
        [scriptFilename, snapshotFilename, UsageHistory.fileName]
    }

    /// Removes the bridge from one profile: puts `settings.json`'s
    /// `statusLine.command` back to what it was before install, then deletes
    /// the bridge script, the snapshot and the history file.
    ///
    /// Refuses, changing nothing, when:
    /// - the command no longer points at this profile's bridge script while
    ///   that script is still there (the user changed it since install),
    /// - the command runs another profile's bridge script (that one is
    ///   removed from that profile — taking it out here would break it),
    /// - the script the command names is unreadable or no longer carries a
    ///   chain, so the original command cannot be recovered and removing
    ///   would lose it,
    /// - `settings.json` is not a JSON object.
    ///
    /// Not installed — no bridge command in `settings.json` and no script on
    /// disk — is a no-op success. `dryRun` computes and reports everything and
    /// writes nothing.
    ///
    /// `settings.json` is written first and the files deleted after: the
    /// chain lives in the script, so the script is the last thing to go.
    public static func uninstall(
        profileDirectory: URL, settingsURL: URL, dryRun: Bool = false
    ) -> RemovalOutcome {
        let fileManager = FileManager.default
        let scriptURL = profileDirectory.appendingPathComponent(scriptFilename)
        let ownScriptExists = fileManager.fileExists(atPath: scriptURL.path)

        let settingsText = try? String(contentsOf: settingsURL, encoding: .utf8)
        var command: String?
        if let settingsText {
            guard let data = settingsText.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) else {
                return .refused("\(settingsURL.path) is not valid JSON, so the status line cannot be checked — nothing was changed")
            }
            guard let object = root as? [String: Any] else {
                return .refused("\(settingsURL.path) is not a JSON object — nothing was changed")
            }
            command = (object["statusLine"] as? [String: Any])?["command"] as? String
        }

        guard let command, isBridgeCommand(command) else {
            if ownScriptExists {
                return .refused(
                    "statusLine.command in \(settingsURL.path) no longer runs the AgentMenu bridge, but "
                        + "\(scriptURL.path) is still there — it was changed after install. "
                        + "Nothing was changed; delete the files by hand if you want them gone"
                )
            }
            return .notInstalled
        }

        let namedPath = bridgeScriptPath(inCommand: command) ?? scriptURL.path
        guard sameFile(namedPath, scriptURL.path) else {
            return .refused(
                "statusLine.command in \(settingsURL.path) runs another profile's bridge (\(namedPath)), "
                    + "not this one's — remove it from that profile. Nothing was changed"
            )
        }
        guard let scriptContents = try? String(contentsOf: scriptURL, encoding: .utf8),
              let settingsText else {
            return .refused(
                "statusLine.command in \(settingsURL.path) runs \(namedPath), which cannot be read, so the status "
                    + "line it chains to cannot be recovered — nothing was changed. Set statusLine.command "
                    + "back by hand, then remove the files"
            )
        }

        let removal: SettingsRemoval
        do {
            removal = try settingsRemoval(original: settingsText, bridgeScriptContents: scriptContents)
        } catch {
            return .refused("\(error) — nothing was changed")
        }

        let present = installedFilenames()
            .map { profileDirectory.appendingPathComponent($0) }
            .filter { fileManager.fileExists(atPath: $0.path) }
            .map(\.path)
        if dryRun { return .removed(restoredCommand: removal.restoredCommand, deleted: present) }

        do {
            guard let data = removal.text.data(using: .utf8) else { throw CocoaError(.fileWriteUnknown) }
            try atomicWrite(data, to: settingsURL)
        } catch {
            return .failed("could not write \(settingsURL.path): \(error.localizedDescription) — nothing was changed")
        }
        // Script last (see above); a file already gone is not an error.
        var deleted: [String] = []
        let order = [snapshotFilename, UsageHistory.fileName, scriptFilename]
        for name in order {
            let url = profileDirectory.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            do {
                try fileManager.removeItem(at: url)
                deleted.append(url.path)
            } catch {
                return .failed(
                    "\(settingsURL.path) was put back, but \(url.path) could not be deleted: "
                        + error.localizedDescription
                )
            }
        }
        return .removed(restoredCommand: removal.restoredCommand, deleted: present.filter(deleted.contains))
    }

    private static func sameFile(_ a: String, _ b: String) -> Bool {
        URL(fileURLWithPath: a).resolvingSymlinksInPath().path
            == URL(fileURLWithPath: b).resolvingSymlinksInPath().path
    }

    // MARK: - Launch-time re-validation, by profile directory

    /// `bridgeState` for one profile directory: reads its own
    /// `agentmenu-statusline.sh` off disk and compares it with
    /// `expectedCLIPath`. This is the launch-time stale re-point's whole
    /// decision, kept here so what it keys off — the script file — is tested
    /// rather than described: once removal has deleted the script this is
    /// `.absent`, and nothing re-installs a bridge the user took out.
    public static func bridgeState(
        profileDirectory: URL,
        expectedCLIPath: String,
        fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> BridgeState {
        let contents = try? String(
            contentsOf: profileDirectory.appendingPathComponent(scriptFilename), encoding: .utf8
        )
        return bridgeState(scriptContents: contents, expectedCLIPath: expectedCLIPath, fileExists: fileExists)
    }

    // MARK: - Removing one top-level key

    /// Takes a top-level (depth-1) key and its value out of raw JSON `text`,
    /// along with the comma and whitespace that belonged to it, leaving every
    /// other byte alone. A text without the key is returned unchanged.
    ///
    /// `replaceTopLevelKey` inserts an absent key in one exact shape — before
    /// the root's closing brace, as `,\n  "key": value\n` (or without the
    /// leading comma into an empty object) — and removal recognises that
    /// shape first and takes out exactly those bytes, so install followed by
    /// removal gives back the file it started from. Any other layout falls
    /// through to a comma-aware removal (first, middle, last or only member).
    /// `settingsRemoval` re-parses and diffs the result, so a scan this gets
    /// wrong throws there instead of being written.
    public static func removeTopLevelKey(in text: String, key: String) throws -> String {
        let chars = Array(text)
        let located = try locateTopLevelKey(chars, key: key)
        guard let keyStart = located.keyStart, let keyEnd = located.keyEnd else { return text }
        guard let valueRange = scanValue(chars, from: keyEnd) else {
            throw SettingsUpdateError.malformedJSON
        }
        let valueEnd = valueRange.upperBound

        func removing(_ lower: Int, _ upper: Int) -> String {
            String(chars[0..<lower]) + String(chars[upper...])
        }

        // Install's own shape: the value runs to a newline and the root's `}`.
        if valueEnd + 2 == located.rootEnd, chars[valueEnd + 1] == "\n" {
            if keyStart >= 4, String(chars[(keyStart - 4)..<keyStart]) == ",\n  " {
                return removing(keyStart - 4, valueEnd + 2)
            }
            if keyStart - 1 == located.rootStart {
                return removing(keyStart, valueEnd + 2)
            }
        }

        var next = valueEnd + 1
        while next < chars.count, chars[next].isWhitespace { next += 1 }
        if next < chars.count, chars[next] == "," {
            // Not the last member: take the key through its own comma and the
            // whitespace up to the next member.
            var end = next + 1
            while end < chars.count, chars[end].isWhitespace { end += 1 }
            return removing(keyStart, end)
        }

        // The last member: take its preceding comma instead, and the
        // whitespace before that comma, so the previous member ends cleanly.
        var previous = keyStart - 1
        while previous > located.rootStart, chars[previous].isWhitespace { previous -= 1 }
        if chars[previous] == "," {
            var lower = previous
            while lower - 1 > located.rootStart, chars[lower - 1].isWhitespace { lower -= 1 }
            return removing(lower, valueEnd + 1)
        }
        // The only member.
        return removing(located.rootStart + 1, located.rootEnd)
    }
}
