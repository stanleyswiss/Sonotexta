import Foundation
import Security

/// Engine selection the migration reads and rewrites. `AppSettings` conforms;
/// tests use an in-memory fake so they never touch the real app's defaults.
protocol OpenSourceMigrationEngineStore: AnyObject {
    var selectedEngine: STTEngineType { get set }
    var profiles: [Profile] { get set }
}

extension AppSettings: OpenSourceMigrationEngineStore {}

/// One-time cleanup when Sonotexta became free and open source.
///
/// 1. Removes the old licence / trial / subscription Keychain items and the
///    trial backup file. BYOK provider keys share the Keychain service but use
///    different account names and are never touched.
/// 2. Users who relied on the hosted proxy had a cloud engine selected without
///    their own key. That proxy is gone, so any cloud engine (global or profile
///    override) whose BYOK key is missing falls back to Apple Speech instead of
///    failing on the next dictation.
/// 3. AI cleanup used to be gated off for them too. Profiles that have it on
///    but no key for the selected AI provider get it switched off, so every
///    dictation doesn't end in a "no AI provider" warning.
///
/// Key checks only change a setting when the Keychain reports the key as
/// absent; an unreadable Keychain keeps the user's choice.
///
/// Guarded by `flagKey`; running it again is a no-op.
enum OpenSourceMigration {
    static let flagKey = "didMigrateOpenSource1"

    /// Account names the removed LicenseManager stored under `KeychainConstants.service`.
    static let legacyLicenseKeychainAccounts = [
        "com.voiceflow.license-key",
        "com.voiceflow.instance-id",
        "com.voiceflow.trial-start",
        "com.voiceflow.activated-at",
        "com.voiceflow.subscription-key",
        "com.voiceflow.subscription-plan",
    ]

    /// ~/Library/Application Support/VoiceFlow/.trial (trial-start backup).
    static var legacyTrialBackupURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("VoiceFlow", isDirectory: true)
            .appendingPathComponent(".trial")
    }

    /// A cloud engine without its BYOK key becomes Apple Speech; everything else is kept.
    static func fallbackEngine(_ engine: STTEngineType, hasKey: (STTEngineType) -> Bool) -> STTEngineType {
        guard engine.isCloudStreaming, !hasKey(engine) else { return engine }
        return .appleSpeech
    }

    /// Applies `fallbackEngine` to the global engine and every profile override.
    /// Returns true when anything changed.
    @discardableResult
    static func migrateEngines(in store: OpenSourceMigrationEngineStore, hasKey: (STTEngineType) -> Bool) -> Bool {
        var changed = false
        let global = fallbackEngine(store.selectedEngine, hasKey: hasKey)
        if global != store.selectedEngine {
            print("[Sonotexta][migration] global engine \(store.selectedEngine.rawValue) has no API key — switched to Apple Speech")
            store.selectedEngine = global
            changed = true
        }
        var profiles = store.profiles
        var profilesChanged = false
        for index in profiles.indices {
            guard let override = profiles[index].engineOverride else { continue }
            let migrated = fallbackEngine(override, hasKey: hasKey)
            if migrated != override {
                print("[Sonotexta][migration] profile \"\(profiles[index].name)\" engine \(override.rawValue) has no API key — switched to Apple Speech")
                profiles[index].engineOverride = migrated
                profilesChanged = true
            }
        }
        if profilesChanged {
            store.profiles = profiles
            changed = true
        }
        return changed
    }

    /// Switches AI cleanup off in every profile when the selected AI provider
    /// has no key. Returns true when anything changed.
    @discardableResult
    static func migrateAIPostProcessing(in store: OpenSourceMigrationEngineStore, aiKeyMissing: Bool) -> Bool {
        guard aiKeyMissing else { return false }
        var profiles = store.profiles
        var changed = false
        for index in profiles.indices where profiles[index].aiPostProcessing {
            print("[Sonotexta][migration] profile \"\(profiles[index].name)\" AI cleanup has no API key — switched off")
            profiles[index].aiPostProcessing = false
            changed = true
        }
        if changed { store.profiles = profiles }
        return changed
    }

    /// Runs the migration once. Returns false when it had already run.
    /// Cleanup failures are logged loudly but do not block the flag: nothing
    /// reads the old licence items any more, so a leftover is inert.
    @discardableResult
    static func runIfNeeded(
        defaults: UserDefaults = .standard,
        store: OpenSourceMigrationEngineStore = AppSettings.shared,
        hasKey: (STTEngineType) -> Bool = liveHasKey,
        aiKeyMissing: () -> Bool = liveAIKeyMissing,
        deleteKeychainAccount: (String) -> OSStatus = deleteLegacyKeychainItem,
        trialBackupURL: URL? = legacyTrialBackupURL,
        fileManager: FileManager = .default
    ) -> Bool {
        guard !defaults.bool(forKey: flagKey) else { return false }

        for account in legacyLicenseKeychainAccounts {
            let status = deleteKeychainAccount(account)
            if status != errSecSuccess && status != errSecItemNotFound {
                print("[Sonotexta][migration] ERROR: could not remove legacy Keychain item \(account) (OSStatus \(status))")
            }
        }

        if let url = trialBackupURL, fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                print("[Sonotexta][migration] ERROR: could not remove trial backup \(url.path): \(error.localizedDescription)")
            }
        }

        migrateEngines(in: store, hasKey: hasKey)
        migrateAIPostProcessing(in: store, aiKeyMissing: aiKeyMissing())

        defaults.set(true, forKey: flagKey)
        print("[Sonotexta][migration] open-source migration complete")
        return true
    }

    /// True unless the Keychain reports the engine's BYOK key as absent.
    /// Accounts match the engines' own key getters.
    static func liveHasKey(_ engine: STTEngineType) -> Bool {
        switch engine {
        case .openAIRealtime: return llmKeyExists(.openAI) != false
        case .deepgram: return keychainItemExists(account: "deepgram") != false
        case .elevenLabsScribe: return keychainItemExists(account: "elevenlabs") != false
        default: return true
        }
    }

    /// True only when the selected AI provider needs a key and the Keychain
    /// reports it as absent.
    static func liveAIKeyMissing() -> Bool {
        let provider = LLMService.shared.selectedProvider
        guard provider.requiresAPIKey else { return false }
        return llmKeyExists(provider) == false
    }

    /// Mirrors `LLMService.loadFromKeychain`: the current "llm-" account, then
    /// the legacy service. nil when either lookup can't be answered.
    static func llmKeyExists(_ provider: LLMService.Provider) -> Bool? {
        let current = keychainItemExists(account: "llm-\(provider.keychainAccount)")
        let legacy = keychainItemExists(account: provider.keychainAccount, service: "com.voiceflow.openai-api-key")
        if current == true || legacy == true { return true }
        if current == nil || legacy == nil { return nil }
        return false
    }

    /// Whether a Keychain item exists, asking for attributes only so the
    /// secret is never read and no access prompt appears. nil when the
    /// Keychain can't say (locked, access denied, other errors).
    static func keychainItemExists(account: String, service: String = KeychainConstants.service) -> Bool? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        switch SecItemCopyMatching(query as CFDictionary, &result) {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        default:
            print("[Sonotexta][migration] Keychain lookup for \(account) inconclusive — keeping current setting")
            return nil
        }
    }

    static func deleteLegacyKeychainItem(account: String) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainConstants.service,
            kSecAttrAccount as String: account,
        ]
        return SecItemDelete(query as CFDictionary)
    }
}
