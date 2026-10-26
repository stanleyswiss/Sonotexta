import AVFoundation
import Foundation
import Security

/// ElevenLabs Scribe v2 Realtime STT — WebSocket streaming at ~150ms latency.
///
/// Wire shape (verbatim from the API reference and context7 official samples):
///   - URL: wss://api.elevenlabs.io/v1/speech-to-text/realtime?model_id=...&audio_format=pcm_16000&commit_strategy=vad&...
///   - Auth: xi-api-key header (works for native binaries; the single-use token
///     flow is only needed when the key would otherwise be exposed in browser JS).
///   - Each audio frame: JSON `{message_type:"input_audio_chunk", audio_base_64, commit:false, sample_rate:16000}`
///   - Server frames: `session_started`, `partial_transcript`, `committed_transcript`,
///     `committed_transcript_with_timestamps`, plus a family of `*_error` types.
///   - Stop: send a final frame with `audio_base_64:""` and `commit:true` to flush,
///     then normal WebSocket close. The empty+commit pattern is the docs-recommended
///     end-of-stream signal — no silence padding hack needed (unlike OpenAI's
///     translate endpoint which has no commit event).
///
/// Optional Vocabulary biasing: when `AppSettings.elevenLabsScribeUseKeyterms`
/// is on, the global glossary's canonical strings are passed as `keyterms[]`
/// query params so the STT model itself is biased toward those terms.
/// Capped at 50 entries × 20 chars per the server limit; biasing adds a 20%
/// premium to the per-minute cost.
final class ElevenLabsScribeRealtimeEngine: STTEngineProtocol {
    let engineType: STTEngineType = .elevenLabsScribe

    var isAvailable: Bool { hasAPIKey }

    /// Profile-driven input-language hint. nil / "auto" → omit `language_code`
    /// (Scribe autodetects). Specific BCP-47 like "bg-BG" is reduced to "bg".
    var inputLanguageHint: String?

    private var urlSession: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private var audioEngine: AVAudioEngine?
    private var onResult: ((String, Bool) -> Void)?
    private var isTranscribing = false
    private var pendingCompletion = false
    /// Engine-owned accumulator across all committed segments. Returned
    /// authoritatively from stopTranscription so DictationManager doesn't have
    /// to race the final-callback queue.
    private var accumulatedFinalText = ""
    /// Most recent partial — used to fold trailing speech into the accumulator
    /// if the server never sends a final committed_transcript on stop.
    private var lastPartial = ""
    /// Exact text of the most recently appended committed segment. Used to
    /// dedup the case where the empty+commit:true flush on stop causes the
    /// server to re-emit the same segment VAD already delivered — observed
    /// in 3.13.2-beta.1 as duplicate text in the bubble.
    private var lastCommittedSegment = ""
    /// Observer for `AVAudioEngineConfigurationChange`. Retained for the
    /// lifetime of the capture session so the helper can re-arm AVAudioEngine
    /// when macOS flips the Bluetooth audio profile (A2DP → HFP/SCO) and
    /// stops the engine. Removed in cleanupSession.
    private var configChangeObserver: NSObjectProtocol?
    private var isRestartingCapture = false
    /// Cached converter + source format. Rebuilt only when `buffer.format`
    /// changes (Bluetooth profile flip, sample-rate change, route change).
    /// Mutated/read exclusively on `processingQueue`.
    private var cachedConverter: AVAudioConverter?
    private var cachedSourceFormat: AVAudioFormat?
    private let inputNormalizer = MicrophoneInputNormalizer(logLabel: "scribe")

    private let processingQueue = DispatchQueue(label: "com.voiceflow.scribe-audio", qos: .userInteractive)

    var audioCaptureIssue: String? { inputNormalizer.captureIssue }

    // MARK: - API Key (Keychain)

    private var hasAPIKey: Bool {
        guard let key = apiKey, !key.isEmpty else { return false }
        return true
    }

