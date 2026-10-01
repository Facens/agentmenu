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
    /// `applescript` kind only, and optional. A script that brings the tab on
    /// a given tty to the front and answers `not found` when there is none
    /// (`TerminalFocus`). Its absence is what hides the focus action: a
    /// terminal AgentMenu has no way to focus says so on the row instead of
    /// pretending.
    public let focusAppleScript: String?
    /// `applescript` kind only, and optional. A script that answers the tty
    /// of the tab the user is looking at right now — `tty of selected tab of
    /// front window` for Terminal — so a Needs-you notification is not posted
    /// for the tab already on screen (KTD10's exception, R32). Without it, a
    /// session in this terminal counts as not frontmost and the notification
    /// posts.
    public let frontmostTTYAppleScript: String?
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
        focusAppleScript: String? = nil,
        frontmostTTYAppleScript: String? = nil,
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
        self.focusAppleScript = focusAppleScript
        self.frontmostTTYAppleScript = frontmostTTYAppleScript
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
        var focusAppleScript: String?
        var frontmostTTYAppleScript: String?

        switch kind {
        case .applescript:
            bundleID = try ManifestParsing.requiredString(root, "bundle_id", id: id)
            appleScript = try ManifestParsing.requiredString(root, "applescript", id: id)
            focusAppleScript = try optionalScript(root, "focus_applescript")
            frontmostTTYAppleScript = try optionalScript(root, "frontmost_tty_applescript")
        case .argv:
            // Focusing is an Apple Event, and an argv terminal has none to
            // send; a key that could never do anything is an error, not a
            // silent no-op.
            try rejectScript(root, "focus_applescript", reason: "only a terminal of kind \"applescript\" can be focused")
            try rejectScript(
                root, "frontmost_tty_applescript",
                reason: "only a terminal of kind \"applescript\" can be asked for its selected tab"
            )
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
            focusAppleScript: focusAppleScript,
            frontmostTTYAppleScript: frontmostTTYAppleScript,
            origin: origin
        )
    }

    /// An optional AppleScript key of an `applescript` terminal: absent is
    /// nil, present must be a non-empty string.
    private static func optionalScript(_ root: TOMLTable, _ key: String) throws -> String? {
        guard let value = root[key] else { return nil }
        guard let text = value.stringValue, !text.isEmpty else {
            throw ManifestError.invalidValue(
                key: key, value: ManifestParsing.describe(value), reason: "must be a non-empty string"
            )
        }
        return text
    }

    /// An AppleScript key that an `argv` terminal must not carry.
    private static func rejectScript(_ root: TOMLTable, _ key: String, reason: String) throws {
        if let value = root[key] {
            throw ManifestError.invalidValue(key: key, value: ManifestParsing.describe(value), reason: reason)
        }
    }
}
