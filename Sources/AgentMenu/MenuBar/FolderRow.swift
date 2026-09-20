// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AgentMenuKit

/// One launch target in the list.
///
/// The row's own click launches; the chevron opens the full override panel. Two
/// hit areas rather than one, because a single click that sometimes launches and
/// sometimes expands is the kind of ambiguity a menu cannot afford.
///
/// Model and effort are **editable from the row itself**: the two values changed
/// most often are one click away, and the panel is for everything else. A pill
/// showing an inherited value is quiet; one carrying an override reads in the
/// accent, so a customised row is still visible at a glance.
struct FolderRow: View {
    let target: LaunchTarget
    /// The values this launch would use, after the three layers are merged.
    let effective: Preset
    let options: PresetOptions
    /// Which fields this target sets itself, rather than inheriting.
    let overridden: Set<PresetField>
    let bypasses: Bool
    let isExpanded: Bool
    /// A launch is in flight for this row. Shown, not hidden: the terminal can
    /// take a moment to answer, and a row that looks idle invites a second
    /// click that starts a second session.
    let isLaunching: Bool
    /// This row stands for a configured folder and can be dragged into a
    /// different position. False for `$HOME` when nothing configures it and
    /// for the Finder window — neither has an entry to move.
    let isDraggable: Bool
    var subtitle: String?
    let setModel: (String?) -> Void
    let setEffort: (String?) -> Void
    let launch: () -> Void
    let toggle: () -> Void

    @Environment(\.colorScheme) private var scheme
    // Not `@State`: the SwiftUI in the macOS 26 SDK declares `State` as a
    // macro, and the plugin that expands it (`libSwiftUIMacros.dylib`) ships
    // with Xcode, not with the Command Line Tools — which R32 says is the
    // only toolchain this project may need. One `@State` was enough to make
    // the whole app target unbuildable on a clean CLT machine; an
    // `ObservableObject` holds the same one flag with no macro involved.
    @StateObject private var hover = HoverState()

    var body: some View {
        // `.contain`, not the default: this row carries several real controls
        // — launch, the model and effort pills, the reorder handle, the
        // chevron — and each needs its own AXIdentifier reachable on its own,
        // not folded into one element that only the row's label describes.
        HStack(spacing: 6) {
            Button(action: launch) {
                HStack(spacing: 8) {
                    // The row is a button, and nothing said so. On hover it
                    // says it: the glyph appears where the eye already is,
                    // before the label it is about to act on.
                    // The same 9 points either way, so the label does not
                    // shift sideways the instant the launch starts.
                    Group {
                        if isLaunching {
                            ProgressView()
                                .controlSize(.mini)
                                .scaleEffect(0.6)
                        } else {
                            Image(systemName: "play.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(hover.hovering ? Color.brandAccent(scheme) : .clear)
                        }
                    }
                    .frame(width: 9)
                    Text(target.label)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                    if let subtitle {
                        // The path gives way first: the label is what the user
                        // recognises, and a truncated path is still readable
                        // from its tail.
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .layoutPriority(0)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Launch an agent session in \(target.path)")
            .accessibilityIdentifier(AccessibilityID.Popover.rowLaunch(target))

            if bypasses {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.brandWarning(scheme))
                    .help("This target launches without the agent's permission prompts.")
            }

            if let values = options.model {
                pill(values: values,
                     current: effective.model,
                     isOverride: overridden.contains(.model),
                     label: "Model",
                     id: AccessibilityID.Popover.rowModel(target),
                     set: setModel)
            }
            if let values = options.effort {
                pill(values: values,
                     current: effective.effort,
                     isOverride: overridden.contains(.effort),
                     label: "Effort",
                     id: AccessibilityID.Popover.rowEffort(target),
                     set: setEffort)
            }

            if hover.hovering {
                // A button, not a label. It appears on hover, at the right of
                // the row, and it says "Launch" — so it is read as the control
                // that launches, and clicked. As a bare `Text` beside the real
                // button it swallowed those clicks and did nothing, which is
                // indistinguishable from the launch being broken.
                Button(action: launch) {
                    Text("Launch")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.brandAccent(scheme))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Launch an agent session in \(target.path)")
            }

            // A handle rather than the whole row: the row is already a button
            // that launches on click, and a drag started anywhere on it would
            // be a gesture competing with the one thing the row is for.
            if isDraggable, let folderID = target.folderID {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 14, height: 22)
                    .contentShape(Rectangle())
                    .opacity(hover.hovering ? 1 : 0)
                    .help("Drag to reorder. The order here is the order you set.")
                    .accessibilityIdentifier(AccessibilityID.Popover.rowReorder(target))
                    .draggable(folderID) {
                        Text(target.label)
                            .font(.system(size: 12))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                    }
            }

            Button(action: toggle) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .contentShape(Rectangle())
                    .frame(width: 16, height: 22)
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Hide the launch options" : "Show every launch option for this target")
            .accessibilityIdentifier(AccessibilityID.Popover.rowExpand(target))
        }
        .accessibilityElement(children: .contain)
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(hover.hovering ? Color.primary.opacity(scheme == .dark ? 0.07 : 0.05) : .clear)
        )
        .onHover { hover.hovering = $0 }
    }

    /// A pill that is also the control. It shows the value without being
    /// opened (R12) and changes it for this launch only until it is saved.
    private func pill(
        values: [String],
        current: String?,
        isOverride: Bool,
        label: String,
        id: String,
        set: @escaping (String?) -> Void
    ) -> some View {
        Menu {
            Button("Inherit") { set(nil) }
            Divider()
            ForEach(values, id: \.self) { value in
                Button {
                    set(value)
                } label: {
                    if value == current {
                        Label(value, systemImage: "checkmark")
                    } else {
                        Text(value)
                    }
                }
            }
        } label: {
            // With nothing set anywhere, the pill shows what it is for rather
            // than an em-dash that means nothing and hides the control.
            Text(current ?? label.lowercased())
                .font(.system(size: 11))
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        // Shown, not hidden. These are menus that look exactly like the labels
        // beside them, and `.hidden` left nothing at all to say they open.
        .menuIndicator(.visible)
        .accessibilityIdentifier(id)
        .fixedSize()
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(isOverride
                      ? Color.brandAccent(scheme).opacity(scheme == .dark ? 0.20 : 0.14)
                      : Color.primary.opacity(scheme == .dark ? 0.09 : 0.055))
        )
        .foregroundStyle(isOverride ? Color.brandAccent(scheme) : Color.secondary)
        .help("\(label) for this launch. Inherited values are shown quietly; this one is \(isOverride ? "set on the target" : "inherited").")
    }
}

/// One `Bool`, in an object because `@State` is unavailable under the
/// Command Line Tools alone (see the comment on `FolderRow.hover`).
final class HoverState: ObservableObject {
    @Published var hovering = false
}
