// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation
import AgentMenuKit

/// `agentmenu statusline-bridge --profile-dir <dir> [--chain <command>]`
/// (R26, R47): what `install-statusline`'s two-line script execs on every
/// status-line refresh. Hidden — kept out of `--help`; a person never types
/// this by hand.
///
/// Reads Claude Code's `statusLine` stdin once, writes the rate-limit
/// snapshot and hourly history `UsageReader`/`UsageHistory` read (throttled
/// to once a minute), then runs the chained command — if any — with the same
/// stdin and mirrors its stdout, stderr, and exit status. Never fails the
/// status line itself: any error writing the snapshot or history is
/// swallowed, so the chained command's own output still appears; a chain
/// that exits on its own propagates its exit status untouched. The one
/// exception is a chain that is still running past `chainTimeout`
/// (finding #4): the bridge forwards whatever it had already printed and
/// reports failure (exit 124) rather than wait on it indefinitely — R47's
/// "never fail the status line" is about not hanging it, not about
/// reproducing a slow chain's exit status byte-for-byte.
func runStatuslineBridge(_ args: [String]) -> Int32 {
    // R47's whole contract is "never break the status line." A chain that
    // does not read stdin (most status-line scripts don't) closes its read
    // end as soon as it starts, and the default action for a write to a
    // pipe nobody is reading is to kill the writer — this whole process —
    // before the chain's own output ever gets forwarded. Ignore it once,
    // here, rather than risk a write anywhere forgetting to guard itself
    // (finding #5).
    signal(SIGPIPE, SIG_IGN)

    var profileDirectory: String?
    var chain: String?

    var index = 0
    while index < args.count {
        switch args[index] {
        case "--profile-dir":
            index += 1
            guard index < args.count else {
                fail("agentmenu statusline-bridge: --profile-dir requires a path")
                return 2
            }
            profileDirectory = args[index]
        case "--chain":
            index += 1
            guard index < args.count else {
                fail("agentmenu statusline-bridge: --chain requires a command")
                return 2
            }
            chain = args[index]
        default:
            fail("agentmenu statusline-bridge: unknown argument '\(args[index])'")
            return 2
        }
        index += 1
    }

    guard let profileDirectory else {
        fail("agentmenu statusline-bridge: --profile-dir is required")
        return 2
    }

    let stdinData = FileHandle.standardInput.readDataToEndOfFile()
    let directoryURL = URL(fileURLWithPath: (profileDirectory as NSString).expandingTildeInPath)

    writeUsageFiles(stdinData: stdinData, profileDirectory: directoryURL, now: Date())

    guard let chain, !chain.isEmpty else {
        return 0
    }
    return runChain(chain, stdin: stdinData)
}

/// Writes the snapshot and hourly history when the throttle allows it, both
/// gated by the same check so there is one throttle, not two. Every failure
/// here is swallowed by design (R47: the bridge must never take the status
/// line down with it) — nothing in this function is allowed to propagate.
private func writeUsageFiles(stdinData: Data, profileDirectory: URL, now: Date) {
    let snapshotURL = profileDirectory.appendingPathComponent(StatuslineBridge.snapshotFilename)
    let historyURL = profileDirectory.appendingPathComponent(UsageHistory.fileName)

    let existingSnapshot = try? Data(contentsOf: snapshotURL)
    // The throttle, unless this payload knows a window the file does not —
    // see `carriesNewWindow`. Every session renders about once a minute, so
    // a plain throttle hands the file to whichever one fires first after the
    // boundary, and an idle session that never reports the 5-hour window
    // keeps it out of the file indefinitely.
    guard StatuslineBridge.shouldWrite(existing: existingSnapshot, now: now)
        || StatuslineBridge.carriesNewWindow(stdin: stdinData, existing: existingSnapshot, now: now)
    else { return }

    if let snapshotData = StatuslineBridge.snapshotJSON(from: stdinData, existing: existingSnapshot, now: now) {
        try? StatuslineBridge.atomicWrite(snapshotData, to: snapshotURL)
    }

    if let row = StatuslineBridge.historyRow(from: stdinData, now: now) {
        let existingHistory = try? String(contentsOf: historyURL, encoding: .utf8)
        let newHistory = StatuslineBridge.mergeHistory(existing: existingHistory, row: row, now: now)
        if let data = newHistory.data(using: .utf8) {
            try? StatuslineBridge.atomicWrite(data, to: historyURL)
        }
    }
}

/// Wall-clock cap on the chained command: past this, the bridge stops
/// waiting and forwards whatever it has rather than hang the status line
/// indefinitely (finding #4). A status line refreshes constantly, so a
/// chain that is still this slow is not going to become useful by waiting
/// longer — R47's whole contract is that nothing chained to it can take the
/// status line down with it.
private let chainTimeout: TimeInterval = 5

