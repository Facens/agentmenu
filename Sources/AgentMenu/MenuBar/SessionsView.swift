// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AgentMenuKit

/// One option of a `SegmentedChips` control.
struct ChipItem: Identifiable {
    let id: String
    let title: String
    /// Sessions waiting on the user under this option; nothing is drawn at 0.
    var count = 0
    let identifier: String
    var help: String?
}

/// The popover's segmented control: the tabs, the Live | Closed toggle and the
/// account pills.
///
/// Drawn from buttons rather than a segmented `Picker`, which the profile
/// switch uses: a `Picker` turns its options into segments whose accessibility
/// identifiers are, by the profile switch's own comment, unverified, and a
/// scenario has to be able to click `popover.tab.sessions`. A plain button
/// with an identifier is the same kind of element the launch rows already
/// expose, and the look — a recessed track with a raised selected segment — is
/// the segmented control's.
struct SegmentedChips: View {
    let items: [ChipItem]
    let selectedID: String
    let select: (String) -> Void

    @Environment(\.colorScheme) private var scheme

    /// Past this many options the segments stop sharing the width equally and
    /// the row scrolls instead, as the profile switch turns into a menu past
    /// three accounts: equal shares would truncate every name.
    private let equalShareLimit = 4

    var body: some View {
        Group {
            if items.count > equalShareLimit {
                ScrollView(.horizontal, showsIndicators: false) { chips(fill: false) }
            } else {
                chips(fill: true)
            }
        }
    }

    private func chips(fill: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(items) { item in
                let selected = item.id == selectedID
                Button { select(item.id) } label: {
                    HStack(spacing: 5) {
                        Text(item.title).lineLimit(1)
                        if item.count > 0 {
                            Text("\(item.count)")
                                .font(.system(size: 10, weight: .bold).monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.brandWarning(scheme)))
                        }
                    }
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .padding(.horizontal, fill ? 6 : 12)
                    .frame(maxWidth: fill ? .infinity : nil, minHeight: 22)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color(nsColor: .controlBackgroundColor))
                                .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.12), radius: 0.8, y: 0.5)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(item.help ?? "")
                .accessibilityIdentifier(item.identifier)
                .accessibilityAddTraits(selected ? [.isSelected] : [])
                .accessibilityLabel(item.count > 0 ? "\(item.title), \(item.count) need you" : item.title)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(scheme == .dark ? 0.10 : 0.07))
        )
    }
}

// MARK: - The account pills

/// The account filter, in the place the profile switch takes on Launch (R6).
/// Hidden with one profile, like the switch. It changes what Live and Closed
/// show and nothing else: the Launch tab's profile, and the usage strip that
/// follows it, stay where they were.
struct SessionsPillBar: View {
    @ObservedObject var model: SessionsModel

