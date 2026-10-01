// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// One configured profile whose transcript store the index reads: the identity
/// callers know it by, and the resolved config directory that holds
/// `projects/`. Resolution (`Overrides.resolveProfileDirectory`) happens
/// before this; the index takes directories as given.
public struct TranscriptProfile: Equatable {
    public let id: String
    public let directory: URL

    public init(id: String, directory: URL) {
        self.id = id
        self.directory = directory
    }
}

/// What a transcript says about whether its session was ever prompted.
public enum PromptState: Equatable, Sendable {
    case prompted
    case neverPrompted
    case unknown
}

/// Whether a closed session can be resumed. A transcript with nothing to
/// resume from is still listed (the user may recognise it and want to know why
/// it will not open), just not offered as a click target.
public enum Restorability: Equatable {
    case restorable
    case notRestorable(reason: String)
}

/// What a transcript's recorded working directory must be before a resume types
/// it into a terminal. One rule for both places that decide: the index, which
/// marks the Closed row, and `HistoryResume.plan`, which refuses the click.
///
/// The directory ends up single-quoted in a command written to a terminal
/// (iTerm `write text`, Terminal `do script`). Quoting stops shell
/// metacharacters but not tty control bytes (0x03 is Ctrl-C, ESC starts a
/// sequence, a newline runs what precedes it), and the transcript is a file
/// anything could have written. So a directory with a control character, or
/// one that is not absolute, is refused rather than repaired.
public enum WorkingDirectoryRule {
    public struct Failure: Error, Equatable {
        /// Reads as a sentence the Closed row shows on hover.
        public let reason: String

        public init(reason: String) { self.reason = reason }
    }

    public static let missingReason = "the transcript records no working directory"
    public static let unsafeReason =
        "the transcript's working directory contains characters that can't be typed into a terminal"

    /// The directory itself when it may be typed, else why not.
    public static func check(_ cwd: String?) -> Result<String, Failure> {
        guard let cwd, !cwd.isEmpty else { return .failure(Failure(reason: missingReason)) }
        guard cwd.hasPrefix("/"),
              !cwd.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return .failure(Failure(reason: unsafeReason))
        }
        return .success(cwd)
    }
}

/// What the index learned about one transcript file, from its first and last
/// 64 KB only.
public struct TranscriptEntry: Equatable {
    /// The file's stem. Live-session and ownership lookups key on this.
    public let sessionId: String
    /// The profile whose store holds the file. For a session AgentMenu never
    /// launched this is where the account comes from on restore (R30).
    public let profileID: String
    public let configDirectory: URL
    public let transcriptURL: URL
    public let modified: Date
    public let size: Int64

    /// Taken from inside the file. The directory name is the cwd with every
    /// non-alphanumeric turned into `-`, which cannot be reversed.
    public let cwd: String?
    /// `cli`, `sdk-cli`, `claude-vscode`, `claude-desktop`, …; nil when the
    /// transcript predates the field or has no records that carry it.
    public let entrypoint: String?
    public let version: String?

    /// The first real prompt: not a tool result, not a `/clear`, not CLI noise.
    public let firstPrompt: String?
    /// Set when that prompt was a slash command.
    public let skill: SkillInvocation?

    public let agentName: String?
    public let customTitle: String?
    public let aiTitle: String?
    public let summary: String?

    public let restorability: Restorability

    /// The last path component of `cwd`, for display and search.
    public var folderName: String? { SessionRowWording.folderName(cwd) }

    /// The session's name. A rename made in AgentMenu (from the store, a later
    /// unit) beats everything the agent recorded.
    public func title(rename: String? = nil) -> SessionTitle {
        SessionTitles.resolve(
            rename: rename,
            agentName: agentName,
            customTitle: customTitle,
            aiTitle: aiTitle,
            summary: summary,
            firstPrompt: firstPrompt,
            skill: skill,
            sessionId: sessionId
        )
    }
}

/// How the index reads bytes, injectable so a test can count reads and prove a
/// small file is read once and an unchanged file is not read again.
public protocol TranscriptChunkReader {
    func read(url: URL, offset: UInt64, length: Int) throws -> Data
}

/// Reads through a `FileHandle`, never the whole file: transcripts reach 30 MB
/// and the median is 1 MB, and only their ends matter here.
public struct FileChunkReader: TranscriptChunkReader {
    public init() {}

    public func read(url: URL, offset: UInt64, length: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: length) ?? Data()
    }
}

