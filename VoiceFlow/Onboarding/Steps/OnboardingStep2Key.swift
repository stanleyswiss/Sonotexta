import SwiftUI

struct OnboardingStep2Key: View {
    @ObservedObject var vm: OnboardingViewModel
    @State private var isTesting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add your \(vm.selectedEngine.displayName) API key")
                .font(.system(size: 18, weight: .bold))
            Text("Your key is stored securely in the macOS Keychain and never leaves your device.")
                .foregroundStyle(.secondary)
                .font(.callout)

            SecureField("Paste API key here…", text: $vm.enteredKey)
                .textFieldStyle(.roundedBorder)
                .font(.system(.callout, design: .monospaced))

            HStack(spacing: 12) {
                Button {
                    isTesting = true
                    Task { @MainActor in
                        let provider = keychainProvider
                        let previousKey = provider.loadKey()
                        // Temporarily save the entered key so testKey() reads it.
                        provider.saveKey(vm.enteredKey)
                        let outcome = await provider.testKey()
                        // Restore the previous key (which may be nil if there
                        // wasn't one before) — we do not want onboarding to
                        // accidentally persist a key the user might still
                        // change before pressing Continue. The final save
                        // happens in `OnboardingViewModel.complete()`.
                        provider.saveKey(previousKey)
                        switch outcome {
                        case .success:               vm.keyTestResult = .ok
                        case .failure(let message):  vm.keyTestResult = .failed(message)
                        }
                        isTesting = false
                    }
                } label: {
                    HStack(spacing: 6) {
                        if isTesting { ProgressView().scaleEffect(0.6) }
                        Text("Test key")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(vm.enteredKey.isEmpty || isTesting)

                switch vm.keyTestResult {
                case .ok:
                    StatusBadge(status: .configured, label: "Key works")
                case .failed(let msg):
                    StatusBadge(status: .error, label: msg)
                case .testing, .idle:
                    EmptyView()
                }

                Spacer()

                Button("Skip — I'll do this later") {
                    vm.enteredKey = ""
                    vm.continueAction()
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
    }

    /// Map the wizard's selected engine to the KeychainProvider that owns
    /// that engine's API key.
    private var keychainProvider: KeychainProvider {
        switch vm.selectedEngine {
        case .openAIRealtime:   return .openAISpeech
        case .deepgram:         return .deepgram
        case .elevenLabsScribe: return .elevenLabs
        default:                return .openAISpeech
        }
    }
}
