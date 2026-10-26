import AVFoundation
import Foundation

final class OpenAITranslateEngine: STTEngineProtocol {
    let engineType: STTEngineType = .openAIRealtime

    /// Available when the user has their own OpenAI API key (BYOK, direct to
    /// OpenAI's translate endpoint).
    var isAvailable: Bool {
        !(LLMService.shared.apiKey ?? "").isEmpty
    }

    /// 2-letter ISO target language for translation output. Set by DictationManager
    /// before startTranscription.
    var targetLanguage: String = "en"
    /// Optional source-language hint (kept for symmetry; not yet sent to translate session).
    var inputLanguageHint: String?

    private var urlSession: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private var audioEngine: AVAudioEngine?
    private var onResult: ((String, Bool) -> Void)?
    private var isTranscribing = false
    /// AVAudioEngineConfigurationChange observer — re-arms after Bluetooth
    /// profile flips that auto-stop AVAudioEngine.
    private var configChangeObserver: NSObjectProtocol?
    private var isRestartingCapture = false
    /// Cached converter + source format. Rebuilt only when `buffer.format`
    /// changes (Bluetooth profile flip, sample-rate change, route change).
    /// Mutated/read exclusively on `processingQueue`.
    private var cachedConverter: AVAudioConverter?
    private var cachedSourceFormat: AVAudioFormat?
    private let inputNormalizer = MicrophoneInputNormalizer(logLabel: "openai-translate")

    private var partialTranscript = ""
    private var pendingCompletion = false
    private var accumulatedFinalText = ""
    /// Wall-clock of the most recent server event of ANY kind. Cheap "is the
    /// pipe alive" signal used during the pre-start phase of stop.
    private var lastServerEventAt: Date = .distantPast
    /// Wall-clock of the most recent `session.input_transcript.delta` or `.done`.
    /// The translate endpoint may emit these as the model finishes ingesting
    /// trailing source audio, before output translation deltas land. We track
    /// it so the stop wait can require BOTH input AND output streams to be
    /// quiet — otherwise we'd exit while the model is still processing the
    /// last few words and lose them. (3.12.0-beta.6)
    private var lastInputTranscriptEventAt: Date = .distantPast
    /// Wall-clock of the most recent `session.output_transcript.delta` or `.done`.
    /// Used as the primary "translation is still being produced" signal during
    /// stop. Stop only considers exiting via the both-streams-quiet path AFTER
    /// at least one output delta has arrived post-stop. (3.12.0-beta.6)
    private var lastOutputTranscriptDeltaAt: Date = .distantPast

    private let processingQueue = DispatchQueue(label: "com.voiceflow.translate-audio", qos: .userInteractive)

    var audioCaptureIssue: String? { inputNormalizer.captureIssue }

    // MARK: - STTEngineProtocol

    func startTranscription(locale: Locale, onResult: @escaping (String, Bool) -> Void) async throws {
        // BYOK only: the user's own OpenAI key is required.
        let apiKey = LLMService.shared.apiKey ?? ""
        if apiKey.isEmpty {
            throw OpenAIRealtimeError.noAPIKey
        }

        await cleanupSession()

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
        self.accumulatedFinalText = ""
        self.inputNormalizer.reset()
        self.isTranscribing = true

        try connectWebSocket(apiKey: apiKey)
        try await startAudioCapture()

        print("[VoiceFlow] OpenAI Translate engine started (target: \(targetLanguage))")
    }

    func stopTranscription() async -> String? {
        guard isTranscribing else {
            print("[VoiceFlow] OpenAI Translate engine already stopped")
            return accumulatedFinalText.isEmpty ? nil : accumulatedFinalText
        }

        let tStop = Date()
        print("[VoiceFlow][translate-stop] T0 stop pressed @ \(tStop.timeIntervalSince1970)")

        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            audioEngine = nil
        }

        // CORRECTNESS (3.11.0): reset `pendingCompletion` BEFORE the silence-
        // padding loop. If a `session.output_transcript.done` arrives during
        // the padding (handler sets pendingCompletion=true when audioEngine is
        // nil), a post-padding reset would clobber the signal and we'd fall
        // back to the partial-fold path even though the server already
        // finalized. Reset here so any concurrent `done` sticks.
        pendingCompletion = false

