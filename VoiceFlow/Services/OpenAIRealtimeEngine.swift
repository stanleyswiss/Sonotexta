import AVFoundation
import Foundation

final class OpenAIRealtimeEngine: STTEngineProtocol {
    let engineType: STTEngineType = .openAIRealtime

    /// Available when the user has their own OpenAI API key (BYOK, direct to
    /// OpenAI's Realtime endpoint). Checks the OpenAI key specifically, not
    /// the selected LLM provider's key — an Anthropic key can't open an
    /// OpenAI Realtime socket. Symmetric with OpenAITranslateEngine.isAvailable.
    var isAvailable: Bool {
        !(LLMService.shared.apiKey ?? "").isEmpty
    }

    private var urlSession: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private var audioEngine: AVAudioEngine?
    private var onResult: ((String, Bool) -> Void)?
    private var isTranscribing = false
    /// AVAudioEngineConfigurationChange observer — re-arms after Bluetooth
    /// profile flips that auto-stop AVAudioEngine. Retained for the lifetime
    /// of the capture session, removed in cleanupSession.
    private var configChangeObserver: NSObjectProtocol?
    private var isRestartingCapture = false
    /// Cached converter + source format. Rebuilt only when `buffer.format`
    /// changes (Bluetooth profile flip, sample-rate change, route change).
    /// Mutated/read exclusively on `processingQueue`.
    private var cachedConverter: AVAudioConverter?
    private var cachedSourceFormat: AVAudioFormat?
    private let inputNormalizer = MicrophoneInputNormalizer(logLabel: "openai-realtime")
    /// Optional input-language hint for the active model. Set by DictationManager
    /// before startTranscription. Sent as `languages: [hint]` in the session
    /// config (2026 models use the plural array field).
    var inputLanguageHint: String?

    /// Accumulated partial transcript for the current speech turn
    private var currentItemId: String?
    private var partialTranscript = ""
    /// Set to true when a completed event arrives after audio capture stopped
    private var pendingCompletion = false
    /// Engine-owned accumulator across all completed turns since startTranscription.
    /// Returned authoritatively from stopTranscription so callers don't have to
    /// race the final-event callback against the await on stop.
    private var accumulatedFinalText = ""

    private let processingQueue = DispatchQueue(label: "com.voiceflow.realtime-audio", qos: .userInteractive)

    var audioCaptureIssue: String? { inputNormalizer.captureIssue }

    // MARK: - STTEngineProtocol

    func startTranscription(locale: Locale, onResult: @escaping (String, Bool) -> Void) async throws {
        // BYOK only: the user's own OpenAI key is required.
        let apiKey = LLMService.shared.apiKey ?? ""
        if apiKey.isEmpty {
            throw OpenAIRealtimeError.noAPIKey
        }

        // Fully clean up any existing session first
        await cleanupSession()

        // Check microphone permission
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if micStatus != .authorized {
            if micStatus == .notDetermined {
                guard await AVCaptureDevice.requestAccess(for: .audio) else {
                    throw OpenAIRealtimeError.micPermissionDenied
                }
            } else {
                throw OpenAIRealtimeError.micPermissionDenied
            }
        }

        self.onResult = onResult
        self.partialTranscript = ""
        self.currentItemId = nil
        self.accumulatedFinalText = ""
        self.inputNormalizer.reset()
        self.isTranscribing = true

        // Connect WebSocket
        try connectWebSocket(apiKey: apiKey)

        // Start audio capture
        try await startAudioCapture()

        print("[VoiceFlow] OpenAI Realtime engine started")
    }

    func stopTranscription() async -> String? {
        guard isTranscribing else {
            print("[VoiceFlow] OpenAI Realtime engine already stopped")
            return accumulatedFinalText.isEmpty ? nil : accumulatedFinalText
        }

        let tStop = Date()
        print("[VoiceFlow][realtime-stop] T0 stop pressed @ \(tStop.timeIntervalSince1970)")

        // 1. Stop audio capture (no more new audio)
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            audioEngine = nil
        }

        // CORRECTNESS (3.11.0-beta.2): reset `pendingCompletion` BEFORE the
        // silence-padding burst so a `completed` event arriving during the
        // burst sticks instead of being clobbered by a post-burst reset.
        // Same lesson as the translate engine.
        pendingCompletion = false

        // 1b. Drain `processingQueue` so any audio chunks the tap callback
        // already enqueued get converted + base64'd + sent over the WS BEFORE
        // we tell the server "you have everything". Without this barrier the
        // last ~200-400ms of speech is still in our local pipeline at commit
        // time and gets dropped from the transcription. Same fix as the
        // translate engine in 3.10.3.
        processingQueue.sync { /* drain */ }
        print("[VoiceFlow] Audio capture stopped, pipeline drained, sending end-of-speech silence...")

