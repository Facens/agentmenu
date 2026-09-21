// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AgentMenuKit

/// A small agent fixture with every capability declared, deliberately not a
/// copy of `Resources/agents/claude-code.toml` — most scenarios here are
/// about the merge and validation logic, not about one real manifest's
/// values, so they should not be able to fail just because that file changes.
private func fixtureAgent(
    advisorDisableArgs: [String] = ["--no-advisor"],
    advisorRankOrder: [String] = []
) -> AgentManifest {
    AgentManifest(
        id: "fixture-agent",
        displayName: "Fixture Agent",
        binary: "fixture",
        profileMechanism: .environment("FIXTURE_CONFIG_DIR"),
        model: FlagSpec(flag: "--model", values: ["sonnet", "opus"]),
        effort: FlagSpec(flag: "--effort", values: ["low", "medium", "high"]),
        permissionMode: PermissionSpec(flag: "--permission-mode", values: ["manual", "bypassPermissions"], bypassValues: ["bypassPermissions"]),
        advisor: AdvisorSpec(flag: "--advisor", values: ["opus", "sonnet"], disableArgs: advisorDisableArgs, rankOrder: advisorRankOrder),
        origin: .bundled
    )
}

/// R50: the fixture above with the two models ranked — sonnet below opus, the
/// order Claude Code's own catalog gives those aliases.
private func rankedFixtureAgent() -> AgentManifest {
    fixtureAgent(advisorRankOrder: ["sonnet", "opus"])
}

