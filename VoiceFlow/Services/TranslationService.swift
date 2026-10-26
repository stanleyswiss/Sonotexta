import Foundation
import Translation
import Security

final class TranslationService {
    static let shared = TranslationService()

    // MARK: - DeepL Keychain

    private let keychainAccount = "deepl-api-key"

    /// The stored DeepL API key, or nil if none is saved.
    var deepLApiKey: String? {
        get { loadDeepLKey() }
        set {
            if let key = newValue, !key.isEmpty {
                saveDeepLKey(key)
            } else {
                deleteDeepLKey()
            }
        }
    }

    var hasDeepL: Bool { deepLApiKey != nil }

    private func saveDeepLKey(_ key: String) {
        deleteDeepLKey()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainConstants.service,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: key.data(using: .utf8)!,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    private func loadDeepLKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainConstants.service,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func deleteDeepLKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainConstants.service,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - DeepL Translation

    /// DeepL maps some language codes differently from BCP-47 / Apple.
    /// EN, PT, ZH need region qualifiers; others pass through as-is.
    private func deepLLanguageCode(_ bcp47: String) -> String {
        let base = String(bcp47.prefix(2)).uppercased()
        switch base {
        case "EN": return "EN-US"
        case "PT": return "PT-BR"
        case "ZH": return "ZH-HANS"
        default:   return base
        }
    }

    /// Translate via the DeepL REST API v2. Uses the free (`api-free.deepl.com`)
    /// or paid (`api.deepl.com`) endpoint based on whether the key ends with `:fx`.
    private func translateWithDeepL(_ text: String, from source: String, to target: String, key: String) async -> String? {
        let host = key.hasSuffix(":fx") ? "api-free.deepl.com" : "api.deepl.com"
        guard let url = URL(string: "https://\(host)/v2/translate") else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("DeepL-Auth-Key \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "text": [text],
            "source_lang": deepLLanguageCode(source),
            "target_lang": deepLLanguageCode(target),
        ]
        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        request.httpBody = httpBody

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                print("[VoiceFlow][DeepL] HTTP \(statusCode)")
                return nil
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let translations = json["translations"] as? [[String: Any]],
               let translated = translations.first?["text"] as? String {
                return translated
            }
        } catch {
            print("[VoiceFlow][DeepL] Request failed: \(error.localizedDescription)")
        }
        return nil
    }

    // MARK: - Public translate

    /// Translate `text` from `sourceLanguageCode` to `targetLanguageCode`.
    ///
    /// If a DeepL API key is stored, DeepL is tried first. Falls back to
    /// Apple Translation (macOS 26.0+) when DeepL is unavailable or fails.
    ///
    /// 3.14.0: `sourceLanguageCode` is now required. The previous overload
    /// hardcoded `source = "en"` which silently corrupted every non-English
    /// dictation that hit this code path — Apple Translation was asked to
    /// translate Czech-as-English, returned nil, and the call site delivered
    /// the raw source text without informing the user.
    func translate(_ text: String, from sourceLanguageCode: String, to targetLanguageCode: String) async -> String? {
        // Reduce BCP-47 ("cs-CZ", "bg-BG") to 2-letter ISO ("cs", "bg") for
        // the base locale; the region-qualified retry below handles the
        // full-region form if needed.
        let sourceBase = String(sourceLanguageCode.prefix(2)).lowercased()
        let targetBase = String(targetLanguageCode.prefix(2)).lowercased()

        // Same-language requests are nonsensical — return nil so the caller
        // falls through to delivering the original text without an Apple
        // Translation round-trip.
        if sourceBase == targetBase {
            return nil
        }

        // DeepL first — faster, higher quality, and doesn't require macOS 26.
        if let key = deepLApiKey {
            if let result = await translateWithDeepL(text, from: sourceLanguageCode, to: targetLanguageCode, key: key) {
                return result
            }
            print("[VoiceFlow][DeepL] Falling back to Apple Translation")
        }

        let target = Locale.Language(identifier: targetLanguageCode)
        let source = Locale.Language(identifier: sourceLanguageCode)

        if #available(macOS 26.0, *) {
            return await translateModern(text, source: source, target: target)
        } else {
            print("[VoiceFlow] Translation requires macOS 26.0+")
            return nil
        }
    }

    @available(macOS 26.0, *)
    private func translateModern(_ text: String, source: Locale.Language, target: Locale.Language) async -> String? {
        do {
            let session = TranslationSession(installedSource: source, target: target)
            let response = try await session.translate(text)
            return response.targetText
        } catch {
            print("[VoiceFlow] Translation error \(source) → \(target): \(error)")

            // Retry with region-qualified locale (Apple Translation sometimes
            // refuses bare 2-letter codes on the target side).
            let regionMap: [String: String] = [
                "cs": "cs-CZ", "bg": "bg-BG", "de": "de-DE", "fr": "fr-FR",
                "es": "es-ES", "it": "it-IT", "pt": "pt-BR", "ru": "ru-RU",
                "zh": "zh-CN", "ja": "ja-JP", "ko": "ko-KR", "ar": "ar-SA",
                "tr": "tr-TR", "nl": "nl-NL", "pl": "pl-PL", "sv": "sv-SE",
                "da": "da-DK", "fi": "fi-FI", "uk": "uk-UA", "ro": "ro-RO",
                "el": "el-GR", "hi": "hi-IN", "en": "en-US",
            ]

            let targetCode = target.languageCode?.identifier ?? ""
            let sourceCode = source.languageCode?.identifier ?? ""
            let qualifiedTarget = regionMap[targetCode].map { Locale.Language(identifier: $0) } ?? target
            let qualifiedSource = regionMap[sourceCode].map { Locale.Language(identifier: $0) } ?? source

            do {
                print("[VoiceFlow] Retrying translation \(qualifiedSource) → \(qualifiedTarget)")
                let session2 = TranslationSession(installedSource: qualifiedSource, target: qualifiedTarget)
                let response2 = try await session2.translate(text)
                return response2.targetText
            } catch {
                print("[VoiceFlow] Translation retry failed: \(error)")
            }

            return nil
        }
    }
}
