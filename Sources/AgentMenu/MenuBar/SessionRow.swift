// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AgentMenuKit

// The rows of the Sessions list. The row views are named `…RowView` because
// AgentMenuKit already has a `SessionRow` — the value a live row is built from.
//
// Every row is a fixed height (`SessionsListLayout`), so the list can be sized
// as a sum: a message, a rename field or a detached marker takes the place of
// something already in the row and never adds a line.

extension SessionStatus {
    /// Colour for the symbol and the word. Never the only cue: each status
    /// also has its own symbol and its own label.
    func color(_ scheme: ColorScheme) -> Color {
        switch self {
        case .needsYou: return Color.brandWarning(scheme)
        case .working: return Color.brandAccent(scheme)
        case .yourTurn: return Color.green
        case .unknown: return Color.secondary
        }
    }
}

extension Color {
    /// The fill behind a hovered row.
    static func rowHoverFill(_ scheme: ColorScheme) -> Color {
        Color.primary.opacity(scheme == .dark ? 0.08 : 0.05)
    }
}

/// The "…" that opens a row's options menu.
private func rowMenuLabel() -> some View {
    Image(systemName: "ellipsis")
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .frame(width: 18, height: 22)
        .contentShape(Rectangle())
}

// MARK: - Headers

/// A group's heading: "Needs you", a folder, or a recency bucket.
struct GroupHeaderView: View {
    let title: String
    let count: Int?
    let isNeedsYou: Bool

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        // The Needs-you heading is one element with an identifier, so a
        // scenario can tell the group is on screen; combining its children is
        // what makes the identifier land on the heading rather than on each
        // of its pieces. Folder headings stay as they were: their names are
        // paths, which no identifier carries.
        if isNeedsYou {
            content
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier(AccessibilityID.Popover.Sessions.needsYouHeader)
        } else {
            content.accessibilityAddTraits(.isHeader)
        }
    }

    private var content: some View {
        HStack(spacing: 5) {
            if isNeedsYou {
                Image(systemName: SessionStatus.needsYou.symbolName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.brandWarning(scheme))
            }
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.6)
                .textCase(.uppercase)
                .foregroundStyle(isNeedsYou ? Color.brandWarning(scheme) : Color.secondary)
                .lineLimit(1)
            if let count {
                Text("\(count)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        // The bottom padding is inside the frame: the list is sized from
        // `headerHeight`, and padding applied after the frame would make
        // every header taller than the sum counts it.
        .padding(.bottom, 3)
        .frame(height: SessionsListLayout.headerHeight, alignment: .bottom)
    }
}

// MARK: - Rename

/// The inline field a row shows while it is being renamed. Return saves,
/// Escape abandons; a blank name clears the rename and brings the recorded
/// title back.
struct RenameField: View {
    @Binding var text: String
    let identifier: String
    let commit: () -> Void
    let cancel: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        TextField("Name", text: $text)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12))
            .focused($focused)
            .onSubmit(commit)
            .onExitCommand(perform: cancel)
            .onAppear { focused = true }
            .accessibilityIdentifier(identifier)
    }
}

// MARK: - Live

struct LiveSessionRowView: View {
    let model: SessionsModel
    let row: SessionRow
    let now: Date
    let isQuitting: Bool
    /// Replaces the detail line: why a click or a save did not do what it said.
    let message: String?
    /// The longer text behind `message`, for its tooltip.
    let messageHelp: String?
    let isRenaming: Bool
    /// Closes the popover after a click that brought a terminal forward, as a
    /// successful launch does.
    let close: () -> Void

    @Environment(\.colorScheme) private var scheme
    // An `ObservableObject`, not `@State` — see `FolderRow.hover`.
    @StateObject private var hover = HoverState()

    private var status: SessionStatus { row.status }

