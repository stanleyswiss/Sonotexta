import AppKit
import SwiftUI

/// Window controller that hosts the onboarding wizard as a centered,
/// non-resizable modal. Presented from `AppDelegate.applicationDidFinishLaunching`
/// when `AppSettings.shared.hasCompletedOnboarding == false` and the user
/// doesn't look like an existing 3.14.x upgrader (see `UpgradeDetector`).
final class OnboardingWindowController: NSWindowController {
    private let onDoneCallback: () -> Void

    init(onDone: @escaping () -> Void) {
        self.onDoneCallback = onDone
        let hostVC = NSHostingController(
            rootView: OnboardingContainerView(onDone: onDone)
        )
        let win = NSWindow(contentViewController: hostVC)
        win.title = "Set up Sonotexta"
        win.styleMask = [.titled, .closable]
        win.isReleasedWhenClosed = false
        win.center()
        super.init(window: win)
    }

    required init?(coder: NSCoder) {
        fatalError("OnboardingWindowController must be initialised with init(onDone:)")
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
    }
}
