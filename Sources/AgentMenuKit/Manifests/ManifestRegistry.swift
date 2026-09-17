// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import CoreServices

/// Whether a manifest can be selected right now, and why not when it cannot.
/// Deliberately has no "unverified" case: every unverified manifest that
/// ships also ships `enabled = false` (R19), so it already reports
/// `.disabledByManifest`. Unverified is a UI label, not a distinct
/// availability state.
public enum Availability: Equatable {
    case available
    /// R21. Carries the binary name that could not be resolved.
    case binaryMissing(String)
    /// R21, terminals. Carries the bundle id whose application is missing.
    case applicationMissing(String)
    /// R19: the manifest — or the user's override of it — ships disabled.
    case disabledByManifest
    /// R44: a user-overlay manifest the user has not marked trusted.
    case needsConfirmation
}

/// Loads agent and terminal manifests from the app bundle and the user's
/// overlay directory, and answers whether each one is selectable right now.
///
/// A manifest is an executable specification — it names a binary, an
/// environment variable, and static arguments — so one that did not ship
/// inside the app bundle is untrusted by construction (R44) until the user
/// confirms it. That distinction lives in `ManifestOrigin`, set here at load
/// time from which directory a file came from; it is not something a
/// manifest can claim about itself.
public final class ManifestRegistry {
    /// The schema version this binary understands. A manifest naming a newer
    /// one is refused (`ManifestError.unsupportedSchema`) rather than parsed
    /// partially.
    public static let schemaVersion = 1

    private let bundledRoot: URL?
    private let userRoot: URL?
    private let fileManager: FileManager
    private let applicationProbe: (String) -> Bool

    public private(set) var agents: [AgentManifest] = []
    public private(set) var terminals: [TerminalManifest] = []
    /// Every manifest that failed to load, so the settings window can show
    /// the reason instead of silently dropping it. One bad file never stops
    /// the rest of the directory from loading.
    public private(set) var failures: [(file: String, error: ManifestError)] = []

    /// `applicationProbe` is not part of the documented API contract — it is
    /// an additive, defaulted parameter so a terminal's availability can be
    /// tested without depending on which applications happen to be installed
    /// on the machine running the tests. Production code can construct with
    /// the default and never think about it; `defaultApplicationProbe` is the
    /// real Launch Services lookup.
    public init(
        bundledRoot: URL?,
        userRoot: URL?,
        fileManager: FileManager = .default,
        applicationProbe: @escaping (String) -> Bool = ManifestRegistry.defaultApplicationProbe
    ) {
        self.bundledRoot = bundledRoot
        self.userRoot = userRoot
        self.fileManager = fileManager
        self.applicationProbe = applicationProbe
    }

