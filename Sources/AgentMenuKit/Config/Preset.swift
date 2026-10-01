// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The three states an advisor setting can be in. A plain `String?` cannot
/// tell "the user has not touched this" apart from "the user turned the
/// advisor off" without reserving a magic string, so this gives the two
/// distinct meanings distinct cases: `.off` is the reserved disabled state,
/// `.model(_)` is enabled with the named advisor model. Preset itself wraps
/// this in one more layer of optional (`AdvisorSetting?`) so "absent, inherit
/// from the layer below" is a third, still-distinct state.
public enum AdvisorSetting: Equatable, Hashable, Sendable {
    case off
    case model(String)
}

/// A layer in the three-layer preset merge (KTD6): global default, folder
/// override, one-shot override. Every field is optional, and an absent field
/// means "inherit from the layer below" — never a default value. Do not give
/// any field here a non-nil default; that would silently promote this layer
/// above the one it is supposed to defer to.
public struct Preset: Equatable, Sendable {
    public var agent: String?
    public var terminal: String?
    public var profile: String?
    public var model: String?
    public var effort: String?
    public var permissionMode: String?
    public var advisor: AdvisorSetting?
    /// "Keep running when window closes" (R15). A layer's own value is
    /// `nil` (inherit), `true` or `false`; `PresetResolver` turns the merged
    /// stack into the effective value, applying `keepRunningDefault` when no
    /// layer set one. After resolution `nil` means "not applicable" (the
    /// agent or terminal cannot keep a session running), never "inherit".
    public var keepRunning: Bool?

    /// The global default when no layer sets `keep_running`: ON, for new and
    /// existing installs alike. A missing key inherits this rather than
    /// writing it, so a config that never mentioned the field stays byte-for-
    /// byte what it was.
    public static let keepRunningDefault = true

    public init(
        agent: String? = nil,
        terminal: String? = nil,
        profile: String? = nil,
        model: String? = nil,
        effort: String? = nil,
        permissionMode: String? = nil,
        advisor: AdvisorSetting? = nil,
        keepRunning: Bool? = nil
    ) {
        self.agent = agent
        self.terminal = terminal
        self.profile = profile
        self.model = model
        self.effort = effort
        self.permissionMode = permissionMode
        self.advisor = advisor
        self.keepRunning = keepRunning
    }

    /// True when every field is absent — this layer would change nothing if
    /// overlaid on top of another.
    public var isEmpty: Bool {
        agent == nil && terminal == nil && profile == nil && model == nil
            && effort == nil && permissionMode == nil && advisor == nil && keepRunning == nil
    }

    /// Fields set in `other` win; fields absent in `other` keep this layer's
    /// value. Call as `lower.overlaid(with: upper)` — `self` is the layer
    /// underneath, `other` is the layer closer to the one-shot override.
    public func overlaid(with other: Preset) -> Preset {
        Preset(
            agent: other.agent ?? agent,
            terminal: other.terminal ?? terminal,
            profile: other.profile ?? profile,
            model: other.model ?? model,
            effort: other.effort ?? effort,
            permissionMode: other.permissionMode ?? permissionMode,
            advisor: other.advisor ?? advisor,
            keepRunning: other.keepRunning ?? keepRunning
        )
    }
}
