import AppKit
import ApplicationServices

/// Result of an insertion attempt. Drives the honest status line and tells the
/// caller whether to surface a "paste manually" hint to the user.
enum InsertionResult {
    /// AX insertion or verified paste: text reached the target app.
    case delivered
    /// Text is on the clipboard but paste was not attempted or could not be trusted.
    /// User can recover via menu bar "Paste Last Dictation".
    case copiedToClipboard
    /// Could not even put the text anywhere (no Accessibility permission).
    case failed
}

final class AccessibilityService {
    static let shared = AccessibilityService()

    /// Tracks the last app the user was in before interacting with VoiceFlow
    private var lastTargetApp: NSRunningApplication?
    private var appObserver: NSObjectProtocol?

    var hasPermission: Bool {
        AXIsProcessTrusted()
    }

    init() {
        // Watch for app switches to always know which app to insert text into
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            // Remember every app EXCEPT VoiceFlow itself
            if app.bundleIdentifier != Bundle.main.bundleIdentifier {
                self?.lastTargetApp = app
            }
        }

        // Initialize with current frontmost app
        if let current = NSWorkspace.shared.frontmostApplication,
           current.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastTargetApp = current
        }
    }

    func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    /// Insertion path: clipboard paste (primary) with leave-in-clipboard fallback.
    ///
    /// We deliberately do NOT use direct Accessibility insertion as the primary path:
    /// `AXUIElementSetAttributeValue(_, kAXSelectedTextAttribute, _)` returns `.success`
    /// in many real-world apps (Terminal, iTerm, Electron-based apps including Claude
    /// Code, web text fields, custom AX implementations) while doing nothing visible.
    /// Trusting that return value caused 3.7's regression where transcriptions stayed
    /// on the clipboard and never appeared in the target. Paste-via-Cmd+V is the
    /// reliable path across the long tail of apps. AX may come back as a primary path
    /// once we have a verifiable read-back to confirm the insertion landed.
    /// Public read of the currently-tracked target app — for callers that want to
    /// SNAPSHOT the target at the start of a dictation session and pass it back
    /// at delivery time, immune to mid-session app activations (Slack toasts,
    /// notification banners, the user clicking a different window). The translate
    /// path's longer post-stop window made this race visible (3.11.0-beta.3).
    func snapshotCurrentTarget() -> NSRunningApplication? {
        lastTargetApp
    }

    /// Convenience overload — uses the live `lastTargetApp`. Kept for menu-bar
    /// recovery paths where following live focus is the desired behavior.
    func insertText(_ text: String) -> InsertionResult {
        insertText(text, targetApp: lastTargetApp)
    }

    /// Insertion path with an EXPLICIT target. Dictation sessions pass the
    /// target captured at startDictation() so a focus change between start and
    /// stop (translation can take 1–3s) can't redirect the paste to the wrong
    /// app. Activation is verified by polling frontmostApplication — if the
    /// system declines to yield activation we surface that honestly as
    /// `.copiedToClipboard` instead of pasting into Sonotexta or nowhere.
    func insertText(_ text: String, targetApp: NSRunningApplication?) -> InsertionResult {
        guard hasPermission else {
            print("[VoiceFlow] No accessibility permission")
            requestPermission()
            // Without AX permission we cannot post Cmd+V either, so leave the text on the
            // clipboard as a last-resort recovery surface.
            placeOnClipboardLeavingItThere(text)
            return .copiedToClipboard
        }

        // Activate the target app and VERIFY before pasting. macOS 14+'s
        // cooperative activation model means the deprecated bare `activate()`
        // can be honored by the WindowServer without bringing the user's
        // edited document window back to key — and our previous blind 300ms
        // sleep didn't notice. The translate path's longer wait window gave
        // Sonotexta's pill enough time to outrank the target for app focus,
        // and Cmd+V then landed nowhere visible (text stayed on clipboard).
        if let targetApp = targetApp {
            print("[VoiceFlow] Target app: \(targetApp.localizedName ?? "unknown") (\(targetApp.bundleIdentifier ?? "?"))")

            // Yield activation if available (macOS 14+) — tells the system
            // we're consenting to the target taking front, defeating the
            // anti-focus-stealing heuristic.
            if #available(macOS 14.0, *) {
                NSApp.yieldActivation(to: targetApp)
            }
            targetApp.activate(options: [.activateAllWindows])

            // Verify-poll: spin up to 600ms in 25ms slices waiting for the
            // target to actually be frontmost. If it never lands, leave the
            // text on the clipboard with an honest .copiedToClipboard result
            // rather than posting Cmd+V into the wrong app.
            let pollStart = Date()
            let pollDeadline: TimeInterval = 0.6
            var frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
            while frontmost != targetApp.processIdentifier,
                  Date().timeIntervalSince(pollStart) < pollDeadline {
                Thread.sleep(forTimeInterval: 0.025)
                frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
            }
            if frontmost != targetApp.processIdentifier {
                let elapsed = Date().timeIntervalSince(pollStart)
                print("[VoiceFlow] Target activation NOT verified after \(String(format: "%.3f", elapsed))s — leaving on clipboard")
                placeOnClipboardLeavingItThere(text)
                return .copiedToClipboard
            }
            let elapsed = Date().timeIntervalSince(pollStart)
            print("[VoiceFlow] Target activation verified in \(String(format: "%.3f", elapsed))s")
        }

        return insertTextViaClipboard(text)
    }

    private func insertTextViaAccessibility(_ text: String) -> Bool {
        // Use lastTargetApp, or frontmost if it's not VoiceFlow
        let app: NSRunningApplication
        if let target = lastTargetApp {
            app = target
        } else if let frontmost = NSWorkspace.shared.frontmostApplication,
                  frontmost.bundleIdentifier != Bundle.main.bundleIdentifier {
            app = frontmost
        } else {
            print("[VoiceFlow] No target app available for AX insertion")
            return false
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        var focusedElement: AnyObject?
        let focusResult = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)

        guard focusResult == .success, let element = focusedElement else {
            print("[VoiceFlow] No focused UI element in \(app.localizedName ?? "app") — falling back to paste")
            return false
        }

        let axElement = element as! AXUIElement

        // Try replacing selected text (inserts at cursor if no selection)
        let setResult = AXUIElementSetAttributeValue(axElement, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        if setResult == .success {
            print("[VoiceFlow] Inserted via AX into \(app.localizedName ?? "app")")
            return true
        }

        // Try setting value directly (append). Only do this for editable text-like roles to
        // avoid stomping on a read-only label that happens to expose kAXValueAttribute.
        var role: AnyObject?
        AXUIElementCopyAttributeValue(axElement, kAXRoleAttribute as CFString, &role)
        let roleString = role as? String ?? ""
        let editableRoles: Set<String> = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String,
        ]
        guard editableRoles.contains(roleString) else {
            return false
        }

        var currentValue: AnyObject?
        let valueResult = AXUIElementCopyAttributeValue(axElement, kAXValueAttribute as CFString, &currentValue)
        if valueResult == .success {
            let current = (currentValue as? String) ?? ""
            let result = AXUIElementSetAttributeValue(axElement, kAXValueAttribute as CFString, (current + text) as CFTypeRef)
            if result == .success {
                print("[VoiceFlow] Inserted via AX value append into \(app.localizedName ?? "app")")
                return true
            }
        }

        return false
    }

    private func insertTextViaClipboard(_ text: String) -> InsertionResult {
        let pasteboard = NSPasteboard.general
        let oldContents = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let postChangeCount = pasteboard.changeCount

        // Build Cmd+V. If event creation fails, the text is on the clipboard but we
        // never posted the keystroke — surface that as copiedToClipboard, not delivered.
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKeyCode: CGKeyCode = 9
        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        else {
            print("[VoiceFlow] Could not synthesize Cmd+V event — leaving text on clipboard for manual paste")
            // Don't restore old clipboard — that would erase the only recovery surface.
            return .copiedToClipboard
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        // 3.14.1-beta.3: log every Cmd+V we post. If the user reports text
        // appearing twice in the target app, this line will appear twice
        // per dictation in Console — definitively answering whether the
        // double-emission is on our side or in the target app's keystroke
        // handling.
        print("[VoiceFlow][paste] posting Cmd+V (text len=\(text.count))")
        keyDown.post(tap: .cgSessionEventTap)
        keyUp.post(tap: .cgSessionEventTap)

        // If user wants to keep transcription in clipboard, don't restore.
        if AppSettings.shared.keepInClipboard {
            #if DEBUG
            print("[VoiceFlow] Pasted into \(lastTargetApp?.localizedName ?? "frontmost app") (kept in clipboard)")
            #endif
            return .delivered
        }

        // Restore clipboard after a configurable delay — increase for VMs/remote desktop.
        // Guard the restore: only put the old contents back if our text is still on the
        // pasteboard. If the user (or the target app) wrote something else after we
        // posted Cmd+V, restoring would clobber that. The changeCount comparison is the
        // canonical way to detect outside writes since we set our value.
        let restoreDelay: TimeInterval = AppSettings.shared.clipboardRestoreDelay
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) {
            guard pasteboard.changeCount == postChangeCount else {
                #if DEBUG
                print("[VoiceFlow] Skipping clipboard restore — pasteboard changed since paste (changeCount \(postChangeCount) → \(pasteboard.changeCount))")
                #endif
                return
            }
            pasteboard.clearContents()
            if let oldContents {
                pasteboard.setString(oldContents, forType: .string)
            }
        }

        #if DEBUG
        print("[VoiceFlow] Inserted via clipboard paste into \(lastTargetApp?.localizedName ?? "frontmost app")")
        #endif
        return .delivered
    }

    /// Final-resort surface: ensure the text is on the clipboard so the user can paste manually.
    /// Used when we don't even have AX permission to post Cmd+V.
    private func placeOnClipboardLeavingItThere(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Attempt to paste the most recent transcription into whatever app currently has focus.
    /// Used by the menu bar "Paste Last Dictation" action.
    func pasteRecoveryText(_ text: String) -> InsertionResult {
        // Don't override lastTargetApp here — the user may have switched apps and wants the
        // current frontmost app to receive it.
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastTargetApp = frontmost
        }
        return insertText(text)
    }

    func frontmostAppBundleIdentifier() -> String? {
        lastTargetApp?.bundleIdentifier ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    deinit {
        if let observer = appObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }
}