    var apiKey: String? {
        get {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: KeychainConstants.service,
                kSecAttrAccount as String: "elevenlabs",
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var result: AnyObject?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                  let data = result as? Data,
                  let string = String(data: data, encoding: .utf8) else { return nil }
            return string
        }
        set {
            let deleteQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: KeychainConstants.service,
                kSecAttrAccount as String: "elevenlabs",
            ]
            SecItemDelete(deleteQuery as CFDictionary)

            if let key = newValue, !key.isEmpty {
                let data = key.data(using: .utf8)!
                let addQuery: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: KeychainConstants.service,
                    kSecAttrAccount as String: "elevenlabs",
                    kSecValueData as String: data,
                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                ]
                SecItemAdd(addQuery as CFDictionary, nil)
            }
        }
    }

    // MARK: - STTEngineProtocol

    func startTranscription(locale: Locale, onResult: @escaping (String, Bool) -> Void) async throws {
        guard let key = apiKey, !key.isEmpty else {
            throw ElevenLabsScribeError.noAPIKey
        }

        await cleanupSession()

        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if micStatus != .authorized {
            if micStatus == .notDetermined {
                guard await AVCaptureDevice.requestAccess(for: .audio) else {
                    throw ElevenLabsScribeError.micPermissionDenied
                }
            } else {
                throw ElevenLabsScribeError.micPermissionDenied
            }
        }

        self.onResult = onResult
        self.isTranscribing = true
        self.pendingCompletion = false
        self.accumulatedFinalText = ""
        self.inputNormalizer.reset()
        self.lastPartial = ""
        self.lastCommittedSegment = ""

        let tStart = Date()
        print("[VoiceFlow][scribe-start] T0 begin")

        try connectWebSocket(apiKey: key)
        print("[VoiceFlow][scribe-start] T1 ws connected (+\(String(format: "%.3f", Date().timeIntervalSince(tStart)))s)")

        // Wrap audio startup in a 10s race so a hung audio unit (notably with
        // freshly-switched Bluetooth devices like AirPods/Headphones) surfaces
        // as a clear error instead of leaving the UI stuck on "Loading...".
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                try await self?.startAudioCapture()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw ElevenLabsScribeError.audioStartupTimeout
            }
            try await group.next()
            group.cancelAll()
        }
        print("[VoiceFlow][scribe-start] T2 audio capture started (+\(String(format: "%.3f", Date().timeIntervalSince(tStart)))s)")

        #if DEBUG
        print("[VoiceFlow] ElevenLabs Scribe engine started")
        #endif
    }

    func stopTranscription() async -> String? {
        guard isTranscribing else {
            return accumulatedFinalText.isEmpty ? nil : accumulatedFinalText
        }

        // 1. Stop audio capture so no new frames enter the pipeline.
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            audioEngine = nil
        }

        // Reset BEFORE the flush so a committed_transcript arriving during the
        // drain sticks instead of being clobbered. Same lesson as the
        // OpenAIRealtimeEngine stop-as-pause sequence.
        pendingCompletion = false

        // 2. Drain queued audio chunks so anything the tap already enqueued
        //    finishes its convert → base64 → send before we tell the server
        //    "you have everything."
        processingQueue.sync { /* drain */ }

        // 3. Send the docs-recommended end-of-stream signal: empty audio +
        //    commit:true. Unlike the OpenAI GA endpoint (no commit event,
        //    needs silence padding), Scribe has explicit commit semantics.
        sendJSON([
            "message_type": "input_audio_chunk",
            "audio_base_64": "",
            "commit": true,
            "sample_rate": 16000,
        ])

        // 4. Wait up to 8s for the final committed_transcript to land. The
        //    translate engine uses a similar 3-12s slider range — 8s is a
        //    reasonable middle ground for Scribe which has lower stop latency.
        //    5s was too short in 3.13.2-beta.1 for long Bulgarian utterances.
        let waitStart = Date()
        while !pendingCompletion && Date().timeIntervalSince(waitStart) < 8.0 {
            try? await Task.sleep(for: .milliseconds(100))
        }

        if !pendingCompletion {
            // Fallback: server never produced a committed_transcript. Promote
            // the most recent partial so the user's words aren't lost.
            let trailing = lastPartial.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trailing.isEmpty {
                if !accumulatedFinalText.isEmpty {
                    accumulatedFinalText += " "
                }
                accumulatedFinalText += trailing
                let cumulative = accumulatedFinalText
                DispatchQueue.main.async { [weak self] in
                    self?.onResult?(cumulative, true)
                }
                #if DEBUG
                print("[VoiceFlow] Scribe trailing partial folded into final")
                #endif
            }
        }

        let finalText = accumulatedFinalText.trimmingCharacters(in: .whitespacesAndNewlines)

        await cleanupSession()
        #if DEBUG
        print("[VoiceFlow] ElevenLabs Scribe engine stopped")
        #endif
        return finalText.isEmpty ? nil : finalText
    }

    private func cleanupSession() async {
        isTranscribing = false

        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }

        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            audioEngine = nil
        }

        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil

        pendingCompletion = false
        accumulatedFinalText = ""
        lastPartial = ""
        lastCommittedSegment = ""
        onResult = nil
        isRestartingCapture = false

        // Drop the converter cache so the next session rebuilds it against
        // whatever native format the new AVAudioEngine produces.
        processingQueue.sync {
            self.cachedConverter = nil
            self.cachedSourceFormat = nil
        }
    }

    // MARK: - Language mapping

    /// Convert a profile input-language hint into a `language_code` query param.
    /// Returns nil when no specific language is requested → Scribe autodetects.
    static func scribeLanguageParam(forHint hint: String?) -> String? {
        guard let raw = hint?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, raw.lowercased() != "auto" else {
            return nil
        }
        let lower = raw.lowercased()
        if let dash = lower.firstIndex(of: "-") {
            return String(lower[..<dash])
        }
        return String(lower.prefix(2))
    }

    /// Clamp the glossary down to the Scribe keyterm limit: 50 entries × 20 chars.
    /// Longer canonicals are truncated; the order is preserved so the most
    /// recently added Vocabulary entries (which are usually the most relevant)
    /// stay in scope.
    static func keytermsForGlossary(_ entries: [GlossaryEntry]) -> [String] {
        entries
            .map { $0.canonical.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(50)
            .map { String($0.prefix(20)) }
    }

    // MARK: - WebSocket

    private func connectWebSocket(apiKey: String) throws {
        let model = AppSettings.shared.selectedElevenLabsScribeModel.rawValue

        var components = URLComponents(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime")!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "model_id", value: model),
            URLQueryItem(name: "audio_format", value: "pcm_16000"),
            URLQueryItem(name: "commit_strategy", value: "vad"),
            // VAD tuning matches the rest of the app's "1.2-1.5s of silence
            // ends an utterance" default. Min speech/silence durations stay at
            // server defaults (100ms each).
            URLQueryItem(name: "vad_silence_threshold_secs", value: "1.5"),
            URLQueryItem(name: "vad_threshold", value: "0.4"),
            // Max inactivity timeout (180s) so a brief pause mid-dictation
            // doesn't kill the session. Confirmed applies to STT endpoint.
            URLQueryItem(name: "inactivity_timeout", value: "180"),
            // Keep verbatim — dictation wants exactly what the user said.
            URLQueryItem(name: "no_verbatim", value: "false"),
        ]

        if let lang = Self.scribeLanguageParam(forHint: inputLanguageHint) {
            items.append(URLQueryItem(name: "language_code", value: lang))
        }

        // Opt-in keyterm biasing — adds 20% to the per-minute cost server-side.
        // Off by default so users don't get surprise billing.
        if AppSettings.shared.elevenLabsScribeUseKeyterms {
            let terms = Self.keytermsForGlossary(AppSettings.shared.glossary)
            for term in terms {
                items.append(URLQueryItem(name: "keyterms", value: term))
            }
            #if DEBUG
            print("[VoiceFlow] Scribe keyterms enabled (\(terms.count) terms, +20% billing)")
            #endif
        }

        components.queryItems = items
        guard let url = components.url else {
            throw ElevenLabsScribeError.invalidURL
        }

        #if DEBUG
        print("[VoiceFlow] Scribe URL model=\(model) lang=\(Self.scribeLanguageParam(forHint: inputLanguageHint) ?? "auto")")
        #endif

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")

        let session = URLSession(configuration: .default)
        self.urlSession = session
        let task = session.webSocketTask(with: request)
        self.webSocketTask = task
        task.resume()

        receiveMessages()
    }

    private func sendJSON(_ dict: [String: Any]) {
        guard let task = webSocketTask,
              let data = try? JSONSerialization.data(withJSONObject: dict),
              let string = String(data: data, encoding: .utf8) else { return }
        task.send(.string(string)) { _ in }
    }

    private func receiveMessages() {
        guard isTranscribing, let task = webSocketTask else { return }

        task.receive { [weak self] result in
            guard let self, self.isTranscribing else { return }

            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleMessage(text)
                    }
                @unknown default:
                    break
                }
                self.receiveMessages()

            case .failure(let error):
                #if DEBUG
                print("[VoiceFlow] Scribe receive error: \(error.localizedDescription)")
                #endif
                self.isTranscribing = false
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["message_type"] as? String else { return }

        switch type {
        case "session_started":
            #if DEBUG
            print("[VoiceFlow] Scribe session started")
            #endif

        case "partial_transcript":
            let transcript = (json["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty else { return }
            // Skip a partial that's exactly the last committed segment — Scribe
            // occasionally emits one as the server transitions between
            // utterances, and showing it as a live partial would render the
            // same text twice in the bubble.
            if transcript == lastCommittedSegment { return }
            lastPartial = transcript
            let liveText = accumulatedFinalText.isEmpty
                ? transcript
                : accumulatedFinalText + " " + transcript
            DispatchQueue.main.async { [weak self] in
                self?.onResult?(liveText, false)
            }

        case "committed_transcript", "committed_transcript_with_timestamps":
            // Both shapes carry `text`; the timestamps variant adds `words[]`
            // which we don't need for dictation.
            let transcript = (json["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty else {
                // Server can fire an empty committed event on the final
                // empty-audio commit:true flush — treat as utterance boundary.
                if audioEngine == nil { pendingCompletion = true }
                return
            }
            // Dedup: the empty+commit:true flush on stop can cause the server
            // to re-emit the same segment VAD had already committed earlier.
            // Compare against the most recently appended segment verbatim.
            if transcript == lastCommittedSegment {
                #if DEBUG
                print("[VoiceFlow] Scribe duplicate committed dropped: \(transcript.prefix(40))…")
                #endif
                if audioEngine == nil { pendingCompletion = true }
                return
            }
            if !accumulatedFinalText.isEmpty {
                accumulatedFinalText += " "
            }
            accumulatedFinalText += transcript
            lastCommittedSegment = transcript
            lastPartial = ""
            let cumulative = accumulatedFinalText
            DispatchQueue.main.async { [weak self] in
                self?.onResult?(cumulative, true)
            }
            // If audio capture is already stopped, signal we're done waiting.
            if audioEngine == nil {
                pendingCompletion = true
            }

        // Fatal errors — the session can't recover. Bail so the user sees
        // the failure and can retry. Unblock stopTranscription if it's waiting.
        case "auth_error",
             "quota_exceeded",
             "unaccepted_terms",
             "rate_limited",
             "resource_exhausted",
             "session_time_limit_exceeded":
            let message = json["error"] as? String ?? type
            print("[VoiceFlow] Scribe FATAL error (\(type)): \(message)")
            isTranscribing = false
            pendingCompletion = true

        // Continuable / transient errors — log but keep the session alive.
        // Killing the WebSocket here was the 3.13.2-beta.1 cause of lost
        // messages mid-utterance, especially on long Bulgarian sentences
        // where the server temporarily flagged commit_throttled.
        case "commit_throttled",
             "transcriber_error",
             "input_error",
             "error",
             "queue_overflow",
             "chunk_size_exceeded",
             "insufficient_audio_activity":
            let message = json["error"] as? String ?? type
            print("[VoiceFlow] Scribe transient (\(type)): \(message) — continuing")

        default:
            break
        }
    }

    // MARK: - Audio Capture

    private func startAudioCapture() async throws {
        let engine = AVAudioEngine()
        let tCap = Date()
        print("[VoiceFlow][scribe-audio] A0 engine created")

        // Configure shared mic BEFORE installing tap — voice processing changes audio format
        AudioSessionHelper.configureSharedInput(for: engine)
        print("[VoiceFlow][scribe-audio] A1 input configured (+\(String(format: "%.3f", Date().timeIntervalSince(tCap)))s)")

        let inputNode = engine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)
        print("[VoiceFlow][scribe-audio] A2 native format: \(Int(nativeFormat.sampleRate))Hz × \(nativeFormat.channelCount)ch")

        // Defensive: a freshly-switched Bluetooth device (AirPods, Headphones)
        // sometimes reports a zero sample rate or zero channels for a brief
        // window before the audio unit fully initializes. Bail with a clear
        // error rather than passing the invalid format into the converter.
        guard nativeFormat.sampleRate > 0 && nativeFormat.channelCount > 0 else {
            throw ElevenLabsScribeError.audioFormatNotReady(
                rate: nativeFormat.sampleRate,
                channels: Int(nativeFormat.channelCount)
            )
        }

        // Scribe accepts 8/16/22.05/24/44.1/48 kHz PCM. We match Deepgram's
        // 16kHz PCM16 mono pattern — well within Scribe's pcm_16000 enum.
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        ) else {
            throw ElevenLabsScribeError.audioFormatError
        }

        // Reset converter cache for a fresh session — a new AVAudioEngine
        // instance may produce a different native format than the last one.
        processingQueue.sync {
            self.cachedConverter = nil
            self.cachedSourceFormat = nil
        }

        inputNode.removeTap(onBus: 0) // defensive
        try installTap(on: engine, targetFormat: targetFormat)
        print("[VoiceFlow][scribe-audio] A3 tap installed (+\(String(format: "%.3f", Date().timeIntervalSince(tCap)))s)")

        // Re-arm against system IO reconfigurations BEFORE starting. The
        // Bluetooth A2DP → HFP profile flip is the canonical case but the
        // same observer also handles route changes, sample-rate changes,
        // and headphone plug/unplug events. Without this, AVAudioEngine
        // silently stops itself and the user sees "Listening..." forever.
        configChangeObserver = AudioSessionHelper.installReconfigObserver(
            for: engine,
            engineName: "scribe",
            isActive: { [weak self] in self?.isTranscribing ?? false },
            setupTap: { [weak self] reconfigEngine in
                guard let self else { return }
                try self.installTap(on: reconfigEngine, targetFormat: targetFormat)
            },
            onFatal: { [weak self] in
                Task { await self?.restartCapture() }
            }
        )

        try await AudioSessionHelper.startEngine(engine)
        self.audioEngine = engine
        print("[VoiceFlow][scribe-audio] A4 engine running (+\(String(format: "%.3f", Date().timeIntervalSince(tCap)))s)")
    }

    /// Install the input tap with `format: nil` — AVAudioEngine uses the
    /// bus's current format implicitly, which eliminates the stale-format
    /// race during Bluetooth A2DP→HFP profile flips. The downsample
    /// converter is built / refreshed per-buffer against `buffer.format`
    /// inside `convertAndSend`.
    private func installTap(on engine: AVAudioEngine, targetFormat: AVAudioFormat) throws {
        engine.inputNode.installTap(onBus: 0, bufferSize: 4800, format: nil) { [weak self] buffer, _ in
            guard let self, self.isTranscribing else { return }
            self.processingQueue.async {
                self.convertAndSend(buffer: buffer, targetFormat: targetFormat)
            }
        }
    }

    private func restartCapture() async {
        print("[Sonotexta][scribe] restartCapture enter")
        guard isTranscribing else {
            print("[Sonotexta][scribe] restartCapture skipped because capture is inactive")
            return
        }
        guard !isRestartingCapture else {
            print("[Sonotexta][scribe] restartCapture already in progress")
            return
        }

        isRestartingCapture = true
        defer {
            isRestartingCapture = false
            print("[Sonotexta][scribe] restartCapture exit")
        }

        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }

        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            audioEngine = nil
        }

        do {
            try await startAudioCapture()
        } catch {
            print("[Sonotexta][scribe] restartCapture failed: \(error.localizedDescription)")
        }
    }

    /// Convert a captured buffer to 16kHz PCM16 mono and send as a
    /// `input_audio_chunk` frame. The converter is cached per source format
    /// and rebuilt only when the tap delivers a buffer whose format differs
    /// from the cached source (e.g. Bluetooth A2DP→HFP profile flip). Runs
    /// exclusively on `processingQueue`, so the cache fields need no lock.
    private func convertAndSend(buffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat) {
        let sourceBuffer: AVAudioPCMBuffer
        do {
            sourceBuffer = try inputNormalizer.normalize(buffer)
        } catch {
            print("[Sonotexta][scribe] Audio normalization failed: \(error.localizedDescription)")
            return
        }
        let sourceFormat = sourceBuffer.format

        if cachedConverter == nil || cachedSourceFormat != sourceFormat {
            guard let newConverter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
                print("[VoiceFlow][scribe] convertAndSend: failed to build converter for \(sourceFormat)")
                return
            }
            cachedConverter = newConverter
            cachedSourceFormat = sourceFormat
        }

        guard let converter = cachedConverter else { return }

        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
        guard outputFrameCount > 0 else { return }

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCount) else { return }

        var error: NSError?
        var inputConsumed = false
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }

        if error != nil { return }
        guard outputBuffer.frameLength > 0 else { return }

        let int16Ptr = outputBuffer.int16ChannelData![0]
        let byteCount = Int(outputBuffer.frameLength) * 2
        let data = Data(bytes: int16Ptr, count: byteCount)
        let base64 = data.base64EncodedString()

        // Per-frame wire shape from the API reference: message_type, audio
        // payload (base64), commit flag (false during streaming — VAD strategy
        // means the server decides when to commit), and sample_rate.
        let message: [String: Any] = [
            "message_type": "input_audio_chunk",
            "audio_base_64": base64,
            "commit": false,
            "sample_rate": 16000,
        ]
        sendJSON(message)
    }
}

// MARK: - Errors

enum ElevenLabsScribeError: LocalizedError {
    case noAPIKey
    case micPermissionDenied
    case invalidURL
    case audioFormatError
    case audioFormatNotReady(rate: Double, channels: Int)
    case audioStartupTimeout

    var errorDescription: String? {
        switch self {
        case .noAPIKey: return "No ElevenLabs API key configured. Add one in Settings → Engine."
        case .micPermissionDenied: return "Microphone access denied."
        case .invalidURL: return "Invalid ElevenLabs Scribe WebSocket URL."
        case .audioFormatError: return "Could not configure audio format for 16kHz PCM16."
        case .audioFormatNotReady(let rate, let channels):
            return "Microphone not ready (got \(Int(rate))Hz × \(channels)ch). If you just switched to a Bluetooth mic (AirPods, headset), wait a second and try again."
        case .audioStartupTimeout:
            return "Microphone took too long to start. Try switching to a different input device or restarting the app."
        }
    }
}