    var body: some View {
        let pills = model.snapshot.pills
        if pills.count > 2 {
            SegmentedChips(
                items: pills.map { info in
                    ChipItem(
                        id: info.id,
                        title: info.title,
                        count: info.needsYouCount,
                        identifier: AccessibilityID.Popover.Sessions.pill(info.pill),
                        help: info.sharedDirectoryWith.isEmpty
                            ? nil
                            : "\(info.title) shares a config directory with \(info.sharedDirectoryWith.joined(separator: " and ")), so their sessions can't be told apart."
                    )
                },
                selectedID: model.snapshot.selectedPill.id,
                select: { id in
                    if let info = pills.first(where: { $0.id == id }) { model.setPill(info.pill) }
                }
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
    }
}

// MARK: - The tab's content

/// Live | Closed, the header menu, and the list.
struct SessionsContent: View {
    @ObservedObject var model: SessionsModel
    /// Closes the popover, as a successful launch does.
    let close: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let guidance = model.notificationGuidance {
                NotificationsDeniedStrip(text: guidance)
            }
            toolbar
            if let count = model.reopening {
                ReopenProgressStrip(count: count)
            }
            if let summary = model.reopenSummary {
                ReopenStrip(summary: summary) { model.reopenSummary = nil }
            }
            switch model.viewState.mode {
            case .live: liveBody
            case .closed: closedBody
            }
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            SegmentedChips(
                items: [
                    ChipItem(id: SessionsMode.live.rawValue, title: "Live", identifier: AccessibilityID.Popover.Sessions.toggleLive),
                    ChipItem(id: SessionsMode.closed.rawValue, title: "Closed", identifier: AccessibilityID.Popover.Sessions.toggleClosed),
                ],
                selectedID: model.viewState.mode.rawValue,
                select: { id in
                    if let mode = SessionsMode(rawValue: id) { model.setMode(mode) }
                }
            )
            .frame(width: 168)
            Spacer()
            headerMenu
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    /// Quit all, Reopen all and Reopen last closed, with their counts. Visible
    /// on Live and Closed, with rows or without, each disabled with a reason
    /// when it has nothing to do.
    private var headerMenu: some View {
        Menu {
            ForEach(model.headerMenuItems) { item in
                Button(item.title) {
                    Task { if await model.perform(item.kind) { close() } }
                }
                    .disabled(!item.isEnabled)
                    .help(item.disabledReason ?? "")
                    .modifier(ReopenShortcut(applies: item.kind == .reopenLastClosed))
                    .accessibilityIdentifier(identifier(for: item.kind))
                if let reason = item.disabledReason {
                    // The reason in the menu itself: a tooltip on a disabled
                    // menu item is easy never to see.
                    Text(reason)
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Quit or reopen sessions")
        .accessibilityLabel("Sessions menu")
        .accessibilityIdentifier(AccessibilityID.Popover.Sessions.headerMenu)
    }

    private func identifier(for kind: SessionsHeaderMenuItem.Kind) -> String {
        switch kind {
        case .quitAll: return AccessibilityID.Popover.Sessions.quitAll
        case .reopenAll: return AccessibilityID.Popover.Sessions.reopenAll
        case .reopenLastClosed: return AccessibilityID.Popover.Sessions.reopenLastClosed
        }
    }

    // MARK: Live

    @ViewBuilder
    private var liveBody: some View {
        let items = SessionsListLayout.liveItems(snapshot: model.snapshot, pending: model.pending)
        if items.isEmpty {
            emptyState(
                symbol: "terminal",
                title: "No running sessions",
                detail: "Claude Code sessions in Terminal and iTerm appear here.",
                identifier: AccessibilityID.Popover.Sessions.emptyLive
            )
        } else {
            list(items)
        }
    }

    // MARK: Closed

    @ViewBuilder
    private var closedBody: some View {
        searchField
        if !model.closedReady {
            // In place of the list, not above it: a list that fills in under
            // the user's eyes moves whatever they were about to click.
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading session history…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 96)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(AccessibilityID.Popover.Sessions.closedIndexing)
        } else {
            let items = SessionsListLayout.closedItems(sections: model.closedSections, expandedFolds: model.expandedFolds)
            if items.isEmpty {
                if model.viewState.search.trimmingCharacters(in: .whitespaces).isEmpty {
                    emptyState(
                        symbol: "clock.arrow.circlepath",
                        title: "No closed sessions",
                        detail: "Sessions from the last 30 days that are no longer running appear here.",
                        identifier: nil
                    )
                } else {
                    emptyState(
                        symbol: "magnifyingglass",
                        title: "No matches",
                        detail: nil,
                        identifier: AccessibilityID.Popover.Sessions.emptyNoMatches
                    )
                }
            } else {
                list(items)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            TextField("Search name or folder", text: Binding(
                get: { model.viewState.search },
                set: { model.setSearch($0) }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .accessibilityIdentifier(AccessibilityID.Popover.Sessions.closedSearch)
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .cardSurface()
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    // MARK: List

    /// The one scrolling region. Its height is the content's, from the items'
    /// own heights, capped — a `ScrollView` takes whatever it is offered, so a
    /// maximum alone would leave a three-row list in a box that scrolls for
    /// no reason.
    private func list(_ items: [SessionsListItem]) -> some View {
        // Ages are the one thing that changes with nothing else changing; a
        // slow timeline keeps "12m ago" from freezing while the popover is
        // open, without anything polling for it.
        TimelineView(.periodic(from: Date(), by: 15)) { context in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { item in
                        row(for: item, now: context.date)
                    }
                }
                .padding(.horizontal, 8)
            }
            .frame(height: SessionsListLayout.listHeight(items))
        }
    }

    @ViewBuilder
    private func row(for item: SessionsListItem, now: Date) -> some View {
        switch item {
        case .groupHeader(_, let title, let count, let isNeedsYou):
            GroupHeaderView(title: title, count: count, isNeedsYou: isNeedsYou)
        case .sectionHeader(let section):
            GroupHeaderView(title: section.title, count: nil, isNeedsYou: false)
        case .live(let sessionRow):
            LiveSessionRowView(
                model: model,
                row: sessionRow,
                now: now,
                isQuitting: model.quitting.contains(sessionRow.key),
                message: model.message(forLive: sessionRow.key),
                messageHelp: model.help(forLive: sessionRow.key),
                isRenaming: model.renaming == .live(sessionRow.key),
                close: close
            )
        case .pending(let launch):
            PendingLaunchRowView(model: model, launch: launch)
        case .closed(let session, let indented):
            ClosedSessionRowView(
                model: model,
                session: session,
                now: now,
                indented: indented,
                accountName: model.profileName(forID: session.entry.profileID),
                message: model.message(forClosed: session.id),
                isResuming: model.resuming.contains(session.id),
                isPendingReopen: model.pendingReopenIDs.contains(session.id),
                isRenaming: model.renaming == .closed(session.id),
                close: close
            )
        case .fold(let fold, let expanded):
            FoldRowView(model: model, fold: fold, expanded: expanded, now: now)
        }
    }

    // MARK: Empty state

    private func emptyState(symbol: String, title: String, detail: String?, identifier: String?) -> some View {
        let content = VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 12, weight: .medium))
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, minHeight: 96)
        .accessibilityElement(children: .combine)
        return Group {
            if let identifier { content.accessibilityIdentifier(identifier) } else { content }
        }
    }
}

/// ⇧⌘T on Reopen last closed, while the popover is open. A modifier so the
/// other two items carry no shortcut.
private struct ReopenShortcut: ViewModifier {
    let applies: Bool

    func body(content: Content) -> some View {
        if applies {
            content.keyboardShortcut("t", modifiers: [.command, .shift])
        } else {
            content
        }
    }
}

// MARK: - Notifications

/// Notifications are turned off for AgentMenu in macOS (R32): says so, and
/// where to turn them back on. Informational — the tab works without them.
struct NotificationsDeniedStrip: View {
    let text: String

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "bell.slash")
                .foregroundStyle(Color.brandWarning(scheme))
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .cardSurface()
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityID.Popover.Sessions.notificationsDenied)
    }
}

// MARK: - The Reopen all result

/// A dismissible strip at the top of the list naming each failure and its
/// reason (R35, R36): what a Reopen all leaves, and a Reopen last closed that
/// failed.
struct ReopenStrip: View {
    let summary: ReopenAllSummary
    let dismiss: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: summary.failures.isEmpty ? "checkmark.circle" : "exclamationmark.triangle.fill")
                    .foregroundStyle(summary.failures.isEmpty ? Color.secondary : Color.brandWarning(scheme))
                Text(summary.headline)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
                .accessibilityIdentifier(AccessibilityID.Popover.Sessions.reopenStripDismiss)
            }
            ForEach(summary.failures) { failure in
                Text("\(failure.name): \(failure.reason)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .cardSurface()
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Popover.Sessions.reopenStrip)
    }
}

