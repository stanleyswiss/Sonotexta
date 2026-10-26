import SwiftUI

/// Privacy controls. First lever: whether the most-recent transcription is
/// retained on disk between launches so the menu-bar recovery actions
/// ("Paste Last Dictation", "Copy Last Dictation", "Show Last Dictation…")
/// stay populated. Default ON; users handling sensitive content (passwords,
/// medical notes, call transcripts) can switch it off and have any existing
/// stored text wiped immediately. The 24h TTL on `LastDictationStore` still
/// applies independently — entries older than a day are evicted on every
/// launch even with retention ON. (Codex P2 finding 2026-05-20.)
struct PrivacySettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var lastDictation = LastDictationStore.shared

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Privacy")
                        .font(.headline)
                    Spacer()
                }

                Toggle(isOn: $settings.retainLastDictationOnDisk) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep last dictation between launches")
                            .font(.body)
                        Text("Lets the menu bar restore your most recent transcription after a relaunch. Entries older than 24 hours are always cleared automatically. Turn off if you dictate sensitive content.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)

                if lastDictation.hasRecoverableText {
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Stored dictation present")
                                .font(.subheadline)
                            if let at = lastDictation.lastTranscribedAt {
                                Text("Captured \(at.formatted(.relative(presentation: .named)))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Clear now", role: .destructive) {
                            lastDictation.purgePersistedText()
                        }
                    }
                }
            }
        }
    }
}
