import AVFoundation
import Foundation
import Security

final class DeepgramEngine: STTEngineProtocol {
    let engineType: STTEngineType = .deepgram

    var isAvailable: Bool { hasAPIKey }

    /// Profile-driven input-language hint. Set by DictationManager before
    /// each `startTranscription`. "auto" / nil → Nova-3 multilingual mode
    /// (`language=multi`, with code-switching). A specific BCP-47 code like
    /// "bg-BG" is reduced to the 2-letter Deepgram code "bg".
    var inputLanguageHint: String?

    private var urlSession: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private var audioEngine: AVAudioEngine?
    private var onResult: ((String, Bool) -> Void)?
    private var isTranscribing = false
    private var pendingCompletion = false
    /// Engine-owned accumulator across all completed turns (Deepgram speech_final segments).
    /// Returned authoritatively from stopTranscription.
    private var accumulatedFinalText = ""
    /// AVAudioEngineConfigurationChange observer — re-arms after Bluetooth
    /// profile flips that auto-stop AVAudioEngine. Removed in cleanupSession.
    private var configChangeObserver: NSObjectProtocol?
    private var isRestartingCapture = false

    private let processingQueue = DispatchQueue(label: "com.voiceflow.deepgram-audio", qos: .userInteractive)

    /// Cached converter + its source format. Rebuilt only when the tap's
    /// `buffer.format` differs from `cachedSourceFormat` (Bluetooth profile
    /// flip, sample-rate change, route change). Mutated and read exclusively
    /// inside `processingQueue.async` blocks so no extra lock is needed.
    private var cachedConverter: AVAudioConverter?
    private var cachedSourceFormat: AVAudioFormat?
    private let inputNormalizer = MicrophoneInputNormalizer(logLabel: "deepgram")

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
                kSecAttrAccount as String: "deepgram",
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
            // Delete existing
            let deleteQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: KeychainConstants.service,
                kSecAttrAccount as String: "deepgram",
            ]
            SecItemDelete(deleteQuery as CFDictionary)

            if let key = newValue, !key.isEmpty {
                let data = key.data(using: .utf8)!
                let addQuery: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: KeychainConstants.service,
                    kSecAttrAccount as String: "deepgram",
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
            throw DeepgramError.noAPIKey
        }

        await cleanupSession()

        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if micStatus != .authorized {
            if micStatus == .notDetermined {
                guard await AVCaptureDevice.requestAccess(for: .audio) else {
                    throw DeepgramError.micPermissionDenied
                }
            } else {
                throw DeepgramError.micPermissionDenied
            }
        }

        self.onResult = onResult
        self.isTranscribing = true
        self.pendingCompletion = false
        self.accumulatedFinalText = ""
        self.inputNormalizer.reset()

        try connectWebSocket(apiKey: key)
        try await startAudioCapture()

        #if DEBUG
        print("[VoiceFlow] Deepgram engine started")
        #endif
    }

    func stopTranscription() async -> String? {
        guard isTranscribing else {
            return accumulatedFinalText.isEmpty ? nil : accumulatedFinalText
        }

        // Stop audio capture
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            audioEngine = nil
        }

        // Send CloseStream message to get final results
        pendingCompletion = false
        sendJSON(["type": "CloseStream"])

        // Wait for final transcript (up to 3 seconds)
        let waitStart = Date()
        while !pendingCompletion && Date().timeIntervalSince(waitStart) < 3.0 {
            try? await Task.sleep(for: .milliseconds(100))
        }

        // Snapshot before cleanup wipes the accumulator.
        let finalText = accumulatedFinalText.trimmingCharacters(in: .whitespacesAndNewlines)

        await cleanupSession()
        #if DEBUG
        print("[VoiceFlow] Deepgram engine stopped")
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

    /// Convert profile input-language hint into a Deepgram `language=` value.
    /// Nova-3: supports `multi` for code-switching across 10 streaming languages,
    /// or a specific 2-letter code for fixed-language mode (better accuracy).
    /// Nova-2: does not support `multi` — fall back to English when hint absent.
    static func deepgramLanguageParam(forHint hint: String?, model: DeepgramModel) -> String {
        guard let raw = hint?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, raw.lowercased() != "auto" else {
            // No specific language requested → multilingual for Nova-3, English for Nova-2.
            return model == .nova3 ? "multi" : "en"
        }
        // "bg-BG" → "bg", "ru-RU" → "ru", "zh-CN" → "zh". Deepgram uses 2-letter
        // codes for most languages.
        let lower = raw.lowercased()
        if let dash = lower.firstIndex(of: "-") {
            return String(lower[..<dash])
        }
        return String(lower.prefix(2))
    }

    // MARK: - WebSocket

    private func connectWebSocket(apiKey: String) throws {
        // Deepgram WebSocket URL with parameters
        let selectedModel = AppSettings.shared.selectedDeepgramModel
        let languageParam = Self.deepgramLanguageParam(forHint: inputLanguageHint, model: selectedModel)
        let urlString = "wss://api.deepgram.com/v1/listen?model=\(selectedModel.rawValue)&language=\(languageParam)&punctuate=true&interim_results=true&utterance_end_ms=1200&vad_events=true&encoding=linear16&sample_rate=16000&channels=1"
        #if DEBUG
        print("[VoiceFlow] Deepgram URL language=\(languageParam) (hint=\(inputLanguageHint ?? "nil"))")
        #endif

        guard let url = URL(string: urlString) else {
            throw DeepgramError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")

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

            case .failure:
                self.isTranscribing = false
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {
        case "Results":
            guard let channel = json["channel"] as? [String: Any],
                  let alternatives = channel["alternatives"] as? [[String: Any]],
                  let transcript = alternatives.first?["transcript"] as? String,
                  !transcript.isEmpty else { return }

            // is_final = this segment is finalized (won't change), speech_final = utterance boundary.
            // We commit to the accumulator only on speech_final to chunk by utterance.
            let speechFinal = json["speech_final"] as? Bool ?? false

            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }

            #if DEBUG
            print("[VoiceFlow] Deepgram \(speechFinal ? "final" : "partial"): \(trimmed)")
            #endif

            if speechFinal {
                // Append finalized utterance to engine-owned accumulator.
                if !accumulatedFinalText.isEmpty {
                    accumulatedFinalText += " "
                }
                accumulatedFinalText += trimmed
                let cumulative = accumulatedFinalText
                DispatchQueue.main.async { [weak self] in
                    self?.onResult?(cumulative, true)
                }
                if audioEngine == nil {
                    pendingCompletion = true
                }
            } else {
                // Live partial: prior committed turns + current in-progress segment.
                let liveText = accumulatedFinalText.isEmpty
                    ? trimmed
                    : accumulatedFinalText + " " + trimmed
                DispatchQueue.main.async { [weak self] in
                    self?.onResult?(liveText, false)
                }
            }

        case "Metadata":
            #if DEBUG
            print("[VoiceFlow] Deepgram session started")
            #endif

        case "UtteranceEnd":
            // Utterance boundary — signal final if audio already stopped
            if audioEngine == nil {
                pendingCompletion = true
            }

        default:
            break
        }
    }

    // MARK: - Audio Capture

    private func startAudioCapture() async throws {
        // Target: 16kHz, PCM16, mono (Deepgram preferred format). Built once
        // per session; the converter against this target is lazily (re)built
        // per-buffer on `processingQueue` whenever `buffer.format` changes.
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        ) else {
            throw DeepgramError.audioFormatError
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
            engineName: "deepgram",
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
        print("[Sonotexta][deepgram] restartCapture enter")
        guard isTranscribing else {
            print("[Sonotexta][deepgram] restartCapture skipped because capture is inactive")
            return
        }
        guard !isRestartingCapture else {
            print("[Sonotexta][deepgram] restartCapture already in progress")
            return
        }

        isRestartingCapture = true
        defer {
            isRestartingCapture = false
            print("[Sonotexta][deepgram] restartCapture exit")
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
            print("[Sonotexta][deepgram] restartCapture failed: \(error.localizedDescription)")
        }
    }

    /// Convert a captured buffer to 16kHz PCM16 mono and send to Deepgram.
    /// The converter is cached per source format and rebuilt only when the
    /// tap delivers a buffer whose format differs from the cached source —
    /// this covers Bluetooth profile flips and sample-rate changes without
    /// allocating a new converter on every callback. Runs exclusively on
    /// `processingQueue`, so the cache fields need no external lock.
    private func convertAndSend(buffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat) {
        let sourceBuffer: AVAudioPCMBuffer
        do {
            sourceBuffer = try inputNormalizer.normalize(buffer)
        } catch {
            print("[Sonotexta][deepgram] Audio normalization failed: \(error.localizedDescription)")
            return
        }
        let sourceFormat = sourceBuffer.format

        if cachedConverter == nil || cachedSourceFormat != sourceFormat {
            guard let newConverter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
                print("[Sonotexta][deepgram] convertAndSend: failed to build converter for \(sourceFormat)")
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
        guard outputBuffer.frameLength > 0,
              let int16Ptr = outputBuffer.int16ChannelData?[0] else { return }

        // Send raw PCM16 bytes directly (Deepgram accepts binary)
        let byteCount = Int(outputBuffer.frameLength) * 2
        let data = Data(bytes: int16Ptr, count: byteCount)

        webSocketTask?.send(.data(data)) { _ in }
    }
}

// MARK: - Errors

enum DeepgramError: LocalizedError {
    case noAPIKey
    case micPermissionDenied
    case invalidURL
    case audioFormatError

    var errorDescription: String? {
        switch self {
        case .noAPIKey: return "No Deepgram API key configured. Add one in Settings → Engine."
        case .micPermissionDenied: return "Microphone access denied."
        case .invalidURL: return "Invalid Deepgram WebSocket URL."
        case .audioFormatError: return "Could not configure audio format for 16kHz PCM16."
        }
    }
}
