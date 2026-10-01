// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation

/// Everything that can go wrong reading or writing the session store.
public enum SessionStoreError: Error, CustomStringConvertible {
    /// The file's `schema` names a version newer than this build understands.
    /// The file is left exactly as it is.
    case unsupportedSchema(found: Int, supported: Int)
    /// The file exists but is not a store this build can read: not JSON, not
    /// an object, no usable `schema`, or a field this build models with the
    /// wrong shape. Also left exactly as it is.
    case corrupt(reason: String)
    /// The file could not be read for a reason other than its content.
    case unreadable(underlying: String)
    /// The file could not be written. The previous file is untouched.
    case write(underlying: String)

    public var description: String {
        switch self {
        case .unsupportedSchema(let found, let supported):
            return "the session store's schema \(found) is newer than the \(supported) this version supports"
        case .corrupt(let reason):
            return "the session store could not be understood: \(reason)"
        case .unreadable(let underlying):
            return "the session store could not be read: \(underlying)"
        case .write(let underlying):
            return "the session store could not be written: \(underlying)"
        }
    }
}

/// What this build models of the store. The renames table, the launch ledger
/// (U11, which also holds the live owned set: the rows whose agent is
/// registered and running), and the pending reopen set, the closed stack and
/// the boot id (U13, KTD12), each an additive key.
public struct SessionStoreData: Equatable {
    /// AgentMenu renames, by session id (R3). Keyed by session id rather than
    /// by live row, because a name belongs to the conversation: it has to
    /// survive the process that was running it, and it is what the Closed
    /// list looks up too.
    public var renames: [String: String]
    /// Every launch AgentMenu made (U11, R22). Written on every change, with
    /// the same durability as everything else here, so it survives a crash or
    /// a power cut.
    public var ledger: LaunchLedger
    /// The pending reopen set, the closed stack and the boot id (U13, R22,
    /// R23, R24). Written with the ledger, so a classification and the rows it
    /// marked land together or not at all.
    public var restore: RestoreState

    public init(
        renames: [String: String] = [:],
        ledger: LaunchLedger = LaunchLedger(),
        restore: RestoreState = RestoreState()
    ) {
        self.renames = renames
        self.ledger = ledger
        self.restore = restore
    }
}

/// The app-owned session store (KTD12): `sessions.json` in
/// `~/Library/Application Support/<bundle id>/`, separate from `config.toml`
/// because config is hand-editable settings and this is state the app writes
/// on every launch, quit and rename.
///
/// **Durable writes.** Every change is written to a temporary file in the same
/// directory, `fsync`ed (with `F_FULLFSYNC` where the file system honours it,
/// so the bytes reach the disk rather than its cache), then `rename(2)`d over
/// the store, and the directory is `fsync`ed after. A reader sees the whole
/// old file or the whole new one; a power cut leaves one of the two. The
/// directory sync is best effort: by then the file's content is safe and the
/// rename has happened, and failing the write over it would report an error
/// for a change that is in place.
///
/// **Refusing, never replacing.** `ConfigStore` may write a fresh document
/// after a failed load; this store must not. A store file that is corrupt, or
/// written by a newer build, may hold the ledger and closed stack a restore
/// depends on, and overwriting it to save a rename would destroy them. So a
/// load that fails leaves the file alone and every change throws until a later
/// load succeeds. Because a write re-reads the file first, this also holds for
/// an instance that never called `load()`: no path reaches `save` without
/// having read what it is about to replace. A corrupt file therefore blocks
/// renames until it is fixed or removed; the error names the problem, and the
/// UI can show it from `refusal`.
///
/// **Forward compatibility.** The file is a JSON object with a `schema`
/// number and one key per section. Adding a section is not a schema change:
/// the version is bumped only for a change an older build could misread. The
/// store keeps the whole top-level object it last read and overwrites only
/// the keys it models, so a key a newer build at the same schema wrote
/// survives a rename made here — the same promise `ConfigStore` makes for
/// `config.toml`. A file whose `schema` is newer than this build is refused.
///
/// Safe to call from any thread: one lock guards the state.
public final class SessionStore: @unchecked Sendable {
    /// The schema this build reads and writes.
    public static let schemaVersion = 1
    public static let fileName = "sessions.json"

    /// The identifier used when the process has no bundle of its own: the
    /// `agentmenu` CLI, and the test runner. It is the app's, so the CLI and
    /// the GUI meet at one file.
    public static let fallbackBundleIdentifier = "dev.facens.agentmenu"

    /// `~/Library/Application Support/<bundle id>/sessions.json`.
    ///
    /// The bundle identifier is read from the running bundle, not hard-coded,
    /// so that a build shipped under a different identifier keeps its own
    /// state instead of sharing one file with the release (the plan's risk
    /// table relies on it). Both parameters are injectable so a test can
    /// compose the path without writing anywhere.
    public static func url(
        bundleIdentifier: String?,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let identifier = bundleIdentifier.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackBundleIdentifier
        return homeDirectory
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(identifier, isDirectory: true)
            .appendingPathComponent(fileName)
    }

