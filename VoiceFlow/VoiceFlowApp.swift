//
//  VoiceFlowApp.swift
//  VoiceFlow
//
//  Created by Stanislav Ivanov on 25.03.2026.
//

import SwiftUI
import AppKit
import AVFoundation
import Combine
import Sparkle

@main
struct VoiceFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // MenuBarExtra doesn't work on macOS 26 debug builds — using NSStatusItem instead.
        // Settings scene provides the standard Cmd+, settings window.
        Settings {
            SettingsView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    var dictationManager: DictationManager?
    /// Shared updater controller. Backed by `UpdaterService.shared` so the
    /// in-app Check-for-Updates button reaches the EXACT same instance as
    /// this menu-bar item — no NSApp.delegate cast involved.
    var updaterController: SPUStandardUpdaterController { UpdaterService.shared }
    private var lastDictationCancellable: AnyCancellable?

    /// Retained as long as the wizard window is on screen so it isn't released
    /// mid-flow. Cleared in the wizard's `onDone` callback.
    private var onboardingController: OnboardingWindowController?

    /// Retained while the WhatsNewSheet is presented as a sheet on the
    /// Settings window. Cleared on dismissal so the next major-version sheet
    /// (if any) can be presented cleanly.
    private var whatsNewWindow: NSWindow?

    /// Set after the deferred Sparkle launch check has fired for this process.
    /// Guards against double-firing if onboarding completes while the
    /// already-onboarded path also tried to schedule one. (Codex P2 finding
    /// 2026-05-20.)
    private var didRunLaunchUpdateCheck = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Unit tests inject into this app as TEST_HOST. Skip ALL startup side
        // effects in that case — most importantly the launch-time microphone
        // permission request: it would raise TCC prompts for the DerivedData
        // copy and, because it shares the installed app's bundle id, corrupt
        // the real app's permission grants (the 2026-08-01 incident).
        if NSClassFromString("XCTestCase") != nil {
            print("[Sonotexta] Test-host launch detected — skipping app startup")
            return
        }
        // 3.16.1-beta.2: line-buffer stdout so user-side `binary | tee` log
        // capture works without losing buffered prints on SIGINT. Swift's
        // print() defaults to full-buffer mode (~8 KB) when stdout is a pipe;
        // SwiftUI apps don't install a SIGINT handler, so Ctrl-C drops the
        // buffer and the tee'd log file ends up empty. setvbuf forces
        // line-buffering regardless of pipe-vs-TTY. Zero behavioral impact;
        // diagnostics-only improvement.
        setvbuf(stdout, nil, _IOLBF, 0)

        // 3.15: Apply the user-selected theme BEFORE any window opens so the
        // first frame the user sees already matches their saved choice. Safe
        // to call early — ThemeService.start() only touches NSApp.appearance
        // and installs a Combine subscription on AppSettings.
        ThemeService.shared.start()

        // 3.15: Onboarding gate. Fresh installs see the 4-step wizard before
        // dictation setup; existing 3.14.x users are auto-marked complete and
        // will see the WhatsNewSheet on their first Settings open instead.
        let appSettings = AppSettings.shared
        if !appSettings.hasCompletedOnboarding {
            if UpgradeDetector.looksLikeExistingUser() {
                // Existing user upgrading — skip wizard, but leave
                // lastSeenMajorVersion nil so WhatsNewSheet fires on first
                // Settings open.
                appSettings.hasCompletedOnboarding = true
            } else {
                // Fresh install — present the wizard. We dispatch async so
                // the rest of applicationDidFinishLaunching can finish first
                // (status item, mic permission request, dictation manager
                // setup all happen in parallel with the wizard being visible).
                DispatchQueue.main.async { [weak self] in
                    self?.presentOnboardingWindow()
                }
            }
        }

        // Open-source release: drop old licence/trial state and move users who
        // relied on the removed hosted proxy off cloud engines and AI cleanup
        // they have no key for. One-time, flag-guarded. Runs after the
        // onboarding gate (UpgradeDetector must still see their old engine
        // choice) and before the menu and DictationManager read the engine.
        OpenSourceMigration.runIfNeeded()

        // Show or hide dock icon based on user preference (default: show)
        NSApp.setActivationPolicy(AppSettings.shared.showInDock ? .regular : .accessory)

        // Use squareLenth to keep the icon compact and reduce chance of being hidden behind notch
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            if let img = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Sonotexta") {
                img.size = NSSize(width: 16, height: 16)
                img.isTemplate = true  // Adapts to light/dark menu bar automatically
                button.image = img
            } else {
                button.title = "V"
            }
        }

        setupMenu()
        // Populate the status/context lines immediately — before the
        // DictationManager exists the context line still shows the global
        // engine, so the menu is never blank.
        updateMenu()

        // Ensure Sparkle's automatic-checks flag is on for existing installs.
        // SUEnableAutomaticChecks = YES in Info.plist sets the default for new
        // installs, but users who launched before that key was added may have
        // no stored value, leaving automaticallyChecksForUpdates in an
        // indeterminate (effectively false) state. Forcing it true here ensures
        // the stored pref is set correctly regardless of install history.
        UserDefaults.standard.set(true, forKey: "SUEnableAutomaticChecks")
        // Clear last-check timestamp so the deferred launch check triggers
        // every launch rather than waiting for Sparkle's 4h interval.
        UserDefaults.standard.removeObject(forKey: "SULastCheckTime")

        // 3.15.x — defer the launch update check until after onboarding is
        // confirmed complete. Previously this fired synchronously inside
        // applicationDidFinishLaunching even when the first-run wizard was
        // about to appear, so a freshly-installed user could be hit with
        // Sparkle's "Update available" alert competing with the welcome
        // wizard. The deferred check also gives the menu bar / dictation
        // manager a moment to settle before Sparkle's user driver tries to
        // foreground the app for the alert. (Codex P2 finding 2026-05-20.)
        scheduleLaunchUpdateCheckIfReady()

        // Request mic permission immediately on launch
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            print("[VoiceFlow] Mic permission on launch: \(granted)")
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let dm = DictationManager()
            dm.onStateChanged = { [weak self] in
                self?.updateMenu()
            }
            self.dictationManager = dm
            dm.setup()
        }

        // Refresh menu when last-dictation availability changes (e.g. first successful
        // transcription after launch enables Paste Last Dictation).
        lastDictationCancellable = LastDictationStore.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateMenu()
            }
    }

    private func setupMenu() {
        let menu = NSMenu()
        // Manage enabled state explicitly so isEnabled on recovery items sticks
        // (default autoenable would re-enable them based on target validation).
        menu.autoenablesItems = false

        let statusMenuItem = NSMenuItem(title: "Ready", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        // Context line — shows WHAT will run right now: the active profile,
        // its output language, and the engine that profile resolves to
        // (override or global default). Answers "what applies?" at a glance
        // without opening Settings.
        let contextMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        contextMenuItem.isEnabled = false
        contextMenuItem.tag = MenuTag.contextLine.rawValue
        menu.addItem(contextMenuItem)

        menu.addItem(NSMenuItem.separator())

        let toggleItem = NSMenuItem(
            title: "Start Dictation",
            action: #selector(toggleDictation),
            keyEquivalent: "d"
        )
        toggleItem.keyEquivalentModifierMask = [.control, .shift]
        toggleItem.target = self
        toggleItem.tag = MenuTag.toggleDictation.rawValue
        menu.addItem(toggleItem)

        // Recovery actions — let the user reach the last transcription when paste failed
        // silently or got swallowed by Secure Input / a stolen-focus moment.
        menu.addItem(NSMenuItem.separator())

        let pasteLastItem = NSMenuItem(
            title: "Paste Last Dictation",
            action: #selector(pasteLastDictation),
            keyEquivalent: "v"
        )
        pasteLastItem.keyEquivalentModifierMask = [.control, .shift]
        pasteLastItem.target = self
        pasteLastItem.tag = MenuTag.pasteLast.rawValue
        menu.addItem(pasteLastItem)

        let copyLastItem = NSMenuItem(
            title: "Copy Last Dictation",
            action: #selector(copyLastDictation),
            keyEquivalent: "c"
        )
        copyLastItem.keyEquivalentModifierMask = [.control, .shift]
        copyLastItem.target = self
        copyLastItem.tag = MenuTag.copyLast.rawValue
        menu.addItem(copyLastItem)

        let showLastItem = NSMenuItem(
            title: "Show Last Dictation…",
            action: #selector(showLastDictation),
            keyEquivalent: ""
        )
        showLastItem.target = self
        showLastItem.tag = MenuTag.showLast.rawValue
        menu.addItem(showLastItem)

        menu.addItem(NSMenuItem.separator())

        let updateItem = NSMenuItem(
            title: "Check for Updates...",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        updateItem.target = updaterController
        menu.addItem(updateItem)

        let settingsItem = NSMenuItem(
            title: "Settings...",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.keyEquivalentModifierMask = .command
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: "Quit Sonotexta",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    /// Called when the user clicks the dock icon while app is running — open Settings
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }

    @objc private func toggleDictation() {
        dictationManager?.toggleDictation()
        updateMenu()
    }

    @objc private func pasteLastDictation() {
        guard let text = LastDictationStore.shared.lastTranscribed, !text.isEmpty else { return }
        let result = AccessibilityService.shared.pasteRecoveryText(text)
        switch result {
        case .delivered:
            LastDictationStore.shared.recordDelivery(.delivered)
        case .copiedToClipboard:
            LastDictationStore.shared.recordDelivery(.copiedToClipboard)
        case .failed:
            LastDictationStore.shared.recordDelivery(.failed)
        }
    }

    @objc private func copyLastDictation() {
        LastDictationStore.shared.copyToClipboard()
    }

    @objc private func showLastDictation() {
        guard let text = LastDictationStore.shared.lastTranscribed, !text.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Last Dictation"
        alert.informativeText = text
        alert.addButton(withTitle: "Copy to Clipboard")
        alert.addButton(withTitle: "Close")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            LastDictationStore.shared.copyToClipboard()
        }
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let settingsView = SettingsView()
            let hostingController = NSHostingController(rootView: settingsView)
            let window = NSWindow(contentViewController: hostingController)
            window.title = "Sonotexta Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 750, height: 520))
            window.minSize = NSSize(width: 700, height: 500)
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Show the What's-new sheet once per major.minor for upgraders.
        // Fresh installs ran the onboarding wizard, which stamps
        // lastSeenMajorVersion in complete(), so this branch is skipped for
        // them. The marker is derived from the bundle version — a hardcoded
        // "3.15.0" here previously kept 3.16+ upgraders from ever seeing a
        // What's-new sheet again.
        let s = AppSettings.shared
        if s.lastSeenMajorVersion != WhatsNewSheet.versionMarker, whatsNewWindow == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, let settingsWindow = self.settingsWindow else { return }
                let sheetVC = NSHostingController(
                    rootView: WhatsNewSheet { [weak self] in
                        guard let self else { return }
                        AppSettings.shared.lastSeenMajorVersion = WhatsNewSheet.versionMarker
                        if let sheet = self.whatsNewWindow {
                            settingsWindow.endSheet(sheet)
                        }
                        self.whatsNewWindow = nil
                    }
                )
                let sheetWin = NSWindow(contentViewController: sheetVC)
                sheetWin.styleMask = [.titled]
                sheetWin.title = ""
                self.whatsNewWindow = sheetWin
                settingsWindow.beginSheet(sheetWin)
            }
        }
    }

    /// Construct and present the first-run onboarding wizard. When the user
    /// finishes (or skips) the wizard, close it and open Settings so the next
    /// step (configuring profiles, glossary, etc.) is one click away.
    private func presentOnboardingWindow() {
        let controller = OnboardingWindowController { [weak self] in
            self?.onboardingController?.close()
            self?.onboardingController = nil
            self?.openSettings()
            // Wizard is gone — safe to ask Sparkle to check for updates now,
            // assuming nobody else (the already-onboarded launch path) beat us
            // to it. The helper is idempotent.
            self?.scheduleLaunchUpdateCheckIfReady()
        }
        onboardingController = controller
        controller.present()
    }

    /// Schedule a single launch-time Sparkle check, gated on onboarding being
    /// complete. Idempotent across the two entry points (already-onboarded
    /// path in `applicationDidFinishLaunching`, and fresh-install path from
    /// the wizard's onDone callback). The 1.5s delay lets the menu bar and
    /// (in the fresh-install case) the post-wizard Settings window settle
    /// before Sparkle's user driver tries to foreground the app for an alert.
    ///
    /// Uses `checkForUpdatesInBackground()` — this is THE call that
    /// presents Sparkle's "Update Available" alert via the standard user
    /// driver when an update exists, while staying silent when up to date.
    ///
    /// DO NOT swap this for `checkForUpdateInformation()` (a previous
    /// 2026-05-20 "fix" did exactly that and silently broke launch-time
    /// notifications for 5 releases). Sparkle's own header for
    /// `checkForUpdateInformation` says verbatim: "Begins a 'probing'
    /// check for updates which will NOT actually offer to update" — the
    /// only outputs are delegate callbacks. No alert, ever. We don't
    /// implement those callbacks, so probing produces literally nothing.
    ///
    /// `automaticallyDownloadsUpdates` is OFF by default (we never set
    /// it), so background-found updates are NOT silently downloaded
    /// before the prompt. The prompt fires when the feed contains a
    /// newer eligible item. `SULastCheckTime` is cleared in
    /// `applicationDidFinishLaunching` right before this runs so the
    /// scheduler throttle gate is open.
    ///
    /// `ForegroundingUserDriverDelegate` brings the alert to the front
    /// at presentation time so menubar-only users actually see it.
    private func scheduleLaunchUpdateCheckIfReady() {
        guard !didRunLaunchUpdateCheck else { return }
        guard AppSettings.shared.hasCompletedOnboarding else {
            // Wizard still active. Will be retried from `OnboardingWindowController.onDone`.
            return
        }
        didRunLaunchUpdateCheck = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            UpdaterService.updater.checkForUpdatesInBackground()
        }
    }

    func updateMenu() {
        guard let menu = statusItem.menu else { return }

        if let item = menu.items.first {
            item.title = dictationManager?.statusText ?? "Ready"
        }

        if let contextItem = menu.item(withTag: MenuTag.contextLine.rawValue) {
            let profile = dictationManager?.profileMatcher.activeProfile
            // Resolved engine = profile override if set, else the global default.
            let engine = profile?.engineOverride ?? AppSettings.shared.selectedEngine
            // Strip the parenthetical from display names like
            // "Whisper (local, offline)" so the menu line stays compact.
            let engineName = engine.displayName.components(separatedBy: " (").first ?? engine.displayName
            // 3.16.6: keep the last AI failure visible until the next
            // successful cleanup — silent AI failures burned us twice.
            let aiWarning = dictationManager?.lastAIFailure != nil ? "  ·  ⚠️ AI cleanup failing" : ""
            if let profile {
                contextItem.title = "Profile: \(profile.name) → \(profile.outputLanguageCode.uppercased())  ·  Engine: \(engineName)\(aiWarning)"
            } else {
                contextItem.title = "Engine: \(engineName)\(aiWarning)"
            }
        }

        menu.item(withTag: MenuTag.toggleDictation.rawValue)?.title =
            (dictationManager?.isDictating ?? false) ? "Stop Dictation" : "Start Dictation"

        // Enable/disable recovery actions based on whether we have a last transcription.
        let hasRecoverable = LastDictationStore.shared.hasRecoverableText
        for tag in [MenuTag.pasteLast, MenuTag.copyLast, MenuTag.showLast] {
            menu.item(withTag: tag.rawValue)?.isEnabled = hasRecoverable
        }

        if let button = statusItem.button {
            let imageName = (dictationManager?.isDictating ?? false) ? "waveform.badge.mic" : "waveform"
            if let img = NSImage(systemSymbolName: imageName, accessibilityDescription: "Sonotexta") {
                img.size = NSSize(width: 16, height: 16)
                img.isTemplate = true
                button.image = img
            }
        }
    }
}

private enum MenuTag: Int {
    case pasteLast = 1001
    case copyLast = 1002
    case showLast = 1003
    case contextLine = 1004
    case toggleDictation = 1005
}