        // ROOT-CAUSE FIX (3.10.3): drain `processingQueue` before sending
        // commit. AVAudioEngine.stop() halts the tap callback but chunks
        // already enqueued on processingQueue convert + base64 + send
        // asynchronously. Without this sync barrier, commit is sent while
        // the last ~200-400ms of audio is still in our local pipeline —
        // server commits without it and the trailing word gets dropped.
        processingQueue.sync { /* drain */ }
        print("[VoiceFlow] Translate pipeline drained, flushing server buffer...")

        // Continuous-silence flush mode (3.12.0-beta.6).
        //
        // Background: gpt-realtime-translate is a continuous-stream endpoint
        // with no client-side commit/finalize event. The model translates
        // audio it has ingested, emits output deltas, and keeps doing so as
        // long as audio (including silence) keeps flowing. Earlier betas sent
        // a one-shot 1s burst of silence and then waited; that wasn't enough
        // to push the model past the trailing source audio, so words spoken
        // right before stop sometimes never got translated and were lost.
        //
        // New strategy: keep the WS open and KEEP SENDING silence chunks at
        // a 200ms cadence for up to `silenceCap` seconds. This guarantees
        // the model sees enough trailing zero audio to finish ingesting and
        // emit translation deltas for the trailing real audio. Then we exit
        // when BOTH the input-transcript stream AND the output-transcript
        // stream have been quiet for `bothStreamsQuiet` seconds (the model
        // has finished both ingesting and translating), or when `.done`
        // arrives (rare on this endpoint), or on `hardCap` for stuck cases.
        //
        // Critical: we do NOT exit on output-only quiet. The model can be
        // mid-ingestion (input_transcript flowing) without yet emitting
        // output deltas — exiting then loses translation that's still
        // in-flight.
        let silenceFrames = 4800                      // 200 ms at 24 kHz
        let silenceBytesPerChunk = silenceFrames * 2  // Int16 = 2 bytes
        let silenceData = Data(count: silenceBytesPerChunk)
        let silenceBase64 = silenceData.base64EncodedString()

        let preStartTimeout: TimeInterval = 3.0       // bail fast if NO event at all post-stop
        let bothStreamsQuiet: TimeInterval = 1.5      // both input+output quiet → translation settled
        let silenceInterval: TimeInterval = 0.2       // pump silence every 200ms
        let silenceCap: TimeInterval = 5.0            // stop sending silence after 5s
        let hardCap: TimeInterval = max(3.0, min(AppSettings.shared.translateStopWaitSeconds, 12.0))

        let stopMarker = tStop
        let waitStart = Date()
        var lastSilenceSentAt = Date.distantPast
        var silenceChunksSent = 0
        var outputFlowingPostStop = false

        while !pendingCompletion {
            try? await Task.sleep(for: .milliseconds(50))
            let now = Date()
            let total = now.timeIntervalSince(waitStart)

            // Continuous silence pump.
            if total < silenceCap && now.timeIntervalSince(lastSilenceSentAt) >= silenceInterval {
                sendJSON(["type": "session.input_audio_buffer.append",
                          "audio": silenceBase64])
                lastSilenceSentAt = now
                silenceChunksSent += 1
            }

            if total >= hardCap {
                print("[VoiceFlow][translate-stop] T2 hardCap (\(String(format: "%.1f", hardCap))s) hit, silenceChunks=\(silenceChunksSent) — exit:hard-cap")
                break
            }

            if !outputFlowingPostStop {
                // Phase A: waiting for the FIRST output delta after stop.
                if lastOutputTranscriptDeltaAt > stopMarker {
                    outputFlowingPostStop = true
                    let delay = now.timeIntervalSince(stopMarker)
                    print("[VoiceFlow][translate-stop] first post-stop output delta @+\(String(format: "%.3f", delay))s — watching for both-streams-quiet or done")
                } else if total >= preStartTimeout && lastServerEventAt <= stopMarker {
                    // Truly no events from the server in preStartTimeout — pipe
                    // is silent, server has nothing to say. Don't keep waiting.
                    print("[VoiceFlow][translate-stop] T2 no events in \(preStartTimeout)s — exit:no-post-stop-events")
                    break
                }
                // Else: server is doing SOMETHING (input transcripts flowing) but
                // hasn't emitted a translation delta yet — keep waiting and pumping.
            } else {
                // Phase B: output started flowing. Exit only when BOTH streams
                // have been quiet for bothStreamsQuiet. The input-stream timestamp
                // stays at .distantPast if the endpoint never emits input transcripts,
                // making `sinceInput` permanently large — that case reduces to a
                // pure output-stream quiet check, same as before.
                let sinceInput = now.timeIntervalSince(lastInputTranscriptEventAt)
                let sinceOutput = now.timeIntervalSince(lastOutputTranscriptDeltaAt)
                if sinceInput >= bothStreamsQuiet && sinceOutput >= bothStreamsQuiet {
                    print("[VoiceFlow][translate-stop] T2 both streams quiet (in:+\(String(format: "%.2f", sinceInput))s out:+\(String(format: "%.2f", sinceOutput))s), silenceChunks=\(silenceChunksSent) — exit:both-streams-quiet")
                    break
                }
            }
        }

