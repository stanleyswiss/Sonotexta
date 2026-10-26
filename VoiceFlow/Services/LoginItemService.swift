import Foundation
import Combine
import ServiceManagement

/// Wraps `SMAppService.mainApp` so the "Start at login" toggle reflects the
/// REAL login-item state, not a shadow UserDefaults flag. The user can flip
/// the same switch in System Settings → General → Login Items at any time,
/// so the system registry is the single source of truth — we re-read it on
/// every Settings open (`refresh()`) instead of persisting our own copy.
final class LoginItemService: ObservableObject {
    static let shared = LoginItemService()

    /// Mirrors `SMAppService.mainApp.status == .enabled` for SwiftUI binding.
    @Published private(set) var isEnabled: Bool
    /// `.requiresApproval` after register() means macOS wants the user to
    /// approve the item in System Settings before it takes effect.
    @Published private(set) var requiresApproval: Bool
    @Published private(set) var lastError: String?

    private init() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled
        requiresApproval = status == .requiresApproval
    }

    /// Re-read the system state (call on Settings appear — the user may have
    /// toggled the login item in System Settings while we weren't looking).
    func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled
        requiresApproval = status == .requiresApproval
    }

    func setEnabled(_ enable: Bool) {
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            // Typical failure: Operation not permitted while the app runs
            // from a translocated path (DMG) — surface it instead of a
            // silently snapped-back toggle.
            lastError = error.localizedDescription
            print("[Sonotexta][loginitem] \(enable ? "register" : "unregister") failed: \(error)")
        }
        refresh()
        print("[Sonotexta][loginitem] status after toggle: \(SMAppService.mainApp.status.rawValue)")
    }

    /// Deep-link to System Settings → General → Login Items for the
    /// requires-approval case.
    func openSystemLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
