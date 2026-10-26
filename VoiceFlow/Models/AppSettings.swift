import Foundation
import Combine
import Carbon
import AppKit

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var selectedEngine: STTEngineType {
        didSet {
            UserDefaults.standard.set(selectedEngine.rawValue, forKey: "selectedEngine")
            // Force immediate disk flush — without this, macOS debounces the
            // write ~10s. If the user force-quits the app within that window
            // (or the audio engine wedges and they kill it), the new
            // selection never reaches disk and next launch reads the stale
            // value. Force-flush + log so we know what's actually persisted.
            UserDefaults.standard.synchronize()
            print("[Sonotexta][settings] selectedEngine persisted: \(selectedEngine.rawValue)")
        }
    }

    @Published var selectedWhisperModel: WhisperModelSize {
        didSet { UserDefaults.standard.set(selectedWhisperModel.rawValue, forKey: "selectedWhisperModel") }
    }

    @Published var selectedOpenAIRealtimeModel: OpenAIRealtimeModel {
        didSet { UserDefaults.standard.set(selectedOpenAIRealtimeModel.rawValue, forKey: "selectedOpenAIRealtimeModel") }
    }

@Published var selectedParakeetModel: ParakeetModelVersion {
    didSet { UserDefaults.standard.set(selectedParakeetModel.rawValue, forKey: "selectedParakeetModel") }
}
@Published var selectedParakeetRealtimeChunkSize: ParakeetRealtimeChunkSize {
    didSet { UserDefaults.standard.set(selectedParakeetRealtimeChunkSize.rawValue, forKey: "selectedParakeetRealtimeChunkSize") }
}

    @Published var globalHotkey: String {
        didSet { UserDefaults.standard.set(globalHotkey, forKey: "globalHotkey") }
    }

    @Published var hotkeyKeyCode: UInt32 {
        didSet { UserDefaults.standard.set(hotkeyKeyCode, forKey: "hotkeyKeyCode") }
    }

    @Published var hotkeyModifiers: UInt32 {
        didSet { UserDefaults.standard.set(hotkeyModifiers, forKey: "hotkeyModifiers") }
    }

    @Published var useGlobeKey: Bool {
        didSet { UserDefaults.standard.set(useGlobeKey, forKey: "useGlobeKey") }
    }

    /// 3.16.4-beta.3: dedicate the RIGHT Option (⌥) key to dictation
    /// (beta-tester request — a modifier most people never use alone, and
    /// unlike Globe it needs no System Settings change). Same press/release
    /// semantics as the Globe key, so hold-to-talk works. Mutually exclusive
    /// with useGlobeKey — the Settings picker enforces that.
    ///
    /// 3.16.5: legacy — superseded by `hotkeyBindings`, kept in sync for
    /// downgrade safety during the transition cycle.
    @Published var useRightOptionKey: Bool {
        didSet { UserDefaults.standard.set(useRightOptionKey, forKey: "useRightOptionKey") }
    }

    /// 3.16.5: the dictation-shortcut table. Every binding = key + profile
    /// (nil → app detection) + mode. Replaces the single global hotkey; the
    /// legacy settings migrate into binding #0 on first launch.
    @Published var hotkeyBindings: [HotkeyBinding] {
        didSet {
            if let data = try? JSONEncoder().encode(hotkeyBindings) {
                UserDefaults.standard.set(data, forKey: "hotkeyBindings")
                UserDefaults.standard.synchronize()
            }
            print("[Sonotexta][settings] hotkeyBindings persisted: \(hotkeyBindings.count) binding(s)")
        }
    }

    @Published var selectedDeepgramModel: DeepgramModel {
        didSet { UserDefaults.standard.set(selectedDeepgramModel.rawValue, forKey: "selectedDeepgramModel") }
    }

    @Published var selectedElevenLabsScribeModel: ElevenLabsScribeModel {
        didSet { UserDefaults.standard.set(selectedElevenLabsScribeModel.rawValue, forKey: "selectedElevenLabsScribeModel") }
    }

    /// When ON, Scribe Realtime receives the Vocabulary glossary canonicals as
    /// `keyterms[]` query params so the STT model itself is biased toward those
    /// terms (in addition to the downstream LLM cleanup). Adds a 20% premium to
    /// the per-minute Scribe cost — off by default so users opt in consciously.
    /// Cap is 50 keyterms × 20 chars each (ElevenLabs server limit).
    @Published var elevenLabsScribeUseKeyterms: Bool {
        didSet { UserDefaults.standard.set(elevenLabsScribeUseKeyterms, forKey: "elevenLabsScribeUseKeyterms") }
    }

    @Published var dictationMode: DictationMode {
        didSet { UserDefaults.standard.set(dictationMode.rawValue, forKey: "dictationMode") }
    }

    @Published var keepInClipboard: Bool {
        didSet { UserDefaults.standard.set(keepInClipboard, forKey: "keepInClipboard") }
    }

    /// Opt-in to receive beta (early-access) updates via Sparkle's channel
    /// feature. Default off — stable users see only stable releases.
    /// When on, the updater accepts items tagged `<sparkle:channel>beta</sparkle:channel>`
    /// in addition to untagged (stable) items.
    @Published var receiveBetaUpdates: Bool {
        didSet {
            UserDefaults.standard.set(receiveBetaUpdates, forKey: "receiveBetaUpdates")
            UpdaterService.applyChannels()
        }
    }

    @Published var clipboardRestoreDelay: Double {
        didSet { UserDefaults.standard.set(clipboardRestoreDelay, forKey: "clipboardRestoreDelay") }
    }

    /// Maximum wait for `session.output_transcript.done` after stop on the
    /// translate engine, before the partial-fold fallback kicks in. Earlier
    /// versions used this as a quiet-window threshold (0.5–2.0s); 3.12.0-beta.4
    /// repurposed it as a hardCap because the quiet-window heuristic was
    /// cutting the model off mid-translation. Range 3.0–12.0s, default 8.0s.
    /// Stored values from the old range (< 3.0) are migrated to the new
    /// default on next read so users don't end up with an out-of-range value.
    @Published var translateStopWaitSeconds: Double {
        didSet { UserDefaults.standard.set(translateStopWaitSeconds, forKey: "translateStopWaitSeconds") }
    }

    /// 3.16.6: custom root folder for model-weight downloads (external drive
    /// use case; beta-tester request). nil/empty = system defaults. Plain
    /// path, not a bookmark — the app is unsandboxed. Resolution lives in
    /// `ModelStorage`; engines must never read this directly.
    @Published var modelStoragePath: String? {
        didSet {
            UserDefaults.standard.set(modelStoragePath, forKey: "modelStoragePath")
            UserDefaults.standard.synchronize()
            print("[Sonotexta][settings] modelStoragePath persisted: \(modelStoragePath ?? "<default>")")
        }
    }

    /// Detect a different volume mounted at the same saved path.
    var modelStorageVolumeUUID: String? {
        didSet { UserDefaults.standard.set(modelStorageVolumeUUID, forKey: "modelStorageVolumeUUID") }
    }

    /// Selected input device UID — nil means system default
    @Published var selectedInputDeviceUID: String? {
        didSet { UserDefaults.standard.set(selectedInputDeviceUID, forKey: "selectedInputDeviceUID") }
    }

    /// Show Sonotexta icon in the Dock (clicking opens Settings). Default: true.
    @Published var showInDock: Bool {
        didSet {
            UserDefaults.standard.set(showInDock, forKey: "showInDock")
            NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
        }
    }

    @Published var profiles: [Profile] {
        didSet {
            saveProfiles()
            print("[Sonotexta][settings] profiles persisted: \(profiles.count) profile(s)")
        }
    }

    /// User-defined AI post-processing presets, shared across all profiles.
    /// Profiles reference these by `Profile.customPresetID`.
    @Published var customPresets: [CustomPreset] {
        didSet { saveCustomPresets() }
    }

    /// Global vocabulary entries injected into the AI cleanup prompt to help
    /// disambiguate misrecognitions ("cloud" → "Claude Code" in dev context)
    /// and preserve product names across translation. Applies to all profiles
    /// uniformly in this iteration; per-profile scoping can come later if
    /// false matches become a problem.
    @Published var glossary: [GlossaryEntry] {
        didSet { saveGlossary() }
    }

    // MARK: - 3.15 additions (theme + onboarding state)

    /// User-selected app appearance: `.system` defers to macOS, `.light` /
    /// `.dark` pin `NSApp.appearance` regardless of OS setting. Wired to
    /// `ThemeService.shared`, which observes this property.
    @Published var appearance: AppearanceMode {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: "appearance")
            // Explicit synchronize so a force-quit immediately after toggling
            // theme still persists the choice (matches the pattern used by
            // `selectedEngine` and `profiles`).
            UserDefaults.standard.synchronize()
        }
    }

    /// `true` once the first-run wizard has finished (fresh install) OR was
    /// auto-skipped for an existing 3.14.x user. While `false`, the
    /// `OnboardingWindowController` runs before menubar/dictation setup.
    @Published var hasCompletedOnboarding: Bool {
        didSet {
            UserDefaults.standard.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding")
            UserDefaults.standard.synchronize()
        }
    }

    /// Marker of the highest "X.Y" major version whose What's-new sheet the
    /// user has already dismissed. `nil` means no sheet has ever been shown
    /// (fresh installs, or pre-3.15 upgrade). `VoiceFlowApp.openSettings`
    /// checks this on every Settings open and shows the sheet exactly once
    /// per major release.
    @Published var lastSeenMajorVersion: String? {
        didSet {
            UserDefaults.standard.set(lastSeenMajorVersion, forKey: "lastSeenMajorVersion")
        }
    }

    /// Whether the most-recently dictated text is persisted to disk
    /// (UserDefaults) so the menu-bar recovery actions — "Paste Last Dictation",
    /// "Copy Last Dictation", "Show Last Dictation…" — survive app relaunch.
    /// Default `true` to preserve existing UX. Users handling sensitive content
    /// (passwords, medical notes, call transcripts) can switch this off to keep
    /// the recovery buffer in memory only. Toggling to `false` wipes any
    /// already-stored text immediately. Independent of the 24h TTL, which
    /// applies to on-disk entries unconditionally. (Codex P2 finding 2026-05-20.)
    @Published var retainLastDictationOnDisk: Bool {
        didSet {
            UserDefaults.standard.set(retainLastDictationOnDisk, forKey: "retainLastDictationOnDisk")
            UserDefaults.standard.synchronize()
            if !retainLastDictationOnDisk {
                LastDictationStore.shared.purgePersistedText()
            }
        }
    }

    private init() {
        let engineRaw = UserDefaults.standard.string(forKey: "selectedEngine") ?? STTEngineType.appleSpeech.rawValue
        self.selectedEngine = STTEngineType(rawValue: engineRaw) ?? .appleSpeech

        // 3.14.1-beta.4 migration: WhisperModelSize.largeTurbo's rawValue
        // changed from "large-v3-turbo" (hyphen, never worked — produced an
        // invalid HuggingFace repo glob) to "large-v3_turbo" (underscore,
        // matches the Argmax repo). Rewrite any stale stored value so the
        // user's prior selection is preserved across this beta upgrade.
        var modelRaw = UserDefaults.standard.string(forKey: "selectedWhisperModel") ?? WhisperModelSize.base.rawValue
        if modelRaw == "large-v3-turbo" {
            modelRaw = "large-v3_turbo"
            UserDefaults.standard.set(modelRaw, forKey: "selectedWhisperModel")
        }
        self.selectedWhisperModel = WhisperModelSize(rawValue: modelRaw) ?? .base

        // 3.16.3-beta.2 migration: the 4o-era OpenAI lineup was replaced by
        // gpt-transcribe / gpt-live-transcribe. Map stored legacy selections
        // to their nearest successor so users keep an equivalent tier
        // (mini + transcribe → transcribe; realtime-whisper → live, same price).
        var realtimeModelRaw = UserDefaults.standard.string(forKey: "selectedOpenAIRealtimeModel") ?? OpenAIRealtimeModel.transcribe.rawValue
        switch realtimeModelRaw {
        case "gpt-4o-mini-transcribe", "gpt-4o-transcribe":
            realtimeModelRaw = OpenAIRealtimeModel.transcribe.rawValue
            UserDefaults.standard.set(realtimeModelRaw, forKey: "selectedOpenAIRealtimeModel")
        case "gpt-realtime-whisper":
            realtimeModelRaw = OpenAIRealtimeModel.liveTranscribe.rawValue
            UserDefaults.standard.set(realtimeModelRaw, forKey: "selectedOpenAIRealtimeModel")
        default:
            break
        }
        self.selectedOpenAIRealtimeModel = OpenAIRealtimeModel(rawValue: realtimeModelRaw) ?? .transcribe

let parakeetModelRaw = UserDefaults.standard.string(forKey: "selectedParakeetModel") ?? ParakeetModelVersion.v3.rawValue
self.selectedParakeetModel = ParakeetModelVersion(rawValue: parakeetModelRaw) ?? .v3
let parakeetRealtimeChunkSizeRaw = UserDefaults.standard.string(forKey: "selectedParakeetRealtimeChunkSize") ?? ParakeetRealtimeChunkSize.ms160.rawValue
self.selectedParakeetRealtimeChunkSize = ParakeetRealtimeChunkSize(rawValue: parakeetRealtimeChunkSizeRaw) ?? .ms160

        self.globalHotkey = UserDefaults.standard.string(forKey: "globalHotkey") ?? "⌃⇧D"

        let storedKeyCode = UInt32(UserDefaults.standard.integer(forKey: "hotkeyKeyCode"))
        let storedModifiers = UInt32(UserDefaults.standard.integer(forKey: "hotkeyModifiers"))
        self.hotkeyKeyCode = storedKeyCode == 0 ? UInt32(kVK_ANSI_D) : storedKeyCode
        self.hotkeyModifiers = storedModifiers == 0 ? UInt32(controlKey | shiftKey) : storedModifiers

        let deepgramModelRaw = UserDefaults.standard.string(forKey: "selectedDeepgramModel") ?? DeepgramModel.nova3.rawValue
        self.selectedDeepgramModel = DeepgramModel(rawValue: deepgramModelRaw) ?? .nova3

        let scribeModelRaw = UserDefaults.standard.string(forKey: "selectedElevenLabsScribeModel") ?? ElevenLabsScribeModel.scribeV2Realtime.rawValue
        self.selectedElevenLabsScribeModel = ElevenLabsScribeModel(rawValue: scribeModelRaw) ?? .scribeV2Realtime

        self.elevenLabsScribeUseKeyterms = UserDefaults.standard.bool(forKey: "elevenLabsScribeUseKeyterms")

        self.useGlobeKey = UserDefaults.standard.bool(forKey: "useGlobeKey")
        self.useRightOptionKey = UserDefaults.standard.bool(forKey: "useRightOptionKey")

        // 3.16.5 migration: build the bindings table from stored data, or
        // synthesize binding #0 from the legacy single-hotkey settings so
        // every upgrader keeps exactly the shortcut they had.
        if let data = UserDefaults.standard.data(forKey: "hotkeyBindings"),
           let decoded = try? JSONDecoder().decode([HotkeyBinding].self, from: data),
           !decoded.isEmpty {
            self.hotkeyBindings = decoded
        } else {
            let legacyModeRaw = UserDefaults.standard.string(forKey: "dictationMode") ?? DictationMode.toggle.rawValue
            let legacyMode = DictationMode(rawValue: legacyModeRaw) ?? .toggle
            let legacyKey: HotkeyBinding.KeySpec
            if UserDefaults.standard.bool(forKey: "useGlobeKey") {
                legacyKey = .globe
            } else if UserDefaults.standard.bool(forKey: "useRightOptionKey") {
                legacyKey = .rightOption
            } else {
                let storedKeyCode = UInt32(UserDefaults.standard.integer(forKey: "hotkeyKeyCode"))
                let storedModifiers = UInt32(UserDefaults.standard.integer(forKey: "hotkeyModifiers"))
                let keyCode = storedKeyCode == 0 ? UInt32(kVK_ANSI_D) : storedKeyCode
                let modifiers = storedModifiers == 0 && storedKeyCode == 0 ? UInt32(controlKey | shiftKey) : storedModifiers
                let display = UserDefaults.standard.string(forKey: "globalHotkey") ?? "⌃⇧D"
                legacyKey = modifiers == 0
                    ? .singleKey(keyCode: keyCode, display: display)
                    : .carbonCombo(keyCode: keyCode, modifiers: modifiers, display: display)
            }
            self.hotkeyBindings = [HotkeyBinding(key: legacyKey, profileID: nil, mode: legacyMode)]
            print("[Sonotexta][settings] migrated legacy hotkey → binding #0 (\(legacyKey.display), \(legacyMode.rawValue))")
        }
        self.keepInClipboard = UserDefaults.standard.bool(forKey: "keepInClipboard")
        self.receiveBetaUpdates = UserDefaults.standard.bool(forKey: "receiveBetaUpdates")
        let storedDelay = UserDefaults.standard.double(forKey: "clipboardRestoreDelay")
        self.clipboardRestoreDelay = storedDelay > 0 ? storedDelay : 0.15

        // Slider semantics changed in 3.12.0-beta.4 from "quiet-window threshold
        // (0.5–2.0s)" to "hardCap for waiting on `done` (3.0–12.0s)". Treat
        // any value outside the new range as legacy and reset to the new default.
        let storedTranslateWait = UserDefaults.standard.double(forKey: "translateStopWaitSeconds")
        self.translateStopWaitSeconds = (storedTranslateWait >= 3.0 && storedTranslateWait <= 12.0) ? storedTranslateWait : 8.0

        self.selectedInputDeviceUID = UserDefaults.standard.string(forKey: "selectedInputDeviceUID")
        self.modelStoragePath = UserDefaults.standard.string(forKey: "modelStoragePath")
        let savedRoot = UserDefaults.standard.string(forKey: "modelStoragePath").map { URL(fileURLWithPath: $0, isDirectory: true) }
        let savedVolumeUUID = UserDefaults.standard.string(forKey: "modelStorageVolumeUUID")
            ?? ModelStorage.volumeUUID(at: savedRoot)
        self.modelStorageVolumeUUID = savedVolumeUUID
        UserDefaults.standard.set(savedVolumeUUID, forKey: "modelStorageVolumeUUID")

        // Default to showing in dock (true) for new users; existing users who never set this get true
        if UserDefaults.standard.object(forKey: "showInDock") != nil {
            self.showInDock = UserDefaults.standard.bool(forKey: "showInDock")
        } else {
            self.showInDock = true
        }

        let modeRaw = UserDefaults.standard.string(forKey: "dictationMode") ?? DictationMode.toggle.rawValue
        self.dictationMode = DictationMode(rawValue: modeRaw) ?? .toggle

        // 3.13.2-beta.3 — resilient profile decoding. Previously a single
        // bad profile (missing field, unknown enum rawValue from a future
        // version) would fail the WHOLE [Profile] decode under `try?` and
        // silently reset every custom profile to a single Default. Now we
        // decode element-by-element via LossyProfile and skip only the
        // bad ones.
        if let data = UserDefaults.standard.data(forKey: "profiles"),
           let lossy = try? JSONDecoder().decode([LossyProfile].self, from: data) {
            let recovered = lossy.compactMap(\.value)
            let dropped = lossy.count - recovered.count
            if dropped > 0 {
                print("[Sonotexta][settings] WARNING: \(dropped)/\(lossy.count) profile(s) failed to decode and were skipped")
            }
            self.profiles = recovered.isEmpty
                ? [Profile(name: "Default", detectionRules: [], outputLanguageCode: "en", tonePrompt: "")]
                : recovered
        } else {
            self.profiles = [
                Profile(name: "Default", detectionRules: [], outputLanguageCode: "en", tonePrompt: "")
            ]
        }

        // Custom presets — load existing or start empty.
        if let data = UserDefaults.standard.data(forKey: "customPresets"),
           let decoded = try? JSONDecoder().decode([CustomPreset].self, from: data) {
            self.customPresets = decoded
        } else {
            self.customPresets = []
        }

        // Glossary — load existing or start empty.
        if let data = UserDefaults.standard.data(forKey: "glossary"),
           let decoded = try? JSONDecoder().decode([GlossaryEntry].self, from: data) {
            self.glossary = decoded
        } else {
            self.glossary = []
        }

        // 3.15.0 additions — appearance + onboarding state. Loaded last so all
        // prior properties are initialized before any observer fires.
        let appearanceRaw = UserDefaults.standard.string(forKey: "appearance") ?? AppearanceMode.system.rawValue
        self.appearance = AppearanceMode(rawValue: appearanceRaw) ?? .system
        self.hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        self.lastSeenMajorVersion = UserDefaults.standard.string(forKey: "lastSeenMajorVersion")

        // Default `true` on first launch so the existing menu-bar recovery
        // feature keeps working without an explicit opt-in. Users can disable
        // via Settings → About & Stats → Privacy.
        if UserDefaults.standard.object(forKey: "retainLastDictationOnDisk") != nil {
            self.retainLastDictationOnDisk = UserDefaults.standard.bool(forKey: "retainLastDictationOnDisk")
        } else {
            self.retainLastDictationOnDisk = true
        }

        // 3.13.2-beta.3 — startup log so the user (and support) can see
        // exactly what was loaded from disk. Distinguishes "lost write"
        // from "got reset later".
        print("[Sonotexta][settings] LOADED: engine=\(selectedEngine.rawValue) whisper=\(selectedWhisperModel.rawValue) profiles=\(profiles.count) glossary=\(glossary.count) appearance=\(appearance.rawValue) onboarded=\(hasCompletedOnboarding)")

        // Migrate legacy single-custom profiles to the global library.
        // Any profile with `aiPreset == .custom`, no customPresetID, and a
        // non-empty tonePrompt becomes a CustomPreset named "Custom — <profile>"
        // referenced by ID. Legacy tonePrompt is preserved on the profile for
        // back-compat / fallback rendering, but customPresetID is now authoritative.
        migrateLegacyCustomPresets()
    }

    private func saveProfiles() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: "profiles")
            // Force flush so force-quit doesn't lose profile edits.
            UserDefaults.standard.synchronize()
        }
    }

    private func saveCustomPresets() {
        if let data = try? JSONEncoder().encode(customPresets) {
            UserDefaults.standard.set(data, forKey: "customPresets")
        }
    }

    private func saveGlossary() {
        if let data = try? JSONEncoder().encode(glossary) {
            UserDefaults.standard.set(data, forKey: "glossary")
        }
    }

    private func migrateLegacyCustomPresets() {
        var didChange = false
        for index in profiles.indices {
            let profile = profiles[index]
            guard profile.aiPreset == .custom,
                  profile.customPresetID == nil,
                  !profile.tonePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            let presetName = "Custom — \(profile.name.isEmpty ? "Migrated" : profile.name)"
            let new = CustomPreset(name: presetName, promptText: profile.tonePrompt)
            customPresets.append(new)
            profiles[index].customPresetID = new.id
            didChange = true
        }
        if didChange {
            // Triggered didSets already; nothing else needed.
        }
    }

    func profileForApp(bundleIdentifier: String) -> Profile? {
        // Check if any profile has a detection rule matching this app
        profiles.first(where: { profile in
            profile.detectionRules.contains(where: { $0.appBundleIdentifier == bundleIdentifier })
        }) ?? profiles.first(where: { $0.isDefault })
    }
}

/// Per-element lossy wrapper for `[Profile]` decode. If a single profile
/// fails to decode (missing field, unknown enum rawValue from a future
/// version), `value` is nil and the array decode continues on the rest
/// instead of throwing and wiping every profile to a single Default.
private struct LossyProfile: Decodable {
    let value: Profile?
    init(from decoder: Decoder) throws {
        do {
            value = try Profile(from: decoder)
        } catch {
            print("[Sonotexta][settings] Profile decode failed (skipped): \(error.localizedDescription)")
            value = nil
        }
    }
}
