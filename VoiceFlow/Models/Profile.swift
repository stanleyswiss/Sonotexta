import Foundation

// MARK: - AI Enhancement Presets

enum AIPreset: String, Codable, CaseIterable, Identifiable {
    case cleanCorrect = "clean_correct"
    case professional = "professional"
    case conciseSummary = "concise_summary"
    case bulletPoints = "bullet_points"
    case paragraphStructure = "paragraph_structure"
    case keyTakeaways = "key_takeaways"
    case qaFormat = "qa_format"
    case actionItems = "action_items"
    case custom = "custom"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cleanCorrect:       return "Clean & Correct"
        case .professional:       return "Professional Tone"
        case .conciseSummary:     return "Concise Summary"
        case .bulletPoints:       return "Bullet Points"
        case .paragraphStructure: return "Paragraph Structure"
        case .keyTakeaways:       return "Key Takeaways"
        case .qaFormat:           return "Q&A Format"
        case .actionItems:        return "Action Items"
        case .custom:             return "Custom..."
        }
    }

    var promptText: String {
        switch self {
        case .cleanCorrect:
            return "Fix grammar, punctuation, and remove filler words. Keep the original meaning and tone."
        case .professional:
            return "Rephrase in a professional, polished tone suitable for business communication."
        case .conciseSummary:
            return "Condense into a brief summary capturing the key points."
        case .bulletPoints:
            return "Restructure into clear, organized bullet points."
        case .paragraphStructure:
            return "Organize into well-structured paragraphs with clear flow."
        case .keyTakeaways:
            return "List the main takeaways and important points."
        case .qaFormat:
            return "Restructure into Q&A format, pairing questions with their answers."
        case .actionItems:
            return "List the actionable tasks and next steps mentioned."
        case .custom:
            return ""
        }
    }

    var icon: String {
        switch self {
        case .cleanCorrect:       return "text.badge.checkmark"
        case .professional:       return "briefcase"
        case .conciseSummary:     return "doc.text"
        case .bulletPoints:       return "list.bullet"
        case .paragraphStructure: return "text.alignleft"
        case .keyTakeaways:       return "star"
        case .qaFormat:           return "questionmark.circle"
        case .actionItems:        return "checklist"
        case .custom:             return "pencil"
        }
    }
}

// MARK: - Custom AI Preset

/// User-defined AI post-processing preset. Stored globally in `AppSettings.customPresets`
/// so a single named prompt (e.g. "Email tone", "Slack casual", "Bullet points punchy")
/// can be reused across multiple profiles. Profiles reference a custom preset by `id`
/// via `Profile.customPresetID`; the prompt text lives here, not duplicated per profile.
struct CustomPreset: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var promptText: String
}

// MARK: - Glossary

/// A user-defined vocabulary entry used to disambiguate misrecognitions and
/// preserve product names across cleanup/translation. Stored globally in
/// `AppSettings.glossary` and applied to every AI-cleanup post-process.
///
/// The entries are NOT used for deterministic regex replacement (that breaks
/// sentences like "deploy to the cloud" when "cloud" is an alias for "Codex").
/// Instead they're injected into the LLM cleanup prompt so the model can
/// disambiguate from context.
struct GlossaryEntry: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    /// The form the entry should appear as in the final text (e.g. "Claude Code").
    var canonical: String
    /// Common misrecognitions of `canonical` from the speech-to-text engine.
    /// E.g. for "Claude Code": ["cloud code", "clawed code", "claude coat"].
    var aliases: [String]
}

// MARK: - Detection Rule

/// A single app + contact detection pair within a profile.
struct DetectionRule: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var appBundleIdentifier: String  // which app (empty = any)
    var contactFilter: String        // what to match in window title (empty = any contact in that app)
}

// MARK: - Profile

