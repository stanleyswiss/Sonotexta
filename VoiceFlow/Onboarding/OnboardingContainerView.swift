import SwiftUI

/// Root view for the first-run onboarding wizard. Presented modally by
/// `OnboardingWindowController` before menubar/dictation setup.
struct OnboardingContainerView: View {
    @StateObject var vm = OnboardingViewModel()
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()
            contentView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(28)
            Divider()
            footerView
        }
        .frame(width: 680, height: 500)
        .background(DesignTokens.surfacePrimary)
    }

    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Set up Sonotexta")
                    .font(.system(size: 16, weight: .semibold))
                Text("Step \(vm.currentStep.rawValue) of 4")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            ProgressView(value: Double(vm.currentStep.rawValue), total: 4)
                .frame(width: 120)
        }
        .padding(20)
    }

    @ViewBuilder
    private var contentView: some View {
        switch vm.currentStep {
        case .engine:   OnboardingStep1Engine(vm: vm)
        case .key:      OnboardingStep2Key(vm: vm)
        case .shortcut: OnboardingStep3Shortcut(vm: vm)
        case .done:     OnboardingStep4Done(vm: vm, onFinish: {
            vm.complete()
            onDone()
        })
        }
    }

    @ViewBuilder
    private var footerView: some View {
        HStack {
            if vm.currentStep != .engine {
                Button("Back", action: vm.backAction)
                    .buttonStyle(.bordered)
            }
            Spacer()
            if vm.currentStep != .done {
                Button("Continue →", action: vm.continueAction)
                    .buttonStyle(.borderedProminent)
                    .tint(DesignTokens.accent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }
}
