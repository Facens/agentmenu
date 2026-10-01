// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Dispatch
import Foundation

/// What happened to a watched path. A small set of its own so the monitor's
/// logic — and its tests — do not depend on `DispatchSource` flags.
public struct FileEvents: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let write = FileEvents(rawValue: 1 << 0)
    public static let delete = FileEvents(rawValue: 1 << 1)
    public static let rename = FileEvents(rawValue: 1 << 2)
}

/// A live watch. Cancelling it is final; arm a new one instead.
public protocol WatchHandle: AnyObject {
    func cancel()
}

/// The one thing the monitor needs from the file system: to be told when a
/// path changes. Injectable so tests can fire events by hand.
public protocol FileWatching {
    /// nil when the path cannot be watched — it does not exist, or the
    /// descriptor could not be opened.
    func watch(_ url: URL, handler: @escaping (FileEvents) -> Void) -> WatchHandle?
}

/// `FileWatching` over kqueue vnode sources.
///
/// Handlers run on the queue given at creation, which should be the queue
/// the `RegistryMonitor` is used from.
public final class VnodeWatcher: FileWatching {
    private let queue: DispatchQueue

    public init(queue: DispatchQueue = .main) {
        self.queue = queue
    }

    private final class Handle: WatchHandle {
        let source: DispatchSourceFileSystemObject
        init(source: DispatchSourceFileSystemObject) { self.source = source }
        func cancel() { source.cancel() }
        deinit { source.cancel() }
    }

    public func watch(_ url: URL, handler: @escaping (FileEvents) -> Void) -> WatchHandle? {
        // O_EVTONLY: a descriptor for events only, which does not keep the
        // volume busy or count as an open for reading.
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            // `.extend` as well as `.write`: a file that grows is reported as
            // extend, not write.
            eventMask: [.write, .extend, .delete, .rename],
            queue: queue
        )
        source.setEventHandler { [weak source] in
            guard let data = source?.data else { return }
            var events: FileEvents = []
            if !data.isDisjoint(with: [.write, .extend]) { events.insert(.write) }
            if data.contains(.delete) { events.insert(.delete) }
            if data.contains(.rename) { events.insert(.rename) }
            handler(events)
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return Handle(source: source)
    }
}

/// Keeps a `RegistryReader`'s picture of the world current without polling
/// for it (KTD9).
///
/// Two kinds of watch, because Claude Code rewrites each registry file **in
/// place** and a directory watch does not see that:
///
/// - a directory watch on each `sessions/` catches a file appearing or
///   disappearing — a session starting or ending;
/// - a watch on each file catches its contents changing — a status change.
///
/// File watches are re-armed as files come and go, and re-armed after a
/// delete or rename event, because a watch follows the vnode it opened and a
/// file replaced by rename is a new vnode. Until a profile has a `sessions/`
/// directory the profile directory is watched instead, so the first session
/// ever started is noticed.
///
/// The monitor does not own the 2-second sweep: whoever holds it calls
/// `sweep()` on a timer while any session is listed, which is what catches a
/// process that died without its file being removed. Everything runs on one
/// queue — the one the watcher delivers on and the caller calls from.
public final class RegistryMonitor {
    private let reader: RegistryReader
    private let watcher: FileWatching
    private let onChange: ([LiveSession]) -> Void

    /// The sessions as of the last refresh.
    public private(set) var sessions: [LiveSession] = []
    /// The session ids of every live registry row as of the last refresh,
    /// including the rows the list leaves out (see `RegistryReader.liveSessionIDs`).
    public private(set) var liveSessionIDs: Set<String> = []
    /// Called on start and then only when `liveSessionIDs` changes. Separate
    /// from `onChange` because an IDE-hosted row appearing changes this set
    /// and not the displayed list. Set it before `start()`.
    public var onLiveSessionIDsChange: ((Set<String>) -> Void)?
    private var published = false
    private var publishedIDs = false
    private var running = false

    private var directoryWatches: [String: (watching: String, handle: WatchHandle)] = [:]
    private var fileWatches: [String: WatchHandle] = [:]

    /// - Parameter onChange: called on start and then only when the list of
    ///   sessions differs from the one last delivered.
    public init(
        reader: RegistryReader,
        watcher: FileWatching,
        onChange: @escaping ([LiveSession]) -> Void
    ) {
        self.reader = reader
        self.watcher = watcher
        self.onChange = onChange
    }

    deinit { stop() }

    public func start() {
        running = true
        refreshAndRearm()
    }

    public func stop() {
        running = false
        directoryWatches.values.forEach { $0.handle.cancel() }
        fileWatches.values.forEach { $0.cancel() }
        directoryWatches = [:]
        fileWatches = [:]
    }

    /// Re-reads everything and repairs the watches. The sweep timer's
    /// entry point, and safe to call at any time.
    public func sweep() {
        guard running else { return }
        refreshAndRearm()
    }

    private func refreshAndRearm() {
        publish(reader.refresh())
        // A watch armed after the read cannot have seen a write that landed
        // in between, so a fresh arming is followed by one more read.
        if rearm() { publish(reader.refresh()) }
    }

    private func publish(_ latest: [LiveSession]) {
        // The ids first: a listener of the list that reads them finds them
        // current.
        let ids = reader.liveSessionIDs
        let idsChanged = !publishedIDs || ids != liveSessionIDs
        if idsChanged {
            publishedIDs = true
            liveSessionIDs = ids
        }
        if !published || latest != sessions {
            published = true
            sessions = latest
            onChange(latest)
        }
        if idsChanged { onLiveSessionIDsChange?(ids) }
    }

    /// Brings the watches in line with the files that exist now. True when it
    /// armed anything new.
    private func rearm() -> Bool {
        var armed = false
        let fileManager = FileManager.default

        // Directory watches: one per profile.
        var wanted: [String: String] = [:]
        let sessionsDirectories = reader.sessionsDirectories
        let profileDirectories = reader.profileDirectories
        for (sessions, profile) in zip(sessionsDirectories, profileDirectories) {
            if fileManager.fileExists(atPath: sessions.path) {
                wanted[sessions.path] = sessions.path
            } else if fileManager.fileExists(atPath: profile.path) {
                wanted[sessions.path] = profile.path
            }
        }
        for (key, entry) in directoryWatches where wanted[key] != entry.watching {
            entry.handle.cancel()
            directoryWatches[key] = nil
        }
        for (key, path) in wanted where directoryWatches[key] == nil {
            let handle = watcher.watch(URL(fileURLWithPath: path)) { [weak self] _ in
                self?.refreshAndRearm()
            }
            if let handle {
                directoryWatches[key] = (path, handle)
                armed = true
            }
        }

        // File watches: one per registry file that exists.
        let present = Set(reader.registryFiles.map(\.path))
        for (path, handle) in fileWatches where !present.contains(path) {
            handle.cancel()
            fileWatches[path] = nil
        }
        for path in present where fileWatches[path] == nil {
            let handle = watcher.watch(URL(fileURLWithPath: path)) { [weak self] events in
                guard let self else { return }
                if !events.isDisjoint(with: [.delete, .rename]) {
                    // That vnode is gone; whatever is at the path now is a
                    // different one and needs a new watch.
                    self.fileWatches[path]?.cancel()
                    self.fileWatches[path] = nil
                }
                self.refreshAndRearm()
            }
            if let handle {
                fileWatches[path] = handle
                armed = true
            }
        }
        return armed
    }
}