    var body: some View {
        HStack(spacing: 6) {
            if isRenaming {
                renameBody
            } else {
                mainButton
            }
            menu
        }
        .padding(.horizontal, 8)
        .frame(height: SessionsListLayout.liveRowHeight)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(background)
        )
        // A quitting row is dimmed, not removed: it is still running until
        // its process exits, and it keeps saying so.
        .opacity(isQuitting ? 0.5 : 1)
        .onHover { hover.hovering = $0 }
        // `.contain`, as `FolderRow` does: the row carries real controls of
        // its own, and each needs its identifier reachable on its own.
        .accessibilityElement(children: .contain)
    }

    private var background: Color {
        if status == .needsYou { return Color.brandWarning(scheme).opacity(hover.hovering ? 0.18 : 0.11) }
        return hover.hovering ? Color.rowHoverFill(scheme) : .clear
    }

    // MARK: Pieces

    private var statusSymbol: some View {
        Image(systemName: status.symbolName)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(status.color(scheme))
            .frame(width: 16, height: 16)
            .accessibilityHidden(true)
    }

    private var mainButton: some View {
        Button { Task { if await model.focus(row) { close() } } } label: {
            HStack(alignment: .top, spacing: 8) {
                statusSymbol
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(row.name)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 6)
                        if row.isDetached {
                            // Beside the status, never instead of it (R9).
                            Text(SessionRowWording.detachedLabel)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 0.5))
                        }
                        Text(isQuitting ? SessionRowWording.quittingLabel : SessionRowWording.statusText(for: row.live))
                            .font(.system(size: 11, weight: status == .needsYou ? .semibold : .regular))
                            .foregroundStyle(status.color(scheme))
                            .lineLimit(1)
                            .fixedSize()
                    }
                    detail
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.Popover.Sessions.liveRow(row.key))
    }

    private var renameBody: some View {
        HStack(alignment: .top, spacing: 8) {
            statusSymbol
            RenameField(
                text: Binding(get: { model.renameDraft }, set: { model.renameDraft = $0 }),
                identifier: AccessibilityID.Popover.Sessions.liveRowRename(row.key),
                commit: { model.commitRename(sessionID: row.sessionId, messageKey: AccessibilityID.Popover.Sessions.liveRowKey(row.key)) },
                cancel: { model.cancelRename() }
            )
        }
    }

    /// Folder, account, terminal, age — for an agent with no registry, folder,
    /// terminal and age (R2).
    @ViewBuilder
    private var detail: some View {
        if let message {
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(Color.brandWarning(scheme))
                .lineLimit(1)
                .help(messageHelp ?? message)
        } else {
            Text(detailText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(helpText)
        }
    }

    private var detailText: String {
        var parts: [String] = []
        if let folder = SessionRowWording.folderName(row.folderPath) { parts.append(folder) }
        if let account = row.profileName, row.live.isClaudeCode {
            parts.append(row.sharedDirectory == nil ? account : account + " ≈")
        }
        parts.append(row.live.terminal.displayName)
        parts.append(UsageSnapshot.describeAge(now.timeIntervalSince(row.live.startedAt)))
        return parts.joined(separator: " · ")
    }

    private var helpText: String {
        var lines: [String] = []
        if let path = row.folderPath { lines.append(PathDisplay.abbreviated(path)) }
        if let note = row.sharedDirectory { lines.append(note.tooltip) }
        return lines.joined(separator: "\n")
    }

    private var menu: some View {
        Menu {
            Button("Rename…") { model.beginRename(live: row) }
                .disabled(!model.canRename(row))
            // Any live session can be quit (R19), owned or not. One AgentMenu
            // started is recorded and stays restorable; any other is only
            // signalled.
            Button("Quit") { model.quit(row) }
                .disabled(isQuitting)
                .help(isQuitting ? "Already quitting." : "Ends this session. Unanswered work in progress is lost.")
                .accessibilityIdentifier(AccessibilityID.Popover.Sessions.liveRowQuit(row.key))
        } label: {
            rowMenuLabel()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Session options")
        .accessibilityIdentifier(AccessibilityID.Popover.Sessions.liveRowMenu(row.key))
    }
}

// MARK: - Pending launches (Starting, Failed to start)

/// A launch with no live row: Starting shows a progress indicator and only
/// Quit; Failed to start keeps its reason and offers Retry and Dismiss (R36).
/// Nothing creates one until owned launches exist (U14), so this renders what
/// it is handed and nothing more.
struct PendingLaunchRowView: View {
    let model: SessionsModel
    let launch: PendingLaunch

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            switch launch.phase {
            case .starting:
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: 16, height: 16)
                VStack(alignment: .leading, spacing: 3) {
                    Text(launch.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text("Starting…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                // A launch that has not registered has no process to signal
                // yet; Quit is available on its row once it appears.
                Button("Quit") {}
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                    .disabled(true)
                    .help("A session that is still starting can be quit once it appears.")
                    .accessibilityIdentifier(AccessibilityID.Popover.Sessions.pendingQuit(launchID: launch.id))
            case .failedToStart(let reason):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.brandWarning(scheme))
                    .frame(width: 16, height: 16)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(launch.title)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        Text("Failed to start")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.brandWarning(scheme))
                    }
                    Text(reason)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        // Retry is not wired yet; the button is here so the
                        // row has its final shape.
                        Button("Retry") {}
                            .buttonStyle(.link)
                            .font(.system(size: 11))
                            .disabled(true)
                            .help("Retrying a launch arrives in a later update.")
                            .accessibilityIdentifier(AccessibilityID.Popover.Sessions.pendingRetry(launchID: launch.id))
                        Button("Dismiss") { model.dismissPending(launch.id) }
                            .buttonStyle(.link)
                            .font(.system(size: 11))
                            .accessibilityIdentifier(AccessibilityID.Popover.Sessions.pendingDismiss(launchID: launch.id))
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(height: launch.phase == .starting ? SessionsListLayout.liveRowHeight : SessionsListLayout.failedRowHeight, alignment: .top)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.Popover.Sessions.pendingRow(launchID: launch.id))
    }
}