        // 1c. Stop-as-pause (3.11.0-beta.2). The server's VAD needs trailing
        // silence to mark the end of an utterance. If the user releases the
        // hotkey right after speaking — before the partial deltas have shown
        // up — abrupt commit gives the server no end-of-speech signal and
        // `conversation.item.input_audio_transcription.completed` never fires.
        // Send 1s of zero PCM16 (5x 200ms chunks) via the regular endpoint's
        // `input_audio_buffer.append` path BEFORE commit so the server has a
        // proper utterance boundary to finalize against. NOTE: regular endpoint
        // uses bare `input_audio_buffer.append` — DO NOT prefix with `session.`
        // (that's the translate-endpoint shape).
        let silenceFrames = 4800                      // 200 ms at 24 kHz
        let silenceBytesPerChunk = silenceFrames * 2  // Int16 = 2 bytes
        let silenceData = Data(count: silenceBytesPerChunk)
        let silenceBase64 = silenceData.base64EncodedString()
        for _ in 0..<5 {
            sendJSON(["type": "input_audio_buffer.append",
                      "audio": silenceBase64])
        }
        let tSilence = Date()
        print("[VoiceFlow][realtime-stop] T1 silence sent (+\(String(format: "%.3f", tSilence.timeIntervalSince(tStop)))s)")

        // 2. Commit the audio buffer so API processes remaining speech.
        // For regular transcription this `commit` is required — UNLIKE translate
        // which has no such event. Don't try to share the call sites.
        sendJSON(["type": "input_audio_buffer.commit"])

        // 3. Wait for final transcription to arrive (up to 5 seconds)
        //    The receive loop stays alive — isTranscribing is still true
        let waitStart = Date()
        while !pendingCompletion && Date().timeIntervalSince(waitStart) < 5.0 {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let tDone = Date()

        if pendingCompletion {
            print("[VoiceFlow][realtime-stop] T2 completed received (+\(String(format: "%.3f", tDone.timeIntervalSince(tStop)))s)")
        } else {
            print("[VoiceFlow][realtime-stop] T2 timed out (+\(String(format: "%.3f", tDone.timeIntervalSince(tStop)))s) — folding partial if any")
            // FALLBACK: server never fired `completed` (VAD timing edge case
            // or connection hiccup). If there's a non-empty partial sitting in
            // the buffer, promote it to final so the user's words aren't lost.
            let trailing = partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trailing.isEmpty {
                if !accumulatedFinalText.isEmpty {
                    accumulatedFinalText += " "
                }
                accumulatedFinalText += trailing
                let cumulative = accumulatedFinalText
                DispatchQueue.main.async { [weak self] in
                    self?.onResult?(cumulative, true)
                }
                print("[VoiceFlow] Realtime trailing partial folded into final")
            }
        }

        // Snapshot the final text BEFORE cleanup wipes the accumulator.
        let finalText = accumulatedFinalText.trimmingCharacters(in: .whitespacesAndNewlines)

        // 4. Now fully clean up
        await cleanupSession()
        print("[VoiceFlow] OpenAI Realtime engine stopped")
        return finalText.isEmpty ? nil : finalText
    }

    /// Full cleanup of all resources — safe to call multiple times
    private func cleanupSession() async {
        isTranscribing = false

        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }

