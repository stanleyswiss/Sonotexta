import Foundation

enum STTEngineType: String, CaseIterable, Identifiable, Codable {
    case appleSpeech = "apple_speech"
    case whisper = "whisper"
    case parakeet = "parakeet"
    case qwen = "qwen3_asr"
    case parakeetRealtime = "parakeet_realtime"
    case openAIRealtime = "openai_realtime"
    case deepgram = "deepgram"
    case elevenLabsScribe = "elevenlabs_scribe"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appleSpeech: return "Apple Speech"
        case .whisper: return "Whisper (local, offline)"
        case .parakeet: return "NVIDIA Parakeet TDT"
        case .qwen: return "Qwen3-ASR (local, experimental)"
        case .parakeetRealtime: return "Parakeet Live (English)"
        case .openAIRealtime: return "OpenAI Realtime (cloud)"
        case .deepgram: return "Deepgram Nova-3"
        case .elevenLabsScribe: return "ElevenLabs Scribe v2 Realtime"
        }
    }

    var description: String {
        switch self {
        case .appleSpeech: return "Built-in on-device recognition via Apple Intelligence"
        case .whisper: return "OpenAI Whisper running locally via whisper.cpp — offline, no API key needed"
        case .parakeet: return "NVIDIA Parakeet TDT 0.6B for fast transcription"
        case .qwen: return "Alibaba Qwen3-ASR 0.6B. Local, offline after download, 30 languages. Experimental CoreML conversion; text appears after you stop."
        case .parakeetRealtime: return "NVIDIA Parakeet Realtime EOU 120M — fastest English dictation, fully offline, ~240MB, live preview as you speak."
        case .openAIRealtime: return "Streaming cloud transcription via OpenAI Realtime API (Mini Transcribe / Transcribe / Realtime Whisper)"
        case .deepgram: return "Streaming cloud transcription via Deepgram Nova-3"
        case .elevenLabsScribe: return "Streaming cloud transcription via ElevenLabs Scribe v2 Realtime — ~150ms latency, 90+ languages, optional Vocabulary keyterm biasing"
        }
    }

    var isBuiltIn: Bool {
        self == .appleSpeech
    }

    var requiresDownload: Bool {
        switch self {
        case .appleSpeech, .openAIRealtime, .deepgram, .elevenLabsScribe: return false
        default: return true
        }
    }

    var isCloudStreaming: Bool {
        self == .openAIRealtime || self == .deepgram || self == .elevenLabsScribe
    }
}

enum ElevenLabsScribeModel: String, CaseIterable, Identifiable, Codable {
    case scribeV2Realtime = "scribe_v2_realtime"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .scribeV2Realtime: return "Scribe v2 Realtime"
        }
    }

    var qualityDescription: String {
        switch self {
        case .scribeV2Realtime: return "~150ms latency. 90+ languages. Best-in-class multilingual accuracy. $0.39/hr (+20% when keyterm biasing is on)."
        }
    }
}

enum WhisperModelSize: String, CaseIterable, Identifiable, Codable {
    case tiny = "tiny"
    case base = "base"
    case small = "small"
    case medium = "medium"
    case large = "large-v3"
    // The Argmax `whisperkit-coreml` repo names the Turbo variant
    // `openai_whisper-large-v3_turbo` (underscore before `turbo`, not hyphen).
    // Prior to 3.14.1-beta.4 we used `large-v3-turbo` (hyphen), which
    // produced `openai_whisper-large-v3-turbo` in the WhisperKit lookup
    // and failed with "modelsUnavailable / No models found matching".
    // Migration in AppSettings rewrites the old rawValue on first read.
    case largeTurbo = "large-v3_turbo"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tiny: return "Tiny (75MB)"
        case .base: return "Base (142MB)"
        case .small: return "Small (466MB)"
        case .medium: return "Medium (1.5GB)"
        case .large: return "Large V3 (3GB)"
        case .largeTurbo: return "Large V3 Turbo (1.6GB)"
        }
    }

    var qualityDescription: String {
        switch self {
        case .tiny: return "Fastest, lowest accuracy. English-focused. Not recommended for other languages."
        case .base: return "Fast, basic accuracy. Struggles with non-English languages."
        case .small: return "Good balance of speed and accuracy. Decent for European languages."
        case .medium: return "High accuracy for most languages. Recommended for Bulgarian, Czech, etc."
        case .large: return "Best accuracy. Excellent for all 99+ languages. Slower, needs more RAM."
        case .largeTurbo: return "Near-best accuracy with faster inference. Great for all languages."
        }
    }
}

