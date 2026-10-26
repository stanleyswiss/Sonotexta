import Foundation

struct AICleanupResult {
    let text: String
    let failure: String?
    var usedAI: Bool { failure == nil }

    /// Every requested cleanup goes through this path, including missing keys.
    /// On failure preserve recoverable text and an explicit, persistent warning.
    static func process(text: String, hasCredentials: Bool,
                        cleanup: () async throws -> String) async -> AICleanupResult {
        do {
            guard hasCredentials else { throw LLMError.noAPIKey }
            return AICleanupResult(text: try await cleanup(), failure: nil)
        } catch {
            return AICleanupResult(text: text, failure: error.localizedDescription)
        }
    }
}
