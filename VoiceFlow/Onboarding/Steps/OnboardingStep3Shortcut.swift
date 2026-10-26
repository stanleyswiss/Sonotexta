import SwiftUI

struct OnboardingStep3Shortcut: View {
    @ObservedObject var vm: OnboardingViewModel
    @ObservedObject var settings: AppSettings = AppSettings.shared
    @State private var isRecording = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set your dictation shortcut")
                .font(.system(size: 18, weight: .bold))
            Text("Press your chosen key combination to start and stop dictation.")
                .foregroundStyle(.secondary)
                .font(.callout)

            SettingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Use Globe/Fn key", isOn: $settings.useGlobeKey)
                    if !settings.useGlobeKey {
                        HStack {
                            Text("Shortcut:")
                            Spacer()
                            Text(settings.globalHotkey)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 4)
                                .background(.quaternary)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            Button(isRecording ? "Cancel" : "Change") {
                                isRecording.toggle()
                            }
                            .buttonStyle(.borderless)
                        }
                        if isRecording {
                            HotkeyRecorderView { keyCode, modifiers, display in
                                settings.globalHotkey = display
                                settings.hotkeyKeyCode = keyCode
                                settings.hotkeyModifiers = modifiers
                                isRecording = false
                                NotificationCenter.default.post(name: .hotkeyChanged, object: nil)
                            }
                            .frame(height: 40)
                        }
                    } else {
                        Text("Press the Globe/Fn key to control dictation. Set Globe key to \"Do Nothing\" in System Settings → Keyboard.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: 0)
        }
    }
}
