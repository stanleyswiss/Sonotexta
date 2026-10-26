import Foundation
import Combine
import AppKit

/// Durable store of the most recent transcription. Survives app relaunch via UserDefaults.
/// Two slots: `lastTranscribed` (any successful transcription, even if delivery failed)
/// and `lastDeliveredStatus` (how the most recent delivery actually went).
/// Menu bar recovery actions read from here so users can re-paste or copy when paste silently fails.
///
/// **Privacy controls (Codex P2 finding 2026-05-20):**
/// 1. Stored text older than `retentionWindow` (24h) is evicted on init — bounds
///    how long a single dictation can sit on disk in plaintext.
/// 2. `AppSettings.retainLastDictationOnDisk` (default true) gates whether
///    `recordTranscription` writes to UserDefaults at all. When false, the
///    store keeps the last transcription in memory for the current session
///    only, and a previously-persisted entry is wiped immediately on toggle.
final class LastDictationStore: ObservableObject {
    static let shared = LastDictationStore()

    @Published private(set) var lastTranscribed: String?
    @Published private(set) var lastTranscribedAt: Date?
    @Published private(set) var lastDeliveryStatus: DeliveryStatus = .none

    private static let textKey = "lastDictation.text"
    private static let dateKey = "lastDictation.date"
    private static let statusKey = "lastDictation.status"

    /// Maximum age of an on-disk entry. Older entries are dropped on init.
    /// Not user-tunable in this iteration — 24h covers the legitimate "I quit
    /// Sonotexta yesterday and want to recover the text I dictated this
    /// morning" case without keeping plaintext around indefinitely.
    private static let retentionWindow: TimeInterval = 24 * 60 * 60

    private init() {
        let defaults = UserDefaults.standard
        let storedText = defaults.string(forKey: Self.textKey)
        let storedTimestamp = defaults.object(forKey: Self.dateKey) as? Double

        // TTL eviction: any stored text whose timestamp is older than the
        // retention window is purged from disk on launch. Done before we
        // hydrate the published properties so the menu-bar items reflect the
        // post-purge state from the first frame.
        if let timestamp = storedTimestamp, timestamp > 0 {
            let age = Date().timeIntervalSince1970 - timestamp
            if age > Self.retentionWindow {
                defaults.removeObject(forKey: Self.textKey)
                defaults.removeObject(forKey: Self.dateKey)
                defaults.removeObject(forKey: Self.statusKey)
                self.lastTranscribed = nil
                self.lastTranscribedAt = nil
                self.lastDeliveryStatus = .none
                return
            }
        }

        self.lastTranscribed = storedText
        if let timestamp = storedTimestamp, timestamp > 0 {
            self.lastTranscribedAt = Date(timeIntervalSince1970: timestamp)
        }
        if let raw = defaults.string(forKey: Self.statusKey),
           let status = DeliveryStatus(rawValue: raw) {
            self.lastDeliveryStatus = status
        }
    }

    /// Record a successful transcription. Call BEFORE attempting delivery so the text is durable
    /// even if paste fails. Status is set to `.transcribed` until delivery updates it.
    /// When `AppSettings.retainLastDictationOnDisk == false`, the text is kept in memory only —
    /// the menu-bar recovery actions still work for the current session, but nothing is written
    /// to UserDefaults.
    func recordTranscription(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let allowDiskWrite = AppSettings.shared.retainLastDictationOnDisk

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lastTranscribed = trimmed
            self.lastTranscribedAt = Date()
            self.lastDeliveryStatus = .transcribed
            if allowDiskWrite {
                UserDefaults.standard.set(trimmed, forKey: Self.textKey)
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.dateKey)
                UserDefaults.standard.set(DeliveryStatus.transcribed.rawValue, forKey: Self.statusKey)
            } else {
                // Belt-and-suspenders: even if the toggle was flipped between
                // launches with leftover entries on disk, the init() eviction
                // OR a `purgePersistedText` call has already cleared them. This
                // branch just ensures we never write fresh plaintext when the
                // user has opted out.
            }
        }
    }

    /// Update delivery status after attempting insertion. Honors the same
    /// retention setting as `recordTranscription`.
    func recordDelivery(_ status: DeliveryStatus) {
        let allowDiskWrite = AppSettings.shared.retainLastDictationOnDisk
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lastDeliveryStatus = status
            if allowDiskWrite {
                UserDefaults.standard.set(status.rawValue, forKey: Self.statusKey)
            }
        }
    }

    /// Wipe any persisted last-dictation entry from disk and clear in-memory
    /// state. Called by the settings toggle when the user opts out, and also
    /// safe to call directly from a "Clear last dictation" button.
    func purgePersistedText() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            UserDefaults.standard.removeObject(forKey: Self.textKey)
            UserDefaults.standard.removeObject(forKey: Self.dateKey)
            UserDefaults.standard.removeObject(forKey: Self.statusKey)
            UserDefaults.standard.synchronize()
            self.lastTranscribed = nil
            self.lastTranscribedAt = nil
            self.lastDeliveryStatus = .none
        }
    }

    /// Whether menu bar recovery actions should be enabled.
    var hasRecoverableText: Bool {
        guard let text = lastTranscribed else { return false }
        return !text.isEmpty
    }

    /// Copy the last transcription to the clipboard. Returns true if there was text to copy.
    @discardableResult
    func copyToClipboard() -> Bool {
        guard let text = lastTranscribed, !text.isEmpty else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return true
    }
}

/// Honest delivery status. "Delivered" means we have positive evidence the text reached the
/// target app (AX insertion or verified paste). Anything else stays in "copied" or "failed"
/// so the user knows to recover manually.
enum DeliveryStatus: String, Codable {
    case none
    case transcribed       // captured but not yet delivered
    case delivered         // AX insertion or paste posted into target
    case copiedToClipboard // text on pasteboard, paste not attempted or not confirmable
    case failed            // could not deliver and clipboard restore would lose it

    var displayText: String {
        switch self {
        case .none:               return "Ready"
        case .transcribed:        return "Transcribed"
        case .delivered:          return "Delivered"
        case .copiedToClipboard:  return "Copied — paste manually"
        case .failed:             return "Could not deliver — check Accessibility permission"
        }
    }
}