/// While a Reopen all runs: it waits for each batch of three to come up, which
/// takes a few seconds, and says so rather than sitting silent.
struct ReopenProgressStrip: View {
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 16, height: 16)
            Text(count == 1 ? "Reopening 1 session…" : "Reopening \(count) sessions…")
                .font(.system(size: 12, weight: .medium))
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .cardSurface()
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityID.Popover.Sessions.reopenProgress)
    }
}

// MARK: - The post-restart banner

/// Above the tabs, on Launch and Sessions alike: sessions that were running when
/// the Mac shut down, AgentMenu's session host died, or AgentMenu stopped are
/// waiting to be reopened (F2). One click brings them back; the cross closes it
/// for this set without losing the set. It clears by itself when the set empties.
/// After a restart, and until it is answered, it also asks once whether to do
/// this by itself at login (R25).
struct RestoreBanner: View {
    @ObservedObject var model: SessionsModel

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let banner = model.restoreBanner {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "arrow.counterclockwise.circle.fill")
                        .foregroundStyle(Color.brandAccent(scheme))
                    Text(banner.message)
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("Reopen all") {
                        Task { await model.reopenAll() }
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 12, weight: .semibold))
                    .disabled(model.reopening != nil)
                    .accessibilityIdentifier(AccessibilityID.Popover.restoreBannerReopenAll)
                    Button { model.dismissRestoreBanner() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                    .accessibilityLabel("Dismiss")
                    .accessibilityIdentifier(AccessibilityID.Popover.restoreBannerDismiss)
                }
                if model.asksReopenAtLogin {
                    // Asked once, here, the first time a restart's set is on
                    // offer (R25): never at launch, never as a modal.
                    VStack(alignment: .leading, spacing: 4) {
                        Text(ReopenAtLoginQuestion.prompt)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier(AccessibilityID.Popover.restoreBannerQuestion)
                        HStack(spacing: 12) {
                            Button(ReopenAtLoginQuestion.yesTitle) {
                                model.answerReopenAtLogin(true)
                            }
                            .disabled(model.reopening != nil)
                            .accessibilityIdentifier(AccessibilityID.Popover.restoreBannerReopenAtLogin)
                            Button(ReopenAtLoginQuestion.noTitle) {
                                model.answerReopenAtLogin(false)
                            }
                            .accessibilityIdentifier(AccessibilityID.Popover.restoreBannerNotAtLogin)
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 11, weight: .semibold))
                    }
                    .padding(.leading, 24)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .cardSurface()
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(AccessibilityID.Popover.restoreBanner)
        }
    }
}

/// ⇧⌘T while the popover is open, on either tab. A menu item's shortcut only
/// reaches a menu that is in the menu bar, and this popover's is not, so a
/// button nobody sees carries the shortcut that really fires.
struct ReopenLastClosedShortcut: View {
    @ObservedObject var model: SessionsModel
    let close: () -> Void

    var body: some View {
        Button("Reopen last closed") {
            Task { if await model.reopenLastClosed() { close() } }
        }
        .keyboardShortcut("t", modifiers: [.command, .shift])
        .disabled(model.closedStackCount == 0)
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }
}
