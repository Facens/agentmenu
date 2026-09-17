// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Minimal test harness.
///
/// XCTest and swift-testing are Xcode-only tooling — neither module is present
/// in a Command Line Tools install — and R32 forbids Xcode-only tooling, so the
/// suite cannot be a SwiftPM `.testTarget`. This is that replacement: an
/// executable that runs every suite and exits non-zero on the first failure it
/// records. It is deliberately small; it is not a test framework.
final class TestRunner {
    private(set) var passed = 0
    private(set) var failures: [String] = []
    private var currentSuite = "(no suite)"

    func suite(_ name: String) {
        currentSuite = name
        print("── \(name)")
    }

    func expect(
        _ condition: Bool,
        _ what: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        if condition {
            passed += 1
        } else {
            record(what, file: file, line: line)
        }
    }

    func expectEqual<T: Equatable>(
        _ actual: T,
        _ expected: T,
        _ what: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        if actual == expected {
            passed += 1
        } else {
            record("\(what) — expected \(expected), got \(actual)", file: file, line: line)
        }
    }

    func expectThrows<T>(
        _ what: String,
        file: StaticString = #file,
        line: UInt = #line,
        _ body: () throws -> T
    ) {
        do {
            _ = try body()
            record("\(what) — expected a thrown error, none was thrown", file: file, line: line)
        } catch {
            passed += 1
        }
    }

    /// Runs `body` and records a failure if it throws, so one broken case does
    /// not abort the whole run.
    func expectNoThrow(
        _ what: String,
        file: StaticString = #file,
        line: UInt = #line,
        _ body: () throws -> Void
    ) {
        do {
            try body()
            passed += 1
        } catch {
            record("\(what) — unexpected error: \(error)", file: file, line: line)
        }
    }

    /// Runs `body`, returning its value, or nil after recording the thrown error.
    /// Use it when the later expectations need the value the call produced.
    func attempt<T>(
        _ what: String,
        file: StaticString = #file,
        line: UInt = #line,
        _ body: () throws -> T
    ) -> T? {
        do {
            let value = try body()
            passed += 1
            return value
        } catch {
            record("\(what) — unexpected error: \(error)", file: file, line: line)
            return nil
        }
    }

    private func record(_ message: String, file: StaticString, line: UInt) {
        let leaf = URL(fileURLWithPath: "\(file)").lastPathComponent
        let entry = "\(currentSuite): \(message)  [\(leaf):\(line)]"
        failures.append(entry)
        print("   ✗ \(entry)")
    }

    func report() -> Int32 {
        print("")
        if failures.isEmpty {
            print("PASS — \(passed) expectations")
            return 0
        }
        print("FAIL — \(failures.count) failed, \(passed) passed")
        for failure in failures { print("  ✗ \(failure)") }
        return 1
    }
}

/// A temporary directory that removes itself.
struct TempDir {
    let url: URL

    init(_ label: String = "agentmenu-tests") {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(label)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func path(_ component: String) -> String {
        url.appendingPathComponent(component).path
    }

    func write(_ contents: String, to component: String) throws {
        let target = url.appendingPathComponent(component)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: target, atomically: true, encoding: .utf8)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// The repository root, computed from a test file's own path rather than
/// the process's working directory (`make test` may run from anywhere):
/// `<file>.swift -> AgentMenuKitTests/ -> Tests/ -> repo root`.
func repositoryRoot(file: StaticString = #filePath) -> URL {
    URL(fileURLWithPath: "\(file)")
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

/// Runs `executable` as a real subprocess and collects its result. `extra`
/// is merged over the current process's environment, and `directory`, when
/// given, becomes the child's working directory. Stdout and stderr are
/// drained fully before `waitUntilExit` — with large output a pipe can
/// deadlock otherwise, once its buffer fills and the child blocks writing to
/// it. A `run()` throw (missing executable, unreadable script, …) is
/// reported as a normal, failing `CLIResult` rather than propagated, so
/// scenarios that expect failure do not need their own catch.
func runProcess(
    _ executable: String,
    _ arguments: [String],
    in directory: URL? = nil,
    environment extra: [String: String] = [:]
) -> CLIResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if let directory {
        process.currentDirectoryURL = directory
    }
    var environment = ProcessInfo.processInfo.environment
    for (key, value) in extra { environment[key] = value }
    process.environment = environment

    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    do {
        try process.run()
    } catch {
        return CLIResult(status: -1, stdout: "", stderr: "\(error)")
    }
    let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    return CLIResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
}
