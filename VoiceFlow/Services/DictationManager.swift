import SwiftUI
import Combine

@MainActor
final class DictationManager: ObservableObject {
    @Published var isDictating = false
    @Published var currentTranscription = ""
    @Published var statusText = "Ready"

    let settings = AppSettings.shared
    let accessibilityService = AccessibilityService.shared
    let hotkeyService = HotkeyService()
    lazy var profileMatcher = ProfileMatcher(settings: settings)

    private let appleSpeechEngine = AppleSpeechEngine()
    let whisperEngine = WhisperEngine()
    let qwenEngine = QwenEngine()
let parakeetEngine = ParakeetEngine()
let parakeetRealtimeEngine = ParakeetRealtimeEngine()
    let openAIRealtimeEngine = OpenAIRealtimeEngine()
    let openAITranslateEngine = OpenAITranslateEngine()
    let deepgramEngine = DeepgramEngine()
    let elevenLabsScribeEngine = ElevenLabsScribeRealtimeEngine()
    private var modelObserver: AnyCancellable?
private var parakeetModelObserver: AnyCancellable?
private var parakeetRealtimeChunkObserver: AnyCancellable?
    private var isStarting = false
    private var isStopping = false
    /// True when AudioSessionHelper fell back to the system default input
    /// because the user's device override couldn't start (Tahoe C920-class
    /// -10868). Per-session; reset in startDictation. Drives the
    /// "(default mic)" suffix in the overlay status so the fallback is
    /// visible instead of silent.
    private var micFellBackThisSession = false
    private var micFallbackObserver: NSObjectProtocol?
    private var modelStorageObserver: NSObjectProtocol?
    /// 3.16.5: the hotkey binding that started the current session (nil when
    /// started from the menu). A binding with a pinned profile overrides
    /// app-detection for the WHOLE session, including the stop/deliver path.
    private var sessionBinding: HotkeyBinding?
    private var session: DictationSession?
    private var storageLease: ModelStorageActivity.Lease?
    /// 3.16.6: short description of the most recent AI post-processing
    /// failure, nil after a successful run. Surfaced in the menu bar and the
    /// overlay — two silent AI failures shipped in a row (preset truncation,
    /// Luna 400) precisely because this state used to vanish in a one-second
    /// status flash.
    @Published private(set) var lastAIFailure: String?
    /// The engine instance that startDictation actually started — used at stop time
    /// so we don't re-pick a different instance if profile state shifted mid-session.
    private var lastStartedEngine: STTEngineProtocol?
    /// Target app frozen at startDictation(). The translate path's stop window
    /// (silence padding + slider quiescence + AI cleanup) is long enough that
    /// app activations during the gap (Slack toasts, focus-stealing windows)
    /// can flip AccessibilityService.lastTargetApp mid-dictation, redirecting
    /// the paste. We snapshot once at start and pass it explicitly to
    /// insertText at delivery time. Cleared in deliverText after delivery.
    private var sessionTargetApp: NSRunningApplication?
    private lazy var overlay: DictationOverlayController = {
        let o = DictationOverlayController()
        o.onStop = { [weak self] in
            self?.stopDictation()
        }
        return o
    }()

    private var activeEngine: STTEngineProtocol {
        switch settings.selectedEngine {
    case .appleSpeech: return appleSpeechEngine
    case .whisper: return whisperEngine
    case .qwen: return qwenEngine
    case .parakeet: return parakeetEngine
    case .parakeetRealtime: return parakeetRealtimeEngine
    case .openAIRealtime: return openAIRealtimeEngine
        case .deepgram: return deepgramEngine
        case .elevenLabsScribe: return elevenLabsScribeEngine
        }
    }

    var onStateChanged: (() -> Void)?

    func setup() {
        micFallbackObserver = NotificationCenter.default.addObserver(
            forName: .audioInputFellBackToDefault, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.micFellBackThisSession = true
                self.overlay.update(status: self.listeningStatus)
            }
        }

