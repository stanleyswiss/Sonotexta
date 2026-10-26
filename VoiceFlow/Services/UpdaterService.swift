import Foundation
import Sparkle
import AppKit
import Combine

/// Single shared `SPUStandardUpdaterController` for the entire app.
///
/// Why a singleton: previous in-app Check-for-Updates fixes (3.8.2 + 3.8.3) failed
/// because the SwiftUI Settings view reached the controller via `NSApp.delegate as? AppDelegate`,
/// which can fail silently across module/preview/lifecycle boundaries. With this
/// singleton, both the menu bar's NSMenuItem AND the Settings view use the exact
/// same instance via `UpdaterService.shared.controller` — no cast involved.
///
/// The controller is initialized once at first access. `startingUpdater: true`
/// kicks off the background scheduled-check loop immediately.
enum UpdaterService {
    /// Delegate is needed to gate which Sparkle channels the user sees.
    /// `[]` = stable only (no `<sparkle:channel>` tag in appcast item).
    /// `["beta"]` = stable + items tagged `<sparkle:channel>beta</sparkle:channel>`.
    /// Driven by `AppSettings.shared.receiveBetaUpdates`.
    private static let delegate = ChannelGatingDelegate()
    /// User-driver delegate that brings the update prompt to the foreground.
    /// Sparkle's "Update Available" alert otherwise opens BEHIND whatever app
    /// is frontmost when the network check completes — easy to miss for
    /// menubar apps where Sonotexta isn't visibly active. The activation
    /// must happen at presentation time, not just at click time, because
    /// the network check is async.
    private static let userDriverDelegate = ForegroundingUserDriverDelegate()

    static let shared: SPUStandardUpdaterController = {
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: delegate,
            userDriverDelegate: userDriverDelegate
        )

        // 3.16.1-beta.4: lock the auto-install path OFF and require user
        // confirmation for every install. Sparkle's default behavior was
        // letting some installs land silently on relaunch — typically because
        // a prior alert's "Automatically download future updates" checkbox
        // had been ticked once and the value persisted in NSUserDefaults.
        // We do two things here, both required:
        //   1. Force the runtime value to false so no historical user-default
        //      can silently re-enable auto-install on a new build.
        //   2. (Paired with Info.plist `SUAllowsAutomaticUpdates = false`)
        //      Sparkle's alert no longer displays the checkbox, so the
        //      setting can never be re-enabled without a code change.
        // Net behavior: auto-CHECKS still happen on the scheduled interval
        // (SUScheduledCheckInterval = 4h); when an update is found, the user
        // sees the standard "Update Available" alert and must explicitly
        // click "Install Update." No silent installs on relaunch.
        controller.updater.automaticallyChecksForUpdates = true
        controller.updater.automaticallyDownloadsUpdates = false

        return controller
    }()

    static var updater: SPUUpdater { shared.updater }

    /// Called whenever the user toggles the beta-updates preference. Tells
    /// Sparkle to re-evaluate which appcast items it considers eligible.
    /// Triggers an immediate background check so the toggle feels responsive.
    static func applyChannels() {
        // The delegate reads the current preference at decision time, so no
        // explicit channel list needs to be pushed. Just nudge Sparkle.
        updater.checkForUpdatesInBackground()
    }
}

/// Sparkle delegate that tells the updater which channels are allowed.
/// Reads `AppSettings.shared.receiveBetaUpdates` on each call so the
/// preference is honored even after Sparkle was constructed.
private final class ChannelGatingDelegate: NSObject, SPUUpdaterDelegate {
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        AppSettings.shared.receiveBetaUpdates ? ["beta"] : []
    }
}

/// User-driver delegate that ensures Sparkle's update window arrives in the
/// foreground. The fix has two parts:
///   1. `standardUserDriverWillHandleShowingUpdate` — fires right before the
///      "Update Available" alert is shown. Force activation policy `.regular`
///      (in case the user has Sonotexta hidden from the dock via showInDock=false)
///      then `NSApp.activate(ignoringOtherApps: true)` to bring the app + alert
///      to the front.
///   2. `standardUserDriverWillFinishUpdateSession` — restore the original
///      activation policy when the update interaction ends, so a hidden-from-dock
///      user doesn't permanently get a dock icon.
private final class ForegroundingUserDriverDelegate: NSObject, SPUStandardUserDriverDelegate {
    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        DispatchQueue.main.async {
            // Always go .regular for the duration of the update prompt — accessory
            // apps cannot reliably bring an alert to the front of other apps.
            if NSApp.activationPolicy() != .regular {
                NSApp.setActivationPolicy(.regular)
            }
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func standardUserDriverWillFinishUpdateSession() {
        DispatchQueue.main.async {
            // Restore the canonical preference. AppSettings.showInDock owns the
            // .regular vs .accessory choice; honor it on the way out.
            let desired: NSApplication.ActivationPolicy = AppSettings.shared.showInDock ? .regular : .accessory
            if NSApp.activationPolicy() != desired {
                NSApp.setActivationPolicy(desired)
            }
        }
    }
}

/// View model for the in-app Check-for-Updates button.
///
/// Observes `SPUUpdater.canCheckForUpdates` so the button can correctly disable
/// itself when an update check is already in progress (silent no-ops were one
/// of the suspects in the long-running "button does nothing" debugging).
/// Also captures the most recent attempt + result so we can surface diagnostic
/// info on screen — if the click doesn't visibly produce a Sparkle alert, the
/// status line tells us where it stopped instead of leaving the user staring
/// at nothing.
@MainActor
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates: Bool = true
    @Published var lastStatus: String?

    private var cancellables = Set<AnyCancellable>()
    private let updater: SPUUpdater

    init(updater: SPUUpdater = UpdaterService.updater) {
        self.updater = updater
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)
    }

    /// Trigger a Sparkle update check.
    ///
    /// Two non-obvious requirements for this to actually show UI in a menubar
    /// app where the Settings window lives in a non-main `NSWindow`:
    ///
    /// 1. Reach `updater.checkForUpdates()` directly — NOT the IBAction
    ///    wrapper `SPUStandardUpdaterController.checkForUpdates(_:)`, which
    ///    expects a non-nil sender for menu-item dispatch and is silent
    ///    when called programmatically with nil.
    ///
    /// 2. `NSApp.activate(ignoringOtherApps: true)` first. Without it,
    ///    Sparkle's "you're up to date" / "update available" alert can
    ///    appear at a window level behind the Settings window — the user
    ///    sees nothing happen even though Sparkle ran.
    func checkForUpdates() {
        NSLog("[Sonotexta] CheckForUpdatesViewModel.checkForUpdates: canCheck=%@, lastCheck=%@",
              canCheckForUpdates ? "true" : "false",
              String(describing: updater.lastUpdateCheckDate))

        guard canCheckForUpdates else {
            lastStatus = "Already checking — please wait"
            return
        }

        lastStatus = "Checking…"
        NSApp.activate(ignoringOtherApps: true)
        updater.checkForUpdates()

        // Sparkle owns the UI from here. Clear the "Checking…" status after a
        // short delay; if Sparkle showed an alert, the user has seen it; if
        // it was silent, the cleared status still tells them the click fired.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.lastStatus == "Checking…" {
                self?.lastStatus = "Check complete (see Sparkle window if an update was offered)"
            }
        }
    }
}