        // Promote `partialTranscript` to final if the model finished mid-turn
        // (no `.done`) but produced output deltas. This is the normal exit
        // path on this endpoint, not a fallback — `gpt-realtime-translate`
        // rarely emits explicit done events.
        if !pendingCompletion {
            let trailing = partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trailing.isEmpty {
                if !accumulatedFinalText.isEmpty {
                    accumulatedFinalText += " "
                }
                accumulatedFinalText += trailing
                print("[VoiceFlow][translate-stop] partial promoted to final (len=\(trailing.count))")
            } else {
                print("[VoiceFlow][translate-stop] no trailing partial, returning accumulated only (len=\(accumulatedFinalText.count))")
            }
        } else {
            print("[VoiceFlow][translate-stop] T2 .done event received — exit:done")
        }

        let finalText = accumulatedFinalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let totalElapsed = Date().timeIntervalSince(tStop)
        print("[VoiceFlow][translate-stop] T3 finalText.length=\(finalText.count) totalStopElapsed=\(String(format: "%.3f", totalElapsed))s")
        await cleanupSession()
        print("[VoiceFlow] OpenAI Translate engine stopped")
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

        partialTranscript = ""
        pendingCompletion = false
        accumulatedFinalText = ""
        lastServerEventAt = .distantPast
        lastInputTranscriptEventAt = .distantPast
        lastOutputTranscriptDeltaAt = .distantPast
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
        print("[VoiceFlow][translate] route=direct")

        guard let url = URL(string: "wss://api.openai.com/v1/realtime/translations?model=gpt-realtime-translate") else {
            throw OpenAIRealtimeError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let session = URLSession(configuration: .default)
        self.urlSession = session
        let task = session.webSocketTask(with: request)
        self.webSocketTask = task
        task.resume()

        sendSessionConfig()
        receiveMessages()
    }

