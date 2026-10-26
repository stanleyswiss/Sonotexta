//
//  VoiceFlowTests.swift
//  VoiceFlowTests
//
//  Real unit tests since 3.16.5 — the target was unrunnable from the
//  Sonotexta rename until the shared scheme + TEST_HOST fix (2026-08-10).
//

import Testing
import Foundation
@testable import Sonotexta

// MARK: - HotkeyBinding (3.16.5 multi-shortcut model)

struct HotkeyBindingTests {

    @Test func effectiveModeDegradesHoldForPressOnlyKeys() {
        let carbon = HotkeyBinding(
            key: .carbonCombo(keyCode: 2, modifiers: 4352, display: "⌃⇧D"),
            profileID: nil,
            mode: .holdToTalk
        )
        #expect(carbon.effectiveMode == .toggle)

        let single = HotkeyBinding(
            key: .singleKey(keyCode: 96, display: "F5"),
            profileID: nil,
            mode: .holdToTalk
        )
        #expect(single.effectiveMode == .toggle)
    }

    @Test func effectiveModeKeepsHoldForModifierKeys() {
        let globe = HotkeyBinding(key: .globe, profileID: nil, mode: .holdToTalk)
        #expect(globe.effectiveMode == .holdToTalk)

        let rightOption = HotkeyBinding(key: .rightOption, profileID: nil, mode: .holdToTalk)
        #expect(rightOption.effectiveMode == .holdToTalk)
    }

    @Test func toggleModeIsNeverDegraded() {
        for key: HotkeyBinding.KeySpec in [
            .globe, .rightOption,
            .carbonCombo(keyCode: 2, modifiers: 4352, display: "⌃⇧D"),
            .singleKey(keyCode: 96, display: "F5"),
        ] {
            let binding = HotkeyBinding(key: key, profileID: nil, mode: .toggle)
            #expect(binding.effectiveMode == .toggle)
        }
    }

    @Test func codableRoundTripPreservesEverything() throws {
        let profileID = UUID()
        let original = [
            HotkeyBinding(key: .carbonCombo(keyCode: 2, modifiers: 4352, display: "⌃⇧D"), profileID: nil, mode: .toggle),
            HotkeyBinding(key: .globe, profileID: profileID, mode: .holdToTalk),
            HotkeyBinding(key: .rightOption, profileID: nil, mode: .holdToTalk),
            HotkeyBinding(key: .singleKey(keyCode: 96, display: "F5"), profileID: profileID, mode: .toggle),
        ]
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode([HotkeyBinding].self, from: data)
        #expect(decoded == original)
    }

    @Test func keySpecDisplayNames() {
        #expect(HotkeyBinding.KeySpec.globe.display == "Globe 🌐")
        #expect(HotkeyBinding.KeySpec.rightOption.display == "Right ⌥")
        #expect(HotkeyBinding.KeySpec.carbonCombo(keyCode: 2, modifiers: 4352, display: "⌃⇧D").display == "⌃⇧D")
        #expect(HotkeyBinding.KeySpec.singleKey(keyCode: 96, display: "F5").display == "F5")
    }

    @Test func supportsHoldMatchesKeyCapabilities() {
        #expect(HotkeyBinding.KeySpec.globe.supportsHold)
        #expect(HotkeyBinding.KeySpec.rightOption.supportsHold)
        #expect(!HotkeyBinding.KeySpec.carbonCombo(keyCode: 2, modifiers: 4352, display: "⌃⇧D").supportsHold)
        #expect(!HotkeyBinding.KeySpec.singleKey(keyCode: 96, display: "F5").supportsHold)
    }
}

// MARK: - TranscriptionFilter

struct TranscriptionFilterTests {

    @Test func stripsNonSpeechArtifacts() {
        #expect(TranscriptionFilter.clean("[BLANK_AUDIO]") == "")
        #expect(TranscriptionFilter.clean("[Music] hello world") == "hello world")
        #expect(TranscriptionFilter.clean("hello (silence) world") == "hello world")
    }

    @Test func leavesNormalTextAlone() {
        #expect(TranscriptionFilter.clean("Hello, world.") == "Hello, world.")
    }

