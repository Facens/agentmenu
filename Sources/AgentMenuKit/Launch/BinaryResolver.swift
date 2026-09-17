// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// KTD5: resolves a binary name to an absolute path, using the cached path
/// when it is still valid and shelling out to a login shell otherwise.
/// `claude` is a zsh *function* on the target machine, so `command -v claude`
/// returns the bare name `claude` and resolves nothing; `whence -p` skips
/// functions and aliases and returns the real path on disk, which is the
/// only thing safe to execute directly (R4, R22).
public struct BinaryResolver {
    public enum Failure: Error, CustomStringConvertible, Equatable {
        case notFound(String)

        public var description: String {
            switch self {
            case .notFound(let binary):
                return "could not resolve '\(binary)' — a login shell could not find it either"
            }
        }
    }

    private let fileManager: FileManager
    private let shell: String

    public init(fileManager: FileManager = .default, shell: String = "/bin/zsh") {
        self.fileManager = fileManager
        self.shell = shell
    }

    /// The argv this resolver would run for `binary`, exposed so a test can
    /// assert on it without actually shelling out.
    ///
    /// `binary` is never spliced into the script text — it comes from a
    /// manifest, including a user manifest in `~/.config/agentmenu/agents/`,
    /// and `zsh -ilc` runs the script with the user's full interactive
    /// environment. Splicing it directly (the earlier shape,
    /// `"whence -p \(binary)"`) let a manifest whose `binary` was
    /// `"claude; touch /tmp/pwned"` execute arbitrary shell text. Instead
    /// `binary` is passed as a positional parameter: `zsh -c 'script' $0
    /// $1…` assigns the word right after the script to `$0` and the rest to
    /// `$1`, `$2`, … — the same mechanism `TerminalLauncher.open`'s
    /// `osascript -e '<script>' <argv>` already relies on — so the script
    /// text itself never contains anything but the fixed word `"$1"`. The
    /// literal `"zsh"` filling `$0` here is arbitrary — nothing reads it —
    /// it only occupies the slot.
    public static func lookupArguments(for binary: String) -> [String] {
        ["-ilc", "whence -p -- \"$1\"", "zsh", binary]
    }

    /// Uses `cached` when it still names an executable file — no process is
    /// launched in that case. Otherwise runs `zsh -ilc 'whence -p <binary>'`
    /// once and caches nothing itself (the caller owns `config.toml`);
    /// throws `.notFound` when the shell cannot resolve it either (AE5, R6).
    public func resolve(_ binary: String, cached: String?) throws -> String {
        if let cached, fileManager.isExecutableFile(atPath: cached) {
            return cached
        }
        guard let resolved = lookUpViaShell(binary) else {
            throw Failure.notFound(binary)
        }
        return resolved
    }

    /// An interactive login shell (`-il`) is what makes `whence` see the
    /// user's own function/alias table — a non-interactive shell would not
    /// have sourced the `.zshrc` that defines `claude` as a function in the
    /// first place, defeating the reason this resolver exists.
    private func lookUpViaShell(_ binary: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = Self.lookupArguments(for: binary)

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        // An interactive login shell can print rc-file noise on stdout ahead
        // of the value `whence -p` actually returns — take the last
        // non-empty line, and require it to look like an absolute path
        // before trusting it: a garbage value here gets cached into
        // config.toml and re-run on every future launch (R22, AE5).
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let last = lines.last(where: { !$0.isEmpty }), last.hasPrefix("/") else {
            return nil
        }
        return last
    }
}
