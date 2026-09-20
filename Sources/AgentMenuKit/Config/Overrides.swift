// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The five KTD4 escape hatches, read in one place instead of at each call
/// site: `AGENTMENU_CONFIG`, `AGENTMENU_MANIFESTS_USER_ROOT`,
/// `AGENTMENU_PROFILE_ROOT`, `AGENTMENU_DEFAULTS_SUITE` and
/// `AGENTMENU_HARNESS_DIR`. Every field is nil unless the corresponding
/// variable is set to a non-empty value, which is what "nothing changes when
/// no variable is set" (KTD4) means in code: a caller that gets an all-nil
/// `Overrides` back falls through to exactly the defaults it used before
/// this type existed.
///
/// Two factories, not one, because the two processes that read these
/// variables cross different trust boundaries:
///
/// - `forCLI` is unconditional. `agentmenu` is a tool the user runs
///   deliberately — there is no Finder launch to protect — and this is the
///   same documented-as-test-only behaviour `resolvedConfigURL()` and
///   `resolvedManifestUserRoot()` had before this file existed. It must
///   never regress.
/// - `forGUI` is gated. A real GUI launch happens from Finder, the Dock or
///   Spotlight — places that supply no arguments at all — while
///   `launchctl setenv` reaches every GUI app the user launches. If the GUI
///   honoured the environment the way the CLI does, any shell on the
///   machine could silently redirect the maintainer's own launch to a
///   configuration of its choosing (R3). `forGUI` closes that hole: every
///   field stays nil unless the process was *also* launched with
///   `-AgentMenuHarness YES` in the argument domain, which only an explicit
///   launch argument can supply — not an environment variable, not a
///   persisted preference file, nothing `launchctl setenv` can reach.
public struct Overrides: Equatable {
    /// `AGENTMENU_CONFIG` — replaces `ConfigStore.defaultURL`.
    public var config: URL?
    /// `AGENTMENU_MANIFESTS_USER_ROOT` — replaces `ManifestRegistry.defaultUserRoot`.
    public var manifestsUserRoot: URL?
    /// `AGENTMENU_PROFILE_ROOT` — see `resolveProfileDirectory`.
    public var profileRoot: URL?
    /// `AGENTMENU_DEFAULTS_SUITE` — the `UserDefaults` suite the harness
    /// journal is activated against instead of the standard domain.
    public var defaultsSuite: String?
    /// `AGENTMENU_HARNESS_DIR` — replaces `Journal.defaultDirectory`.
    public var harnessDirectory: URL?

    public init(
        config: URL? = nil,
        manifestsUserRoot: URL? = nil,
        profileRoot: URL? = nil,
        defaultsSuite: String? = nil,
        harnessDirectory: URL? = nil
    ) {
        self.config = config
        self.manifestsUserRoot = manifestsUserRoot
        self.profileRoot = profileRoot
        self.defaultsSuite = defaultsSuite
        self.harnessDirectory = harnessDirectory
    }

    /// The key the argument domain carries. `-AgentMenuHarness YES` on the
    /// command line is what sets it: `UserDefaults`'s argument domain is
    /// populated straight from the process's own argv, is the first domain
    /// `object(forKey:)`/`bool(forKey:)` consult, and is per-process — the
    /// same mechanism `Tests/AgentMenuKitTests/JournalTests.swift` already
    /// relies on and documents (`setVolatileDomain(_:forName:
    /// UserDefaults.argumentDomain)`) as "where a value handed to a launch
    /// would land anyway".
    public static let harnessFlagKey = "AgentMenuHarness"

    private static func nonEmpty(_ environment: [String: String], _ key: String) -> String? {
        guard let value = environment[key], !value.isEmpty else { return nil }
        return value
    }

    private static func url(_ environment: [String: String], _ key: String) -> URL? {
        nonEmpty(environment, key).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    }

