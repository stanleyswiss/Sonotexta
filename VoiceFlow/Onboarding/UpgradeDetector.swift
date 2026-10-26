import Foundation

/// Heuristic for "does this look like an existing 3.14.x user upgrading,
/// or a brand-new install?". Used by `VoiceFlowApp` to decide whether
/// to show the 4-step onboarding wizard (fresh installs only).
///
/// We mark the user as existing if ANY of:
///   - selectedEngine differs from the default (.appleSpeech)
///   - more than one profile exists (defaults ship a single "Default")
///   - glossary or customPresets contain entries
///   - any keychain-stored API key is present
enum UpgradeDetector {
    static func looksLikeExistingUser() -> Bool {
        let s = AppSettings.shared
        if s.selectedEngine != .appleSpeech { return true }
        if s.profiles.count > 1 { return true }
        if !s.glossary.isEmpty { return true }
        if !s.customPresets.isEmpty { return true }
        let providersToCheck: [KeychainProvider] = [
            .openAISpeech, .deepgram, .elevenLabs,
            .openAIPostProcessing, .openRouter, .deepL
        ]
        for provider in providersToCheck {
            if provider.maskedDisplay() != nil { return true }
        }
        return false
    }
}
