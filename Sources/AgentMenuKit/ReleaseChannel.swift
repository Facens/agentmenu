// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The three release channels (R20 / KTD10, as amended): stable, beta and
/// alpha, distinguished by the shape of the version string.
///
/// This mirrors `packaging/version.sh`'s `version_channel` exactly — the two
/// are two implementations of one grammar, kept in lockstep by a test that
/// runs the same table against both (`Tests/AgentMenuKitTests/BundleVersionTests.swift`
/// and `Tests/AgentMenuKitTests/ReleaseChannelTests.swift`). Change one,
/// change the other, or the tests catch the drift.
///
///   form              channel
///   X.Y.Z             stable
///   X.Y.Z-beta.N      beta     (N in 1...99)
///   X.Y.Z-alpha       alpha
///
/// Anything else — a leading `v`, a two-component version, a fourth
/// component, `-rc1`, `-alpha.1`, `-beta.0`, `-beta.100`, non-digit
/// components — is rejected.
public enum ReleaseChannel: String, Equatable, Sendable {
    case alpha, beta, stable

    /// Parses a version string into its release channel, or nil when the
    /// string does not match the grammar above.
    public init?(version: String) {
        // \A and \z, not ^ and $: ICU's $ also matches before a trailing
        // newline, which bash's `=~` does not, and the two grammars must
        // reject exactly the same strings.
        // Mirrors packaging/version.sh's `[1-9][0-9]?` for N exactly: one or
        // two digits, no leading zero, which is what keeps 1...99 without a
        // separate numeric bounds check — "01" and "100" both fail the shape.
        if version.range(of: #"\A[0-9]+\.[0-9]+\.[0-9]+\z"#, options: .regularExpression) != nil {
            self = .stable
        } else if version.range(of: #"\A[0-9]+\.[0-9]+\.[0-9]+-beta\.[1-9][0-9]?\z"#, options: .regularExpression) != nil {
            self = .beta
        } else if version.range(of: #"\A[0-9]+\.[0-9]+\.[0-9]+-alpha\z"#, options: .regularExpression) != nil {
            self = .alpha
        } else {
            return nil
        }
    }
}