        // Stop audio capture if still running
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            audioEngine = nil
        }

        // Close WebSocket
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil

        // Invalidate URLSession to release all resources
        urlSession?.invalidateAndCancel()
        urlSession = nil

        partialTranscript = ""
        currentItemId = nil
        pendingCompletion = false
        accumulatedFinalText = ""
        onResult = nil
        isRestartingCapture = false

        // Drop the converter cache so the next session rebuilds it against
        // whatever native format the new AVAudioEngine produces.
        processingQueue.sync {
            self.cachedConverter = nil
            self.cachedSourceFormat = nil
        }
    }

    // MARK: - WebSocket

    private func connectWebSocket(apiKey: String) throws {
        // Direct to OpenAI with the user's own key (BYOK).
        print("[VoiceFlow][realtime] route=direct")

        guard let url = URL(string: "wss://api.openai.com/v1/realtime?intent=transcription") else {
            throw OpenAIRealtimeError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        // Realtime moved to GA — no OpenAI-Beta header.

        // Create and retain the URLSession
        let session = URLSession(configuration: .default)
        self.urlSession = session
        let task = session.webSocketTask(with: request)
        self.webSocketTask = task
        task.resume()

        // Send session configuration
        sendSessionConfig()

        // Start receiving messages
        receiveMessages()
    }

    private func sendSessionConfig() {
        let selectedModel = AppSettings.shared.selectedOpenAIRealtimeModel

        // GA `session.update` shape for ALL models. The legacy
        // `transcription_session.update` event is silently ignored on the GA
        // endpoint (no beta header), which left mini/transcribe with no
        // configured transcription model and produced empty results in 3.10.0.
        var transcription: [String: Any] = ["model": selectedModel.rawValue]

        // 2026 models take `languages` (plural, array of ISO 639-1) — the
        // singular `language` field belongs to the retired 4o lineup, and the
        // docs explicitly warn against sending both. One bad field rejects
        // the WHOLE session.update (see the 3.16.2 translate fix), so shape
        // matters here.
        if let hint = inputLanguageHint, !hint.isEmpty, hint != "auto" {
            transcription["languages"] = [String(hint.prefix(2))]
        }

        // Bias the model toward Vocabulary glossary canonicals via native
        // keyword hints — same effect as the ElevenLabs keyterms feature but
        // without the price premium. Capped at 50 terms to stay conservative.
        let keywords = AppSettings.shared.glossary
            .map { $0.canonical.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(50)
        if !keywords.isEmpty {
            transcription["keywords"] = Array(keywords)
        }

        // Latency knob unique to gpt-live-transcribe (minimal…xhigh). "low"
        // favors snappy deltas while keeping phrase grouping reasonable.
        if selectedModel == .liveTranscribe {
            transcription["delay"] = "low"
        }

        var input: [String: Any] = [
            "format": ["type": "audio/pcm", "rate": 24000],
            "transcription": transcription
        ]

        // gpt-transcribe commits per turn — keep our preferred 1.2s server-VAD
        // silence boundary so turns actually commit. Live Transcribe paces
        // itself (delay knob) and picks its own VAD, like the old
        // gpt-realtime-whisper path, which rejected turn_detection outright.
        if selectedModel == .transcribe {
            input["turn_detection"] = [
                "type": "server_vad",
                "threshold": 0.5,
                "prefix_padding_ms": 300,
                "silence_duration_ms": 1200
            ]
            input["noise_reduction"] = ["type": "near_field"]
        }

        let config: [String: Any] = [
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": ["input": input]
            ]
        ]

        sendJSON(config)
        print("[VoiceFlow] OpenAI Realtime session config sent (model: \(selectedModel.rawValue))")
    }

    private func sendJSON(_ dict: [String: Any]) {
        guard let task = webSocketTask,
              let data = try? JSONSerialization.data(withJSONObject: dict),
              let string = String(data: data, encoding: .utf8) else { return }
        task.send(.string(string)) { error in
            if let error {
                print("[VoiceFlow] WebSocket send error: \(error.localizedDescription)")
            }
        }
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
                // Continue receiving
                self.receiveMessages()

            case .failure(let error):
                print("[VoiceFlow] WebSocket receive error: \(error.localizedDescription)")
                // Connection lost — stop cleanly so user can retry
                self.isTranscribing = false
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {
        case "transcription_session.created", "session.created":
            print("[VoiceFlow] Realtime transcription session created")

        case "transcription_session.updated", "session.updated":
            print("[VoiceFlow] Realtime transcription session configured")

        case "input_audio_buffer.speech_started":
            // New speech turn — reset partial accumulator
            currentItemId = nil
            partialTranscript = ""
            print("[VoiceFlow] Speech detected")

        case "input_audio_buffer.speech_stopped":
            print("[VoiceFlow] Speech ended, processing...")

        case "conversation.item.input_audio_transcription.delta":
            // Streaming partial transcript
            let itemId = json["item_id"] as? String ?? ""
            let delta = json["delta"] as? String ?? ""

            if currentItemId != itemId {
                // New item — start fresh
                currentItemId = itemId
                partialTranscript = ""
            }
            partialTranscript += delta

            let partial = partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !partial.isEmpty {
                // Show cumulative live text: prior completed turns + the in-progress partial.
                let liveText = accumulatedFinalText.isEmpty
                    ? partial
                    : accumulatedFinalText + " " + partial
                DispatchQueue.main.async { [weak self] in
                    self?.onResult?(liveText, false)
                }
            }

        case "conversation.item.input_audio_transcription.completed":
            // Final transcript for this turn
            let transcript = json["transcript"] as? String ?? ""
            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                #if DEBUG
                print("[VoiceFlow] OpenAI Realtime final turn: \(trimmed)")
                #endif
                // Append to engine-owned accumulator. The callback delivers the FULL
                // cumulative text so the manager doesn't have to mirror the buffer.
                if !accumulatedFinalText.isEmpty {
                    accumulatedFinalText += " "
                }
                accumulatedFinalText += trimmed
                let cumulative = accumulatedFinalText
                DispatchQueue.main.async { [weak self] in
                    self?.onResult?(cumulative, true)
                }
            }
            // Reset for next turn
            currentItemId = nil
            partialTranscript = ""
            // If audio capture is already stopped (user pressed stop), signal we're done waiting
            if audioEngine == nil {
                pendingCompletion = true
            }

        case "error":
            let errorInfo = json["error"] as? [String: Any]
            let message = errorInfo?["message"] as? String ?? "Unknown error"
            print("[VoiceFlow] Realtime API error: \(message)")

        default:
            break
        }
    }

    // MARK: - Audio Capture

    private func startAudioCapture() async throws {
        // Target format: 24kHz, PCM16, mono. Built once per session; the
        // converter against this target is rebuilt per-buffer on
        // `processingQueue` whenever `buffer.format` changes.
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 24000,
            channels: 1,
            interleaved: true
        ) else {
            throw OpenAIRealtimeError.audioFormatError
        }

        // Reset converter cache for a fresh session — a new AVAudioEngine
        // instance may produce a different native format than the last one.
        processingQueue.sync {
            self.cachedConverter = nil
            self.cachedSourceFormat = nil
        }

        let engine = AVAudioEngine()
        AudioSessionHelper.configureSharedInput(for: engine)
        engine.inputNode.removeTap(onBus: 0)
        try installTap(on: engine, targetFormat: targetFormat)

        configChangeObserver = AudioSessionHelper.installReconfigObserver(
            for: engine,
            engineName: "openai-realtime",
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
        print("[VoiceFlow] Audio capture started (target: 24000Hz PCM16)")
    }

    /// Install the input tap with `format: nil` — AVAudioEngine uses the
    /// bus's current format implicitly, which eliminates the stale-format
    /// race during Bluetooth A2DP→HFP profile flips. The downsample
    /// converter is built / refreshed per-buffer against `buffer.format`.
    private func installTap(on engine: AVAudioEngine, targetFormat: AVAudioFormat) throws {
        engine.inputNode.installTap(onBus: 0, bufferSize: 4800, format: nil) { [weak self] buffer, _ in
            guard let self, self.isTranscribing else { return }
            self.processingQueue.async {
                self.convertAndSend(buffer: buffer, targetFormat: targetFormat)
            }
        }
    }

    private func restartCapture() async {
        print("[Sonotexta][openai-realtime] restartCapture enter")
        guard isTranscribing else {
            print("[Sonotexta][openai-realtime] restartCapture skipped because capture is inactive")
            return
        }
        guard !isRestartingCapture else {
            print("[Sonotexta][openai-realtime] restartCapture already in progress")
            return
        }

        isRestartingCapture = true
        defer {
            isRestartingCapture = false
            print("[Sonotexta][openai-realtime] restartCapture exit")
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
            print("[Sonotexta][openai-realtime] restartCapture failed: \(error.localizedDescription)")
        }
    }

    /// Convert a captured buffer to 24kHz PCM16 mono and send to OpenAI
    /// Realtime as a base64 `input_audio_buffer.append` event. The converter
    /// is cached per source format and rebuilt only when the tap delivers a
    /// buffer whose format differs from the cached source — this covers
    /// Bluetooth profile flips and sample-rate changes without allocating a
    /// new converter on every callback. Runs exclusively on
    /// `processingQueue`, so the cache fields need no external lock.
    private func convertAndSend(buffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat) {
        let sourceBuffer: AVAudioPCMBuffer
        do {
            sourceBuffer = try inputNormalizer.normalize(buffer)
        } catch {
            print("[Sonotexta][openai-realtime] Audio normalization failed: \(error.localizedDescription)")
            return
        }
        let sourceFormat = sourceBuffer.format

        if cachedConverter == nil || cachedSourceFormat != sourceFormat {
            guard let newConverter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
                print("[VoiceFlow][openai-realtime] convertAndSend: failed to build converter for \(sourceFormat)")
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

        if let error {
            print("[VoiceFlow] Audio conversion error: \(error.localizedDescription)")
            return
        }

        guard outputBuffer.frameLength > 0,
              let int16Ptr = outputBuffer.int16ChannelData?[0] else { return }

        let byteCount = Int(outputBuffer.frameLength) * 2  // 2 bytes per Int16 sample
        let data = Data(bytes: int16Ptr, count: byteCount)
        let base64 = data.base64EncodedString()

        // Send to WebSocket
        let message: [String: Any] = [
            "type": "input_audio_buffer.append",
            "audio": base64
        ]
        self.sendJSON(message)
    }
}

// MARK: - Errors

enum OpenAIRealtimeError: LocalizedError {
    case noAPIKey
    case micPermissionDenied
    case invalidURL
    case audioFormatError
    case connectionFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey: return "No OpenAI API key configured. Add one in Settings → AI."
        case .micPermissionDenied: return "Microphone access denied."
        case .invalidURL: return "Invalid Realtime API URL."
        case .audioFormatError: return "Could not configure audio format for 24kHz PCM16."
        case .connectionFailed(let msg): return "WebSocket connection failed: \(msg)"
        }
    }
}
