// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The rules about *whether* and *what* this build may update to (R12, R20,
/// KTD20). Sparkle itself lives in the app target — this is the part that can
/// be reasoned about without it, and therefore the part the test runner can
/// reach: `AgentMenuKit` is linked into the tests, the app is not.
///
/// Three decisions live here, each of which has a wrong answer that is
/// invisible until a release goes out:
///
/// - An alpha build must not update itself. A local `make bundle` is replaced
///   by the next `make bundle`; an updater compiled into it would swap the
///   maintainer's working build for the latest public release, which is the
///   opposite of what a local build is for.
/// - A build whose public key is empty must not check at all. Sparkle can
///   accept an update on a matching code signature alone, so a feed fetched
///   without a key to verify against is not merely unverified — it is a
///   second, weaker acceptance path nobody chose.
/// - A beta build looks at the beta channel by default, and a stable build
///   does not. Sparkle keeps no channel preference of its own (KTD8), so the
///   default has to be derived from the running version every launch rather
///   than mirrored into storage.
public enum UpdatePolicy {

    /// Why the updater is not running, when it is not.
    public enum Refusal: Equatable, Sendable {
        /// A local build. `make bundle` with no VERSION produces `X.Y.Z-alpha`.
        case alphaBuild
        /// `SUPublicEDKey` is empty or absent — a build made before the feed
        /// was provisioned, or one whose plist was mangled.
        case noPublicKey
        /// The version string is not one this project's grammar produces, so
        /// the channel cannot be named. Refusing beats guessing: the guess
        /// that matters most (is this an alpha?) is the one that would let a
        /// local build update itself.
        case unreadableVersion(String)

        public var description: String {
            switch self {
            case .alphaBuild:
                return "this is a local build; updates come from `make bundle`"
            case .noPublicKey:
                return "this build carries no update-signing key, so it cannot verify a feed"
            case .unreadableVersion(let version):
                return "'\(version)' is not a version this project produces, so its channel is unknown"
            }
        }
    }

    /// Whether to start the updater at all, and why not when not.
    ///
    /// `publicKey` is `SUPublicEDKey` exactly as the plist carries it —
    /// whitespace is treated as empty, because a key that is one stray space
    /// is not a key and the failure it produces otherwise is a signature
    /// mismatch at install time, hours later and nowhere near its cause.
    public static func refusal(version: String, publicKey: String?) -> Refusal? {
        guard let channel = ReleaseChannel(version: version) else {
            return .unreadableVersion(version)
        }
        if channel == .alpha {
            return .alphaBuild
        }
        let key = publicKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if key.isEmpty {
            return .noPublicKey
        }
        return nil
    }

    /// The channels this copy accepts, for `SPUUpdaterDelegate`'s
    /// `allowedChannels(for:)`.
    ///
    /// An empty set means the default channel only, which is where finals
    /// live. A beta's appcast item carries `<sparkle:channel>beta</…>` and is
    /// therefore invisible to a copy that does not ask for it; the final of
    /// the same version carries no channel and supersedes it for everyone
    /// (KTD20).
    public static func allowedChannels(betaEnabled: Bool) -> Set<String> {
        betaEnabled ? ["beta"] : []
    }

    /// The preference as it stands: what the user chose, or — when they
    /// have not — what this build implies.
    public static func betaEnabled(preference: Bool?, version: String) -> Bool {
        preference ?? defaultBetaPreference(version: version)
    }

    /// What the "Receive beta updates" preference should be when the user has
    /// never touched it.
    ///
    /// On for a beta build: someone running `0.2.0-beta.1` is already on that
    /// channel, and defaulting them off would offer them nothing until the
    /// final shipped — the one case where an update they are waiting for
    /// exists and is hidden. Off everywhere else.
    public static func defaultBetaPreference(version: String) -> Bool {
        ReleaseChannel(version: version) == .beta
    }
}
