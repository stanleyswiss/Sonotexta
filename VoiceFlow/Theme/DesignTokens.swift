import SwiftUI

/// Single source of truth for adaptive colors used throughout the app.
///
/// Every token resolves through Asset Catalog ColorSets at
/// `VoiceFlow/Assets.xcassets/Colors/`, which carry both light and dark
/// appearance variants. The HUD pair (`hudBackground`, `hudForeground`) is
/// intentionally non-adaptive — the dictation overlay keeps the same dark
/// background in both themes for legibility on any wallpaper.
///
/// Do NOT hardcode `.white`, `.black.opacity(...)` or `Color(red:green:blue:)`
/// in feature code. Add a new token here and reference it.
enum DesignTokens {
    /// Primary accent (purple/violet). Use for selected states, primary buttons,
    /// and focus indicators.
    static let accent           = Color("AccentPurple", bundle: .main)

    /// Top-level surface (window background, primary card fill).
    static let surfacePrimary   = Color("SurfacePrimary", bundle: .main)

    /// Sub-surface (sidebar, secondary card fill).
    static let surfaceSecondary = Color("SurfaceSecondary", bundle: .main)

    /// Tertiary surface (nested rows inside a secondary card).
    static let surfaceTertiary  = Color("SurfaceTertiary", bundle: .main)

    /// Hairline border used to separate cards and rows.
    static let borderSubtle     = Color("BorderSubtle", bundle: .main)

    /// Semantic colors. Always use the named token instead of `.green`/`.red`.
    static let statusSuccess    = Color("StatusSuccess", bundle: .main)
    static let statusWarning    = Color("StatusWarning", bundle: .main)
    static let statusDanger     = Color("StatusDanger", bundle: .main)
    static let statusNeutral    = Color("StatusNeutral", bundle: .main)

    /// Dictation HUD background. Intentionally dark in both modes.
    static let hudBackground    = Color("HUDBackground", bundle: .main)

    /// Dictation HUD foreground (text + icons). Pairs with `hudBackground`,
    /// intentionally non-adaptive.
    static let hudForeground    = Color("HUDForeground", bundle: .main)
}
