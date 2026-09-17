// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AgentMenuKit

/// The brand accent as SwiftUI colours.
///
/// Only AgentMenu's own chrome uses these — the mark, the Launch button, the
/// rate-limit bars. Standard controls keep `Color.accentColor`, which follows
/// the accent the user chose in System Settings; overriding that would make the
/// app look broken rather than branded. See docs/brand.md.
extension Color {
    static func brandAccent(_ scheme: ColorScheme) -> Color {
        let c = scheme == .dark ? Brand.accentDark : Brand.accentLight
        return Color(.sRGB, red: c.red, green: c.green, blue: c.blue)
    }

    static func brandWarning(_ scheme: ColorScheme) -> Color {
        let c = scheme == .dark ? Brand.warningDark : Brand.warningLight
        return Color(.sRGB, red: c.red, green: c.green, blue: c.blue)
    }
}

/// The mark, drawn rather than loaded: it is three strokes, and a vector here
/// scales with Dynamic Type without shipping another asset.
struct BrandMark: View {
    var size: CGFloat = 19
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Canvas { context, canvasSize in
            let s = canvasSize.width / 18
            let color = Color.brandAccent(scheme)
            var caret = Path()
            caret.move(to: CGPoint(x: 5.4 * s, y: 5.2 * s))
            caret.addLine(to: CGPoint(x: 8.6 * s, y: 9 * s))
            caret.addLine(to: CGPoint(x: 5.4 * s, y: 12.8 * s))

            var line = Path()
            line.move(to: CGPoint(x: 10.6 * s, y: 12.8 * s))
            line.addLine(to: CGPoint(x: 13.2 * s, y: 12.8 * s))

            let stroke = StrokeStyle(lineWidth: 1.9 * s, lineCap: .round, lineJoin: .round)
            context.stroke(caret, with: .color(color), style: stroke)
            context.stroke(line, with: .color(color), style: stroke)
            context.fill(
                Path(ellipseIn: CGRect(x: (12.7 - 1.15) * s, y: (5.4 - 1.15) * s, width: 2.3 * s, height: 2.3 * s)),
                with: .color(color)
            )
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A card surface: the popover's own grouping, one step above the background.
struct CardBackground: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.06), radius: 1, y: 0.5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(scheme == .dark ? 0.6 : 0.35), lineWidth: 0.5)
            )
    }
}

extension View {
    func cardSurface() -> some View { modifier(CardBackground()) }
}
