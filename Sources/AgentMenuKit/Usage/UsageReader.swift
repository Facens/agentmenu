// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Reads `tb-rate-snapshot.json` (R23). The app never computes usage itself —
/// this only parses what the status-line script already wrote, and refuses
/// rather than guesses when the shape is unrecognised (KTD7).
public struct UsageReader {
    /// `v` values this reader understands. A snapshot with any other `v` is
    /// `.refused`, not force-parsed against today's shape.
    public static let supportedVersions: Set<Int> = [1]

    /// Matches the status-line script's own write cadence (throttled to once
    /// per 60s) with headroom, so a normal in-session gap between writes
    /// doesn't itself read as stale.
    public static let defaultStaleAfter: TimeInterval = 300

    public let staleAfter: TimeInterval
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default, staleAfter: TimeInterval = UsageReader.defaultStaleAfter) {
        self.fileManager = fileManager
        self.staleAfter = staleAfter
    }

    public func read(at url: URL) -> UsageReading {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return .unavailable
        }
        // A directory at the snapshot path is not a snapshot — treat it the
        // same as "no file here" (R25) rather than inventing a refusal for
        // a shape mismatch nobody asked about.
        if isDirectory.boolValue {
            return .unavailable
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .refused(reason: "could not read snapshot file: \(error.localizedDescription)")
        }

        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            return .refused(reason: "malformed JSON: \(error.localizedDescription)")
        }

        guard let object = json as? [String: Any] else {
            return .refused(reason: "snapshot root is not a JSON object")
        }

        return Self.parseSnapshot(object)
    }

    public func read(template: String, profileDirectory: URL) -> UsageReading {
        read(at: Self.resolvePath(template: template, profileDirectory: profileDirectory))
    }

    /// Substitutes `{profile_dir}` in a manifest's `usage_snapshot` template.
    /// A template with no placeholder passes through unchanged.
    public static func resolvePath(template: String, profileDirectory: URL) -> URL {
        let substituted = template.replacingOccurrences(of: "{profile_dir}", with: profileDirectory.path)
        return URL(fileURLWithPath: substituted).standardizedFileURL
    }

    // MARK: - Parsing

    private static func parseSnapshot(_ object: [String: Any]) -> UsageReading {
        guard let versionValue = numberValue(object["v"]), versionValue.truncatingRemainder(dividingBy: 1) == 0 else {
            return .refused(reason: "missing or invalid \"v\"")
        }
        let version = Int(versionValue)
        guard supportedVersions.contains(version) else {
            let supported = supportedVersions.sorted().map(String.init).joined(separator: ", ")
            return .refused(reason: "unknown snapshot version \(version) (supported: \(supported))")
        }

        guard let ts = numberValue(object["ts"]) else {
            return .refused(reason: "missing or invalid \"ts\"")
        }
        let writtenAt = Date(timeIntervalSince1970: ts)

        var windows: [UsageWindow] = []
        for kind in UsageWindowKind.allCases {
            guard let raw = object[kind.rawValue], !(raw is NSNull) else {
                // Absent (or explicit null) means the window isn't in this
                // snapshot — never synthesised as zero (R24).
                continue
            }
            guard let windowObject = raw as? [String: Any] else {
                return .refused(reason: "\"\(kind.rawValue)\" is not an object")
            }
            guard let usedPercentage = numberValue(windowObject["used_percentage"]) else {
                return .refused(reason: "\"\(kind.rawValue)\" has a missing or non-numeric \"used_percentage\"")
            }
            guard let resetsAtValue = numberValue(windowObject["resets_at"]) else {
                return .refused(reason: "\"\(kind.rawValue)\" has a missing or non-numeric \"resets_at\"")
            }
            windows.append(
                UsageWindow(
                    kind: kind,
                    usedPercentage: usedPercentage,
                    resetsAt: Date(timeIntervalSince1970: resetsAtValue)
                )
            )
        }

        return .available(UsageSnapshot(version: version, writtenAt: writtenAt, windows: windows))
    }

    /// Extracts a JSON number as `Double`, rejecting everything else —
    /// including JSON booleans, via the shared `isJSONBoolean` guard (a
    /// plain `as? Double` on a boolean's `NSNumber` would otherwise silently
    /// succeed as 1.0/0.0).
    private static func numberValue(_ any: Any?) -> Double? {
        guard let any, !(any is NSNull) else { return nil }
        guard let number = any as? NSNumber else { return nil }
        if isJSONBoolean(number) { return nil }
        return number.doubleValue
    }
}