/// Indexes Claude Code transcripts for names and history without reading them.
///
/// A transcript is JSONL, one record per line, and the facts the Closed list
/// needs sit at its two ends: cwd, entrypoint and the first prompt near the
/// start, the latest title records near the end (Claude Code rewrites them
/// last). So each file costs at most two 64 KB reads, whatever its size, and a
/// file is read again only when its size or modification time changes.
///
/// A file no larger than the two chunks together is read once, whole, rather
/// than as two overlapping reads. Where a chunk starts mid-line (the tail of a
/// large file) the partial first line is dropped, and any line that does not
/// parse, such as one cut off by the chunk edge or by a write in progress, is
/// skipped rather than failing the file.
///
/// Safe to call from any thread: the cache is guarded by a lock.
public final class TranscriptIndex: @unchecked Sendable {
    public static let defaultRetention: TimeInterval = 30 * 86_400
    public static let defaultChunkBytes = 64 * 1024

    public let retention: TimeInterval
    public let chunkBytes: Int
    private let reader: TranscriptChunkReader
    private let fileManager: FileManager

    private struct CachedFacts {
        let size: Int64
        let modified: Date
        let facts: TranscriptFacts
    }

    private let lock = NSLock()
    private var cache: [String: CachedFacts] = [:]

    /// `retention` mirrors the agent's `cleanupPeriodDays` (30 by default):
    /// files it would already have deleted are not worth listing.
    public init(
        retention: TimeInterval = TranscriptIndex.defaultRetention,
        chunkBytes: Int = TranscriptIndex.defaultChunkBytes,
        reader: TranscriptChunkReader = FileChunkReader(),
        fileManager: FileManager = .default
    ) {
        self.retention = retention
        self.chunkBytes = chunkBytes
        self.reader = reader
        self.fileManager = fileManager
    }

    /// Every transcript in each profile's store modified within the retention
    /// window, newest first. Nothing is filtered by entrypoint or liveness
    /// here; `ClosedSessionList` does that, so one scan serves both the Live
    /// lookups and the Closed list.
    ///
    /// The same config directory listed under two profiles is read once, for
    /// the first: two profiles pointing at one directory hold one transcript
    /// store, not two.
    public func scan(profiles: [TranscriptProfile], now: Date) -> [TranscriptEntry] {
        lock.lock()
        defer { lock.unlock() }

        let cutoff = now.addingTimeInterval(-retention)
        var entries: [TranscriptEntry] = []
        var seenDirectories = Set<String>()
        var seenPaths = Set<String>()

        for profile in profiles {
            let directoryKey = profile.directory.resolvingSymlinksInPath().standardizedFileURL.path
            guard seenDirectories.insert(directoryKey).inserted else { continue }

            for file in transcriptFiles(in: profile.directory) where file.modified >= cutoff {
                seenPaths.insert(file.url.path)
                let facts: TranscriptFacts
                if let hit = cache[file.url.path], hit.size == file.size, hit.modified == file.modified {
                    facts = hit.facts
                } else {
                    facts = readFacts(of: file.url, size: file.size)
                    if !facts.unreadable {
                        cache[file.url.path] = CachedFacts(size: file.size, modified: file.modified, facts: facts)
                    }
                }
                entries.append(makeEntry(file: file, profile: profile, facts: facts))
            }
        }

        // Files that left the window, or the disk, must not linger in memory.
        cache = cache.filter { seenPaths.contains($0.key) }

        return entries.sorted {
            $0.modified != $1.modified ? $0.modified > $1.modified : $0.sessionId < $1.sessionId
        }
    }

    // MARK: - One session

    /// Whether a session was ever prompted, for the restore classification
    /// (U13): a session with no user record in its transcript has nothing to
    /// resume, so it stays out of the pending set and the closed stack.
    ///
    /// Looks for `projects/*/<id>.jsonl` under each directory and reads the
    /// head of the one it finds; it lists no transcripts and keeps no cache,
    /// because it runs only when a session has ended. `neverPrompted` means a
    /// transcript with no user record, or none at all (the agent writes the
    /// file with the first prompt); `unknown` means there was nowhere to look
    /// or the file could not be read, and the caller keeps the session in.
    public func promptState(ofSession sessionID: String, in configDirectories: [URL]) -> PromptState {
        guard SessionIdentifier.isValid(sessionID) else { return .unknown }
        var looked = false
        var seen = Set<String>()
        for directory in configDirectories {
            guard seen.insert(directory.standardizedFileURL.path).inserted else { continue }
            let projects = directory.appendingPathComponent("projects", isDirectory: true)
            guard let names = try? fileManager.contentsOfDirectory(atPath: projects.path) else { continue }
            looked = true
            for name in names.sorted() {
                let file = projects.appendingPathComponent(name, isDirectory: true)
                    .appendingPathComponent("\(sessionID).jsonl")
                guard let attributes = try? fileManager.attributesOfItem(atPath: file.path),
                      let size = (attributes[.size] as? NSNumber)?.int64Value
                else { continue }
                let facts = readFacts(of: file, size: size)
                if facts.unreadable { return .unknown }
                return facts.sawUserRecord ? .prompted : .neverPrompted
            }
        }
        return looked ? .neverPrompted : .unknown
    }

