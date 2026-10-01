// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AgentMenuKit

// The session store (KTD12, first slice): an app-owned JSON file holding the
// renames table. Every case runs against a `TempDir`; nothing here touches the
// real `~/Library/Application Support`. The cases that matter most are the
// refusals: a file this build cannot understand must come out of a rename
// attempt byte for byte as it went in.

private func bytes(_ url: URL) -> Data? { try? Data(contentsOf: url) }

private func names(in directory: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
}

func runSessionStoreTests(_ t: TestRunner) {
    t.suite("SessionStore")

    // MARK: 1. A missing file is a first run, not an error.

    do {
        let dir = TempDir("sessionstore-missing")
        defer { dir.cleanup() }
        let store = SessionStore(url: dir.url.appendingPathComponent("sessions.json"))
        t.expect(!store.exists, "the file does not exist yet")
        if let data = t.attempt("loading a missing store does not throw", { try store.load() }) {
            t.expect(data.renames.isEmpty, "a missing store loads empty")
        }
        t.expect(store.renames.isEmpty, "renames is empty before anything is set")
        t.expect(store.refusal == nil, "a missing file is not a refusal")
        t.expect(!store.exists, "loading wrote nothing")
    }

    // MARK: 2. Set, read back, clear; a second store on the same file sees it.

    do {
        let dir = TempDir("sessionstore-roundtrip")
        defer { dir.cleanup() }
        let url = dir.url.appendingPathComponent("sessions.json")
        let store = SessionStore(url: url)

        t.expectNoThrow("setting a rename on a missing store creates it") {
            try store.setRename("Invoices", for: "sess-1")
        }
        t.expectNoThrow("a second rename") { try store.setRename("Audit", for: "sess-2") }
        t.expectEqual(store.renames, ["sess-1": "Invoices", "sess-2": "Audit"], "both renames are held")

        let other = SessionStore(url: url)
        if let data = t.attempt("a fresh store loads the file", { try other.load() }) {
            t.expectEqual(data.renames, ["sess-1": "Invoices", "sess-2": "Audit"], "the renames table round-trips through the file")
        }
        t.expectEqual(other.renames, ["sess-1": "Invoices", "sess-2": "Audit"], "renames reflects the last load")

        t.expectNoThrow("overwriting a rename") { try store.setRename("Invoices, March", for: "sess-1") }
        t.expectEqual(store.renames["sess-1"], "Invoices, March", "the newest rename wins")

        t.expectNoThrow("clearing a rename") { try store.setRename(nil, for: "sess-1") }
        t.expect(store.renames["sess-1"] == nil, "a cleared rename is gone")
        t.expectEqual(SessionStore(url: url).renamesFromDisk(), ["sess-2": "Audit"], "the clear reached the file")

        t.expectNoThrow("clearing a rename that was never set is a no-op") { try store.setRename(nil, for: "never") }
        t.expectEqual(store.renames, ["sess-2": "Audit"], "…and changes nothing")
    }

    // MARK: 3. A blank name is a clear; names are trimmed; an empty id is ignored.

    do {
        let dir = TempDir("sessionstore-blank")
        defer { dir.cleanup() }
        let store = SessionStore(url: dir.url.appendingPathComponent("sessions.json"))
        t.expectNoThrow("set a padded name") { try store.setRename("  Padded  \n", for: "a") }
        t.expectEqual(store.renames["a"], "Padded", "a name is stored trimmed")
        t.expectNoThrow("set a whitespace-only name") { try store.setRename("   ", for: "a") }
        t.expect(store.renames["a"] == nil, "a whitespace-only name clears the rename")
        t.expectNoThrow("set nil") { try store.setRename("again", for: "a"); try store.setRename(nil, for: "a") }
        t.expect(store.renames.isEmpty, "nil clears the rename")
        t.expectNoThrow("an empty session id is ignored") { try store.setRename("x", for: "") }
        t.expect(store.renames.isEmpty, "…and nothing is stored under it")
    }

    // MARK: 4. Writes are atomic: after a save only the store file is on disk,
    // no temporary file, and the file is private to the user.

    do {
        let dir = TempDir("sessionstore-atomic")
        defer { dir.cleanup() }
        let nested = dir.url.appendingPathComponent("Application Support/dev.example.test", isDirectory: true)
        let url = nested.appendingPathComponent("sessions.json")
        let store = SessionStore(url: url)
        for index in 0..<5 {
            t.expectNoThrow("save \(index) creates the directory and writes") {
                try store.setRename("name \(index)", for: "s\(index)")
            }
        }
        t.expectEqual(names(in: nested), ["sessions.json"], "no temporary file is left after saves")
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        t.expectEqual(
            (attributes?[.posixPermissions] as? NSNumber)?.intValue, 0o600,
            "the store is readable by its owner only"
        )
        if let data = bytes(url), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            t.expectEqual((object["schema"] as? NSNumber)?.intValue, SessionStore.schemaVersion, "the file carries its schema version")
            t.expectEqual((object["renames"] as? [String: String])?.count, 5, "the file is complete JSON with every rename")
        } else {
            t.expect(false, "the store file is valid JSON")
        }
    }

    // A failed write leaves the previous file exactly as it was, and nothing
    // else in the directory. A read-only directory is the failure that can be
    // produced without a fault-injection seam.
    do {
        let dir = TempDir("sessionstore-writefail")
        let locked = dir.url.appendingPathComponent("locked", isDirectory: true)
        defer {
            _ = try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
            dir.cleanup()
        }
        let url = locked.appendingPathComponent("sessions.json")
        let store = SessionStore(url: url)
        t.expectNoThrow("first save") { try store.setRename("Keep", for: "k") }
        let before = bytes(url)
        try? FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        if getuid() != 0 {
            t.expectThrows("saving into a read-only directory throws") { try store.setRename("Lose", for: "l") }
            t.expectEqual(bytes(url), before, "the previous file is untouched by the failed write")
            t.expectEqual(names(in: locked), ["sessions.json"], "no temporary file is left by the failed write")
            t.expectEqual(store.renames, ["k": "Keep"], "a failed write does not change what the store reports")
        }
    }

    // MARK: 5. A newer schema is refused, and never overwritten.

    do {
        let dir = TempDir("sessionstore-newer")
        defer { dir.cleanup() }
        let url = dir.url.appendingPathComponent("sessions.json")
        let newer = """
        {"schema":99,"renames":{"a":"from the future"},"ledger":[{"launch":"x"}]}
        """
        try? newer.write(to: url, atomically: true, encoding: .utf8)
        let before = bytes(url)

        let store = SessionStore(url: url)
        do {
            _ = try store.load()
            t.expect(false, "loading a newer schema throws")
        } catch let error as SessionStoreError {
            if case .unsupportedSchema(let found, let supported) = error {
                t.expectEqual(found, 99, "the error names the schema found")
                t.expectEqual(supported, SessionStore.schemaVersion, "…and the one this build supports")
            } else {
                t.expect(false, "the error is unsupportedSchema, got \(error)")
            }
        } catch {
            t.expect(false, "the error is a SessionStoreError, got \(error)")
        }
        t.expect(store.refusal != nil, "the store reports it is refusing")
        t.expectThrows("setting a rename refuses") { try store.setRename("x", for: "a") }
        t.expectThrows("clearing a rename refuses") { try store.setRename(nil, for: "a") }
        t.expectEqual(bytes(url), before, "the newer file is byte-for-byte unchanged")
        t.expectEqual(names(in: dir.url), ["sessions.json"], "nothing else was written next to it")

        // A store that never called load must not write over it either.
        let eager = SessionStore(url: url)
        t.expectThrows("a store that skipped load still refuses to write") { try eager.setRename("x", for: "a") }
        t.expectEqual(bytes(url), before, "…and the file is still unchanged")
    }

    // MARK: 6. A file this build cannot read is refused, not replaced (the
    // safest reading of "corrupt": the user's renames may still be in it).

    do {
        let cases: [(String, String)] = [
            ("not JSON", "this is not json"),
            ("empty file", ""),
            ("a JSON array", "[1,2,3]"),
            ("no schema", "{\"renames\":{}}"),
            ("a string schema", "{\"schema\":\"1\",\"renames\":{}}"),
            ("a boolean schema", "{\"schema\":true,\"renames\":{}}"),
            ("a fractional schema", "{\"schema\":1.5,\"renames\":{}}"),
            ("a zero schema", "{\"schema\":0,\"renames\":{}}"),
            ("renames not an object", "{\"schema\":1,\"renames\":[\"a\"]}"),
            ("a rename that is not a string", "{\"schema\":1,\"renames\":{\"a\":7}}"),
            ("truncated JSON", "{\"schema\":1,\"renames\":{\"a\":\"Inv"),
        ]
        for (label, content) in cases {
            let dir = TempDir("sessionstore-corrupt")
            defer { dir.cleanup() }
            let url = dir.url.appendingPathComponent("sessions.json")
            try? content.write(to: url, atomically: true, encoding: .utf8)
            let before = bytes(url)
            let store = SessionStore(url: url)
            t.expectThrows("\(label): load throws") { try store.load() }
            t.expectThrows("\(label): setRename refuses") { try store.setRename("x", for: "a") }
            t.expectEqual(bytes(url), before, "\(label): the file is left exactly as it was")
            t.expectEqual(names(in: dir.url), ["sessions.json"], "\(label): nothing was written beside it")
        }
    }

    // A refusal is not permanent: once the file is readable again a load
    // clears it and writes are accepted.
    do {
        let dir = TempDir("sessionstore-recover")
        defer { dir.cleanup() }
        let url = dir.url.appendingPathComponent("sessions.json")
        try? "garbage".write(to: url, atomically: true, encoding: .utf8)
        let store = SessionStore(url: url)
        t.expectThrows("garbage refuses") { try store.load() }
        try? FileManager.default.removeItem(at: url)
        t.expectNoThrow("after the file is removed, load succeeds") { _ = try store.load() }
        t.expect(store.refusal == nil, "the refusal is cleared")
        t.expectNoThrow("and a rename is accepted") { try store.setRename("ok", for: "a") }
    }

    // MARK: 7. Forward compatibility: fields this build does not model
    // (KTD12's ledger, live set, pending set, closed stack and boot id are
    // later units') survive a rename at the same schema version.

    do {
        let dir = TempDir("sessionstore-unknown")
        defer { dir.cleanup() }
        let url = dir.url.appendingPathComponent("sessions.json")
        let source = """
        {"schema":1,"renames":{"a":"Old"},"bootId":"abc-123","closed":[{"id":"z","at":5}],"ledger":{"n":{"deep":[1,2]}}}
        """
        try? source.write(to: url, atomically: true, encoding: .utf8)
        let store = SessionStore(url: url)
        t.expectNoThrow("load a file with unknown fields") { _ = try store.load() }
        t.expectNoThrow("rename with unknown fields present") { try store.setRename("New", for: "a") }
        t.expectNoThrow("second rename") { try store.setRename("Other", for: "b") }
        if let data = bytes(url), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            t.expectEqual(object["bootId"] as? String, "abc-123", "an unknown string field is preserved")
            t.expectEqual((object["closed"] as? [[String: Any]])?.count, 1, "an unknown array field is preserved")
            t.expect(object["ledger"] != nil, "an unknown nested field is preserved")
            t.expectEqual(object["renames"] as? [String: String], ["a": "New", "b": "Other"], "the renames were updated alongside")
        } else {
            t.expect(false, "the rewritten file is valid JSON")
        }

        // Unknown fields are kept even when this store never loaded first.
        let eager = SessionStore(url: url)
        t.expectNoThrow("a rename without an explicit load") { try eager.setRename("Third", for: "c") }
        if let data = bytes(url), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            t.expectEqual(object["bootId"] as? String, "abc-123", "the field survives a write from a store that skipped load")
        }
    }

    // MARK: 8. Two stores on one file: a write re-reads first, so a rename
    // another instance made is not lost.

    do {
        let dir = TempDir("sessionstore-two")
        defer { dir.cleanup() }
        let url = dir.url.appendingPathComponent("sessions.json")
        let first = SessionStore(url: url)
        let second = SessionStore(url: url)
        t.expectNoThrow("first writes") { try first.setRename("One", for: "a") }
        t.expectNoThrow("second writes") { try second.setRename("Two", for: "b") }
        t.expectEqual(second.renames, ["a": "One", "b": "Two"], "the second store kept the first's rename")
    }

    // MARK: 9. The default path is composed from the bundle identifier, with
    // an injected home. Nothing is written to it.

    do {
        let home = URL(fileURLWithPath: "/tmp/agentmenu-home-not-real", isDirectory: true)
        t.expectEqual(
            SessionStore.url(bundleIdentifier: "dev.example.beta", homeDirectory: home).path,
            "/tmp/agentmenu-home-not-real/Library/Application Support/dev.example.beta/sessions.json",
            "the store lives under Application Support/<bundle id>"
        )
        t.expectEqual(
            SessionStore.url(bundleIdentifier: nil, homeDirectory: home).path,
            "/tmp/agentmenu-home-not-real/Library/Application Support/dev.facens.agentmenu/sessions.json",
            "without a bundle identifier (the CLI, a test run) it is the app's own"
        )
        t.expectEqual(
            SessionStore.url(bundleIdentifier: "", homeDirectory: home).path,
            "/tmp/agentmenu-home-not-real/Library/Application Support/dev.facens.agentmenu/sessions.json",
            "an empty bundle identifier is treated as none"
        )
        t.expect(
            SessionStore.defaultURL.path.hasSuffix("/Library/Application Support/dev.facens.agentmenu/sessions.json")
                || Bundle.main.bundleIdentifier != nil,
            "defaultURL resolves to the app's Application Support directory"
        )
        // It is separate from config.toml.
        t.expect(SessionStore.defaultURL != ConfigStore.defaultURL, "the store is not config.toml")
    }

    // MARK: 10. The pending reopen set, the closed stack and the boot id (U13)

    do {
        let dir = TempDir("sessionstore-restore")
        defer { dir.cleanup() }
        let url = dir.url.appendingPathComponent("sessions.json")
        let store = SessionStore(url: url)
        let when = Date(timeIntervalSince1970: 1_800_000_000)

        func session(_ id: String, cause: EndCause) -> RestorableSession {
            RestorableSession(
                sessionID: id, launchID: "launch-" + id, profileID: "work", configDirectory: "/profiles/work",
                cwd: "/projects/app", preset: Preset(model: "opus", effort: "high", keepRunning: true),
                terminalID: "iterm2", hostSocket: "/h/s", endedAt: when, cause: cause
            )
        }
        let a = session("a", cause: .together)
        let c = session("c", cause: .hostDied)
        let b = session("b", cause: .individual)

        t.expectNoThrow("writing the restore state") {
            try store.updateRestore { state in
                state.pending = PendingReopenSet(sessions: [a, c], formedAt: when, updatedAt: when.addingTimeInterval(3), cause: .hostDied, touched: true)
                state.closed = [b]
                state.bootID = "uuid:boot-1"
            }
        }
        t.expectEqual(store.restore.pendingCount, 2, "the store reports the pending count")
        t.expectEqual(store.restore.closedCount, 1, "and the closed depth")

        let reloaded = SessionStore(url: url)
        if let data = t.attempt("a fresh store loads it", { try reloaded.load() }) {
            t.expectEqual(data.restore.pending?.sessions, [a, c], "the pending set round-trips, entry for entry")
            t.expectEqual(data.restore.pending?.cause, .hostDied, "with its cause")
            t.expectEqual(data.restore.pending?.touched, true, "and whether it was acted on")
            t.expectEqual(data.restore.pending?.formedAt, when, "and when it formed")
            t.expectEqual(data.restore.pending?.updatedAt, when.addingTimeInterval(3), "and when it last grew")
            t.expectEqual(data.restore.closed, [b], "the closed stack round-trips")
            t.expectEqual(data.restore.bootID, "uuid:boot-1", "the boot id round-trips")
            t.expectEqual(data.restore.closed.first?.preset.keepRunning, true, "an entry carries its whole preset")
        }

        // Another section's changes do not disturb it, and it does not disturb
        // theirs.
        t.expectNoThrow("a rename alongside") { try store.setRename("Named", for: "a") }
        t.expectNoThrow("a ledger change alongside") {
            try store.updateLedger { $0.begin(LedgerRow(launchID: "l1", cwd: "/p", terminalID: "t", startedAt: when, causeRecordedAt: when), now: when) }
        }
        let third = SessionStore(url: url)
        _ = try? third.load()
        t.expectEqual(third.restore.pending?.sessions, [a, c], "the restore state survives a rename and a launch")
        t.expectEqual(third.ledger.rows.map(\.launchID), ["l1"], "and the ledger survives it")
        t.expectEqual(third.ledger.rows.first?.causeRecordedAt, when, "with the time its cause was recorded")

        // One write for the ledger and the restore state.
        t.expectNoThrow("update changes both in one write") {
            try store.update { data in
                data.restore.restored(["a"])
                data.ledger.update(launchID: "l1") { $0.classified = true }
            }
        }
        let fourth = SessionStore(url: url)
        _ = try? fourth.load()
        t.expectEqual(fourth.restore.pending?.sessionIDs, ["c"], "a restored session left the pending set")
        t.expectEqual(fourth.ledger.row(launchID: "l1")?.classified, true, "and the row is marked, from the same write")

        // Emptying removes the keys, so an old reader sees what it always saw.
        t.expectNoThrow("emptying the restore state") {
            try store.updateRestore { state in
                state.pending = nil
                state.closed = []
                state.bootID = nil
            }
        }
        if let data = bytes(url), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            t.expect(object["pending_reopen"] == nil && object["closed_stack"] == nil && object["boot_id"] == nil, "an emptied section leaves no key behind")
        }
    }

    // An older store file, with none of the three keys, loads and is not
    // touched by a read.
    do {
        let dir = TempDir("sessionstore-restore-old")
        defer { dir.cleanup() }
        let url = dir.url.appendingPathComponent("sessions.json")
        let source = """
        {"schema":1,"renames":{"a":"Old"},"ledger":{"rows":[{"launch_id":"l1","cwd":"/p","terminal":"t","started_at":1800000000000,"phase":"live","pid":4,"proc_start":9,"last_session_id":"s","ended_at":1800000001000,"end_cause":"individual"}]}}
        """
        try? source.write(to: url, atomically: true, encoding: .utf8)
        let before = bytes(url)
        let store = SessionStore(url: url)
        if let data = t.attempt("an older store loads", { try store.load() }) {
            t.expect(data.restore.pending == nil, "no pending set")
            t.expect(data.restore.closed.isEmpty, "no closed stack")
            t.expectEqual(data.restore.bootID, nil, "no boot id")
            t.expectEqual(data.ledger.rows.first?.classified, false, "a row from before classification is not classified")
            t.expectEqual(data.ledger.rows.first?.endCause, .individual, "its cause is read")
        }
        t.expectEqual(bytes(url), before, "loading wrote nothing")
        t.expectNoThrow("a rename on the older store") { try store.setRename("New", for: "a") }
        if let data = bytes(url), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            t.expect(object["pending_reopen"] == nil && object["closed_stack"] == nil && object["boot_id"] == nil, "and it adds none of the keys")
        }
    }

    // A section of the wrong shape is refused, never overwritten; an entry
    // that cannot be read is skipped.
    do {
        let dir = TempDir("sessionstore-restore-bad")
        defer { dir.cleanup() }
        let url = dir.url.appendingPathComponent("sessions.json")
        try? #"{"schema":1,"closed_stack":"nope"}"#.write(to: url, atomically: true, encoding: .utf8)
        let before = bytes(url)
        let store = SessionStore(url: url)
        t.expectThrows("a closed stack that is not a list is refused") { try store.load() }
        t.expectThrows("and a rename is refused with it") { try store.setRename("x", for: "a") }
        t.expectEqual(bytes(url), before, "the file is untouched")

        let tolerant = #"{"schema":1,"closed_stack":[{"session_id":"s1","launch_id":"l","cwd":"/p","terminal":"t","ended_at":1800000000000,"cause":"exited"},{"junk":true}],"pending_reopen":{"sessions":[{"junk":true}]}}"#
        try? tolerant.write(to: url, atomically: true, encoding: .utf8)
        let loaded = SessionStore(url: url)
        if let data = t.attempt("entries that cannot be read are skipped", { try loaded.load() }) {
            t.expectEqual(data.restore.closed.map(\.sessionID), ["s1"], "the readable entry is kept")
            t.expect(data.restore.pending == nil, "a set with nothing readable in it is none")
        }
    }

}

private extension SessionStore {
    /// What a brand-new store reads from the file, bypassing any state on
    /// this instance.
    func renamesFromDisk() -> [String: String] {
        (try? SessionStore(url: url).load().renames) ?? [:]
    }
}
