// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The two ways a terminal manifest can deliver a command to a window.
public enum TerminalKind: String, Equatable, Sendable {
    /// A scriptable macOS application; AgentMenu hands it one shell command
    /// string through an AppleScript.
    case applescript
    /// A binary that takes a working directory and a command as arguments.
    case argv
}

/// A terminal manifest, parsed from TOML. See `docs/adding-a-terminal.md`
/// for the key-by-key contract this type implements.
public struct TerminalManifest: Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let kind: TerminalKind
    public let enabled: Bool
    public let unverified: Bool
    /// `applescript` kind only. Also the availability probe (R21): a
    /// terminal whose application is not installed reports unavailable.
    public let bundleID: String?
    /// `argv` kind only.
    public let binary: String?
    /// `argv` kind only.
    public let args: [String]
    /// `applescript` kind only.
    public let appleScript: String?
    public let origin: ManifestOrigin

    public init(
        id: String,
        displayName: String,
        kind: TerminalKind,
        enabled: Bool = true,
        unverified: Bool = false,
        bundleID: String? = nil,
        binary: String? = nil,
        args: [String] = [],
        appleScript: String? = nil,
        origin: ManifestOrigin
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.enabled = enabled
        self.unverified = unverified
        self.bundleID = bundleID
        self.binary = binary
        self.args = args
        self.appleScript = appleScript
        self.origin = origin
    }

    public static func parse(_ text: String, origin: ManifestOrigin) throws -> TerminalManifest {
        let document: TOMLDocument
        do {
            document = try TOMLDocument.parse(text)
        } catch let error as TOMLError {
            throw ManifestError.parse(error)
        }
        let root = document.root

        let id = try ManifestParsing.idAndValidatedSchema(root)

        let displayName = try ManifestParsing.requiredString(root, "display_name", id: id)

        let kindRaw = try ManifestParsing.requiredString(root, "kind", id: id)
        guard let kind = TerminalKind(rawValue: kindRaw) else {
            throw ManifestError.invalidValue(
                key: "kind", value: kindRaw, reason: "must be \"applescript\" or \"argv\""
            )
        }

        let enabled = try ManifestParsing.optionalBool(root, "enabled", default: true, id: id)
        let unverified = try ManifestParsing.optionalBool(root, "unverified", default: false, id: id)

        var bundleID: String?
        var binary: String?
        var args: [String] = []
        var appleScript: String?

        switch kind {
        case .applescript:
            bundleID = try ManifestParsing.requiredString(root, "bundle_id", id: id)
            appleScript = try ManifestParsing.requiredString(root, "applescript", id: id)
        case .argv:
            let argvBinary = try ManifestParsing.requiredString(root, "binary", id: id)
            try ManifestParsing.validateBinaryName(argvBinary, id: id)
            binary = argvBinary
            guard let argsValue = root["args"] else {
                throw ManifestError.missingKey("args", id: id)
            }
            guard let argsArray = argsValue.stringArrayValue else {
                throw ManifestError.invalidValue(
                    key: "args", value: ManifestParsing.describe(argsValue), reason: "must be an array of strings"
                )
            }
            args = argsArray
        }

        return TerminalManifest(
            id: id,
            displayName: displayName,
            kind: kind,
            enabled: enabled,
            unverified: unverified,
            bundleID: bundleID,
            binary: binary,
            args: args,
            appleScript: appleScript,
            origin: origin
        )
    }
}