    // MARK: - Enumeration

    private struct TranscriptFile {
        let url: URL
        let sessionId: String
        let size: Int64
        let modified: Date
    }

    /// `<profile>/projects/<project>/<sessionId>.jsonl`, exactly two levels:
    /// deeper files (`<sessionId>/subagents/…`) are a session's helpers, not
    /// sessions. Older CLI versions wrote sub-agent transcripts beside the
    /// sessions as `agent-<id>.jsonl`; those are skipped by name.
    private func transcriptFiles(in profileDirectory: URL) -> [TranscriptFile] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let projects = profileDirectory.appendingPathComponent("projects", isDirectory: true)
        guard let projectDirs = try? fileManager.contentsOfDirectory(
            at: projects, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [TranscriptFile] = []
        for projectDir in projectDirs {
            guard (try? projectDir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let children = try? fileManager.contentsOfDirectory(
                    at: projectDir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
                  )
            else { continue }
            for child in children where child.pathExtension == "jsonl" {
                let sessionId = child.deletingPathExtension().lastPathComponent
                guard !sessionId.hasPrefix("agent-"),
                      let values = try? child.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true,
                      let modified = values.contentModificationDate
                else { continue }
                files.append(TranscriptFile(
                    url: child,
                    sessionId: sessionId,
                    size: Int64(values.fileSize ?? 0),
                    modified: modified
                ))
            }
        }
        return files
    }

    // MARK: - Reading

    private func readFacts(of url: URL, size: Int64) -> TranscriptFacts {
        do {
            if size <= Int64(chunkBytes) * 2 {
                let whole = try reader.read(url: url, offset: 0, length: Int(size))
                var facts = TranscriptFacts.parseHead(whole)
                facts.applyTitles(fromTail: whole, dropLeadingPartialLine: false)
                return facts
            }
            let head = try reader.read(url: url, offset: 0, length: chunkBytes)
            let tail = try reader.read(url: url, offset: UInt64(size) - UInt64(chunkBytes), length: chunkBytes)
            var facts = TranscriptFacts.parseHead(head)
            facts.applyTitles(fromTail: tail, dropLeadingPartialLine: true)
            return facts
        } catch {
            var facts = TranscriptFacts()
            facts.unreadable = true
            return facts
        }
    }

    private func makeEntry(file: TranscriptFile, profile: TranscriptProfile, facts: TranscriptFacts) -> TranscriptEntry {
        let restorability: Restorability
        if facts.unreadable {
            restorability = .notRestorable(reason: "the transcript could not be read")
        } else if !facts.sawUserRecord {
            restorability = .notRestorable(reason: "the transcript has no user message to resume from")
        } else if case .failure(let problem) = WorkingDirectoryRule.check(facts.cwd) {
            restorability = .notRestorable(reason: problem.reason)
        } else {
            restorability = .restorable
        }
        return TranscriptEntry(
            sessionId: file.sessionId,
            profileID: profile.id,
            configDirectory: profile.directory,
            transcriptURL: file.url,
            modified: file.modified,
            size: file.size,
            cwd: facts.cwd,
            entrypoint: facts.entrypoint,
            version: facts.version,
            firstPrompt: facts.firstPrompt,
            skill: facts.skill,
            agentName: facts.agentName,
            customTitle: facts.customTitle,
            aiTitle: facts.aiTitle,
            summary: facts.summary,
            restorability: restorability
        )
    }
}

// MARK: - Parsing

/// The facts recovered from one transcript's two ends. Internal: callers see
/// them through `TranscriptEntry`.
struct TranscriptFacts: Equatable {
    var cwd: String?
    var entrypoint: String?
    var version: String?
    var sawUserRecord = false
    var firstPrompt: String?
    var skill: SkillInvocation?
    var agentName: String?
    var customTitle: String?
    var aiTitle: String?
    var summary: String?
    var unreadable = false

    /// A first prompt is capped: it feeds a one-line name, and a pasted page
    /// would sit in the cache for nothing.
    static let promptCap = 500

