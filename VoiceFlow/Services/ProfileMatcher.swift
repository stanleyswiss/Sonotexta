import AppKit
import ApplicationServices
import Combine

final class ProfileMatcher: ObservableObject {
    @Published var activeProfile: Profile?

    private var settings: AppSettings
    private var workspaceObserver: NSObjectProtocol?

    init(settings: AppSettings) {
        self.settings = settings
        startObserving()
        updateActiveProfile()
    }

    private func startObserving() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.updateActiveProfile()
        }
    }

    private func updateActiveProfile() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleId = app.bundleIdentifier else {
            activeProfile = settings.profiles.first(where: { $0.isDefault })
            return
        }

        // Get window title once (expensive AX call) — fetched lazily because
        // app-wide rules don't need it.
        var windowTitle: String?
        var windowTitleFetched = false

        func getWindowTitle() -> String {
            if !windowTitleFetched {
                windowTitle = frontmostWindowTitle(for: app)
                windowTitleFetched = true
                print("[Sonotexta] Window title for \(bundleId): \"\(windowTitle ?? "<none>")\"")
            }
            return windowTitle ?? ""
        }

        // Specificity-based matching: contact-specific rules ALWAYS beat app-wide
        // rules, regardless of profile order in settings.profiles. Without this,
        // a "Teams → German" catchall added before "Filip in Teams → English"
        // would shadow the more specific rule and Filip would get German.
        //
        // Pass 1: contact-specific match (rule.appBundleIdentifier == bundleId
        //         AND non-empty contactFilter that matches the window title).
        // Pass 2: app-wide match (rule.appBundleIdentifier == bundleId AND
        //         empty contactFilter).
        // Pass 3: default profile.
        //
        // Within a pass, list order is the tiebreaker (so the user can still
        // resolve two-contact-specific-rules-match-same-window conflicts by
        // reordering, but they don't have to reorder for the common case).

        // Pass 1 — contact-specific
        for profile in settings.profiles where !profile.isDefault {
            for rule in profile.detectionRules {
                guard rule.appBundleIdentifier == bundleId,
                      !rule.contactFilter.isEmpty else { continue }
                let title = getWindowTitle()
                if title.localizedCaseInsensitiveContains(rule.contactFilter) {
                    print("[Sonotexta] Matched (contact-specific): \"\(rule.contactFilter)\" in \(rule.appBundleIdentifier) → profile \"\(profile.name)\"")
                    activeProfile = profile
                    return
                }
            }
        }

        // Pass 2 — app-wide
        for profile in settings.profiles where !profile.isDefault {
            for rule in profile.detectionRules {
                guard rule.appBundleIdentifier == bundleId,
                      rule.contactFilter.isEmpty else { continue }
                print("[Sonotexta] Matched (app-wide): any contact in \(rule.appBundleIdentifier) → profile \"\(profile.name)\"")
                activeProfile = profile
                return
            }
        }

        // Pass 3 — default
        activeProfile = settings.profiles.first(where: { $0.isDefault })
    }

    /// Read the frontmost window's title via Accessibility API
    private func frontmostWindowTitle(for app: NSRunningApplication) -> String? {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var focusedWindow: AnyObject?
        let result = AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedWindow)
        guard result == .success else { return nil }

        var title: AnyObject?
        let titleResult = AXUIElementCopyAttributeValue(focusedWindow as! AXUIElement, kAXTitleAttribute as CFString, &title)
        guard titleResult == .success, let windowTitle = title as? String else { return nil }
        return windowTitle
    }

    /// Force re-evaluate the active profile (call at dictation start to catch conversation switches)
    func refresh() {
        updateActiveProfile()
    }

    deinit {
        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }
}