/// Redirects one of a chained process's std streams to a temp file rather
/// than a pipe, and forwards it once the child has exited (or the wall-
/// clock cap has passed).
///
/// EOF on a pipe's read end arrives only once *every* holder of its write
/// end has closed it, and a chain that backgrounds a process (e.g. `(sleep
/// 30 &) ; echo quick-line`) leaves a grandchild holding that write end
/// open long after the chain itself has exited and already printed — so
/// reading the pipe to EOF blocks on a grandchild the chain has nothing
/// further to do with (finding #4). That hazard applies to stdout and
/// stderr independently — a grandchild that only inherits stderr (or only
/// stdout) still wedges whichever pipe it holds — so both streams get this
/// treatment, not just stdout. A regular file has no such "every writer"
/// semantics: once the immediate child exits, whatever it wrote is already
/// on disk, regardless of whether some detached grandchild still has the fd
/// open.
private final class ChainStreamCapture {
    private let tempURL: URL
    private let tempFileCreated: Bool
    private let outputHandle: FileHandle?
    private let fallbackPipe: Pipe

    init() {
        fallbackPipe = Pipe()
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentmenu-statusline-chain-\(UUID().uuidString)")
        tempFileCreated = FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        // Prefer the temp file; fall back to the pipe if it can't be
        // created (an unwritable /tmp, say) rather than refuse to run the
        // chain at all — a write failure here must not itself break the
        // status line (R47).
        outputHandle = tempFileCreated ? try? FileHandle(forWritingTo: tempURL) : nil
    }

    /// What to assign to `process.standardOutput` / `.standardError`.
    var processHandle: Any { outputHandle ?? fallbackPipe }

    /// Closes the write side, reads whatever the child wrote, and forwards
    /// it to `destination`. Call once, after the child has exited or the
    /// timeout has passed.
    func forwardAndCleanup(to destination: FileHandle) {
        defer { if tempFileCreated { try? FileManager.default.removeItem(at: tempURL) } }
        let data: Data
        if let outputHandle {
            try? outputHandle.close()
            data = (try? Data(contentsOf: tempURL)) ?? Data()
        } else {
            // Fallback path only: still subject to the pipe's EOF-on-every-
            // writer-closed semantics, so a chain that both backgrounds a
            // process AND hits this fallback can still block here past
            // `chainTimeout` — the narrow residual risk of falling back at
            // all.
            data = fallbackPipe.fileHandleForReading.readDataToEndOfFile()
        }
        destination.write(data)
    }
}

/// Runs the chained command with `stdin` on its own stdin, mirrors its
/// stdout and stderr to ours, and returns its exit status.
///
/// The child's stdin is written from a background queue rather than
/// serially before reading stdout/stderr — a payload bigger than the pipe
/// buffer would otherwise deadlock (this process still writing, the child
/// blocked on a full stdin pipe nobody is draining yet) — using the
/// throwing write API rather than the non-throwing one, so a chain that
/// never reads stdin (closing the pipe on its end) surfaces as a caught
/// error instead of silently taking this process down with the default
/// `SIGPIPE` action — which `signal(SIGPIPE, SIG_IGN)` at the bridge's
/// entry point also guards against (finding #5).
private func runChain(_ chain: String, stdin: Data) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", chain]

    let stdinPipe = Pipe()
    process.standardInput = stdinPipe

    let stdoutCapture = ChainStreamCapture()
    let stderrCapture = ChainStreamCapture()
    process.standardOutput = stdoutCapture.processHandle
    process.standardError = stderrCapture.processHandle

    do {
        try process.run()
    } catch {
        fail("agentmenu statusline-bridge: could not run chained command: \(error)")
        return 127
    }

    let writer = stdinPipe.fileHandleForWriting
    DispatchQueue.global().async {
        try? writer.write(contentsOf: stdin)
        try? writer.close()
    }

    let exited = waitWithTimeout(process, timeout: chainTimeout)
    // Forward whatever the chain printed regardless of whether it exited in
    // time — a timeout still surfaces what it had already written (below).
    stdoutCapture.forwardAndCleanup(to: .standardOutput)
    stderrCapture.forwardAndCleanup(to: .standardError)

    guard exited else {
        // Still running past the cap: forward what it had already printed
        // (above) and report failure rather than hang the status line.
        process.terminate()
        return 124
    }
    return process.terminationStatus
}

/// Waits for `process` to exit, up to `timeout`, rather than block forever —
/// `Process.waitUntilExit()` has no timeout of its own.
private func waitWithTimeout(_ process: Process, timeout: TimeInterval) -> Bool {
    let semaphore = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        process.waitUntilExit()
        semaphore.signal()
    }
    return semaphore.wait(timeout: .now() + timeout) == .success
}