    @Test func genericBracketSweepBehavior() {
        // By design: ANY short alphabetic bracketed segment is treated as a
        // non-speech marker and stripped, even if unlisted…
        #expect(TranscriptionFilter.clean("before [Laughter] after") == "before after")
        // …but segments containing digits are considered real content and kept.
        #expect(TranscriptionFilter.clean("see [figure 3] for details") == "see [figure 3] for details")
    }

    @Test func emptyInputStaysEmpty() {
        #expect(TranscriptionFilter.clean("") == "")
        #expect(TranscriptionFilter.clean("   ") == "")
    }
}

// MARK: - Model catalog invariants (guard against silent drift)

struct ModelCatalogTests {

    @Test func openAIRealtimeModelsAre2026Lineup() {
        #expect(OpenAIRealtimeModel.allCases.map(\.rawValue) == ["gpt-transcribe", "gpt-live-transcribe"])
    }

    @Test func dictationModeRawValuesAreStable() {
        // Persisted in UserDefaults + HotkeyBinding JSON — a rename would
        // silently reset user settings on upgrade.
        #expect(DictationMode.toggle.rawValue == "toggle")
        #expect(DictationMode.holdToTalk.rawValue == "hold_to_talk")
    }
}

// MARK: - LLM reasoning-effort selection (the Luna-400 regression)

struct ReasoningEffortTests {

    @Test func gpt56FamilyUsesNoneNotMinimal() {
        // 5.6 models 400 on "minimal" — their floor is "none".
        #expect(LLMService.minimalReasoningEffort(forBareModelID: "gpt-5.6-luna") == "none")
        #expect(LLMService.minimalReasoningEffort(forBareModelID: "gpt-5.6-sol") == "none")
    }

    @Test func gpt5FamilyUsesMinimal() {
        #expect(LLMService.minimalReasoningEffort(forBareModelID: "gpt-5-nano") == "minimal")
        #expect(LLMService.minimalReasoningEffort(forBareModelID: "gpt-5-mini") == "minimal")
        #expect(LLMService.minimalReasoningEffort(forBareModelID: "gpt-5") == "minimal")
    }

    @Test func oSeriesUsesLow() {
        #expect(LLMService.minimalReasoningEffort(forBareModelID: "o4-mini") == "low")
    }

    @Test func nonReasoningModelsGetNoKnob() {
        #expect(LLMService.minimalReasoningEffort(forBareModelID: "gpt-4o-mini") == nil)
        #expect(LLMService.minimalReasoningEffort(forBareModelID: "gpt-4.1-nano") == nil)
        #expect(LLMService.minimalReasoningEffort(forBareModelID: "llama-3.3-70b-versatile") == nil)
    }
}


// MARK: - ModelStorage path derivation (3.16.6 custom weights location)

struct ModelStorageTests {

    private let root = URL(fileURLWithPath: "/Volumes/External/SonotextaModels", isDirectory: true)

    @Test func defaultPathsMatchHistoricalLocations() {
        // These exact locations predate the feature — changing them silently
        // strands users' downloaded models.
        #expect(ModelStorage.whisperDownloadBase(customRoot: nil) == nil)
        #expect(ModelStorage.whisperModelsDirectory(customRoot: nil).path.hasSuffix(
            "Documents/huggingface/models/argmaxinc/whisperkit-coreml"))
        #expect(ModelStorage.fluidAudioModelsRoot(customRoot: nil).path.hasSuffix(
            "Application Support/FluidAudio/Models"))
    }

    @Test func customRootLayout() {
        #expect(ModelStorage.whisperDownloadBase(customRoot: root)?.path ==
            "/Volumes/External/SonotextaModels/WhisperKit")
        #expect(ModelStorage.whisperModelsDirectory(customRoot: root).path ==
            "/Volumes/External/SonotextaModels/WhisperKit/models/argmaxinc/whisperkit-coreml")
        #expect(ModelStorage.fluidAudioModelsRoot(customRoot: root).path ==
            "/Volumes/External/SonotextaModels/FluidAudio/Models")
    }
}
