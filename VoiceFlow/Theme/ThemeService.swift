import AppKit
import Combine

/// Bridges the `AppSettings.appearance` property to `NSApp.appearance`.
///
/// Lifecycle:
///   1. Call `ThemeService.shared.start()` once during
///      `applicationDidFinishLaunching` BEFORE any window opens. This applies
///      the user's saved appearance and subscribes to future changes.
///   2. Any subsequent write to `AppSettings.shared.appearance` propagates
///      to `NSApp.appearance` on the next runloop tick via the Combine
///      subscription below.
///
/// `start()` is idempotent — calling it twice replaces the previous subscription.
final class ThemeService {
    static let shared = ThemeService()

    private var cancellable: AnyCancellable?
    private var hasStarted = false

    private init() {}

    /// Applies the current `AppSettings.shared.appearance` and starts observing
    /// future writes. Must be called on the main actor (it touches `NSApp`).
    func start() {
        // Idempotent: drop the old subscription before installing the new one.
        cancellable?.cancel()
        apply(AppSettings.shared.appearance)
        cancellable = AppSettings.shared.$appearance
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] mode in
                self?.apply(mode)
            }
        hasStarted = true
    }

    private func apply(_ mode: AppearanceMode) {
        // `nil` → macOS chooses (System). `.aqua` / `.darkAqua` → pinned.
        NSApp.appearance = mode.nsAppearance
    }
}
