import AppKit

/// User-selectable application appearance.
/// `.system` defers to macOS's current Light/Dark setting; `.light` and `.dark`
/// pin `NSApp.appearance` regardless of OS preference. Persisted as the raw
/// string in `AppSettings.appearance`.
enum AppearanceMode: String, Codable, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    /// Maps to an `NSAppearance` for `NSApp.appearance`. `nil` means "let macOS decide".
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        }
    }
}