    /// Reads records from the start of the data until the first real prompt,
    /// collecting cwd, entrypoint and version from the first records that
    /// carry them. Stops there: nothing after the first prompt is needed, which
    /// is what keeps the head read cheap.
    static func parseHead(_ data: Data) -> TranscriptFacts {
        var facts = TranscriptFacts()
        forEachLine(in: data, dropLeadingPartialLine: false) { line in
            guard let record = Self.decode(line), let type = record["type"] as? String else { return true }

            facts.cwd = facts.cwd ?? nonEmpty(record["cwd"])
            facts.entrypoint = facts.entrypoint ?? nonEmpty(record["entrypoint"])
            facts.version = facts.version ?? nonEmpty(record["version"])

            // A sidechain is a sub-agent's conversation, not the session's own.
            guard type == "user", record["isSidechain"] as? Bool != true else { return true }
            facts.sawUserRecord = true

            guard record["isMeta"] as? Bool != true,
                  let text = promptText(of: record),
                  !isNoise(text)
            else { return true }

            let skill = SkillInvocation.parse(prompt: text)
            if skill?.isLifecycleCommand == true { return true }
            facts.firstPrompt = String(text.prefix(promptCap))
            facts.skill = skill
            return false
        }
        return facts
    }

    /// Takes the latest `agent-name`, `custom-title`, `ai-title` and `summary`
    /// records from data that ends where the file ends. Later records overwrite
    /// earlier ones, so several `ai-title` lines yield the last.
    mutating func applyTitles(fromTail data: Data, dropLeadingPartialLine: Bool) {
        var agentName: String?, customTitle: String?, aiTitle: String?, summary: String?
        Self.forEachLine(in: data, dropLeadingPartialLine: dropLeadingPartialLine, requiringAny: Self.titleNeedles) { line in
            guard let record = Self.decode(line), let type = record["type"] as? String else { return true }
            switch type {
            case "agent-name": agentName = Self.nonEmpty(record["agentName"]) ?? agentName
            case "custom-title": customTitle = Self.nonEmpty(record["customTitle"]) ?? customTitle
            case "ai-title": aiTitle = Self.nonEmpty(record["aiTitle"]) ?? aiTitle
            case "summary": summary = Self.nonEmpty(record["summary"]) ?? summary
            default: break
            }
            return true
        }
        self.agentName = agentName
        self.customTitle = customTitle
        self.aiTitle = aiTitle
        self.summary = summary
    }

    /// Cheap byte patterns a line must contain to be worth decoding at all.
    /// Most of a transcript's bytes are tool output and assistant text; this
    /// keeps the tail scan from decoding any of it. A false positive (a prompt
    /// that mentions "summary") is decoded and then rejected by its `type`.
    private static let titleNeedles: [[UInt8]] = [
        Array("ai-title".utf8), Array("custom-title".utf8),
        Array("agent-name".utf8), Array("\"summary\"".utf8),
    ]

    private static func nonEmpty(_ any: Any?) -> String? {
        (any as? String).trimmedNonEmpty
    }

    /// A user record's text, from either shape `content` takes: a string, or an
    /// array of blocks. A record made only of tool results (or images) is the
    /// agent's plumbing, not a prompt, and yields nil.
    private static func promptText(of record: [String: Any]) -> String? {
        guard let message = record["message"] as? [String: Any] else { return nil }
        let text: String
        if let string = message["content"] as? String {
            text = string
        } else if let blocks = message["content"] as? [[String: Any]] {
            text = blocks
                .filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }
                .joined(separator: "\n")
        } else {
            return nil
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    /// Text the CLI writes into the user channel that the user never typed.
    private static func isNoise(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("<local-command-") || trimmed.hasPrefix("[Request interrupted")
    }

    private static func decode(_ line: UnsafeRawBufferPointer) -> [String: Any]? {
        let data = Data(bytes: line.baseAddress!, count: line.count)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Calls `body` with each non-empty line's bytes, stopping when it returns
    /// false. With `requiringAny`, lines containing none of the patterns are
    /// skipped without being handed over. `dropLeadingPartialLine` discards
    /// everything up to the first newline: the chunk began mid-record, and a
    /// suffix of a line must never be mistaken for a whole one.
    private static func forEachLine(
        in data: Data,
        dropLeadingPartialLine: Bool,
        requiringAny needles: [[UInt8]] = [],
        _ body: (UnsafeRawBufferPointer) -> Bool
    ) {
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress, buffer.count > 0 else { return }
            var start = 0
            if dropLeadingPartialLine {
                guard let newline = memchr(base, 0x0A, buffer.count) else { return }
                start = base.distance(to: UnsafeRawPointer(newline)) + 1
            }
            while start < buffer.count {
                let rest = base + start
                let length: Int
                if let newline = memchr(rest, 0x0A, buffer.count - start) {
                    length = rest.distance(to: UnsafeRawPointer(newline))
                } else {
                    length = buffer.count - start
                }
                if length > 0 {
                    let line = UnsafeRawBufferPointer(start: rest, count: length)
                    let wanted = needles.isEmpty || needles.contains { needle in
                        needle.withUnsafeBytes { memmem(rest, length, $0.baseAddress!, needle.count) != nil }
                    }
                    if wanted, !body(line) { return }
                }
                start += length + 1
            }
        }
    }
}
