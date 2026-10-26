import SwiftUI
import Sparkle

struct UpdatesView: View {
    @StateObject private var viewModel = CheckForUpdatesViewModel()
    @ObservedObject private var settings = AppSettings.shared
    @State private var lastCheckedText: String = Self.formatLastChecked()

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    private var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Text("Updates")
                        .font(.title)
                        .fontWeight(.bold)
                    Text("Check for new versions and see what's changed.")
                        .foregroundStyle(.secondary)
                }

                // Current version + check button
                SettingsCard {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Sonotexta v\(appVersion)")
                                    .font(.title3)
                                    .fontWeight(.semibold)
                                Text("Build \(buildNumber)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Button {
                                viewModel.checkForUpdates()
                            } label: {
                                Text("Check for Updates")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!viewModel.canCheckForUpdates)
                        }

                        // Last-checked timestamp — lets the user confirm auto-checks
                        // are actually firing without needing to see a dialog.
                        HStack(spacing: 4) {
                            Image(systemName: "clock")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text(lastCheckedText)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.top, 2)
                        .onAppear { lastCheckedText = Self.formatLastChecked() }

                        if let status = viewModel.lastStatus {
                            Text(status)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, 4)
                        }
                    }
                }

                // Update channel — opt-in beta access
                SettingsCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: $settings.receiveBetaUpdates) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Receive beta updates")
                                    .font(.system(size: 13, weight: .medium))
                                Text("Early-access releases (3.x.y-beta.N) ship to this channel first. Stable users see only fully-tested releases. You can switch off anytime — the next stable release will pick you back up.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .toggleStyle(.switch)
                    }
                }

                // Release History — kept in sync with the website + appcast
                VStack(alignment: .leading, spacing: 12) {
                    Text("Release History")
                        .font(.headline)

                    ForEach(Array(Self.releaseHistory.enumerated()), id: \.element.version) { index, release in
                        ReleaseCard(
                            version: release.version,
                            date: release.date,
                            isLatest: index == 0,
                            changes: release.changes
                        )
                    }
                }
            }
            .padding(24)
        }
    }

    private static func formatLastChecked() -> String {
        guard let date = UpdaterService.updater.lastUpdateCheckDate else {
            return "Last checked: never (will check on next launch)"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Last checked: \(formatter.localizedString(for: date, relativeTo: Date()))"
    }

    /// Single source of truth for the in-app release history. Keep in sync
    /// with `voiceflow-updates/appcast.xml`. The website is a separate repository.
    /// Trim to the most recent ~8 releases — older entries live on the website.
    private static let releaseHistory: [Release] = [
        Release(version: "3.16.6", date: "Sep 21, 2026", changes: [
            "FaceTime dictation now works alongside calls on the built-in Mac microphone. Sonotexta handles the three-channel call route explicitly and selects a real microphone channel before converting to mono.",
            "Experimental local Qwen3-ASR is available for 30 languages and runs offline after download. Review longer transcripts carefully: this CoreML conversion can add words near chunk boundaries, and Bulgarian is not supported.",
            "Choose a custom storage folder for local model weights, including an external drive. Model moves run in the background with progress and preserve the originals if verification fails.",
            "More reliable capture and delivery: first words are retained while models load, stop/finalization races are serialized, microphone rates such as 44.1 kHz convert correctly, and AI or model-storage failures are shown instead of failing silently.",
        ]),
        Release(version: "3.16.6-beta.4", date: "Sep 20, 2026", changes: [
            "FaceTime microphone fix candidate: Sonotexta now supports the built-in Mac microphone's three-channel call format and selects the strongest real input channel before converting to mono, avoiding speech cancellation during calls.",
            "Multichannel microphone routes now log per-channel signal levels. If a call supplies only digital silence, Sonotexta shows an actionable microphone error instead of the generic “No speech detected” message.",
            "Please validate FaceTime both unmuted and muted, plus normal dictation outside calls. This remains a beta candidate until that live hardware test passes.",
        ]),
        Release(version: "3.16.6-beta.3", date: "Sep 19, 2026", changes: [
            "Experimental local Qwen3-ASR: download and manage the model in Dictation settings, then select it globally or in a profile. Speech is transcribed after you stop recording, with support for 30 languages.",
            "Qwen is an experimental CoreML conversion and can insert extra words, especially around chunk boundaries in longer dictations. Please review its output carefully; Bulgarian is not supported.",
            "Default microphone capture now uses an input-only audio setup to improve compatibility during calls. This is a FaceTime test candidate; live FaceTime and microphone hardware validation are still needed.",
        ]),
        Release(version: "3.16.6-beta.2", date: "Sep 6, 2026", changes: [
            "Model moves now run in the background with progress. Copies are verified before switching locations, and failed moves keep the original models. Use Default explains how to recover when an external drive is disconnected.",
            "Fixed cold-start and stop timing: captured speech is retained while models load, concurrent loads are shared, and automatic/manual completion cannot deliver the same dictation twice.",
            "Corrected local audio conversion for microphone sample rates such as 44.1 kHz. The profile selected at dictation start stays fixed even if you switch apps.",
            "AI cleanup now warns when credentials are missing and preserves the raw text for recovery. Local model loads validate the selected storage folder and volume before downloading.",
            "C920 microphone test candidate: input-only device setup and native audio-format negotiation, with clearer diagnostics. Please test the per-app override; hardware validation is still needed.",
        ]),
        Release(version: "3.16.6-beta.1", date: "Aug 24, 2026", changes: [
            "Choose where model weights are stored — point Whisper and Parakeet downloads at an external drive (Dictation → Model Storage). Existing models are moved automatically; if the drive is missing, Sonotexta says so instead of re-downloading to your system disk.",
            "AI cleanup failures are now loud: a clear overlay message, a persistent menu-bar warning until the next successful run, and visible reasons when dictation can't start.",
        ]),
        Release(version: "3.16.5", date: "Aug 12, 2026", changes: [
            "Multiple dictation shortcuts — each key with its own profile and mode (toggle or hold-to-talk). Set up under Dictation → Dictation Shortcuts.",
            "No more lost first words while a local model (Whisper/Parakeet) loads — audio is captured during warm-up and transcribed once ready.",
            "Fixed two silent AI-cleanup failures: long custom presets were truncated to 200 characters, and GPT-5.6 Luna rejected our request parameters. AI post-processing now visibly applies your presets on every engine.",
        ]),
        Release(version: "3.16.5-beta.3", date: "Aug 11, 2026", changes: [
            "Fixed: GPT-5.6 Luna AI processing failed silently on every dictation (the model rejects a parameter the older GPT-5 family accepts) — raw text was delivered instead of cleaned text. Luna now works for real.",
        ]),
        Release(version: "3.16.5-beta.2", date: "Aug 10, 2026", changes: [
            "Fixed: long custom AI presets were silently truncated to 200 characters, which could turn AI cleanup into a no-op. Full presets (up to 4,000 characters, with line breaks) now reach the model intact.",
        ]),
        Release(version: "3.16.5-beta.1", date: "Aug 10, 2026", changes: [
            "Multiple dictation shortcuts — each with its own key, profile, and mode (toggle or hold). Set them up under Dictation → Dictation Shortcuts.",
            "No more lost first words: audio is captured while a local model (Whisper/Parakeet) is still loading and transcribed once it's ready.",
            "Settings tip explaining Parakeet Live's lowercase output and the AI-cleanup fix.",
        ]),
        Release(version: "3.16.4", date: "Aug 10, 2026", changes: [
            "New dictation key option: Right Option (⌥) — hold-to-talk friendly, no System Settings changes. Pick it under Dictation → Hotkey.",
            "Microphone resilience: if your selected mic can't start, Sonotexta falls back to the system default and says so — no more silent failures.",
            "New AI model: GPT-5.6 Luna, OpenAI's newest budget model for post-processing.",
            "Clearer engine error logging for support diagnostics.",
        ]),
        Release(version: "3.16.4-beta.3", date: "Aug 10, 2026", changes: [
            "New dictation key option: Right Option (⌥) — hold-to-talk friendly, no System Settings changes needed. Pick it under Dictation → Hotkey.",
        ]),
        Release(version: "3.16.4-beta.2", date: "Aug 10, 2026", changes: [
            "New AI model option: GPT-5.6 Luna — OpenAI's newest budget model for post-processing (requested by a beta tester).",
        ]),
        Release(version: "3.16.4-beta.1", date: "Aug 6, 2026", changes: [
            "If your selected microphone can't start (e.g. some USB webcams on macOS Tahoe), Sonotexta now automatically falls back to the system default mic and says so in the overlay — instead of silently failing.",
            "Engine errors during final transcription are now logged loudly for easier support diagnostics.",
        ]),
        Release(version: "3.16.3", date: "Aug 1, 2026", changes: [
            "Start at login — enable in Dictation → Startup and Sonotexta is ready right after a restart.",
            "New OpenAI models: Transcribe (more accurate, cheaper) and Live Transcribe (lowest latency). Your selection migrates automatically.",
            "Vocabulary terms now bias the OpenAI engine as free keyword hints; menu bar shows the active profile and engine.",
            "One-time note: updating from 3.16.2 or older requires a manual download — the update signing key was replaced.",
        ]),
        Release(version: "3.16.3-beta.2", date: "Jul 12, 2026", changes: [
            "New OpenAI transcription models: Transcribe (more accurate, 25% cheaper) and Live Transcribe (lowest latency). Old models migrate automatically.",
            "Vocabulary terms now bias the OpenAI engine directly as free keyword hints.",
            "Pinned profile input languages are passed to the OpenAI engine as language hints.",
        ]),
        Release(version: "3.16.3-beta.1", date: "Jul 12, 2026", changes: [
            "Start at login — Sonotexta can auto-launch after a restart. Enable in Dictation → Startup.",
            "Settings clarity pass: stale references to the old tab names fixed, scope notes on per-engine model pickers.",
            "What's-new sheet un-stuck — it was frozen on 3.15 content for upgraders.",
        ]),
        Release(version: "3.16.2", date: "Jun 14, 2026", changes: [
            "Fixed translation profiles with a pinned input language (e.g. English to German) sometimes translating into the wrong language.",
        ]),
        Release(version: "3.16.1", date: "May 31, 2026", changes: [
            "Fixed a crash on macOS Tahoe when audio devices reconfigure mid-dictation.",
            "Fixed Whisper translating English audio when no translation was requested.",
            "Updates are now always confirmed before download and install — nothing happens silently.",
            "Better diagnostics for USB microphone device overrides.",
        ]),
        Release(version: "3.16.0", date: "May 26, 2026", changes: [
            "New engine mode: Parakeet Live — streaming local transcription, text appears as you speak, fully offline.",
            "Fixed launch update popup and Parakeet Live double-paste.",
        ]),
        Release(version: "3.15.0", date: "May 22, 2026", changes: [
            "Redesigned Settings: 5 clearer tabs (Dictation, Profiles, Connections, AI & Language, About).",
            "New Connections tab puts every API key on one page.",
            "System / Light / Dark theme picker; first-run wizard for new installs.",
        ]),
        Release(version: "3.14.3", date: "May 20, 2026", changes: [
            "DeepL translation support — add your API key in AI Settings for higher-quality translation on any macOS version.",
            "Test buttons for every API provider (Deepgram, ElevenLabs Scribe, DeepL).",
            "Auto-update now fires reliably on every launch — root cause was Sparkle's permission flag never being stored.",
            "Updates tab shows when the last automatic check ran.",
        ]),
        Release(version: "3.10.7", date: "May 8, 2026", changes: [
            "Apologies for the wild ride today — 7 stable releases across 4 hours is a lot to push to everyone.",
            "Introducing the Early-Bird (beta) update channel — opt in via the toggle above to get experimental fixes before they ship to all users.",
            "Stable users continue to see only fully-tested releases.",
        ]),
    ]

    private struct Release {
        let version: String
        let date: String
        let changes: [String]
    }
}

// MARK: - Release Card

struct ReleaseCard: View {
    let version: String
    let date: String
    let isLatest: Bool
    let changes: [String]

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center) {
                    Text("v\(version)")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color(red: 0.42, green: 0.36, blue: 0.91), Color(red: 0.29, green: 0.1, blue: 0.54)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )

                    Text(date)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if isLatest {
                        Text("Latest")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color(red: 0.42, green: 0.36, blue: 0.91).opacity(0.15))
                            .foregroundStyle(Color(red: 0.64, green: 0.61, blue: 0.99))
                            .clipShape(Capsule())
                    }

                    Spacer()
                }

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(changes, id: \.self) { change in
                        HStack(alignment: .top, spacing: 8) {
                            Text("+")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color(red: 0.64, green: 0.61, blue: 0.99))
                                .frame(width: 12)
                            Text(change)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }
}
