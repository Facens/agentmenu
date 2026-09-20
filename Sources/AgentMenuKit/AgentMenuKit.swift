// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Where the shipped manifests live.
///
/// The app runs from `AgentMenu.app/Contents/MacOS/AgentMenu` and the CLI from
/// `AgentMenu.app/Contents/Resources/bin/agentmenu` (KTD8), so both reach
/// `Contents/Resources/{agents,terminals}` — from different depths. During
/// development neither is inside a bundle, so the repository's own `Resources/`
/// is the fallback.
public enum ResourceRoot {
    /// Directory holding the bundled `agents/` and `terminals/` manifests, or
    /// nil when no candidate exists on disk.
    public static func bundled(
        executable: URL = RunningExecutable.url,
        fileManager: FileManager = .default
    ) -> URL? {
        for candidate in candidates(executable: executable) {
            var isDirectory: ObjCBool = false
            let agents = candidate.appendingPathComponent("agents")
            if fileManager.fileExists(atPath: agents.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return candidate
            }
        }
        return nil
    }

    /// How far up from the executable the walk below will look. Six covers
    /// the deepest layout seen (`.build/out/Products/Debug` is four above the
    /// package root) with room to spare, and stops well short of turning a
    /// binary in `/usr/local/bin` into a search of the whole filesystem.
    static let ancestorSearchDepth = 6

    static func candidates(executable: URL) -> [URL] {
        let dir = executable.deletingLastPathComponent()
        var candidates: [URL] = [
            // Contents/MacOS/AgentMenu -> Contents/Resources
            dir.deletingLastPathComponent().appendingPathComponent("Resources"),
            // Contents/Resources/bin/agentmenu -> Contents/Resources
            dir.deletingLastPathComponent(),
            dir.appendingPathComponent("Resources"),
        ]

        // Then every ancestor's `Resources`, because the build directory's
        // shape is SwiftPM's to change and this used to hard-code one guess
        // at it. The guess was `../../../Resources`, written for
        // `.build/<config>/<binary>`; this toolchain puts products in
        // `.build/out/Products/Debug`, so the path landed on the directory
        // *above* the repository and found nothing. `resolve --command` then
        // failed for every folder with "no agent is configured or available"
        // — for anyone running the CLI from a plain `swift build`, which is
        // what the test suite does, and is why two of its scenarios have been
        // failing rather than flaking.
        var ancestor = dir
        for _ in 0..<ancestorSearchDepth {
            ancestor = ancestor.deletingLastPathComponent().standardizedFileURL
            guard ancestor.path != "/" else { break }
            candidates.append(ancestor.appendingPathComponent("Resources"))
        }
        return candidates
    }
}

/// Where this program actually is on disk.
///
/// `CommandLine.arguments[0]` is whatever the caller typed — a bare name from a
/// `PATH` install, or a relative path resolved against the current directory —
/// so deriving anything from it makes the answer depend on where the user
/// happened to be standing. Two bugs came from that: manifests were looked for
/// beside the wrong directory, and `install-statusline` wrote a bridge script
/// pointing at a binary that was not there.
public enum RunningExecutable {
    public static var url: URL {
        if let path = Bundle.main.executablePath {
            return URL(fileURLWithPath: path).resolvingSymlinksInPath()
        }
        return URL(fileURLWithPath: CommandLine.arguments.first ?? "")
            .resolvingSymlinksInPath()
    }

    public static var path: String { url.path }
}

/// Version string reported by the CLI and the settings window.
///
/// Read from the bundle it is running inside, so a release built with
/// `make bundle VERSION=…` reports the version it was actually stamped with
/// rather than a literal somebody has to remember to bump.
///
/// The CLI needs the second lookup: it lives at
/// `Contents/Resources/bin/agentmenu` (KTD8), and `Bundle.main` for a plain
/// executable buried in Resources is its own directory, not the surrounding
/// `.app` — so it finds no Info.plist and used to report the development
/// fallback from inside a real release.
public let agentMenuVersion: String = {
    if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
        return version
    }
    // …/Contents/Resources/bin/agentmenu -> …/Contents/Info.plist
    let contents = RunningExecutable.url
        .deletingLastPathComponent()   // bin
        .deletingLastPathComponent()   // Resources
        .deletingLastPathComponent()   // Contents
    if let plist = NSDictionary(contentsOf: contents.appendingPathComponent("Info.plist")),
       let version = plist["CFBundleShortVersionString"] as? String {
        return version
    }
    // No Info.plist found at all — running straight from `swift build`,
    // outside any bundle. Not a real version; shaped as a valid alpha
    // (ReleaseChannel(version:) accepts it) rather than an arbitrary literal
    // a bundle could never actually produce.
    return "0.0.0-alpha"
}()