struct Profile: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    /// Multiple app + contact detection rules. Any match activates this profile.
    var detectionRules: [DetectionRule]
    /// Expected input language — "auto" means auto-detect.
    var inputLanguageCode: String
    var outputLanguageCode: String
    var translateNatively: Bool = false
    var tonePrompt: String
    var aiPostProcessing: Bool
    /// Optional engine override — nil means use global setting
    var engineOverride: STTEngineType?
    /// AI enhancement preset — nil means use legacy tonePrompt (migration-safe).
    /// When set to `.custom`, the active prompt comes from either:
    ///  - `customPresetID` looked up in `AppSettings.customPresets` (preferred since v3.9), or
    ///  - the legacy `tonePrompt` string on this profile (auto-migrated on first run).
    var aiPreset: AIPreset?
    /// Reference to a user-defined preset in `AppSettings.customPresets`.
    /// Only meaningful when `aiPreset == .custom`. Nil means "use the legacy
    /// per-profile `tonePrompt` field" (back-compat for profiles created before v3.9).
    var customPresetID: UUID?

    /// Default profile has no detection rules (matches everything)
    var isDefault: Bool {
        detectionRules.isEmpty
    }

    /// Legacy compatibility: first rule's bundle ID (used by AppSettings.profileForApp)
    var appBundleIdentifier: String {
        detectionRules.first?.appBundleIdentifier ?? ""
    }

    /// Legacy compatibility: first rule's contact filter
    var contactFilter: String {
        detectionRules.first?.contactFilter ?? ""
    }

    init(
        id: UUID = UUID(),
        name: String = "",
        detectionRules: [DetectionRule] = [],
        inputLanguageCode: String = "auto",
        outputLanguageCode: String = "en",
        translateNatively: Bool = false,
        tonePrompt: String = "",
        aiPostProcessing: Bool = false,
        engineOverride: STTEngineType? = nil,
        aiPreset: AIPreset? = nil,
        customPresetID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.detectionRules = detectionRules
        self.inputLanguageCode = inputLanguageCode
        self.outputLanguageCode = outputLanguageCode
        self.translateNatively = translateNatively
        self.tonePrompt = tonePrompt
        self.aiPostProcessing = aiPostProcessing
        self.engineOverride = engineOverride
        self.aiPreset = aiPreset
        self.customPresetID = customPresetID
    }

    // Custom decoder — migrates old single app+contact to detectionRules array.
    //
    // 3.13.2-beta.3 hardening: every field except `id` and `name` is decoded
    // tolerantly. A single missing/corrupt field on a single profile must NOT
    // make the entire `[Profile]` array fail to decode, because the load site
    // wraps the whole-array decode in `try?` and silently resets to a single
    // Default profile on any failure — wiping every custom profile the user
    // configured. Codable for String enums also THROWS on unknown rawValue
    // (e.g. a future STTEngineType case seen on a downgrade), so we decode
    // enums as strings and accept-as-nil when the rawValue is unknown rather
    // than letting it propagate.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)

        // Try new format first (detectionRules array)
        if let rules = try container.decodeIfPresent([DetectionRule].self, forKey: .detectionRules) {
            detectionRules = rules
        } else {
            // Migrate from old single app + contact format
            let oldApp = try container.decodeIfPresent(String.self, forKey: .appBundleIdentifier) ?? ""
            let oldContact = try container.decodeIfPresent(String.self, forKey: .contactFilter) ?? ""
            if oldApp.isEmpty && oldContact.isEmpty {
                detectionRules = [] // Default profile
            } else {
                detectionRules = [DetectionRule(appBundleIdentifier: oldApp, contactFilter: oldContact)]
            }
        }

        inputLanguageCode = (try? container.decodeIfPresent(String.self, forKey: .inputLanguageCode)) ?? "auto"
        outputLanguageCode = (try? container.decodeIfPresent(String.self, forKey: .outputLanguageCode)) ?? "en"
        translateNatively = (try? container.decodeIfPresent(Bool.self, forKey: .translateNatively)) ?? false
        tonePrompt = (try? container.decodeIfPresent(String.self, forKey: .tonePrompt)) ?? ""
        aiPostProcessing = (try? container.decodeIfPresent(Bool.self, forKey: .aiPostProcessing)) ?? false

        // Enum fields: decode the raw string, then lookup. Unknown rawValue
        // (e.g. a STTEngineType case added in a future build) becomes nil
        // instead of throwing and tanking the whole profile array.
        if let rawEngine = try? container.decodeIfPresent(String.self, forKey: .engineOverride) {
            engineOverride = STTEngineType(rawValue: rawEngine)
        } else {
            engineOverride = nil
        }
        if let rawPreset = try? container.decodeIfPresent(String.self, forKey: .aiPreset) {
            aiPreset = AIPreset(rawValue: rawPreset)
        } else {
            aiPreset = nil
        }
        customPresetID = (try? container.decodeIfPresent(UUID.self, forKey: .customPresetID)) ?? nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, detectionRules, appBundleIdentifier, contactFilter
        case inputLanguageCode, outputLanguageCode, translateNatively, tonePrompt
        case aiPostProcessing, engineOverride, aiPreset, customPresetID
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(detectionRules, forKey: .detectionRules)
        try container.encode(inputLanguageCode, forKey: .inputLanguageCode)
        try container.encode(outputLanguageCode, forKey: .outputLanguageCode)
        try container.encode(translateNatively, forKey: .translateNatively)
        try container.encode(tonePrompt, forKey: .tonePrompt)
        try container.encode(aiPostProcessing, forKey: .aiPostProcessing)
        try container.encodeIfPresent(engineOverride, forKey: .engineOverride)
        try container.encodeIfPresent(aiPreset, forKey: .aiPreset)
        try container.encodeIfPresent(customPresetID, forKey: .customPresetID)
    }

    static let inputLanguages: [(code: String, name: String)] = [
        ("auto", "Auto-detect"),
        ("en", "English"),
        ("de", "German"),
        ("fr", "French"),
        ("es", "Spanish"),
        ("it", "Italian"),
        ("pt-BR", "Portuguese"),
        ("ru-RU", "Russian"),
        ("zh-CN", "Chinese"),
        ("ja-JP", "Japanese"),
        ("ko-KR", "Korean"),
        ("ar-SA", "Arabic"),
        ("tr-TR", "Turkish"),
        ("nl-NL", "Dutch"),
        ("pl-PL", "Polish"),
        ("uk-UA", "Ukrainian"),
        ("hi-IN", "Hindi"),
        ("bg-BG", "Bulgarian"),
        ("cs-CZ", "Czech"),
        ("sv-SE", "Swedish"),
        ("da-DK", "Danish"),
        ("fi-FI", "Finnish"),
        ("ro-RO", "Romanian"),
        ("el-GR", "Greek"),
    ]

    static let supportedLanguages: [(code: String, name: String, translationAvailable: Bool)] = [
        ("auto", "Same as spoken (no translation)", true),
        ("en", "English", true),
        ("de", "German", true),
        ("fr", "French", true),
        ("es", "Spanish", true),
        ("it", "Italian", true),
        ("pt-BR", "Portuguese", true),
        ("ru-RU", "Russian", true),
        ("zh-CN", "Chinese (Simplified)", true),
        ("ja-JP", "Japanese", true),
        ("ko-KR", "Korean", true),
        ("ar-SA", "Arabic", true),
        ("tr-TR", "Turkish", true),
        ("nl-NL", "Dutch", true),
        ("pl-PL", "Polish", true),
        ("uk-UA", "Ukrainian", true),
        ("hi-IN", "Hindi", true),
        // Below: not supported by Apple Translation
        ("bg-BG", "Bulgarian", false),
        ("cs-CZ", "Czech", false),
        ("sv-SE", "Swedish", false),
        ("da-DK", "Danish", false),
        ("fi-FI", "Finnish", false),
        ("ro-RO", "Romanian", false),
        ("el-GR", "Greek", false),
    ]
}
