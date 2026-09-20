// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation

/// A refusal to write, carrying the one sentence the app logs.
///
/// Refusing is a normal outcome here, not an exception in the "something went
/// wrong" sense: a key naming `../x` is a request the app is contractually
/// required to turn down, and the only trace it may leave is this sentence
/// (AE11).
public struct JournalRefusal: Error, CustomStringConvertible, Equatable {
    public let reason: String

    public init(_ reason: String) {
        self.reason = reason
    }

    public var description: String { reason }
}

/// What a launch found when it looked for the hook.
public enum JournalActivation {
    /// No key: nothing is written, any journal left behind has been deleted,
    /// and nothing else about the launch changes (AE6).
    case inert
    /// The key named a usable file; this is the writer.
    case writing(Journal)
    /// The key named something the contract forbids. Nothing was created,
    /// anywhere; the caller logs `reason` once and carries on (AE11).
    case refused(reason: String)
}

/// The read-only state hook's journal: NDJSON, one event per line, written
/// only when a `UserDefaults` key names it (KTD3, R13, R16).
///
/// This type is a security boundary, not a logging convenience. The key that
/// turns it on can be set by any process running as the user, so the writer
/// has to be safe against a key value that names something other than what it
/// claims to. That is why the file handling here is POSIX rather than
/// `FileManager`, which is the opposite of `ConfigStore`'s choice and
/// deliberately so:
///
/// - `FileManager` and `String.write(to:)` follow symlinks, so either would
///   turn "name a file in my own directory" into "write anywhere the user can
///   write". `Darwin.open` with `O_NOFOLLOW` refuses instead.
/// - Checking the path and then opening it is two operations on a name, and a
///   name can be replaced between them. Every check here is made on the
///   *descriptor* — `fstat`, not `stat` — so there is nothing to swap.
/// - The size cap rewrites the file it already holds open, through that same
///   descriptor. Re-resolving the path to trim it would hand back the
///   guarantee the open had just established.
/// - The descriptor is opened `O_APPEND` and written with one unbuffered
///   `write(2)` per line, so a line is never interleaved with another writer's
///   and a process that dies mid-run leaves whole lines behind it.
///
/// It never computes anything and never changes what the app does, in the
/// spirit of `UsageReader`: every value on a line is something the app had
/// already decided on its own.
public final class Journal: @unchecked Sendable {
    /// The shape of a line. Bumped when a field is added, removed or
    /// reinterpreted, never for a new event name — the vocabulary is an enum
    /// and a reader that does not know an event simply does not match it.
    public static let schemaVersion = 1

    /// The key that turns the hook on, read from the active defaults domain
    /// (KTD4). Its value is a leaf file name — never a path.
    public static let journalKey = "harnessJournal"
    /// The run nonce the gate generates (KTD7), echoed on every line so a
    /// report cannot be built from an older run's journal.
    public static let nonceKey = "harnessNonce"

    /// The fixed cap, 1 MiB. Around ten thousand lines of the payloads this
    /// app writes — far more than any scenario produces, and small enough
    /// that the whole file is a cheap read for the trim and for
    /// `guest/wait.sh`, which re-reads it on every poll.
    public static let defaultMaximumBytes = 1 << 20