    /// `AGENTMENU_SESSION_STORE` replaces this (`Overrides.sessionStore`).
    public static var defaultURL: URL {
        url(bundleIdentifier: Bundle.main.bundleIdentifier)
    }

    public let url: URL

    private let lock = NSLock()
    /// What this instance last read or wrote.
    private var data = SessionStoreData()
    /// The whole top-level object at that point, so keys this build does not
    /// model are written back.
    private var retained: [String: Any] = [:]
    private var lastRefusal: SessionStoreError?

    public init(url: URL = SessionStore.defaultURL) {
        self.url = url
    }

    public var exists: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// The renames as of the last load or change; empty before either.
    public var renames: [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return data.renames
    }

    /// The launch ledger as of the last load or change; empty before either.
    public var ledger: LaunchLedger {
        lock.lock()
        defer { lock.unlock() }
        return data.ledger
    }

    /// The pending reopen set, the closed stack and the boot id as of the last
    /// load or change; empty before either.
    public var restore: RestoreState {
        lock.lock()
        defer { lock.unlock() }
        return data.restore
    }

    /// Why the store is refusing to write, from the last load or change that
    /// failed, or nil. Cleared by the next successful load.
    public var refusal: SessionStoreError? {
        lock.lock()
        defer { lock.unlock() }
        return lastRefusal
    }

    /// Reads the file. A file that does not exist is a first run and loads
    /// empty. Throws for a newer schema, a file this build cannot read, or an
    /// I/O failure, and never writes: a failed load leaves the file exactly
    /// as it was.
    @discardableResult
    public func load() throws -> SessionStoreData {
        lock.lock()
        defer { lock.unlock() }
        return try loadLocked()
    }

    /// Sets the name AgentMenu shows for a session, or clears it when `name`
    /// is nil or blank (a rename to nothing is a request to go back to the
    /// recorded title, not to show an empty row). The name is trimmed. An
    /// empty session id is ignored: there is nothing to key it by.
    public func setRename(_ name: String?, for sessionId: String) throws {
        guard !sessionId.isEmpty else { return }
        let trimmed = name.trimmedNonEmpty
        try mutate { data in
            if let trimmed {
                data.renames[sessionId] = trimmed
            } else {
                data.renames[sessionId] = nil
            }
        }
    }

    /// Changes the launch ledger and writes it. `change` returns nothing: a
    /// change that leaves the ledger as it was writes nothing.
    public func updateLedger(_ change: (inout LaunchLedger) -> Void) throws {
        try mutate { data in change(&data.ledger) }
    }

    /// Changes the restore state alone (the pending set, the closed stack, the
    /// boot id) and writes it: a restore taking a session out of both lists
    /// (U14). A change that leaves it as it was writes nothing.
    public func updateRestore(_ change: (inout RestoreState) -> Void) throws {
        try mutate { data in change(&data.restore) }
    }

    /// Changes the whole store in one write: the classification of ended rows
    /// marks the ledger and replaces the restore state together.
    public func update(_ change: (inout SessionStoreData) -> Void) throws {
        try mutate(change)
    }

    // MARK: - Reading

    private func loadLocked() throws -> SessionStoreData {
        do {
            let (parsed, object) = try readFile()
            data = parsed
            retained = object
            lastRefusal = nil
            return parsed
        } catch let error as SessionStoreError {
            lastRefusal = error
            throw error
        }
    }