    /// `~/.config/agentmenu` — the parent of the user's `agents/` and
    /// `terminals/` overlay directories.
    public static var defaultUserRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/agentmenu")
    }

    /// Looks an application up by bundle id via Launch Services. `NSWorkspace`
    /// would be the ordinary way to do this, but it is an AppKit type and
    /// this library stays UI-free so it can be used from the CLI target too;
    /// this Core Services call is the lowest-level equivalent available.
    /// `LSCopyApplicationURLsForBundleIdentifier` has been deprecated since
    /// macOS 12 with no non-AppKit replacement — the deprecation is
    /// acknowledged, not worked around. This function is itself not marked
    /// deprecated: doing so would push the warning onto every caller of the
    /// default `init`, which did nothing wrong.
    public static func defaultApplicationProbe(_ bundleID: String) -> Bool {
        guard let unmanaged = LSCopyApplicationURLsForBundleIdentifier(bundleID as CFString, nil) else {
            return false
        }
        let urls = unmanaged.takeRetainedValue() as NSArray
        return urls.count > 0
    }

    /// Loads every `.toml` file in the bundled `agents/`+`terminals/`
    /// directories, then the user's overlay: a user manifest with the same
    /// `id` as a bundled one replaces it (KTD3). Never throws as a whole —
    /// one malformed or invalid file is recorded in `failures` and every
    /// other file still loads, because a settings window listing manifests
    /// must not go blank over a single typo.
    public func load() {
        var agentOrder: [String] = []
        var agentsByID: [String: AgentManifest] = [:]
        var terminalOrder: [String] = []
        var terminalsByID: [String: TerminalManifest] = [:]
        var collectedFailures: [(file: String, error: ManifestError)] = []

        for (root, origin) in [(bundledRoot, ManifestOrigin.bundled), (userRoot, ManifestOrigin.user)] {
            guard let root else { continue }

            let agentFiles = tomlFiles(in: root.appendingPathComponent("agents"))
            collectedFailures.append(contentsOf: agentFiles.failures)
            for (file, text) in agentFiles.loaded {
                do {
                    let manifest = try AgentManifest.parse(text, origin: origin)
                    if agentsByID[manifest.id] == nil { agentOrder.append(manifest.id) }
                    agentsByID[manifest.id] = manifest
                } catch let error as ManifestError {
                    collectedFailures.append((file: file.path, error: error))
                } catch {
                    collectedFailures.append((
                        file: file.path,
                        error: .invalidValue(key: "file", value: file.path, reason: String(describing: error))
                    ))
                }
            }

            let terminalFiles = tomlFiles(in: root.appendingPathComponent("terminals"))
            collectedFailures.append(contentsOf: terminalFiles.failures)
            for (file, text) in terminalFiles.loaded {
                do {
                    let manifest = try TerminalManifest.parse(text, origin: origin)
                    if terminalsByID[manifest.id] == nil { terminalOrder.append(manifest.id) }
                    terminalsByID[manifest.id] = manifest
                } catch let error as ManifestError {
                    collectedFailures.append((file: file.path, error: error))
                } catch {
                    collectedFailures.append((
                        file: file.path,
                        error: .invalidValue(key: "file", value: file.path, reason: String(describing: error))
                    ))
                }
            }
        }

        agents = agentOrder.map { agentsByID[$0]! }
        terminals = terminalOrder.map { terminalsByID[$0]! }
        failures = collectedFailures
    }

    public func agent(id: String) -> AgentManifest? {
        agents.first { $0.id == id }
    }

    public func terminal(id: String) -> TerminalManifest? {
        terminals.first { $0.id == id }
    }

    /// Precedence: an unconfirmed user manifest is `.needsConfirmation`
    /// before anything else is even considered (R44) — trust is checked
    /// first because everything past it assumes the process it would run is
    /// one the user agreed to run. Next, an effectively-disabled manifest is
    /// `.disabledByManifest` (R19). Only once both pass does a missing
    /// binary matter (R21).
    public func availability(of agent: AgentManifest, config: Config, binaryPath: String?) -> Availability {
        if agent.origin == .user {
            let trusted = config.agentState[agent.id]?.trusted ?? false
            if !trusted { return .needsConfirmation }
        }
        let enabled = config.agentState[agent.id]?.enabled ?? agent.enabled
        if !enabled { return .disabledByManifest }
        if binaryPath == nil { return .binaryMissing(agent.binary) }
        return .available
    }

    /// Same precedence as the agent overload; the missing-binary check at
    /// the end becomes a missing-application check for `applescript`
    /// terminals, probed by bundle id, or a missing-binary check for `argv`
    /// ones.
    public func availability(of terminal: TerminalManifest, config: Config, binaryPath: String?) -> Availability {
        if terminal.origin == .user {
            let trusted = config.terminalState[terminal.id]?.trusted ?? false
            if !trusted { return .needsConfirmation }
        }
        let enabled = config.terminalState[terminal.id]?.enabled ?? terminal.enabled
        if !enabled { return .disabledByManifest }
        switch terminal.kind {
        case .applescript:
            // Parsing guarantees bundle_id is present for this kind.
            let bundleID = terminal.bundleID ?? ""
            if !applicationProbe(bundleID) { return .applicationMissing(bundleID) }
            return .available
        case .argv:
            if binaryPath == nil { return .binaryMissing(terminal.binary ?? "") }
            return .available
        }
    }

    /// `.toml` files directly inside `directory`, sorted by filename for a
    /// deterministic load order, plus a failure entry for every one of them
    /// that could not be read as UTF-8 text — permissions, a mid-write
    /// truncation, a symlink to nowhere. Any other file (`.DS_Store`, a
    /// stray `.bak`) is silently skipped rather than attempted and reported
    /// as a failure — it was never a manifest to begin with, so it was never
    /// a load that could fail. A directory that does not exist yields no
    /// files and no failures, not an error: the user overlay directories
    /// usually do not exist at all.
    ///
    /// An unreadable file used to be dropped by the `try?` below with
    /// nothing recorded anywhere — not loaded, not in `failures` — so it
    /// simply vanished from the settings pane instead of being listed as
    /// broken. Routing the read failure through the same `failures` channel
    /// a bad parse already uses is what "one bad file must not stop the
    /// rest, and must not go unreported either" already promises for every
    /// other way a manifest can fail.
    private func tomlFiles(in directory: URL) -> (loaded: [(URL, String)], failures: [(file: String, error: ManifestError)]) {
        guard let entries = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return ([], [])
        }
        let files = entries
            .filter { $0.pathExtension == "toml" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var loaded: [(URL, String)] = []
        var readFailures: [(file: String, error: ManifestError)] = []
        for file in files {
            do {
                let text = try String(contentsOf: file, encoding: .utf8)
                loaded.append((file, text))
            } catch {
                readFailures.append((
                    file: file.path,
                    error: .invalidValue(key: "file", value: file.path, reason: "could not be read: \(String(describing: error))")
                ))
            }
        }
        return (loaded, readFailures)
    }
}
