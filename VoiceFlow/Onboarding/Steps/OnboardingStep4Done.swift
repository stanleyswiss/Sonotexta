import SwiftUI

struct OnboardingStep4Done: View {
    @ObservedObject var vm: OnboardingViewModel
    let onFinish: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(DesignTokens.statusSuccess)
            Text("Sonotexta is ready")
                .font(.system(size: 22, weight: .bold))
            Text(readyHint)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            HStack(spacing: 12) {
                Button("Open Settings") {
                    onFinish()
                }
                .buttonStyle(.bordered)
                Button("Done") {
                    onFinish()
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignTokens.accent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var readyHint: String {
        let s = AppSettings.shared
        let trigger = s.useGlobeKey ? "Globe" : s.globalHotkey
        return "Press \(trigger) to start dictating. You can change any setting later."
    }
}
