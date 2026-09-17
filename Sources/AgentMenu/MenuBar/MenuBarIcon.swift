// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import AgentMenuKit

/// The menu-bar glyph.
///
/// It is a template image, so macOS tints it for the light and dark menu bar
/// and for the highlighted state; the rendered PNG carries only alpha. The
/// fallback matters: a bundle assembled without the icon step should still
/// show something clickable rather than an empty slot.
enum MenuBarIcon {
    static func image() -> NSImage? {
        guard let image = NSImage(named: Brand.menuBarImageName) else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }

    /// The badge shown beside the glyph once an account is close to a limit:
    /// a two-bar meter, then the number.
    ///
    /// The meter carries what a number cannot — both windows at once, each at
    /// its own length and its own colour, so a weekly limit filling up while
    /// the 5-hour one is empty is one glance rather than a tooltip. The number
    /// stays because a bar says "nearly full" and never says how nearly.
    ///
    /// The glyph itself is left alone, still a template: a coloured menu-bar
    /// icon has to be redrawn on every appearance change to stay legible
    /// against a bar that may be light, dark, or wallpaper showing through,
    /// and that is macOS's job as long as the image stays a template. The
    /// meter is an attachment drawn by a handler, which AppKit re-runs at draw
    /// time — so its `labelColor` track resolves against whichever appearance
    /// is current, with no observer of our own.
    static func badge(for alert: UsageAlert, snapshot: UsageSnapshot, now: Date = Date()) -> NSAttributedString {
        let badge = NSMutableAttributedString()

        let attachment = NSTextAttachment()
        attachment.image = meter(for: snapshot, now: now)
        attachment.bounds = NSRect(x: 0, y: -2, width: meterSize.width, height: meterSize.height)
        badge.append(NSAttributedString(string: " "))
        badge.append(NSAttributedString(attachment: attachment))

        badge.append(NSAttributedString(
            string: " " + alert.badge,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(
                    ofSize: NSFont.systemFontSize(for: .small),
                    weight: alert.level == .exhausted ? .bold : .semibold
                ),
                .foregroundColor: color(for: alert.level),
            ]
        ))
        return badge
    }

    static let meterSize = NSSize(width: 17, height: 11)

    /// Two stacked tracks — 5-hour above, weekly below — each filled to its
    /// own percentage and coloured by its own level.
    ///
    /// A window the snapshot does not carry, or one already past its reset,
    /// draws an empty track rather than being left out: a meter with one bar
    /// in it looks like a meter that has lost a bar. Empty is the honest
    /// picture of a window with no current reading.
    static func meter(for snapshot: UsageSnapshot, now: Date = Date()) -> NSImage {
        let age = snapshot.age(now: now)
        let readings = UsageWindowKind.allCases.map { kind -> Double? in
            guard let window = snapshot.window(kind),
                  window.state(now: now, age: age, staleAfter: UsageReader.defaultStaleAfter) != .rolledOver
            else { return nil }
            return window.usedPercentage
        }

        let size = meterSize
        return NSImage(size: size, flipped: false) { _ in
            let barHeight: CGFloat = 4
            let gap: CGFloat = 3
            // The stack's own height, not one bar's: measuring from the wrong
            // one put the second bar below the image's bottom edge, where it
            // was drawn clipped to half its height.
            let stackHeight = CGFloat(UsageWindowKind.allCases.count) * barHeight
                + CGFloat(UsageWindowKind.allCases.count - 1) * gap
            let top = (size.height + stackHeight) / 2

            for (index, reading) in readings.enumerated() {
                let y = top - CGFloat(index) * (barHeight + gap) - barHeight
                let track = NSRect(x: 0, y: y, width: size.width, height: barHeight)
                NSColor.labelColor.withAlphaComponent(0.22).setFill()
                NSBezierPath(roundedRect: track, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()

                guard let reading, reading > 0 else { continue }
                let fraction = max(0, min(1, reading / 100))
                // Never thinner than its own cap: a 2% reading that rounds to
                // nothing looks identical to no reading at all.
                let width = max(barHeight, size.width * fraction)
                let fill = NSRect(x: 0, y: y, width: width, height: barHeight)
                color(for: UsageAlertLevel(usedPercentage: reading)).setFill()
                NSBezierPath(roundedRect: fill, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()
            }
            return true
        }
    }

    /// Three steps, three colours that survive both a light and a dark menu
    /// bar. System colours on purpose: they are the ones the rest of macOS
    /// uses for the same escalation, and they adapt with the appearance.
    static func color(for level: UsageAlertLevel) -> NSColor {
        switch level {
        // Visible, but not a colour that asks for anything: below the first
        // threshold a full-ish bar is information, not a warning.
        case .normal: return .labelColor.withAlphaComponent(0.55)
        case .caution: return .systemOrange
        case .warning, .exhausted: return .systemRed
        }
    }

    /// What the icon means, spelled out — including how old the reading is,
    /// so an hour-old 97% is never presented as the state right now.
    static func tooltip(for alert: UsageAlert, profileName: String, now: Date = Date()) -> String {
        let window = alert.kind == .fiveHour ? "5-hour" : "weekly"
        let head: String
        switch alert.level {
        case .exhausted:
            head = "\(profileName): the \(window) limit is used up"
        default:
            head = "\(profileName): \(Int(alert.usedPercentage.rounded()))% of the \(window) limit used"
        }
        let resets = DateFormatter()
        resets.dateFormat = Calendar.current.isDate(alert.resetsAt, inSameDayAs: now) ? "HH:mm" : "EEE HH:mm"
        return head
            + ", resets \(resets.string(from: alert.resetsAt))"
            + " — read \(UsageSnapshot.describeAge(alert.age))"
    }
}
