// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// One field of a `Preset`, named so an `UnsupportedValue` can say which one
/// it is about.
public enum PresetField: String, CaseIterable, Equatable {
    case agent, terminal, profile, model, effort, permissionMode, advisor
}

/// A preset value the active agent's manifest does not declare (R13):
/// reported, and never forwarded to `CommandBuilder`. Claude Code answers an
/// unknown `--effort` with a warning and then silently falls back to its own
/// default — worse than simply not sending the flag — so the resolver strips
/// the value before it can reach the binary.
public struct UnsupportedValue: Equatable {
    public let field: PresetField
    public let value: String
    public let reason: String

    public init(field: PresetField, value: String, reason: String) {
        self.field = field
        self.value = value
        self.reason = reason
    }
}

/// The outcome of KTD6's three-layer merge: the effective preset with every
/// unsupported value already stripped, plus what was stripped and why.
public struct ResolvedPreset: Equatable {
    public let preset: Preset
    public let unsupported: [UnsupportedValue]

    public init(preset: Preset, unsupported: [UnsupportedValue]) {
        self.preset = preset
        self.unsupported = unsupported
    }
}

/// KTD6: global default, folder override, one-shot override, topmost set
/// value wins. Once merged, the result is checked against the active agent's
/// manifest so a value the agent does not declare is reported instead of
/// reaching the binary (R13).
public enum PresetResolver {
    /// `agent` is the manifest of the *effective* agent (after `agent`/
    /// `terminal`/`profile` themselves are merged elsewhere) — this function
    /// only validates model, effort, permission mode and advisor against it.
    /// When `agent` is nil (no agent manifest resolved yet — for instance the
    /// CLI previewing a preset before an agent is configured) nothing can be
    /// checked, so nothing is marked unsupported: nil would force a reason
    /// string that names no manifest, and `CommandBuilder.build` requires a
    /// non-optional `AgentManifest` regardless, so no unsafe value can reach
    /// a binary as a result of skipping validation here.
    ///
    /// When more than one field is unsupported, `unsupported` lists them in
    /// field order — model, effort, permission mode, advisor — deterministic
    /// rather than an accident of iteration order, since a caller (the CLI's
    /// `resolve` command) renders this list to the user.
    public static func resolve(global: Preset, folder: Preset, oneShot: Preset, agent: AgentManifest?) -> ResolvedPreset {
        var merged = global.overlaid(with: folder).overlaid(with: oneShot)
        guard let agent else {
            return ResolvedPreset(preset: merged, unsupported: [])
        }

        var unsupported: [UnsupportedValue] = []

        if let model = merged.model {
            if let spec = agent.model, spec.accepts(model) {
                // supported, keep it
            } else {
                unsupported.append(UnsupportedValue(
                    field: .model,
                    value: model,
                    reason: reason(fieldLabel: "model", value: model, agentID: agent.id, declared: agent.model != nil)
                ))
                merged.model = nil
            }
        }

        if let effort = merged.effort {
            if let spec = agent.effort, spec.accepts(effort) {
                // supported, keep it
            } else {
                unsupported.append(UnsupportedValue(
                    field: .effort,
                    value: effort,
                    reason: reason(fieldLabel: "effort", value: effort, agentID: agent.id, declared: agent.effort != nil)
                ))
                merged.effort = nil
            }
        }

        if let mode = merged.permissionMode {
            if let spec = agent.permissionMode, spec.accepts(mode) {
                // supported, keep it
            } else {
                unsupported.append(UnsupportedValue(
                    field: .permissionMode,
                    value: mode,
                    reason: reason(
                        fieldLabel: "permission mode", value: mode, agentID: agent.id, declared: agent.permissionMode != nil
                    )
                ))
                merged.permissionMode = nil
            }
        }

        if let advisor = merged.advisor {
            switch advisor {
            case .model(let model):
                if let spec = agent.advisor, spec.accepts(model) {
                    // supported, keep it
                } else {
                    unsupported.append(UnsupportedValue(
                        field: .advisor,
                        value: model,
                        reason: reason(fieldLabel: "advisor", value: model, agentID: agent.id, declared: agent.advisor != nil)
                    ))
                    merged.advisor = nil
                }
            case .off:
                if let spec = agent.advisor, spec.canDisable {
                    // supported, keep it
                } else {
                    let reasonText: String
                    if agent.advisor == nil {
                        reasonText = "the \(agent.id) manifest does not declare an advisor capability"
                    } else {
                        reasonText = "the \(agent.id) manifest declares no way to turn the advisor off"
                    }
                    unsupported.append(UnsupportedValue(field: .advisor, value: "off", reason: reasonText))
                    merged.advisor = nil
                }
            }
        }

        return ResolvedPreset(preset: merged, unsupported: unsupported)
    }

    /// `declared` distinguishes "the capability section is absent entirely"
    /// from "the section exists but does not list this value" — both are
    /// unsupported, but the reason should say which is true.
    private static func reason(fieldLabel: String, value: String, agentID: String, declared: Bool) -> String {
        let article = "aeiou".contains(fieldLabel.first.map { Character($0.lowercased()) } ?? " ") ? "an" : "a"
        if declared {
            return "the \(agentID) manifest does not declare \(article) \(fieldLabel) value '\(value)'"
        }
        return "the \(agentID) manifest does not declare \(article) \(fieldLabel) capability"
    }
}
