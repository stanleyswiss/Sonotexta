import SwiftUI

/// Connections tab — every API key and credential in one place.
///
/// Three cards: Speech Engines, AI Post-Processing, Translation.
/// API keys are stored in macOS Keychain (the same accounts used by the
/// engine-specific configs) via `KeychainProvider`.
///
/// Note: OpenAI shows up in BOTH Speech Engines (Realtime engine) and AI
/// Post-Processing (LLM cleanup) — it is the SAME stored key. Removing
/// in one place removes everywhere.
struct ConnectionsSettingsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Text("Connections")
                        .font(.title)
                        .fontWeight(.bold)
                    Text("Every API key and provider in one place.")
                        .foregroundStyle(.secondary)
                }

                speechEnginesCard
                aiPostProcessingCard
                translationCard
            }
            .padding(24)
        }
    }

    private var speechEnginesCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(
                    "Speech Engines",
                    subtitle: "Cloud engines that transcribe your audio."
                )
                APIKeyRow(provider: .openAISpeech)
                Divider()
                APIKeyRow(provider: .deepgram)
                Divider()
                APIKeyRow(provider: .elevenLabs)
            }
        }
    }

    private var aiPostProcessingCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(
                    "AI Post-Processing",
                    subtitle: "LLMs that clean and translate transcripts. The OpenAI key is shared with the Speech Engines section."
                )
                APIKeyRow(provider: .openAIPostProcessing)
                Divider()
                APIKeyRow(provider: .groq)
                Divider()
                APIKeyRow(provider: .gemini)
                Divider()
                APIKeyRow(provider: .openRouter)
                Divider()
                APIKeyRow(provider: .ollama)
            }
        }
    }

    private var translationCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(
                    "Translation",
                    subtitle: "Where translation runs when output language ≠ spoken language."
                )
                APIKeyRow(provider: .deepL)
                Divider()
                APIKeyRow(provider: .appleTranslate)
            }
        }
    }
}
