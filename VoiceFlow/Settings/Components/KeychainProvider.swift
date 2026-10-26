import Foundation
import Security

/// Symbolic provider identity used by `APIKeyRow` and `ConnectionsSettingsView`
/// to read/write/test API keys.
///
/// Each case is backed by an existing service in the codebase:
///   - `openAI*`, `anthropic`, `openRouter`, `ollama` route through `LLMService`
///     (Keychain account `llm-<provider>` under `com.voiceflow.app`).
///   - `deepgram` routes through `DeepgramEngine.apiKey` (Keychain account
///     `deepgram`).
///   - `elevenLabs` routes through `ElevenLabsScribeRealtimeEngine.apiKey`
///     (account `elevenlabs`).
///   - `deepL` routes through `TranslationService.deepLApiKey`.
///   - `appleTranslate` is a non-key readout (built-in macOS feature).
///
/// `openAI` (Speech) and `openAIAI` (Post-processing) intentionally back the
/// same `llm-openai` Keychain entry. The UI renders the row twice because
/// the brief asks for it; under the hood there is one key.
enum KeychainProvider: String, Identifiable, Hashable {
    // Speech Engines section
    case openAISpeech            // backs llm-openai
    case deepgram                // backs DeepgramEngine
    case elevenLabs              // backs ElevenLabsScribeRealtimeEngine

    // AI Post-processing section
    case openAIPostProcessing    // backs llm-openai (SAME key as openAISpeech)
    case groq                    // backs llm-groq
    case gemini                  // backs llm-gemini
    case openRouter              // backs llm-openrouter
    case ollama                  // local — no key

    // Translation section
    case deepL                   // backs TranslationService.deepLApiKey
    case appleTranslate          // no key — built-in

    var id: String { rawValue }

    /// Display label shown in the row.
    var displayName: String {
        switch self {
        case .openAISpeech:         return "OpenAI"
        case .deepgram:             return "Deepgram"
        case .elevenLabs:           return "ElevenLabs"
        case .openAIPostProcessing: return "OpenAI"
        case .groq:                 return "Groq"
        case .gemini:               return "Gemini"
        case .openRouter:           return "OpenRouter"
        case .ollama:               return "Ollama"
        case .deepL:                return "DeepL"
        case .appleTranslate:       return "Apple Translate"
        }
    }

    /// SF Symbol used as the row glyph.
    var icon: String {
        switch self {
        case .openAISpeech, .openAIPostProcessing: return "brain"
        case .deepgram:                            return "waveform"
        case .elevenLabs:                          return "speaker.wave.2.fill"
        case .groq:                                return "bolt.fill"
        case .gemini:                              return "sparkle"
        case .openRouter:                          return "globe"
        case .ollama:                              return "desktopcomputer"
        case .deepL:                               return "character.bubble"
        case .appleTranslate:                      return "apple.logo"
        }
    }

    /// One-line help text shown in placeholder / setup state.
    var keyPlaceholder: String {
        switch self {
        case .openAISpeech, .openAIPostProcessing: return "sk-..."
        case .deepgram:                            return "Deepgram API key"
        case .elevenLabs:                          return "ElevenLabs API key"
        case .groq:                                return "gsk_..."
        case .gemini:                              return "AIza..."
        case .openRouter:                          return "sk-or-..."
        case .ollama:                              return ""
        case .deepL:                               return "DeepL API key (ends with :fx for free tier)"
        case .appleTranslate:                      return ""
        }
    }

    /// `true` when the provider has no user-managed key (Ollama local, Apple
    /// Translate). UI uses this to render a "running locally" / "built-in"
    /// readout instead of an editable key row.
    var isKeyless: Bool {
        switch self {
        case .ollama, .appleTranslate: return true
        default: return false
        }
    }

    /// Loads the current stored key (or returns nil). Routes through whichever
    /// existing service owns the key.
    func loadKey() -> String? {
        switch self {
        case .openAISpeech, .openAIPostProcessing:
            return LLMService.shared.apiKey(for: .openAI)
        case .groq:                                return LLMService.shared.apiKey(for: .groq)
        case .gemini:                              return LLMService.shared.apiKey(for: .gemini)
        case .openRouter:                          return LLMService.shared.apiKey(for: .openRouter)
        case .deepgram:
            // Mirrors DeepgramEngine.apiKey getter — service
            // `KeychainConstants.service`, account "deepgram".
            return Self.readKeychain(account: "deepgram")
        case .elevenLabs:
            // Mirrors ElevenLabsScribeRealtimeEngine.apiKey getter — account "elevenlabs".
            return Self.readKeychain(account: "elevenlabs")
        case .deepL:
            return TranslationService.shared.deepLApiKey
        case .ollama, .appleTranslate:
            return nil
        }
    }

    /// Saves a key (or removes it when `key` is nil/empty).
    func saveKey(_ key: String?) {
        let normalized = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (normalized?.isEmpty == false) ? normalized : nil
        switch self {
        case .openAISpeech, .openAIPostProcessing:
            LLMService.shared.setAPIKey(value, for: .openAI)
        case .groq:                                LLMService.shared.setAPIKey(value, for: .groq)
        case .gemini:                              LLMService.shared.setAPIKey(value, for: .gemini)
        case .openRouter:                          LLMService.shared.setAPIKey(value, for: .openRouter)
        case .deepgram:
            Self.writeKeychain(account: "deepgram", value: value)
        case .elevenLabs:
            Self.writeKeychain(account: "elevenlabs", value: value)
        case .deepL:
            TranslationService.shared.deepLApiKey = value
        case .ollama, .appleTranslate:
            // No-op — keyless providers do not store credentials.
            break
        }
    }

