import SwiftUI

struct AISettingsView: View {
    @StateObject private var llmService = LLMService.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var apiKeyInput = ""
    @State private var showKey = false
    @State private var testResult: String?
    @State private var isTesting = false
    @State private var deepLKeyInput = ""
    @State private var showDeepLKey = false
    @State private var deepLSaveStatus: DeepLSaveStatus = .idle
    @State private var deepLTestStatus: String?
    @State private var isTestingDeepL = false

    private enum DeepLSaveStatus { case idle, saved, removed }

    private var provider: LLMService.Provider { llmService.selectedProvider }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Text("AI Post-Processing")
                        .font(.title)
                        .fontWeight(.bold)
                    Text("Configure the LLM provider for text cleanup, translation, and tone adjustment.")
                        .foregroundStyle(.secondary)
                }

                // Provider picker
                SettingsCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Provider")
                            .font(.headline)

                        Picker("Provider", selection: Binding(
                            get: { llmService.selectedProvider },
                            set: {
                                llmService.selectedProvider = $0
                                // Load existing key for new provider
                                apiKeyInput = llmService.apiKey(for: $0) ?? ""
                                showKey = false
                                testResult = nil
                            }
                        )) {
                            ForEach(LLMService.Provider.allCases) { p in
                                Text(p.displayName).tag(p)
                            }
                        }
                        .pickerStyle(.radioGroup)
                        .horizontalRadioGroupLayout()

                        // Provider-specific info
                        HStack(spacing: 6) {
                            Image(systemName: providerIcon)
                                .foregroundStyle(.blue)
                            Text(providerDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // API Key (not shown for Ollama)
                if provider.requiresAPIKey {
                    SettingsCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("\(provider.displayName) API Key")
                                .font(.headline)

                            HStack {
                                if showKey {
                                    TextField(provider.keyPlaceholder, text: $apiKeyInput)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(.callout, design: .monospaced))
                                } else {
                                    SecureField(provider.keyPlaceholder, text: $apiKeyInput)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(.callout, design: .monospaced))
                                }

                                Button(showKey ? "Hide" : "Show") {
                                    showKey.toggle()
                                }
                                .buttonStyle(.borderless)
                            }

                            HStack {
                                Button("Save Key") {
                                    llmService.setAPIKey(apiKeyInput, for: provider)
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(apiKeyInput.isEmpty)

                                if let key = llmService.apiKey(for: provider), !key.isEmpty {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                    Text("Saved")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                if let key = llmService.apiKey(for: provider), !key.isEmpty {
                                    Button("Remove") {
                                        llmService.setAPIKey(nil, for: provider)
                                        apiKeyInput = ""
                                    }
                                    .foregroundStyle(.red)
                                    .buttonStyle(.borderless)
                                }
                            }

                            Text(provider.keyHelpText)
                                .font(.caption)
                                .foregroundStyle(.tertiary)

                            Text("Your API key is stored securely in the macOS Keychain.")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                } else {
                    // Ollama local — setup info
                    SettingsCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Local Setup")
                                .font(.headline)

                            Text("Ollama runs AI models entirely on your Mac — no API key, no cloud, fully private.")
                                .font(.callout)
                                .foregroundStyle(.secondary)

                            Divider()

                            VStack(alignment: .leading, spacing: 4) {
                                Label("Install Ollama from ollama.com", systemImage: "1.circle")
                                Label("Open Terminal and run: ollama pull llama3.1", systemImage: "2.circle")
                                Label("Keep Ollama running in the background", systemImage: "3.circle")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }

                // Model
                SettingsCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Model")
                            .font(.headline)

                        Picker("Model", selection: Binding(
                            get: { llmService.selectedModelID },
                            set: { llmService.selectedModelID = $0 }
                        )) {
                            ForEach(provider.models) { model in
                                HStack {
                                    Text(model.name)
                                    Text("— \(model.detail)")
                                        .foregroundStyle(.secondary)
                                }
                                .tag(model.id)
                            }
                        }
                        .labelsHidden()
                    }
                }

                // Test
                SettingsCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Test Connection")
                                .font(.headline)

                            Spacer()

                            Button {
                                testConnection()
                            } label: {
                                HStack(spacing: 6) {
                                    if isTesting {
                                        ProgressView()
                                            .scaleEffect(0.6)
                                    }
                                    Text("Test")
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(!llmService.hasAPIKey || isTesting)
                        }

                        if let result = testResult {
                            Label(result, systemImage: result.contains("Success") ? "checkmark.circle" : "xmark.circle")
                                .font(.caption)
                                .foregroundStyle(result.contains("Success") ? .green : .red)
                        }
                    }
                }

                // Translate stop max wait
                SettingsCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Translate Stop Max Wait")
                                .font(.headline)
                            Spacer()
                            Text("\(String(format: "%.1f", settings.translateStopWaitSeconds))s")
                                .font(.system(.callout, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }

                        Slider(
                            value: $settings.translateStopWaitSeconds,
                            in: 3.0...12.0,
                            step: 0.5
                        ) {
                            Text("Translate stop max wait")
                        } minimumValueLabel: {
                            Text("3s").font(.caption2).foregroundStyle(.secondary)
                        } maximumValueLabel: {
                            Text("12s").font(.caption2).foregroundStyle(.secondary)
                        }

                        Text("Maximum time to wait for the translation model's authoritative \"done\" signal before falling back to the partial transcript. Sonotexta exits as soon as the model says it's done — this is just the safety cap for stalls. Default 8s. Only affects the per-profile native translation engine.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                // Vocabulary (glossary)
                VocabularyCard(settings: settings)

                // DeepL translation key
                SettingsCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("DeepL Translation")
                                .font(.headline)
                            if TranslationService.shared.hasDeepL {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                        }

                        Text("Optional. When a DeepL API key is set, Sonotexta uses DeepL as the translation backend instead of Apple Translation — higher quality and no macOS 26 requirement.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack {
                            if showDeepLKey {
                                TextField("DeepL API key (ends with :fx for free tier)", text: $deepLKeyInput)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(.callout, design: .monospaced))
                            } else {
                                SecureField("DeepL API key (ends with :fx for free tier)", text: $deepLKeyInput)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(.callout, design: .monospaced))
                            }
                            Button(showDeepLKey ? "Hide" : "Show") {
                                showDeepLKey.toggle()
                            }
                            .buttonStyle(.borderless)
                        }

                        HStack {
                            Button("Save Key") {
                                TranslationService.shared.deepLApiKey = deepLKeyInput
                                deepLSaveStatus = .saved
                                deepLTestStatus = nil
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(deepLKeyInput.isEmpty)

                            Button {
                                testDeepLKey()
                            } label: {
                                HStack(spacing: 4) {
                                    if isTestingDeepL { ProgressView().scaleEffect(0.6) }
                                    Text("Test")
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled((TranslationService.shared.deepLApiKey ?? (deepLKeyInput.isEmpty ? nil : deepLKeyInput)) == nil || isTestingDeepL)

                            if deepLSaveStatus == .saved {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text("Saved")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            if TranslationService.shared.hasDeepL {
                                Button("Remove") {
                                    TranslationService.shared.deepLApiKey = nil
                                    deepLKeyInput = ""
                                    deepLSaveStatus = .idle
                                    deepLTestStatus = nil
                                }
                                .foregroundStyle(.red)
                                .buttonStyle(.borderless)
                            }
                        }

                        if let status = deepLTestStatus {
                            Label(status, systemImage: status.hasPrefix("✓") ? "checkmark.circle" : "xmark.circle")
                                .font(.caption)
                                .foregroundStyle(status.hasPrefix("✓") ? .green : .red)
                        }

                        Text("Get your free key at deepl.com/pro#developer — 500,000 characters/month free.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)

                        Text("Your API key is stored securely in the macOS Keychain.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                // How it works
                SettingsCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("How It Works")
                            .font(.headline)

                        VStack(alignment: .leading, spacing: 6) {
                            Label("Speech is transcribed by your selected engine", systemImage: "1.circle")
                            Label("If AI post-processing is ON, text is sent to \(provider.displayName) for cleanup + translation", systemImage: "2.circle")
                            Label("Processed text is pasted into the target app", systemImage: "3.circle")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(24)
        }
        .onAppear {
            if let existing = llmService.apiKey(for: provider) {
                apiKeyInput = existing
            }
            if let existing = TranslationService.shared.deepLApiKey {
                deepLKeyInput = existing
            }
        }
    }

    // MARK: - Provider Info

    private var providerIcon: String {
        switch provider {
        case .openAI: return "brain"
        case .groq: return "bolt.fill"
        case .gemini: return "sparkle"
        case .openRouter: return "globe"
        case .ollama: return "desktopcomputer"
        case .ollamaCloud: return "cloud"
        }
    }

    private var providerDescription: String {
        switch provider {
        case .openAI: return "Best quality. Pay-per-use with your own API key."
        case .groq: return "Ultra-fast inference. Generous free tier with open-source models."
        case .gemini: return "Google's models. Free tier with 15 RPM / 1M tokens per day."
        case .openRouter: return "200+ models, one API key. Access Claude, GPT, Llama, and more. Free models available."
        case .ollama: return "Fully local and private. No internet needed. Runs on your Mac's hardware."
        case .ollamaCloud: return "Run large models on Ollama's cloud GPUs. Free tier available, Pro $20/mo, Max $100/mo."
        }
    }

    // MARK: - Test

    private func testDeepLKey() {
        let key = TranslationService.shared.deepLApiKey
            ?? (deepLKeyInput.isEmpty ? nil : deepLKeyInput)
        guard let key else { return }
        isTestingDeepL = true
        deepLTestStatus = nil
        Task {
            let host = key.hasSuffix(":fx") ? "api-free.deepl.com" : "api.deepl.com"
            var req = URLRequest(url: URL(string: "https://\(host)/v2/usage")!)
            req.setValue("DeepL-Auth-Key \(key)", forHTTPHeaderField: "Authorization")
            let status: Int
            do {
                let (_, resp) = try await URLSession.shared.data(for: req)
                status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            } catch {
                await MainActor.run {
                    deepLTestStatus = "✗ Network error: \(error.localizedDescription)"
                    isTestingDeepL = false
                }
                return
            }
            await MainActor.run {
                deepLTestStatus = status == 200 ? "✓ Key valid" : "✗ Invalid key (HTTP \(status))"
                isTestingDeepL = false
            }
        }
    }

    private func testConnection() {
        isTesting = true
        testResult = nil
        Task {
            do {
                let result = try await llmService.postProcess(
                    text: "Hello this is a test",
                    outputLanguage: "en",
                    tonePrompt: ""
                )
                await MainActor.run {
                    testResult = "Success: \"\(result)\""
                    isTesting = false
                }
            } catch {
                await MainActor.run {
                    testResult = "Error: \(error.localizedDescription)"
                    isTesting = false
                }
            }
        }
    }
}

// MARK: - Vocabulary card

/// Editable list of `GlossaryEntry` records. Each row: canonical term + a
/// comma-separated list of misrecognitions ("heard as"). Empty rows are
/// allowed in the UI but filtered out when sent to the LLM.
private struct VocabularyCard: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Vocabulary")
                        .font(.headline)
                    Spacer()
                    Button {
                        settings.glossary.append(GlossaryEntry(canonical: "", aliases: []))
                    } label: {
                        Label("Add", systemImage: "plus.circle")
                    }
                    .buttonStyle(.borderless)
                }

                Text("Teach the AI cleanup how you pronounce specific terms. Useful for product names that get misrecognized (e.g. \"Claude Code\" heard as \"cloud code\"). Applied to every dictation that uses AI cleanup; non-matching words are left alone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if settings.glossary.isEmpty {
                    Text("No entries yet. Click Add to create one.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 6)
                } else {
                    VStack(spacing: 8) {
                        ForEach($settings.glossary) { $entry in
                            VocabularyRow(entry: $entry) {
                                settings.glossary.removeAll { $0.id == entry.id }
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct VocabularyRow: View {
    @Binding var entry: GlossaryEntry
    var onDelete: () -> Void

    /// Bridge between `[String]` storage and the comma-separated text field.
    private var aliasText: Binding<String> {
        Binding(
            get: { entry.aliases.joined(separator: ", ") },
            set: { newValue in
                entry.aliases = newValue
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
        )
    }

    var body: some View {
        HStack(spacing: 8) {
            TextField("Canonical (e.g. Claude Code)", text: $entry.canonical)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)

            TextField("Heard as (comma-separated)", text: aliasText)
                .textFieldStyle(.roundedBorder)

            Button {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.borderless)
            .help("Delete entry")
        }
    }
}