    /// `~/Library/Application Support/dev.facens.agentmenu/harness/`.
    ///
    /// Built from `homeDirectoryForCurrentUser` for the same reason
    /// `ConfigStore.defaultURL` is: it is the one answer that does not depend
    /// on where the process was started. KTD4 notes that a `HOME` override
    /// does not reach it, which is precisely why the directory is injected
    /// rather than looked up inside the writer.
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/dev.facens.agentmenu/harness")
    }

    private let lock = NSLock()
    private let fd: Int32
    private let build: String
    private let nonce: String?
    private let maximumBytes: Int
    private let clock: () -> Date
    private var nextSequence: Int
    /// Settled before the instance escapes `open`, then never written again,
    /// which is why it is read without the lock.
    private var boot: Int

    /// How many times a journal has been started at this path, this one
    /// included. A relaunch or a reboot continues the file, so the counter is
    /// what tells two runs apart inside one journal (KTD3).
    public var bootCount: Int { boot }

    /// The sequence the next line will carry. Continues across a relaunch.
    public var nextSeq: Int {
        lock.lock()
        defer { lock.unlock() }
        return nextSequence
    }

    private init(
        fd: Int32,
        build: String,
        nonce: String?,
        maximumBytes: Int,
        clock: @escaping () -> Date,
        nextSequence: Int,
        boot: Int
    ) {
        self.fd = fd
        self.build = build
        self.nonce = nonce
        self.maximumBytes = maximumBytes
        self.clock = clock
        self.nextSequence = nextSequence
        self.boot = boot
    }

    deinit {
        Darwin.close(fd)
    }

    // MARK: - Activation

    /// The whole launch-time decision, in one place: open a journal, stay
    /// inert, or refuse.
    ///
    /// `defaults` and `directory` are injected rather than looked up. Today
    /// the app passes `UserDefaults.standard` and `defaultDirectory`; **U7**
    /// resolves both per KTD4 — the isolated defaults suite and whatever
    /// `AGENTMENU_HARNESS_DIR` names — and passes them here without touching
    /// anything in this file.
    ///
    /// The order matters and is part of the contract: the name is validated
    /// before anything is created, so a refused key leaves no directory, no
    /// file and no trace beyond the sentence the caller logs (AE11).
    public static func activate(
        defaults: UserDefaults,
        directory: URL,
        build: String,
        maximumBytes: Int = Journal.defaultMaximumBytes,
        clock: @escaping () -> Date = Date.init
    ) -> JournalActivation {
        guard let raw = defaults.object(forKey: journalKey) else {
            // No key: this is an ordinary launch. Anything a previous harness
            // run left behind goes now, so "no hook requested" and "no
            // journal on disk" are the same state (AE6).
            clean(directory: directory)
            return .inert
        }
        // `object(forKey:)` rather than `string(forKey:)`: the latter turns a
        // number written with `defaults write -int` into "5", which would
        // quietly accept a value that is not a file name at all.
        guard let name = raw as? String else {
            return .refused(reason: "\(journalKey) is not a string; it names a journal file by leaf name")
        }
        do {
            let nonce = defaults.object(forKey: nonceKey) as? String
            let journal = try open(
                directory: directory,
                name: name,
                build: build,
                nonce: nonce,
                maximumBytes: maximumBytes,
                clock: clock
            )
            return .writing(journal)
        } catch let refusal as JournalRefusal {
            return .refused(reason: refusal.reason)
        } catch {
            return .refused(reason: String(describing: error))
        }
    }

    // MARK: - The name

    /// A leaf file name, and nothing else (KTD3).
    ///
    /// The rule is deliberately wider than "reject an absolute path": any
    /// separator and any `..` anywhere are refused, so `a/b`, `../x` and
    /// `x/../../etc/passwd` all fail the same check, and so does a name that
    /// only looks harmless because of how some later API would resolve it.
    /// Control characters are refused too — a name may legally contain a
    /// newline, and the refusal line the app logs must stay one line.
    public static func validate(name: String) throws {
        func refuse(_ why: String) -> JournalRefusal {
            JournalRefusal("\(journalKey) refused: \(why)")
        }
        guard !name.isEmpty else { throw refuse("the name is empty") }
        guard !name.contains("/") else { throw refuse("a journal name may not contain a path separator") }
        guard !name.contains("..") else { throw refuse("a journal name may not contain \"..\"") }
        guard name != "." else { throw refuse("\".\" is not a file name") }
        guard !name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw refuse("a journal name may not contain control characters")
        }
        guard name.utf8.count <= 255 else { throw refuse("a journal name may not exceed 255 bytes") }
    }

    // MARK: - Opening

    /// Opens (or continues) the journal at `directory/name`.
    ///
    /// Every clause of KTD3's file contract is enforced here, in this order:
    /// the name is a leaf name; the directory is opened without following a
    /// link at its last component; the file is created inside it with
    /// `openat`, so the name cannot address anything outside that directory;
    /// creation is `O_CREAT|O_EXCL` at mode 0600; an existing name is
    /// reopened `O_NOFOLLOW`, which is what turns a symlink into a refusal;
    /// and the descriptor — not the path — is then checked to be a regular
    /// file this user owns with no other name pointing at it.
    public static func open(
        directory: URL,
        name: String,
        build: String,
        nonce: String? = nil,
        maximumBytes: Int = Journal.defaultMaximumBytes,
        clock: @escaping () -> Date = Date.init
    ) throws -> Journal {
        try validate(name: name)

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw JournalRefusal("could not create the harness directory at \(directory.path): \(error.localizedDescription)")
        }

        // `O_NOFOLLOW` on the directory as well: the journal is confined to
        // the app's own harness directory, and a symlink standing in for that
        // directory would move the whole thing elsewhere.
        let dirfd = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard dirfd >= 0 else {
            throw JournalRefusal("could not open the harness directory at \(directory.path): \(Self.describe(errno))")
        }
        defer { Darwin.close(dirfd) }

        // `O_CLOEXEC`: this app spawns `osascript` and its own CLI, and a
        // descriptor onto the journal is not theirs to inherit.
        let creationFlags = O_RDWR | O_CREAT | O_EXCL | O_APPEND | O_NOFOLLOW | O_CLOEXEC
        var fd = openat(dirfd, name, creationFlags, mode_t(0o600))
        var created = true
        if fd < 0 {
            let creationError = errno
            guard creationError == EEXIST else {
                throw JournalRefusal("could not create \(name) in the harness directory: \(Self.describe(creationError))")
            }
            // The name is taken. Reopen it — never truncating, never
            // following: a symlink fails here with ELOOP, which is the
            // refusal KTD3 asks for.
            created = false
            fd = openat(dirfd, name, O_RDWR | O_APPEND | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else {
                let openError = errno
                if openError == ELOOP {
                    throw JournalRefusal("\(name) in the harness directory is a symlink; the journal is never written through one")
                }
                throw JournalRefusal("could not open \(name) in the harness directory: \(Self.describe(openError))")
            }
        }

        var info = stat()
        guard fstat(fd, &info) == 0 else {
            let statError = errno
            Darwin.close(fd)
            throw JournalRefusal("could not inspect \(name) in the harness directory: \(Self.describe(statError))")
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            Darwin.close(fd)
            throw JournalRefusal("\(name) in the harness directory is not a regular file")
        }
        guard info.st_uid == getuid() else {
            Darwin.close(fd)
            throw JournalRefusal("\(name) in the harness directory is owned by another user")
        }
        // A second hard link means the same bytes have another name, in a
        // directory this app has no business writing into — the one way a
        // regular file the user owns can still be a write primitive.
        guard info.st_nlink == 1 else {
            Darwin.close(fd)
            throw JournalRefusal("\(name) in the harness directory has more than one name")
        }
        // Restores the mode the contract promises on a file that already
        // existed, and makes creation's mode independent of the umask.
        _ = fchmod(fd, mode_t(0o600))

        let journal = Journal(
            fd: fd,
            build: build,
            nonce: nonce,
            maximumBytes: maximumBytes,
            clock: clock,
            nextSequence: 1,
            boot: 1
        )
        if !created {
            journal.continueFromExistingContent()
        }
        return journal
    }

    /// Picks the sequence and boot counter up where the file left them.
    ///
    /// Read from the last line that parses, not from a line count: the cap
    /// drops the oldest lines, so counting would rewind `seq` the first time
    /// a journal is trimmed and a reader would see it go backwards.
    private func continueFromExistingContent() {
        let content = readAll()
        guard !content.isEmpty else { return }
        var lastSeq: Int?
        var lastBoot: Int?
        for line in content.split(separator: 0x0A) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if let seq = object["seq"] as? Int { lastSeq = seq }
            if let data = object["data"] as? [String: Any], let boot = data["boot"] as? Int { lastBoot = boot }
        }
        if let lastSeq { nextSequence = lastSeq + 1 }
        if let lastBoot { boot = lastBoot + 1 }
    }

    // MARK: - Writing

    /// Writes the run's first line: `harness started`, the fixture echo, and
    /// the boot counter (KTD3).
    public func start(fixture: [String: JournalValue]) {
        var data = fixture
        data["boot"] = .integer(bootCount)
        append(.harnessStarted, data)
    }

    /// Appends one line. Never throws and never reports: a journal that
    /// cannot be written must not change what the app does (R13), and the
    /// app has already surfaced anything the user needs to know through its
    /// own UI.
    public func append(_ event: JournalEvent, _ data: [String: JournalValue] = [:]) {
        lock.lock()
        defer { lock.unlock() }

        var line: [String: Any] = [
            "seq": nextSequence,
            "t": Self.timestamp(clock()),
            "schema": Self.schemaVersion,
            "build": build,
            "event": event.rawValue,
            "data": JournalValue.object(data).jsonObject,
        ]
        // Always present, so every line has the same shape whether or not the
        // gate supplied a nonce for this run.
        if let nonce {
            line["nonce"] = nonce
        } else {
            line["nonce"] = NSNull()
        }

        // `JSONSerialization` escapes every control character, so a value
        // carrying a newline cannot break the one-object-per-line invariant
        // the readers depend on. `sortedKeys` makes a line diffable;
        // `withoutEscapingSlashes` keeps paths legible.
        guard var bytes = try? JSONSerialization.data(
            withJSONObject: line,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ) else { return }
        bytes.append(0x0A)

        trimIfNeeded(for: bytes.count)
        guard writeAll(bytes) else { return }
        // No `fsync` per line, on purpose. The line is already whole and
        // visible to every reader the moment `write(2)` returns — there is no
        // buffer on this side of it, so the app dying mid-run cannot lose or
        // halve a line, which is the guarantee KTD3 asks for. A flush would
        // only add durability against the *host* dying, and it would add it
        // on the main actor: `detecting finished` and `launch requested` sit
        // in the click path, and the reader polls twice a second. The first
        // line is the one exception — it carries the nonce and the fixture
        // echo a whole report is built from, and it is written once.
        if event == .harnessStarted {
            _ = fsync(fd)
        }
        nextSequence += 1
    }

    /// Drops whole lines from the front until the new one fits under the cap.
    ///
    /// Done through the open descriptor: `ftruncate` and `write` on `fd`,
    /// never a second `open` of the path. Re-resolving the name here would
    /// reintroduce exactly the symlink and swap hazards the open ruled out —
    /// a cap implemented with `String.write(to:)` is a write primitive with
    /// extra steps.
    private func trimIfNeeded(for incoming: Int) {
        var info = stat()
        guard fstat(fd, &info) == 0 else { return }
        let size = Int(info.st_size)
        guard size + incoming > maximumBytes else { return }

        let content = readAll()
        var cut = 0
        // Only whole lines are dropped, so the file always starts at a line
        // boundary and a reader never sees a half line at the front.
        while content.count - cut + incoming > maximumBytes {
            guard let newline = content[content.startIndex.advanced(by: cut)...].firstIndex(of: 0x0A) else {
                cut = content.count
                break
            }
            cut = content.distance(from: content.startIndex, to: newline) + 1
        }
        let kept = Data(content[content.startIndex.advanced(by: cut)...])
        guard ftruncate(fd, 0) == 0 else { return }
        if !kept.isEmpty {
            _ = writeAll(kept)
        }
    }

    /// One line, one `write(2)`, retried only when the kernel took part of it
    /// or was interrupted. Unbuffered on purpose: there is no `FileHandle` or
    /// stdio layer holding bytes back, so every line a reader has seen is a
    /// line that is really on disk.
    @discardableResult
    private func writeAll(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard var pointer = raw.baseAddress else { return true }
            var remaining = raw.count
            while remaining > 0 {
                let written = Darwin.write(fd, pointer, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if written == 0 { return false }
                pointer = pointer.advanced(by: written)
                remaining -= written
            }
            return true
        }
    }

    /// The whole file, read through the descriptor with `pread` so the
    /// append offset is never disturbed.
    private func readAll() -> Data {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size > 0 else { return Data() }
        var buffer = [UInt8](repeating: 0, count: Int(info.st_size))
        var total = 0
        while total < buffer.count {
            let read = buffer.withUnsafeMutableBytes { raw -> Int in
                pread(fd, raw.baseAddress!.advanced(by: total), raw.count - total, off_t(total))
            }
            if read < 0 {
                if errno == EINTR { continue }
                return Data()
            }
            if read == 0 { break }
            total += read
        }
        return Data(buffer[0..<total])
    }

    // MARK: - Cleanup

    /// Deletes the journals a previous run left in `directory` (KTD3).
    ///
    /// Only files this writer could have written: a regular file, not a
    /// symlink, owned by this user, whose first line parses as a journal
    /// line. The harness directory is shared with whatever KTD4's override
    /// points at, and `harness/run.sh` keeps a run's `report.json`,
    /// `steps.ndjson` and `evidence.ndjson` next to the journal it collects —
    /// "delete every file here" would destroy the evidence of the very run
    /// asking for the journal.
    ///
    /// Creates nothing: with no directory there is nothing to clean, and a
    /// normal launch must leave no trace of the harness at all (AE6).
    public static func clean(directory: URL) {
        let dirfd = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard dirfd >= 0 else { return }
        guard let stream = fdopendir(dirfd) else {
            Darwin.close(dirfd)
            return
        }
        defer { closedir(stream) }   // closes dirfd with it

        while let entry = readdir(stream) {
            var record = entry.pointee
            // The capacity is read before the pointer is taken: `d_name` is a
            // fixed-size C array, and reading it inside the closure would be a
            // second access to the same storage the closure already holds.
            let capacity = MemoryLayout.size(ofValue: record.d_name)
            let name = withUnsafePointer(to: &record.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: capacity) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != ".." else { continue }

            var info = stat()
            // `AT_SYMLINK_NOFOLLOW`: a symlink here is not ours to remove and
            // is certainly not a journal — it is left in place, where it will
            // be refused the next time the hook is asked for.
            guard fstatat(dirfd, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  (info.st_mode & S_IFMT) == S_IFREG,
                  info.st_uid == getuid(),
                  looksLikeAJournal(dirfd: dirfd, name: name)
            else { continue }
            _ = unlinkat(dirfd, name, 0)
        }
    }

    /// Whether the first line of `name` is a line this writer wrote: a JSON
    /// object carrying the two fields every line has.
    private static func looksLikeAJournal(dirfd: Int32, name: String) -> Bool {
        let fd = openat(dirfd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }

        var buffer = [UInt8](repeating: 0, count: 4096)
        let read = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, 0) }
        guard read > 0 else { return false }
        let head = Data(buffer[0..<read])
        guard let newline = head.firstIndex(of: 0x0A) else { return false }
        guard let object = try? JSONSerialization.jsonObject(with: head[..<newline]) as? [String: Any] else {
            return false
        }
        return object["schema"] != nil && object["event"] != nil
    }

    // MARK: - Helpers

    /// UTC, with milliseconds, so two lines written in the same second still
    /// order and a report can line a journal up against a screenshot.
    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    static func timestamp(_ date: Date) -> String {
        timestampFormatter.string(from: date)
    }

    private static func describe(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}
