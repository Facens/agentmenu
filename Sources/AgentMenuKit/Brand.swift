// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Brand values the app draws with, kept in one place so the popover, the
/// settings window and the rendered icon cannot drift apart.
///
/// The accent is deliberately not the system accent colour: a launcher's own
/// primary action should read as this app's, and the amber used to mark a
/// permission mode that stops asking has to stay unmistakably different from
/// it. Standard macOS controls keep the user's system accent; only AgentMenu's
/// own chrome uses these.
public enum Brand {
    /// #D6336C — the accent on a light appearance.
    public static let accentLight = (red: 0.839, green: 0.200, blue: 0.424)
    /// #FF6B9D — the accent on a dark appearance, lifted for contrast.
    public static let accentDark = (red: 1.0, green: 0.420, blue: 0.616)
    /// #A15C07 / #F5B301 — a permission mode that stops asking (R37).
    ///
    /// Pushed towards yellow, away from orange: against a rose accent an orange
    /// warning is a hue apart, and this marking exists to be unmistakable at a
    /// glance before a click that starts an agent which never asks.
    public static let warningLight = (red: 0.631, green: 0.361, blue: 0.027)
    public static let warningDark = (red: 0.961, green: 0.702, blue: 0.004)

    /// Name of the menu-bar template image in the bundle's Resources.
    public static let menuBarImageName = "MenuBarIconTemplate"
}