    private func readFile() throws -> (SessionStoreData, [String: Any]) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return (SessionStoreData(), [:])
        }
        let raw: Data
        do {
            raw = try Data(contentsOf: url)
        } catch {
            throw SessionStoreError.unreadable(underlying: String(describing: error))
        }
        return try Self.decode(raw)
    }

    static func decode(_ raw: Data) throws -> (SessionStoreData, [String: Any]) {
        guard !raw.isEmpty else { throw SessionStoreError.corrupt(reason: "the file is empty") }
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: raw)
        } catch {
            throw SessionStoreError.corrupt(reason: "it is not valid JSON")
        }
        guard let object = json as? [String: Any] else {
            throw SessionStoreError.corrupt(reason: "the top level is not an object")
        }

        // The version comes first, before any other field is looked at: a
        // newer build is free to change what `renames` looks like.
        guard let schemaNumber = object["schema"] as? NSNumber, !isJSONBoolean(schemaNumber),
              schemaNumber.doubleValue.truncatingRemainder(dividingBy: 1) == 0 else {
            throw SessionStoreError.corrupt(reason: "'schema' is missing or is not an integer")
        }
        let schema = schemaNumber.intValue
        if schema > schemaVersion {
            throw SessionStoreError.unsupportedSchema(found: schema, supported: schemaVersion)
        }
        guard schema >= 1 else { throw SessionStoreError.corrupt(reason: "'schema' must be 1 or more") }

        var renames: [String: String] = [:]
        if let value = object["renames"] {
            guard let table = value as? [String: Any] else {
                throw SessionStoreError.corrupt(reason: "'renames' is not an object")
            }
            for (sessionId, name) in table {
                guard let name = name as? String else {
                    throw SessionStoreError.corrupt(reason: "the rename for \(sessionId) is not a string")
                }
                // A blank name means "no rename"; it is not worth keeping.
                if let trimmed = name.trimmedNonEmpty { renames[sessionId] = trimmed }
            }
        }

        var ledger = LaunchLedger()
        if let value = object["ledger"] {
            guard let table = value as? [String: Any] else {
                throw SessionStoreError.corrupt(reason: "'ledger' is not an object")
            }
            // No `rows` is an empty ledger; a `rows` that is not a list is not
            // something this build wrote.
            let rows: [Any]
            if let value = table["rows"] {
                guard let list = value as? [Any] else {
                    throw SessionStoreError.corrupt(reason: "'ledger.rows' is not a list")
                }
                rows = list
            } else {
                rows = []
            }
            // A row this build cannot read is skipped, not fatal: a launch
            // must never be blocked by an old row.
            ledger = LaunchLedger(rows: rows.compactMap { ($0 as? [String: Any]).flatMap(LedgerRow.init(json:)) })
        }

        var restore = RestoreState()
        if let value = object["pending_reopen"] {
            guard let table = value as? [String: Any] else {
                throw SessionStoreError.corrupt(reason: "'pending_reopen' is not an object")
            }
            restore.pending = PendingReopenSet(json: table)
        }
        if let value = object["closed_stack"] {
            guard let list = value as? [Any] else {
                throw SessionStoreError.corrupt(reason: "'closed_stack' is not a list")
            }
            // An entry this build cannot read is skipped, not fatal.
            restore.closed = list.compactMap { ($0 as? [String: Any]).flatMap(RestorableSession.init(json:)) }
        }
        if let value = object["boot_id"] {
            guard let text = value as? String else {
                throw SessionStoreError.corrupt(reason: "'boot_id' is not a string")
            }
            restore.bootID = text.isEmpty ? nil : text
        }
        return (SessionStoreData(renames: renames, ledger: ledger, restore: restore), object)
    }

    // MARK: - Writing

    /// Re-reads the file, applies `change`, and writes the result. Reading
    /// first is what makes a refusal hold for an instance that never loaded,
    /// and keeps two instances from overwriting each other's changes with
    /// stale state. In-memory state moves only after the write succeeded.
    private func mutate(_ change: (inout SessionStoreData) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }

        var current = try loadLocked()
        let before = current
        change(&current)
        // No change, no write — but the file is still created on the first
        // real change, not before.
        guard current != before else { return }

        var object = retained
        object["schema"] = Self.schemaVersion
        object["renames"] = current.renames
        // The key appears with the first launch and never before, so a store
        // that has only ever held renames is byte-for-byte what it was.
        if !current.ledger.isEmpty || object["ledger"] != nil {
            var table = (object["ledger"] as? [String: Any]) ?? [:]
            table["rows"] = current.ledger.rows.map { $0.jsonObject() }
            object["ledger"] = table
        }
        // The same rule for the restore keys: each appears with its first
        // content and goes again when it empties, so a store that has never
        // held a reopen set is byte-for-byte what it was.
        object["pending_reopen"] = current.restore.pending?.jsonObject()
        object["closed_stack"] = current.restore.closed.isEmpty ? nil : current.restore.closed.map { $0.jsonObject() }
        object["boot_id"] = current.restore.bootID

        let encoded: Data
        do {
            encoded = try JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
        } catch {
            throw SessionStoreError.write(underlying: "could not encode the store: \(error)")
        }
        do {
            try Self.writeDurably(encoded, to: url)
        } catch {
            throw SessionStoreError.write(underlying: String(describing: error))
        }
        data = current
        retained = object
    }

    private struct POSIXFailure: Error, CustomStringConvertible {
        let call: String
        let code: Int32
        var description: String { "\(call): \(String(cString: strerror(code)))" }
    }

    /// Temp file, `fsync`, `rename`, directory `fsync`. The temporary file
    /// is created exclusively with mode 0600 (session names are private) and
    /// removed on any failure before the rename.
    static func writeDurably(_ bytes: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")

        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw POSIXFailure(call: "open", code: errno) }
        do {
            try bytes.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw POSIXFailure(call: "write", code: errno)
                    }
                    offset += written
                }
            }
            // F_FULLFSYNC asks the drive to flush its own cache too; a file
            // system that does not support it falls back to plain fsync.
            if fcntl(descriptor, F_FULLFSYNC) == -1, fsync(descriptor) == -1 {
                throw POSIXFailure(call: "fsync", code: errno)
            }
        } catch {
            close(descriptor)
            unlink(temporary.path)
            throw error
        }
        close(descriptor)

        guard rename(temporary.path, url.path) == 0 else {
            let code = errno
            unlink(temporary.path)
            throw POSIXFailure(call: "rename", code: code)
        }

        let directoryDescriptor = open(directory.path, O_RDONLY)
        if directoryDescriptor >= 0 {
            _ = fsync(directoryDescriptor)
            close(directoryDescriptor)
        }
    }
}