        hotkeyService.register(
            onToggle: { [weak self] binding in
                let manager = self
                Task { @MainActor in
                    manager?.toggleDictation(binding: binding)
                }
            },
            onStartHold: { [weak self] binding in
                let manager = self
                Task { @MainActor in
                    manager?.startDictation(binding: binding)
                }
            },
            onStopHold: { [weak self] _ in
                let manager = self
                Task { @MainActor in
                    manager?.stopDictation()
                }
            }
        )

        if !accessibilityService.hasPermission {
            accessibilityService.requestPermission()
        }

        modelObserver = settings.$selectedWhisperModel.sink { [weak self] _ in
            self?.whisperEngine.unloadModel()
        }

parakeetModelObserver = settings.$selectedParakeetModel.sink { [weak self] _ in
    self?.parakeetEngine.unloadModel()
}
        parakeetRealtimeChunkObserver = settings.$selectedParakeetRealtimeChunkSize.sink { [weak self] _ in
            self?.parakeetRealtimeEngine.unloadModel()
        }

        // 3.16.6: model storage location changed → drop every loaded local
        // model so the next dictation reloads from the new paths (warm-up
        // capture keeps that reload graceful).
        modelStorageObserver = NotificationCenter.default.addObserver(
            forName: .modelStorageChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.whisperEngine.unloadModel()
                self?.qwenEngine.unloadModel()
                self?.parakeetEngine.unloadModel()
                self?.parakeetRealtimeEngine.unloadModel()
                ModelManager.shared.refreshDownloadedModels()
            }
        }

        // Pre-load the selected engine model in the background
        preloadModel()
    }

    private func preloadModel() {
        Task { [weak self] in
            guard let self else { return }
            print("[VoiceFlow] Pre-loading \(settings.selectedEngine.displayName) model...")
            do {
                switch settings.selectedEngine {
                case .whisper:
                    try await whisperEngine.loadModel(name: settings.selectedWhisperModel.rawValue)
                case .qwen:
                    try await qwenEngine.loadModel()
                case .parakeet:
                    try await parakeetEngine.loadModel()
                case .parakeetRealtime:
                    try await parakeetRealtimeEngine.loadModel()
                case .appleSpeech, .openAIRealtime, .deepgram, .elevenLabsScribe:
                    break // No preload needed (built-in / cloud-based)
                }
                print("[VoiceFlow] Model pre-loaded, ready for instant dictation")
            } catch {
                print("[VoiceFlow] Pre-load failed (will load on first use): \(error.localizedDescription)")
            }
        }
    }

    func toggleDictation(binding: HotkeyBinding? = nil) {
        if isDictating {
            stopDictation()
        } else if isStopping {
            // 3.14.1-beta.2: a previous stop is still finalizing (engine
            // wrap-up + AI cleanup + paste). Ignore the toggle — starting
            // a fresh session here would interleave with the in-flight
            // delivery and corrupt both transcripts. `isDictating` flips
            // to false as soon as the engine reports stop, before the
            // delivery pipeline starts, so this window is brief but real.
            print("[VoiceFlow] toggleDictation: ignored — previous stop still finalizing")
        } else {
            startDictation(binding: binding)
        }
    }

    /// Resolve which engine to use — profile override takes priority over global setting.
    /// No licence gate: every engine (local or BYOK cloud) is available to everyone.
    /// A cloud engine without its key fails loudly at start (noAPIKey), it is
    /// never silently swapped for another engine.
    nonisolated static func resolveEngineType(profileOverride: STTEngineType?, globalEngine: STTEngineType) -> STTEngineType {
        profileOverride ?? globalEngine
    }

    private func effectiveEngineType(for profile: Profile?) -> STTEngineType {
        Self.resolveEngineType(profileOverride: profile?.engineOverride, globalEngine: settings.selectedEngine)
    }

    /// AI post-processing runs whenever the profile asks for it (no licence gate).
    nonisolated static func shouldPostProcessWithAI(profile: Profile?) -> Bool {
        profile?.aiPostProcessing ?? false
    }

    private func engineInstance(for type: STTEngineType) -> STTEngineProtocol {
        switch type {
    case .appleSpeech: return appleSpeechEngine
    case .whisper: return whisperEngine
    case .qwen: return qwenEngine
    case .parakeet: return parakeetEngine
    case .parakeetRealtime: return parakeetRealtimeEngine
    case .openAIRealtime: return openAIRealtimeEngine
        case .deepgram: return deepgramEngine
        case .elevenLabsScribe: return elevenLabsScribeEngine
        }
    }

    /// True when the active profile asks for in-session translation via the
    /// dedicated gpt-realtime-translate endpoint and the language pair makes that meaningful.
    private func shouldUseTranslateEngine(profile: Profile?, effectiveType: STTEngineType, outputLang: String) -> Bool {
        guard let profile, profile.translateNatively else { return false }
        guard effectiveType == .openAIRealtime else { return false }
        guard outputLang != "auto", !outputLang.isEmpty else { return false }
        let inputBase = String(profile.inputLanguageCode.prefix(2))
        let outputBase = String(outputLang.prefix(2))
        guard inputBase != outputBase else { return false }
        return true
    }

    /// Overlay status for the active-listening state; carries the mic
    /// fallback note when the override device failed this session.
    private var listeningStatus: String {
        micFellBackThisSession ? "Listening (default mic)..." : "Listening..."
    }

    func startDictation(binding: HotkeyBinding? = nil) {
        guard !isDictating && !isStarting && !isStopping else { return }
        do { storageLease = try ModelStorageActivity.shared.acquire() }
        catch {
            statusText = error.localizedDescription
            onStateChanged?()
            return
        }
        isStarting = true
        isDictating = true
        micFellBackThisSession = false
        sessionBinding = binding
        // Pin the binding's profile for the whole session (nil profileID or a
        // deleted profile falls through to app detection).
        let pinnedProfile = binding?.profileID.flatMap { id in
            settings.profiles.first(where: { $0.id == id })
        }
        if let pinned = pinnedProfile {
            print("[Sonotexta][hotkey] binding \(binding?.key.display ?? "?") pinned profile: \(pinned.name)")
        }
        currentTranscription = ""
        DictationStats.shared.sessionStarted()

        // Freeze the paste target NOW. Anything the user does between start and
        // stop (window switches, notification banners, focus-stealing alerts)
        // must NOT be allowed to redirect the eventual paste.
        sessionTargetApp = accessibilityService.snapshotCurrentTarget()
        if let target = sessionTargetApp {
            print("[VoiceFlow] Session target frozen: \(target.localizedName ?? "?") (\(target.bundleIdentifier ?? "?"))")
        }

        // Re-evaluate profile at dictation time (catches conversation switches within an app)
        profileMatcher.refresh()
        let profile = pinnedProfile ?? profileMatcher.activeProfile
        let effectiveEngine = effectiveEngineType(for: profile)
        let inputLang = profile?.inputLanguageCode ?? "auto"
        let outputLang = profile?.outputLanguageCode ?? "en"
        let useTranslateEngine = shouldUseTranslateEngine(profile: profile, effectiveType: effectiveEngine, outputLang: outputLang)

        // 3.13.2-beta.3 — full engine decision log every dictation. When the user
        // reports "fell back to OAI Realtime" or similar, this single line shows
        // exactly why: which profile matched, what its override is, the global
        // engine setting, and the resolved effective engine. Without it,
        // support reports are unfalsifiable.
        print("[Sonotexta][engine] profile=\(profile?.name ?? "nil") override=\(profile?.engineOverride?.rawValue ?? "nil") global=\(settings.selectedEngine.rawValue) effective=\(effectiveEngine.rawValue) translate=\(useTranslateEngine) input=\(inputLang) output=\(outputLang)")

        let engine: STTEngineProtocol
        if useTranslateEngine {
            openAITranslateEngine.targetLanguage = String(outputLang.prefix(2))
            openAITranslateEngine.inputLanguageHint = inputLang
            engine = openAITranslateEngine
            print("[VoiceFlow] Profile \"\(profile?.name ?? "?")\" using gpt-realtime-translate (→ \(outputLang))")
        } else {
            // Thread the profile's input-language hint into whichever engine
            // we're about to start. Without this, Deepgram falls back to
            // English-only ("language=en") and Whisper auto-detects (which
            // mis-IDs Bulgarian/Cyrillic as Russian on short utterances).
            switch effectiveEngine {
            case .openAIRealtime:
                openAIRealtimeEngine.inputLanguageHint = inputLang
            case .deepgram:
                deepgramEngine.inputLanguageHint = inputLang
            case .whisper:
                whisperEngine.inputLanguageHint = inputLang
            case .elevenLabsScribe:
                elevenLabsScribeEngine.inputLanguageHint = inputLang
            default:
                break
            }
            engine = engineInstance(for: effectiveEngine)
        }
        lastStartedEngine = engine
        let session = DictationSession(engine: engine, profile: profile)
        self.session = session
        let engineName = useTranslateEngine ? "OpenAI Realtime Translate" : effectiveEngine.displayName

        if let override = profile?.engineOverride {
            print("[VoiceFlow] Profile \"\(profile?.name ?? "?")\" overrides engine to \(override.displayName)")
        }

        statusText = "Loading \(engineName)..."
        onStateChanged?()

        // Build profile + language info for the overlay
        let profileName = profile?.name
        let langInfo: String? = {
            guard let p = profile, p.outputLanguageCode != "auto" else { return nil }
            let langName = languageName(for: p.outputLanguageCode)
            return "→ \(langName)"
        }()
        overlay.show(status: "Loading \(engineName)...", profileName: profileName, languageInfo: langInfo)

        // Use input language hint for speech engine locale if set
        let locale = inputLang != "auto" ? Locale(identifier: inputLang) : Locale.current
        qwenEngine.languageHint = inputLang == "auto" ? nil : locale.language.languageCode?.identifier

        // Whisper's `.translate` task is for non-English → English. Enabling it
        // for English source audio causes Whisper to return empty (the model
        // sees the input is already in the target language and produces
        // nothing), which surfaces as a "Delivered with no text" symptom.
        //
        // Pre-beta.3 (build ≤ 91): gate was `outputLang == "en"` alone, which
        // forced translate-task on for every English-output run regardless of
        // input language. Bug: a Default profile with input=auto + output=en
        // ran English-in through translate-task → finalLen=0 → silent failure.
        //
        // Correct gate (per Codex audit 2026-05-28): translate-task ONLY when
        // the input language is known AND non-English, with output=en. For
        // input=auto the safe choice is transcribe — Whisper's transcribe task
        // works for any language and still outputs the spoken language; if
        // the user wants English output specifically from non-English audio,
        // they should set the input language explicitly on their profile.
        whisperEngine.useTranslateTask =
            effectiveEngine == .whisper &&
            outputLang == "en" &&
            inputLang != "auto" &&
            !inputLang.lowercased().hasPrefix("en")

        let isRealtime = effectiveEngine.isCloudStreaming

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isStarting = false }

            do {
                self.statusText = "Listening (\(engineName))..."
                self.onStateChanged?()
                self.overlay.update(status: self.listeningStatus)

                try await session.start(locale: locale) { [weak self] text, isFinal in
                    Task { @MainActor in
                        guard let self, self.session?.id == session.id, !self.isStopping, self.isDictating else { return }

                        if isRealtime {
                            // Realtime engines now pass CUMULATIVE text in `text` for both
                            // partials and finals — engine owns the accumulator, so we just
                            // reflect whatever it tells us. No buffer mirror needed here.
                            self.currentTranscription = text
                            self.statusText = "Listening..."
                            self.overlay.update(status: self.listeningStatus)
                            self.overlay.updateTranscription(text)
                            self.onStateChanged?()
                            // Do NOT end dictation — wait for manual stop
                        } else {
                            self.currentTranscription = text
                            self.overlay.updateTranscription(text)
                            if isFinal {
                                // Automatic and manual completion take the SAME path.
                                // stopDictation claims isStopping before any await.
                                self.stopDictation()
                            } else {
                                self.statusText = "Listening..."
                                self.overlay.update(status: self.listeningStatus)
                                self.onStateChanged?()
                            }
                        }
                    }
                }.value
            } catch {
                // If Stop is already waiting for this start, it owns final cleanup.
                guard !self.isStopping else { return }
                _ = await session.finish()
                self.isDictating = false
                self.statusText = "Error: \(error.localizedDescription)"
                self.sessionTargetApp = nil
                self.storageLease = nil
                DictationStats.shared.sessionCancelled()
                self.onStateChanged?()
                self.overlay.hideWith(status: "Couldn't start: \(error.localizedDescription)", phase: .error, after: 3.0)
            }
        }
    }

    func stopDictation() {
        guard isDictating, !isStopping, let session else { return }
        isStopping = true
        statusText = "Stopping..."
        onStateChanged?()
        // 3.14.1: push the status to the overlay explicitly. Without this,
        // the overlay sits on "Listening..." for the entire 5-15s while
        // local Whisper Large V3 runs its final-pass transcription, making
        // the UI look frozen even though work is happening.
        overlay.update(status: "Processing...")

        let preStopTranscription = currentTranscription
        let profile = session.profile
        // Prefer the engine actually started — covers translate-engine selection.
        let engine = session.engine
        let outputLang = profile?.outputLanguageCode ?? "en"
        let alreadyTranslated = (engine as AnyObject) === (openAITranslateEngine as AnyObject)

        Task { @MainActor [weak self] in
            guard let self else { return }
            print("[VoiceFlow][stop] T0 awaiting engine.stopTranscription()")
            let tStop = Date()

            // Authoritative final text comes from the engine's stopTranscription return value.
            // This eliminates the prior race where DictationManager read a buffer before the
            // queued final callback had a chance to apply.
            let engineFinal = await session.finish()
            print("[VoiceFlow][stop] T1 engine returned (+\(String(format: "%.2f", Date().timeIntervalSince(tStop)))s, finalLen=\(engineFinal?.count ?? 0))")

            // 3.14.1-beta.2 fix: flip `isDictating` to false RIGHT NOW so the
            // menu bar item flips from "Stop Dictation" back to "Start
            // Dictation" promptly, and the menubar icon stops showing the
            // recording state. Delivery and AI cleanup may still be in
            // progress, but we're no longer recording — the state machine
            // should reflect that. `isStopping` stays true so a hotkey
            // press during this window doesn't kick off a fresh session
            // through `toggleDictation`. Final cleanup of `isStopping` runs
            // after delivery completes.
            self.isDictating = false
            self.onStateChanged?()

            // Priority: engine return value > pre-stop snapshot > callback-set state.
            // currentTranscription is read last because for some engines its update is queued
            // on main and may not have applied yet by the time stopTranscription returns.
            let textToDeliver = engineFinal
                ?? (preStopTranscription.isEmpty ? nil : preStopTranscription)
                ?? (self.currentTranscription.isEmpty ? nil : self.currentTranscription)

            if let startError = session.startError {
                self.overlay.hideWith(status: "Couldn't start: \(startError.localizedDescription)", phase: .error, after: 3.0)
                DictationStats.shared.sessionCancelled()
            } else if let error = engine.finalizationError {
                self.overlay.hideWith(status: "Transcription failed: \(error.localizedDescription)", phase: .error, after: 5.0)
                DictationStats.shared.sessionCancelled()
            } else if textToDeliver == nil, let issue = engine.audioCaptureIssue {
                self.overlay.hideWith(status: issue, phase: .error, after: 6.0)
                DictationStats.shared.sessionCancelled()
            } else if let textToDeliver, !textToDeliver.isEmpty {
                print("[VoiceFlow][stop] T2 entering processAndDeliver (len=\(textToDeliver.count))")
                await self.processAndDeliver(text: textToDeliver, profile: profile, outputLang: outputLang, alreadyTranslated: alreadyTranslated)
                print("[VoiceFlow][stop] T3 processAndDeliver returned (+\(String(format: "%.2f", Date().timeIntervalSince(tStop)))s)")
            } else {
                print("[VoiceFlow][stop] T2 nothing to deliver — hiding overlay")
                // Nothing to deliver — just hide overlay (no false "Delivered" flash)
                self.overlay.hideWith(status: "No speech detected", phase: .processing, after: 1.0)
                DictationStats.shared.sessionCancelled()
            }

            self.isStopping = false
            self.session = nil
            self.sessionTargetApp = nil
            self.lastStartedEngine = nil
            self.sessionBinding = nil
            self.storageLease = nil
            self.currentTranscription = ""
            self.statusText = "Ready"
            self.onStateChanged?()
            print("[VoiceFlow][stop] T4 state reset complete (+\(String(format: "%.2f", Date().timeIntervalSince(tStop)))s)")
        }
    }

    private func processAndDeliver(text: String, profile: Profile?, outputLang: String, alreadyTranslated: Bool = false) async {
        // Strip non-speech artifacts ([Music], [silence], etc.) before any processing
        var finalText = TranscriptionFilter.clean(text)
        guard !finalText.isEmpty else {
            // 3.14.1-beta.2: don't flash "Delivered" when the filter ate
            // everything — there's nothing to deliver.
            overlay.hideWith(status: "Nothing to deliver", phase: .processing, after: 1.0)
            return
        }

        let useAI = Self.shouldPostProcessWithAI(profile: profile)

        // Resolve the effective AI prompt:
        //   1. Built-in preset (.cleanCorrect, .professional, etc.) — use its promptText
        //   2. .custom with a customPresetID → look up in AppSettings.customPresets
        //   3. .custom without an ID (legacy) → fall back to profile.tonePrompt
        //   4. No aiPreset at all → fall back to profile.tonePrompt (legacy migration-safe)
        let tonePrompt: String = {
            guard let profile else { return "" }
            if let preset = profile.aiPreset, preset != .custom {
                return preset.promptText
            }
            if let customID = profile.customPresetID,
               let custom = AppSettings.shared.customPresets.first(where: { $0.id == customID }) {
                return custom.promptText
            }
            return profile.tonePrompt
        }()

        // AI Post-Processing path: send to LLM for cleanup + translation + tone.
        //
        // 3.14.0 P2.1 fix: pass the CLEANED finalText (artifacts stripped by
        // TranscriptionFilter) to the LLM, not the raw text. Previously the
        // raw text was passed, so the [Music] / [silence] / placeholder
        // markers could influence the cleanup output and the filter step
        // was wasted.
        if useAI {
            statusText = "AI processing..."
            onStateChanged?()
            overlay.update(status: "AI processing...")

            let outcome = await AICleanupResult.process(text: finalText, hasCredentials: LLMService.shared.hasAPIKey) {
                try await LLMService.shared.postProcess(
                    text: finalText,
                    inputLanguage: profile?.inputLanguageCode ?? "auto",
                    outputLanguage: outputLang,
                    tonePrompt: tonePrompt,
                    skipTranslation: alreadyTranslated,
                    glossary: AppSettings.shared.glossary
                )
            }
            lastAIFailure = outcome.failure
            if let failure = outcome.failure {
                print("[VoiceFlow] LLM post-processing failed: \(failure)")
            }
            deliverText(outcome.text, profile: profile, usedAI: outcome.usedAI, aiFailed: outcome.failure != nil)
            return
        }

        // Non-AI path: use Whisper translate or Apple Translation.
        //
        // 3.14.0 P1.2/P1.3 fix: previously TranslationService was called with
        // a hardcoded source="en", so any Bulgarian/Czech/Russian source got
        // silently routed through Apple-Translate-from-English and either
        // failed or produced gibberish. Now we pass the profile's actual
        // input language. Also: gracefully bail when the language pair isn't
        // supported by Apple Translation (e.g. cs-CZ ↔ bg-BG) instead of
        // silently delivering raw source text.
        guard outputLang != "auto" else {
            deliverText(finalText, profile: profile)
            return
        }

        let inputLang = profile?.inputLanguageCode ?? "auto"
        let whisperAlreadyTranslated = session?.engine.engineType == .whisper && outputLang == "en" && whisperEngine.useTranslateTask

        if !whisperAlreadyTranslated && !alreadyTranslated && inputLang != "auto" {
            // Skip the round-trip entirely for unsupported targets — Apple
            // Translation can't do Bulgarian/Czech/Slovak/etc. Profile
            // editor already labels these as AI-only; we now enforce it.
            let targetSupported = Profile.supportedLanguages.first(where: { $0.code == outputLang })?.translationAvailable ?? false
            if !targetSupported {
                print("[VoiceFlow] Apple Translation does not support \(outputLang) — delivering source. Enable AI Post-Processing on this profile to translate.")
            } else {
                statusText = "Translating to \(languageName(for: outputLang))..."
                onStateChanged?()
                overlay.update(status: "Translating...")

                if let translated = await TranslationService.shared.translate(finalText, from: inputLang, to: outputLang) {
                    finalText = translated
                    #if DEBUG
                    print("[VoiceFlow] Translated \(inputLang) → \(outputLang)")
                    #endif
                } else {
                    print("[VoiceFlow] Translation \(inputLang) → \(outputLang) returned nil — delivering source")
                }
            }
        }

        deliverText(finalText, profile: profile)
    }

    private func languageName(for code: String) -> String {
        Profile.supportedLanguages.first(where: { $0.code == code })?.name ?? code
    }

    private func deliverText(_ text: String, profile: Profile?, usedAI: Bool = false, aiFailed: Bool = false) {
        // 3.14.1-beta.2 fix: attempt the insertion BEFORE hiding the overlay,
        // and surface the real result. Previously `overlay.hide()` was called
        // first and unconditionally flashed "Delivered" — even when the text
        // actually fell back to the clipboard (target app didn't become
        // frontmost within insertText's 600ms verification window) or the
        // insertion failed outright. That misled users into thinking the
        // text had landed when it was sitting in the clipboard waiting for
        // a manual ⌘V.
        print("[VoiceFlow][deliver] attempting insertText into target=\(sessionTargetApp?.bundleIdentifier ?? "nil")")

        // Record the transcription BEFORE attempting delivery — if paste fails or the
        // result is .copiedToClipboard, the user can still recover via the menu bar.
        LastDictationStore.shared.recordTranscription(text)

        let result = accessibilityService.insertText(text, targetApp: sessionTargetApp)
        // Clear the frozen target — menu-bar "Paste Last Dictation" should
        // follow live focus, not whatever was frontmost when this session
        // started.
        sessionTargetApp = nil
        let deliveryStatus: DeliveryStatus
        switch result {
        case .delivered:
            print("[VoiceFlow][deliver] .delivered — pasted into target")
            statusText = aiFailed ? "Delivered RAW — AI cleanup failed" : "Delivered"
            deliveryStatus = .delivered
            if aiFailed {
                // Linger long enough to be read — this replaced a sub-second
                // flash that let two AI bugs masquerade as working for days.
                overlay.hideWith(status: "Delivered raw text — AI cleanup failed", phase: .error, after: 2.5)
            } else {
                overlay.hideWith(status: "Delivered", phase: .delivered, after: 0.8)
            }
            DictationStats.shared.sessionCompleted(text: text, usedAI: usedAI)
            // Ensure clipboard has the FINAL processed text (not raw transcription)
            // when keepInClipboard is enabled.
            if AppSettings.shared.keepInClipboard {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(text, forType: .string)
            }
        case .copiedToClipboard:
            print("[VoiceFlow][deliver] .copiedToClipboard — target activation failed, text in clipboard")
            statusText = aiFailed ? "AI cleanup failed — raw text copied; paste with ⌘V" : "Copied to clipboard — paste with ⌘V"
            deliveryStatus = .copiedToClipboard
            // Hold the overlay longer (2.5s) for clipboard fallback so the
            // user actually sees the message instead of a misleading
            // "Delivered" flash that disappears in 0.8s.
            overlay.hideWith(status: statusText, phase: aiFailed ? .error : .processing, after: 2.5)
            // Still count as a completed session — text was produced and is recoverable.
            DictationStats.shared.sessionCompleted(text: text, usedAI: usedAI)
        case .failed:
            print("[VoiceFlow][deliver] .failed — check Accessibility permission")
            statusText = "Could not deliver — check Accessibility permission"
            deliveryStatus = .failed
            overlay.hideWith(status: "Could not deliver — check Accessibility permission", phase: .error, after: 3.0)
        }
        LastDictationStore.shared.recordDelivery(deliveryStatus)
        onStateChanged?()

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            if self?.isDictating == false {
                self?.statusText = "Ready"
                self?.onStateChanged?()
            }
        }
    }
}