    private func sendSessionConfig() {
        let outLang = String(targetLanguage.prefix(2))
        // ONLY `audio.output.language` is valid for a translation session.
        //
        // REGRESSION FIX (post-3.16.1): the 3.14.0 "P1.4" change added
        // `audio.input.language` here to pin the source language. But the
        // OpenAI translation-session schema has NO such field — the only valid
        // keys under `audio.input` are `transcription` (an object: {model}) and
        // `noise_reduction`. The Realtime API rejects the entire `session.update`
        // when it sees an unknown parameter, which meant `output.language` was
        // ALSO dropped and the model fell back to its default output language
        // (observed: Spanish). This only triggered for profiles that PIN an
        // input language (e.g. "English → German"); input=auto omitted the bad
        // field and translated correctly, which made the bug look random.
        //
        // The translate model auto-detects the source language from the audio
        // stream — there is no supported way to pin it. (`input.transcription.model`
        // only requests source-transcript deltas, which we don't surface.) So we
        // send output-language only, exactly as pre-3.14.0 did.
        let audio: [String: Any] = [
            "output": ["language": outLang]
        ]
        let config: [String: Any] = [
            "type": "session.update",
            "session": ["audio": audio]
        ]
        sendJSON(config)
        print("[VoiceFlow] OpenAI Translate session config sent (output: \(outLang); source auto-detected)")
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
                self.receiveMessages()

            case .failure(let error):
                print("[VoiceFlow] Translate WebSocket receive error: \(error.localizedDescription)")
                self.isTranscribing = false
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {
        case "session.created":
            print("[VoiceFlow] Translate session created")

        case "session.updated":
            print("[VoiceFlow] Translate session configured")

        case "session.output_transcript.delta":
            let now = Date()
            lastServerEventAt = now
            lastOutputTranscriptDeltaAt = now
            let delta = json["delta"] as? String ?? ""
            partialTranscript += delta
            let partial = partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !partial.isEmpty {
                let liveText = accumulatedFinalText.isEmpty
                    ? partial
                    : accumulatedFinalText + " " + partial
                DispatchQueue.main.async { [weak self] in
                    self?.onResult?(liveText, false)
                }
            }

        case "session.output_transcript.done":
            let now = Date()
            lastServerEventAt = now
            lastOutputTranscriptDeltaAt = now
            let transcript = json["transcript"] as? String ?? ""
            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                #if DEBUG
                print("[VoiceFlow] OpenAI Translate final turn: \(trimmed)")
                #endif
                if !accumulatedFinalText.isEmpty {
                    accumulatedFinalText += " "
                }
                accumulatedFinalText += trimmed
                let cumulative = accumulatedFinalText
                DispatchQueue.main.async { [weak self] in
                    self?.onResult?(cumulative, true)
                }
            }
            partialTranscript = ""
            if audioEngine == nil {
                pendingCompletion = true
            }

        case "session.input_transcript.delta", "session.input_transcript.done":
            // Source-language transcript — track its timing so the stop wait
            // can avoid exiting while the model is still ingesting trailing
            // source audio. We don't surface the source text to the user.
            let now = Date()
            lastServerEventAt = now
            lastInputTranscriptEventAt = now

        case "session.output_audio.delta":
            // Sonotexta is text-input; ignore translated audio frames.
            break

        case "error":
            let errorInfo = json["error"] as? [String: Any]
            let message = errorInfo?["message"] as? String ?? "Unknown error"
            print("[VoiceFlow] Translate API error: \(message)")

        default:
            break
        }
    }

    // MARK: - Audio Capture

    private func startAudioCapture() async throws {
        // Target format: 24kHz, PCM16, mono. The converter against this
        // target is rebuilt per-buffer on `processingQueue` whenever
        // `buffer.format` changes.
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
            engineName: "translate",
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
        print("[VoiceFlow] Translate audio capture started (target: 24000Hz PCM16)")
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
        print("[Sonotexta][translate] restartCapture enter")
        guard isTranscribing else {
            print("[Sonotexta][translate] restartCapture skipped because capture is inactive")
            return
        }
        guard !isRestartingCapture else {
            print("[Sonotexta][translate] restartCapture already in progress")
            return
        }

        isRestartingCapture = true
        defer {
            isRestartingCapture = false
            print("[Sonotexta][translate] restartCapture exit")
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
            print("[Sonotexta][translate] restartCapture failed: \(error.localizedDescription)")
        }
    }

    /// Convert a captured buffer to 24kHz PCM16 mono and send to OpenAI
    /// Translate as a base64 `session.input_audio_buffer.append` event. The
    /// converter is cached per source format and rebuilt only when the tap
    /// delivers a buffer whose format differs from the cached source. Runs
    /// exclusively on `processingQueue`, so the cache fields need no
    /// external lock.
    private func convertAndSend(buffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat) {
        let sourceBuffer: AVAudioPCMBuffer
        do {
            sourceBuffer = try inputNormalizer.normalize(buffer)
        } catch {
            print("[Sonotexta][translate] Audio normalization failed: \(error.localizedDescription)")
            return
        }
        let sourceFormat = sourceBuffer.format

        if cachedConverter == nil || cachedSourceFormat != sourceFormat {
            guard let newConverter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
                print("[VoiceFlow][translate] convertAndSend: failed to build converter for \(sourceFormat)")
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
            print("[VoiceFlow] Translate audio conversion error: \(error.localizedDescription)")
            return
        }

        guard outputBuffer.frameLength > 0,
              let int16Ptr = outputBuffer.int16ChannelData?[0] else { return }

        let byteCount = Int(outputBuffer.frameLength) * 2
        let data = Data(bytes: int16Ptr, count: byteCount)
        let base64 = data.base64EncodedString()

        // NOTE: translate endpoint uses `session.`-prefixed append, unlike /v1/realtime.
        let message: [String: Any] = [
            "type": "session.input_audio_buffer.append",
            "audio": base64
        ]
        self.sendJSON(message)
    }
}