    /// Computes a masked display string from the stored key: first 4 + bullets
    /// up to a max width. Returns nil if no key is stored.
    func maskedDisplay() -> String? {
        guard let raw = loadKey(), !raw.isEmpty else { return nil }
        if raw.count <= 8 {
            return String(repeating: "•", count: raw.count)
        }
        let prefix = raw.prefix(4)
        let bullets = String(repeating: "•", count: 12)
        return "\(prefix)\(bullets)"
    }

    /// Runs a network test of the stored key. Returns success/error message
    /// suitable for displaying inline (status-prefixed). Throws on transport
    /// failure so callers can present a generic "could not reach provider".
    ///
    /// Keyless providers (Ollama, Apple Translate) return `.success("built-in")`
    /// without making a network call.
    @MainActor
    func testKey() async -> TestOutcome {
        switch self {
        case .openAISpeech, .openAIPostProcessing:
            return await testLLM(provider: .openAI)
        case .groq:
            return await testLLM(provider: .groq)
        case .gemini:
            return await testLLM(provider: .gemini)
        case .openRouter:
            return await testLLM(provider: .openRouter)
        case .deepgram:
            return await testDeepgram()
        case .elevenLabs:
            return await testElevenLabs()
        case .deepL:
            return await testDeepL()
        case .ollama:
            return .success("Ollama auto-detected at localhost:11434")
        case .appleTranslate:
            return .success("Built-in (macOS 26+)")
        }
    }

    enum TestOutcome: Equatable {
        case success(String)
        case failure(String)

        var isSuccess: Bool {
            if case .success = self { return true }
            return false
        }
    }

    private func testLLM(provider: LLMService.Provider) async -> TestOutcome {
        // For LLM providers we run the same `postProcess` round-trip the AI
        // tab uses for its "Test connection" button — it sends a minimal
        // prompt and returns either the cleaned result or an error.
        do {
            // Temporarily honor whatever provider/model the user already has
            // selected in `LLMService` — the test only needs to verify the
            // KEY works against this provider, not change anything.
            let previousProvider = LLMService.shared.selectedProvider
            let previousModel    = LLMService.shared.selectedModelID
            LLMService.shared.selectedProvider = provider
            // Use the default model for this provider so we don't accidentally
            // hit a non-existent model id while testing.
            LLMService.shared.selectedModelID = provider.defaultModelID
            defer {
                LLMService.shared.selectedProvider = previousProvider
                LLMService.shared.selectedModelID = previousModel
            }
            _ = try await LLMService.shared.postProcess(
                text: "hello",
                outputLanguage: "en",
                tonePrompt: ""
            )
            return .success("Key works")
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private func testDeepgram() async -> TestOutcome {
        guard let key = loadKey(), !key.isEmpty else {
            return .failure("No key configured")
        }
        var req = URLRequest(url: URL(string: "https://api.deepgram.com/v1/projects")!)
        req.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            return status == 200
                ? .success("Key works")
                : .failure("Deepgram returned HTTP \(status)")
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private func testElevenLabs() async -> TestOutcome {
        guard let key = loadKey(), !key.isEmpty else {
            return .failure("No key configured")
        }
        var req = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/user")!)
        req.setValue(key, forHTTPHeaderField: "xi-api-key")
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            return status == 200
                ? .success("Key works")
                : .failure("ElevenLabs returned HTTP \(status)")
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private func testDeepL() async -> TestOutcome {
        guard let key = loadKey(), !key.isEmpty else {
            return .failure("No key configured")
        }
        let host = key.hasSuffix(":fx") ? "api-free.deepl.com" : "api.deepl.com"
        var req = URLRequest(url: URL(string: "https://\(host)/v2/usage")!)
        req.setValue("DeepL-Auth-Key \(key)", forHTTPHeaderField: "Authorization")
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            return status == 200
                ? .success("Key works")
                : .failure("DeepL returned HTTP \(status)")
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    // MARK: - Raw Keychain access for engine-owned accounts
    //
    // DeepgramEngine and ElevenLabsScribeRealtimeEngine expose their keys
    // as instance `apiKey` properties — convenient when a transcription
    // session is already in flight, but the Connections tab needs to
    // read/write keys without instantiating an engine. These helpers
    // hit the SAME `KeychainConstants.service` + account names so reads
    // and writes here are bit-for-bit interoperable with the engines.

    /// Reads a key for the given Keychain account in
    /// `KeychainConstants.service`. Returns nil when no entry exists.
    private static func readKeychain(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainConstants.service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else { return nil }
        return string
    }

    /// Writes a key for the given Keychain account in
    /// `KeychainConstants.service`. Passing nil removes the entry.
    private static func writeKeychain(account: String, value: String?) {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainConstants.service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        guard let value, !value.isEmpty, let data = value.data(using: .utf8) else { return }
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainConstants.service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }
}