// MARK: - Closed

struct ClosedSessionRowView: View {
    let model: SessionsModel
    let session: ClosedSession
    let now: Date
    let indented: Bool
    let accountName: String
    let message: String?
    let isResuming: Bool
    /// Reopen all would bring it back (it is in the pending reopen set).
    let isPendingReopen: Bool
    let isRenaming: Bool
    let close: () -> Void

    @Environment(\.colorScheme) private var scheme
    @StateObject private var hover = HoverState()

    /// nil when the session can be resumed; otherwise why it cannot.
    private var notRestorableReason: String? {
        if case .notRestorable(let reason) = session.entry.restorability { return reason }
        return nil
    }

    var body: some View {
        HStack(spacing: 6) {
            if isRenaming {
                RenameField(
                    text: Binding(get: { model.renameDraft }, set: { model.renameDraft = $0 }),
                    identifier: AccessibilityID.Popover.Sessions.closedRowRename(sessionID: session.id),
                    commit: { model.commitRename(sessionID: session.id, messageKey: AccessibilityID.Popover.Sessions.closedRowKey(sessionID: session.id)) },
                    cancel: { model.cancelRename() }
                )
            } else {
                mainButton
            }
            menu
        }
        .padding(.leading, indented ? 26 : 8)
        .padding(.trailing, 8)
        .frame(height: indented ? SessionsListLayout.foldedChildHeight : SessionsListLayout.closedRowHeight)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(hover.hovering && notRestorableReason == nil ? Color.rowHoverFill(scheme) : .clear)
        )
        // A row that cannot be resumed stays listed — the user may recognise
        // it — but dimmed, with why on hover.
        .opacity(notRestorableReason == nil ? 1 : 0.5)
        .help(notRestorableReason ?? "")
        .onHover { hover.hovering = $0 }
        .accessibilityElement(children: .contain)
    }

    private var mainButton: some View {
        Button {
            guard notRestorableReason == nil else { return }
            Task { if await model.resume(session) { close() } }
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let message {
                        Text(message)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.brandWarning(scheme))
                            .lineLimit(1)
                    } else {
                        Text(detailText)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 6)
                if isPendingReopen {
                    reopenAllTag
                }
                if isResuming {
                    ProgressView().controlSize(.mini).scaleEffect(0.6)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityID.Popover.Sessions.closedRow(sessionID: session.id))
    }

    /// "Reopen all brings it back": this session was running when the others
    /// stopped together, and is in the set Reopen all restores (U5 step 8).
    private var reopenAllTag: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.counterclockwise")
            Text("Reopen all")
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.primary.opacity(scheme == .dark ? 0.12 : 0.07)))
        .help("Reopen all brings this session back.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Reopen all brings this session back")
        .accessibilityIdentifier(AccessibilityID.Popover.Sessions.closedRowPendingTag(sessionID: session.id))
    }

    private var detailText: String {
        var parts: [String] = []
        if let folder = session.entry.folderName { parts.append(folder) }
        parts.append(accountName)
        parts.append(UsageSnapshot.describeAge(now.timeIntervalSince(session.entry.modified)))
        return parts.joined(separator: " · ")
    }

    private var menu: some View {
        Menu {
            Button("Rename…") { model.beginRename(closed: session) }
                .disabled(model.renameUnavailableReason != nil)
        } label: {
            rowMenuLabel()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Session options")
        .accessibilityIdentifier(AccessibilityID.Popover.Sessions.closedRowMenu(sessionID: session.id))
    }
}

/// Unowned runs of one skill in one folder, folded into one row that opens on
/// click (R29).
struct FoldRowView: View {
    let model: SessionsModel
    let fold: SkillFold
    let expanded: Bool
    let now: Date

    @StateObject private var hover = HoverState()
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button { model.toggleFold(fold.id) } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 12)
                VStack(alignment: .leading, spacing: 3) {
                    Text("/\(fold.skill)")
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text(detailText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
            }
            .padding(.horizontal, 8)
            .frame(height: SessionsListLayout.closedRowHeight)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hover.hovering ? Color.rowHoverFill(scheme) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.hovering = $0 }
        .accessibilityLabel("\(fold.skill), \(fold.count) runs, \(expanded ? "expanded" : "collapsed")")
        .accessibilityIdentifier(AccessibilityID.Popover.Sessions.foldRow(foldID: fold.id))
    }

    private var detailText: String {
        var parts = ["\(fold.count) runs"]
        if let cwd = fold.cwd, let folder = SessionRowWording.folderName(cwd) { parts.append(folder) }
        if let newest = fold.sessions.first {
            parts.append(UsageSnapshot.describeAge(now.timeIntervalSince(newest.entry.modified)))
        }
        return parts.joined(separator: " · ")
    }
}