/// 3.16.3-beta.2: lineup replaced with OpenAI's 2026 transcription models.
/// The retired 4o-era ids (gpt-4o-mini-transcribe / gpt-4o-transcribe /
/// gpt-realtime-whisper) still work server-side but are no longer offered;
/// stored selections migrate in AppSettings.init.
enum OpenAIRealtimeModel: String, CaseIterable, Identifiable, Codable {
    case transcribe = "gpt-transcribe"
    case liveTranscribe = "gpt-live-transcribe"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .transcribe: return "Transcribe (accurate)"
        case .liveTranscribe: return "Live Transcribe (low-latency)"
        }
    }

    var qualityDescription: String {
        switch self {
        case .transcribe: return "OpenAI's newest transcription model — more accurate and cheaper ($0.0045/min) than the previous generation. Text arrives per phrase. Recommended for dictation."
        case .liveTranscribe: return "Streaming model that delivers text as you speak. Lowest latency, strong on accents and noise. ~4x the cost of Transcribe ($0.017/min)."
        }
    }
}

enum ParakeetModelVersion: String, CaseIterable, Identifiable, Codable {
    case v2 = "v2"
    case v3 = "v3"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .v2: return "Parakeet TDT v2 (~1.2GB)"
        case .v3: return "Parakeet TDT v3 (~1.2GB)"
        }
    }

    var qualityDescription: String {
        switch self {
        case .v2: return "English-focused. Best accuracy for English-only dictation."
        case .v3: return "25 European languages. Recommended for multilingual use (Bulgarian, Czech, German, etc.)."
        }
    }
}

enum DeepgramModel: String, CaseIterable, Identifiable, Codable {
    case nova3 = "nova-3"
    case nova2 = "nova-2"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .nova3: return "Nova-3 (latest)"
        case .nova2: return "Nova-2"
        }
    }

    var qualityDescription: String {
        switch self {
        case .nova3: return "Latest model. Best accuracy, 10 streaming languages with code-switching."
        case .nova2: return "Previous generation. Good accuracy, reliable."
        }
    }
}

enum DictationMode: String, CaseIterable, Identifiable {
    case toggle = "toggle"
    case holdToTalk = "hold_to_talk"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .toggle: return "Toggle (press to start, press to stop)"
        case .holdToTalk: return "Hold to Talk (hold key, release to stop)"
        }
    }
}

protocol STTEngineProtocol {
    var engineType: STTEngineType { get }
    var isAvailable: Bool { get }
    /// A final inference failure must not be presented as silence or partial success.
    var finalizationError: Error? { get }
    /// Actionable capture-path failure detected even though the audio engine
    /// itself started successfully (for example, zero-filled call audio).
    var audioCaptureIssue: String? { get }

    func startTranscription(locale: Locale, onResult: @escaping (String, Bool) -> Void) async throws

    /// Stop transcription and return the canonical final text the engine produced.
    /// `nil` means no final text was produced (silence, very short utterance with no
    /// recognizable speech, error during finalization). When non-nil, this is authoritative —
    /// callers should prefer it over any text accumulated via the `onResult` callback to
    /// avoid races where the final callback hadn't yet fired when stop returned.
    func stopTranscription() async -> String?

    /// End capture immediately without discarding audio needed for final inference.
    func pauseCapture()
}

extension STTEngineProtocol {
    var finalizationError: Error? { nil }
    var audioCaptureIssue: String? { nil }
    func pauseCapture() {} // Cloud engines finalize through their existing stop handshake.
}
