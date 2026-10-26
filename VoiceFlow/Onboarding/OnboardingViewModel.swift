import SwiftUI
import Combine
import Carbon

@MainActor
final class OnboardingViewModel: ObservableObject {
    enum Step: Int, CaseIterable { case engine = 1, key, shortcut, done }
    enum KeyTestResult: Equatable { case idle, testing, ok, failed(String) }

    @Published var currentStep: Step = .engine
    @Published var selectedEngine: STTEngineType = .appleSpeech
    @Published var enteredKey: String = ""
    @Published var keyTestResult: KeyTestResult = .idle
    @Published var useGlobeKey: Bool = false

    var requiresKey: Bool {
        switch selectedEngine {
        case .openAIRealtime, .deepgram, .elevenLabsScribe: return true
        default: return false
        }
    }

    func continueAction() {
        switch currentStep {
        case .engine:   currentStep = requiresKey ? .key : .shortcut
        case .key:      currentStep = .shortcut
        case .shortcut: currentStep = .done
        case .done:     break
        }
    }

    func backAction() {
        switch currentStep {
        case .key:      currentStep = .engine
        case .shortcut: currentStep = requiresKey ? .key : .engine
        case .done:     currentStep = .shortcut
        case .engine:   break
        }
    }

    func complete() {
        AppSettings.shared.selectedEngine = selectedEngine
        if requiresKey && !enteredKey.isEmpty {
            switch selectedEngine {
            case .openAIRealtime:    KeychainProvider.openAISpeech.saveKey(enteredKey)
            case .deepgram:          KeychainProvider.deepgram.saveKey(enteredKey)
            case .elevenLabsScribe:  KeychainProvider.elevenLabs.saveKey(enteredKey)
            default: break
            }
        }
        if useGlobeKey {
            AppSettings.shared.useGlobeKey = true
            // 3.16.5: the bindings table is authoritative — replace the
            // migrated default (⌃⇧D) with the wizard's Globe choice.
            AppSettings.shared.hotkeyBindings = [
                HotkeyBinding(key: .globe, profileID: nil, mode: AppSettings.shared.dictationMode)
            ]
            NotificationCenter.default.post(name: .hotkeyChanged, object: nil)
        }
        AppSettings.shared.hasCompletedOnboarding = true
        // Stamp the current major.minor so a fresh install never sees the
        // upgrade What's-new sheet for the version it just installed.
        AppSettings.shared.lastSeenMajorVersion = WhatsNewSheet.versionMarker
    }
}