    /// Unconditional: no flag, no gate. The CLI's long-standing behaviour,
    /// extended from the two variables `resolvedConfigURL()` and
    /// `resolvedManifestUserRoot()` used to read separately to all five.
    public static func forCLI(environment: [String: String] = ProcessInfo.processInfo.environment) -> Overrides {
        Overrides(
            config: url(environment, "AGENTMENU_CONFIG"),
            manifestsUserRoot: url(environment, "AGENTMENU_MANIFESTS_USER_ROOT"),
            profileRoot: url(environment, "AGENTMENU_PROFILE_ROOT"),
            defaultsSuite: nonEmpty(environment, "AGENTMENU_DEFAULTS_SUITE"),
            harnessDirectory: url(environment, "AGENTMENU_HARNESS_DIR")
        )
    }

    /// Gated on the argument domain. Reads nothing else from `defaults`
    /// besides `harnessFlagKey`, and reads it *before* anything else runs —
    /// checking any other key, or reading `AGENTMENU_DEFAULTS_SUITE` first
    /// and deriving the gate from a value inside that suite, would let a
    /// domain other than the argument one (a plist under
    /// `~/Library/Preferences`, persisted by an earlier `defaults write`)
    /// open the gate instead of an actual launch argument. Once the gate is
    /// open, every field is read exactly as `forCLI` reads it — one
    /// implementation of "read the five variables", not two that could
    /// drift apart.
    public static func forGUI(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Overrides {
        guard defaults.bool(forKey: harnessFlagKey) else { return Overrides() }
        return forCLI(environment: environment)
    }

    /// The `UserDefaults` domain `suite` names, or `.standard` when `suite`
    /// is nil or the named suite could not be opened. `HarnessJournal
    /// .activate(defaults:)` takes this directly, so the domain the journal
    /// key is read from and the domain named in its own fixture echo
    /// (`defaultsSuite`) can never name two different things.
    public static func defaults(forSuite suite: String?) -> UserDefaults {
        guard let suite else { return .standard }
        return UserDefaults(suiteName: suite) ?? .standard
    }

    /// A profile's config directory, resolved the way KTD4 asks a profile
    /// root to be respected: `configDirectory` that is already absolute —
    /// or spells a specific user's home (`~bob/…`), which this convention
    /// does not cover — is used exactly as written, ignoring `profileRoot`
    /// entirely. This is deliberate, not an oversight: it is what "a profile
    /// whose config_dir is absolute ignores the profile root" asks for, and
    /// it is exactly what the harness itself writes — KTD4 notes "the
    /// harness seeds profiles with absolute config directories … so both
    /// are inherited," precisely so a real harness run never depends on
    /// this substitution at all.
    ///
    /// Only a directory that is exactly `~` or starts with `~/` is
    /// redirected, and only when `profileRoot` is set: the leading `~` is
    /// replaced with `profileRoot`, so `~/.claude` under a profile root of
    /// `/tmp/x` resolves to `/tmp/x/.claude`. That is the same
    /// identity-to-directory shape `Detection.profiles(for:)` produces when
    /// it names an account from a directory it finds under the home
    /// directory (`~/.claude`, `~/.claude-<suffix>`), just rooted somewhere
    /// other than the real home — so a profile `seedIfMissing` creates
    /// before the harness ever ran still resolves somewhere under the
    /// isolated root rather than the maintainer's own.
    ///
    /// With `profileRoot` nil this is byte-identical to
    /// `Profile.expandedConfigDirectory` — real `~` expansion against the
    /// process's actual home — which is what every call site used before
    /// this function existed.
    public static func resolveProfileDirectory(_ configDirectory: String, profileRoot: URL?) -> URL {
        guard let profileRoot,
              configDirectory == "~" || configDirectory.hasPrefix("~/") else {
            return URL(fileURLWithPath: (configDirectory as NSString).expandingTildeInPath)
        }
        let remainder = configDirectory.dropFirst() // "" for "~", "/xyz" for "~/xyz"
        guard !remainder.isEmpty else { return profileRoot }
        return profileRoot.appendingPathComponent(String(remainder.dropFirst()))
    }
}