func runPresetResolverTests(_ t: TestRunner) {
    t.suite("PresetResolver")

    // MARK: 1. AE1 — folder overrides one field of the global default, the rest is inherited

    do {
        let global = Preset(model: "sonnet", effort: "medium")
        let folder = Preset(model: "opus")
        let resolved = PresetResolver.resolve(global: global, folder: folder, oneShot: Preset(), agent: fixtureAgent())

        t.expectEqual(resolved.preset.model, "opus", "folder's model wins over the global default")
        t.expectEqual(resolved.preset.effort, "medium", "effort, unset in the folder, is inherited from the global default")
        t.expectEqual(resolved.unsupported, [], "both values are declared by the fixture agent, so nothing is unsupported")
    }

    // MARK: 2. AE2 — a one-shot override does not mutate the folder preset

    do {
        let folder = Preset(effort: "medium")
        let folderBefore = folder
        let oneShot = Preset(effort: "xhigh")

        let resolved = PresetResolver.resolve(global: Preset(), folder: folder, oneShot: oneShot, agent: fixtureAgent())

        t.expect(resolved.preset.effort == nil, "xhigh is unsupported for this fixture, so the one-shot value never lands in the effective preset")
        t.expectEqual(folder, folderBefore, "the folder Preset value itself is unchanged after resolving — resolve() reads layers, it never writes back to them")
    }

    // MARK: 3. A value the manifest's capability section does not list is reported unsupported, and omitted

    do {
        let preset = Preset(effort: "turbo")
        let resolved = PresetResolver.resolve(global: preset, folder: Preset(), oneShot: Preset(), agent: fixtureAgent())

        t.expect(resolved.preset.effort == nil, "the unsupported effort value is stripped from the effective preset")
        t.expectEqual(resolved.unsupported.count, 1, "exactly one unsupported value reported")
        if let first = resolved.unsupported.first {
            t.expectEqual(first.field, .effort, "the unsupported value names the effort field")
            t.expectEqual(first.value, "turbo", "the unsupported value carries the rejected value")
            t.expect(first.reason.contains("fixture-agent"), "the reason names the manifest: \(first.reason)")
            t.expect(first.reason.contains("turbo"), "the reason names the rejected value: \(first.reason)")
        }
    }

    // MARK: 4. A value requested for a capability the manifest does not declare at all is also unsupported

    do {
        let agent = AgentManifest(id: "no-model", displayName: "No Model", binary: "n", origin: .bundled)
        let resolved = PresetResolver.resolve(global: Preset(model: "opus"), folder: Preset(), oneShot: Preset(), agent: agent)

        t.expect(resolved.preset.model == nil, "model is stripped: this manifest has no [model] section at all")
        t.expectEqual(resolved.unsupported.count, 1, "one unsupported value")
        t.expectEqual(resolved.unsupported.first?.field, .model, "the field is model")
        t.expect(
            resolved.unsupported.first?.reason.contains("capability") ?? false,
            "an absent section reads as a missing capability, not as an unlisted value: \(String(describing: resolved.unsupported.first?.reason))"
        )
    }

    // MARK: 5. permissionMode follows the same rule as model/effort

    do {
        let resolved = PresetResolver.resolve(
            global: Preset(permissionMode: "yolo"), folder: Preset(), oneShot: Preset(), agent: fixtureAgent()
        )
        t.expect(resolved.preset.permissionMode == nil, "an undeclared permission mode is stripped")
        t.expectEqual(resolved.unsupported.first?.field, .permissionMode, "reported against the permissionMode field")
    }

    // MARK: 6. advisor .model(_) with an unlisted model is unsupported

    do {
        let resolved = PresetResolver.resolve(
            global: Preset(advisor: .model("haiku")), folder: Preset(), oneShot: Preset(), agent: fixtureAgent()
        )
        t.expect(resolved.preset.advisor == nil, "haiku is not one of the fixture's advisor values")
        t.expectEqual(resolved.unsupported.first?.field, .advisor, "reported against the advisor field")
        t.expectEqual(resolved.unsupported.first?.value, "haiku", "the rejected model is named")
    }

    // MARK: 7. advisor .off is unsupported when the manifest declares no disable_args

    do {
        let agent = fixtureAgent(advisorDisableArgs: [])
        let resolved = PresetResolver.resolve(global: Preset(advisor: .off), folder: Preset(), oneShot: Preset(), agent: agent)

        t.expect(resolved.preset.advisor == nil, "no off switch exists, so .off is stripped")
        t.expectEqual(resolved.unsupported.count, 1, "one unsupported value")
        t.expectEqual(resolved.unsupported.first?.field, .advisor, "reported against the advisor field")
    }

    // MARK: 8. advisor .off is supported when the manifest does declare disable_args

    do {
        let agent = fixtureAgent(advisorDisableArgs: ["--settings", "{\"advisorModel\":\"\"}"])
        let resolved = PresetResolver.resolve(global: Preset(advisor: .off), folder: Preset(), oneShot: Preset(), agent: agent)

        t.expectEqual(resolved.preset.advisor, .off, "an off switch exists, so .off survives resolution")
        t.expectEqual(resolved.unsupported, [], "nothing unsupported")
    }

    // MARK: 8b. Two fields unsupported at once are both reported, in field order (model, effort, permissionMode, advisor)

    do {
        let preset = Preset(model: "haiku", effort: "turbo", permissionMode: "manual", advisor: .model("opus"))
        let resolved = PresetResolver.resolve(global: preset, folder: Preset(), oneShot: Preset(), agent: fixtureAgent())

        t.expectEqual(resolved.preset.model, nil, "haiku is unsupported and stripped")
        t.expectEqual(resolved.preset.effort, nil, "turbo is unsupported and stripped")
        t.expectEqual(resolved.preset.permissionMode, "manual", "manual is declared and survives")
        t.expectEqual(resolved.preset.advisor, .model("opus"), "opus is a declared advisor model and survives")
        t.expectEqual(resolved.unsupported.map(\.field), [.model, .effort], "both unsupported fields are reported, in field order — model before effort")
    }

    // MARK: 9. A nil agent validates nothing — every merged value passes through unchanged

    do {
        let preset = Preset(model: "not-a-real-model", effort: "turbo", permissionMode: "yolo", advisor: .model("nope"))
        let resolved = PresetResolver.resolve(global: preset, folder: Preset(), oneShot: Preset(), agent: nil)

        t.expectEqual(resolved.preset, preset, "with no manifest to validate against, the merge result is returned as-is")
        t.expectEqual(resolved.unsupported, [], "nothing can be reported unsupported without a manifest to name in the reason")
    }

    // MARK: 10. Every layer empty resolves to an empty preset

    do {
        let resolved = PresetResolver.resolve(global: Preset(), folder: Preset(), oneShot: Preset(), agent: fixtureAgent())
        t.expect(resolved.preset.isEmpty, "three empty layers merge to an empty preset")
        t.expectEqual(resolved.unsupported, [], "nothing to report")
    }

    // MARK: 11. The resolver never validates agent/terminal/profile — those are plain identifiers here, not values checked against the manifest

    do {
        let preset = Preset(agent: "some-other-agent", terminal: "some-terminal", profile: "some-profile")
        let resolved = PresetResolver.resolve(global: preset, folder: Preset(), oneShot: Preset(), agent: fixtureAgent())
        t.expectEqual(resolved.preset.agent, "some-other-agent", "agent id passes through untouched")
        t.expectEqual(resolved.preset.terminal, "some-terminal", "terminal id passes through untouched")
        t.expectEqual(resolved.preset.profile, "some-profile", "profile id passes through untouched")
        t.expectEqual(resolved.unsupported, [], "none of these fields are checked by this resolver")
    }

    // MARK: 12. R50 — an advisor ranked below the main model is raised to it, not dropped

    do {
        let preset = Preset(model: "opus", advisor: .model("sonnet"))
        let resolved = PresetResolver.resolve(global: preset, folder: Preset(), oneShot: Preset(), agent: rankedFixtureAgent())

        t.expectEqual(resolved.preset.advisor, .model("opus"), "sonnet cannot advise opus, so the advisor is raised to opus")
        t.expectEqual(resolved.preset.model, "opus", "the main model is untouched — the advisor moves, never the model")
        t.expectEqual(resolved.unsupported, [], "a raised value is not an unsupported one: the flag still reaches the binary")
        t.expectEqual(resolved.adjusted.count, 1, "exactly one adjustment reported")
        if let first = resolved.adjusted.first {
            t.expectEqual(first.field, .advisor, "the adjustment names the advisor field")
            t.expectEqual(first.from, "sonnet", "it carries the value the user chose")
            t.expectEqual(first.to, "opus", "it carries the value that will be sent")
            t.expect(first.reason.contains("fixture-agent"), "the reason names the manifest: \(first.reason)")
        }
    }

    // MARK: 13. R50 — an advisor at or above the main model's rank is left alone

    do {
        let atSameRank = PresetResolver.resolve(
            global: Preset(model: "opus", advisor: .model("opus")), folder: Preset(), oneShot: Preset(), agent: rankedFixtureAgent()
        )
        t.expectEqual(atSameRank.preset.advisor, .model("opus"), "equal ranks pair — verified against the real binary, not inferred")
        t.expectEqual(atSameRank.adjusted, [], "nothing to adjust")

        let above = PresetResolver.resolve(
            global: Preset(model: "sonnet", advisor: .model("opus")), folder: Preset(), oneShot: Preset(), agent: rankedFixtureAgent()
        )
        t.expectEqual(above.preset.advisor, .model("opus"), "a stronger advisor stands")
        t.expectEqual(above.adjusted, [], "nothing to adjust")
    }

    // MARK: 14. R50 — a manifest that declares no ranks accepts every pairing

    do {
        let resolved = PresetResolver.resolve(
            global: Preset(model: "opus", advisor: .model("sonnet")), folder: Preset(), oneShot: Preset(), agent: fixtureAgent()
        )
        t.expectEqual(resolved.preset.advisor, .model("sonnet"), "with no declared order, no pairing is refused and nothing is raised")
        t.expectEqual(resolved.adjusted, [], "nothing to adjust")
    }

    // MARK: 15. R50 — with no effective main model there is nothing to compare, so the advisor stands

    do {
        let resolved = PresetResolver.resolve(
            global: Preset(advisor: .model("sonnet")), folder: Preset(), oneShot: Preset(), agent: rankedFixtureAgent()
        )
        t.expectEqual(resolved.preset.advisor, .model("sonnet"), "the agent's own default model is unknown here, so the advisor is left as chosen")
        t.expectEqual(resolved.adjusted, [], "nothing to adjust")
    }

    // MARK: 16. R50 — an advisor turned off stays off; raising applies to a chosen model only

    do {
        let resolved = PresetResolver.resolve(
            global: Preset(model: "opus", advisor: .off), folder: Preset(), oneShot: Preset(), agent: rankedFixtureAgent()
        )
        t.expectEqual(resolved.preset.advisor, .off, "off is a choice, not a weak advisor")
        t.expectEqual(resolved.adjusted, [], "nothing to adjust")
    }

    // MARK: 17. R50 — when the main model is not itself an advisor value, the weakest advisor that reaches its class wins

    do {
        let agent = AgentManifest(
            id: "asymmetric",
            displayName: "Asymmetric",
            binary: "a",
            model: FlagSpec(flag: "--model", values: ["small", "huge"]),
            advisor: AdvisorSpec(
                flag: "--advisor",
                values: ["medium", "large", "enormous"],
                rankOrder: ["small", "medium", "huge", "large", "enormous"]
            ),
            origin: .bundled
        )
        let resolved = PresetResolver.resolve(
            global: Preset(model: "huge", advisor: .model("medium")), folder: Preset(), oneShot: Preset(), agent: agent
        )

        t.expectEqual(resolved.preset.advisor, .model("large"), "large is the cheapest advisor that reaches huge's class; enormous overshoots")
        t.expectEqual(resolved.adjusted.first?.from, "medium", "the adjustment carries the chosen value")
        t.expectEqual(resolved.adjusted.first?.to, "large", "and the value that replaces it")
    }

    // MARK: 18. R50 — an unsupported advisor is still dropped, never raised

    do {
        let resolved = PresetResolver.resolve(
            global: Preset(model: "opus", advisor: .model("haiku")), folder: Preset(), oneShot: Preset(), agent: rankedFixtureAgent()
        )
        t.expect(resolved.preset.advisor == nil, "haiku is not a declared advisor value, so it is stripped before any ranking applies")
        t.expectEqual(resolved.unsupported.first?.field, .advisor, "reported unsupported")
        t.expectEqual(resolved.adjusted, [], "a stripped value is not an adjusted one")
    }
}
