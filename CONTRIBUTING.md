# Contributing to AgentMenu

Thanks for looking at this. AgentMenu is a small project with one maintainer, so
the rules here are short — but the licence grant below is not optional, and it
is worth understanding before you write anything.

## The cheapest useful contribution needs no grant at all

Agent and terminal support in AgentMenu is **data, not code**. A manifest file in
`~/.config/agentmenu/agents/` or `~/.config/agentmenu/terminals/` overlays a
bundled one with the same `id`, so you can add or fix an agent on your own
machine without touching this repository and without signing anything.

If your manifest works, open an issue with it attached. Verified community
manifests get listed in the README with attribution, and you keep every right to
your own file. See [docs/adding-an-agent.md](docs/adding-an-agent.md) and
[docs/adding-a-terminal.md](docs/adding-a-terminal.md).

## Licence, and why a pull request needs a grant

AgentMenu is released under the **GNU General Public License, version 3 or
later** (see [LICENSE](LICENSE)). You get the four freedoms it promises, and
nobody — including the maintainer — can take the published code away from you.

A paid version of AgentMenu may exist later. If it does, it will be **additional
code that is never published**, not a relicensing of this repository: what is
GPL here stays GPL. That shape is deliberate, and it is what makes the next
paragraph necessary.

**By submitting a contribution (a pull request, a patch, code in an issue), you
grant Andrea Giannangelo a perpetual, irrevocable, worldwide, non-exclusive,
royalty-free licence to use, reproduce, modify, prepare derivative works of,
publicly display, sublicense, distribute and relicense your contribution,
including under terms different from the project's current licence, and
including commercial terms.** You keep the copyright in your contribution. You
confirm you are entitled to grant this — that the work is yours, or that your
employer has authorised it.

Concretely: your contribution may end up in a paid build of AgentMenu. That is
stated here, upfront, rather than announced after the fact.

A `Signed-off-by` trailer (a DCO) would **not** carry this grant — it licenses a
patch under the project's *current* terms only. Projects that collected only a
DCO and later needed to change licence had to go back and ask every past
contributor, and some never finished. That is why the grant is a merge
precondition here from the first day rather than something added later.

The grant is enforced automatically: a bot asks you to accept it on your first
pull request, and no outside contribution is merged before that acceptance is
recorded. If you would rather not grant it, the manifest route above is a real
contribution path and needs nothing from you.

## Practical notes

- Build with `make build`, run the suite with `make test`, assemble the app with
  `make bundle`. **Xcode is not required and must not become required** —
  Command Line Tools plus SwiftPM is the supported toolchain, which is why the
  test suite is a plain executable target instead of an XCTest bundle (neither
  XCTest nor swift-testing exists in a Command Line Tools install).
- Keep `AgentMenuKit` free of UI: it holds configuration, manifests, preset
  resolution, command construction and the snapshot reader, and it is where
  tests live. The app target is verified by running it.
- The app **never writes to an agent's configuration directory**. The single
  exception is the status-line bridge install, which the user runs
  deliberately from Settings → Accounts and which names the file and the key
  it changes before writing. A pull request that adds another write there
  will not be merged.
- Every Swift file under `Sources/` and `Tests/` starts with a two-line header:
  `// Copyright (c) 2026 Andrea Giannangelo` followed by
  `// SPDX-License-Identifier: GPL-3.0-or-later`. CI checks for exactly one
  SPDX line per file. Keep it.
- Accessibility identifiers are part of a control's contract, not incidental
  UI detail. The black-box test harness drives the built app by
  `AXIdentifier` — never by coordinate, never by title, never by label text —
  so every control a scenario clicks carries a stable `<surface>.<control>`
  identifier from the one builder in
  `Sources/AgentMenuKit/Support/AccessibilityID.swift`. Renaming or removing
  one is a harness-facing change, on purpose: it should be as deliberate as
  changing a public API. A dynamic identifier (a folder row, say) never
  embeds a raw filesystem path, a username, a home directory, or any other
  user-supplied free text — hash it instead, the way the folder builders
  already do — because an `AXIdentifier` sits in the same accessibility tree
  a screen reader walks, and a leaked automation log can capture it wholesale.
  A profile id or an agent/terminal manifest id is the one exception: those
  come from the config's own stable ids, not from user text, and are carried
  verbatim. The one place identifiers deliberately do **not** appear is a
  native `NSAlert` or SwiftUI `confirmationDialog` — those keep their button
  titles as they are, and the harness matches on the title instead.
- Conventional commit messages (`feat:`, `fix:`, `docs:`, …) are appreciated but
  not enforced.
