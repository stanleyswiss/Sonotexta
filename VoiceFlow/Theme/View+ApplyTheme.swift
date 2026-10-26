import SwiftUI

extension View {
    /// Reserved for future per-view environment injection.
    ///
    /// Today theme application happens centrally via `NSApp.appearance` from
    /// `ThemeService`, so any SwiftUI view inside an `NSWindow` already sees
    /// the correct `colorScheme`. Calling this modifier is a no-op, but call
    /// sites use it as the documented seam in case we later need per-view
    /// overrides (e.g. a preview pane that always renders dark).
    func applyAppTheme() -> some View { self }
}
