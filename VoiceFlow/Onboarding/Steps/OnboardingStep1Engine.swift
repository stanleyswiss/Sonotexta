import SwiftUI

struct OnboardingStep1Engine: View {
    @ObservedObject var vm: OnboardingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose a transcription engine")
                .font(.system(size: 18, weight: .bold))
            Text("You can always change this in Settings → Dictation later.")
                .foregroundStyle(.secondary)
                .font(.callout)

            VStack(spacing: 8) {
                ForEach(STTEngineType.allCases) { engine in
                    EngineOptionRow(
                        engine: engine,
                        isSelected: vm.selectedEngine == engine
                    ) {
                        vm.selectedEngine = engine
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct EngineOptionRow: View {
    let engine: STTEngineType
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? DesignTokens.accent : .secondary)
                    .font(.system(size: 18))
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(engine.displayName)
                            .font(.system(size: 13, weight: .semibold))
                        if engine.requiresAPIKeyForOnboarding {
                            Text("Cloud")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(.secondary.opacity(0.15))
                                .clipShape(Capsule())
                        }
                    }
                    Text(engine.description)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
            }
            .padding(10)
            .background(
                isSelected ? DesignTokens.accent.opacity(0.08) : Color.clear
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        isSelected ? DesignTokens.accent.opacity(0.4) : Color.clear,
                        lineWidth: 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Onboarding-only extension that mirrors the cloud/local split used by the
/// wizard. Lives here (not on the model) so STTEngine.swift stays untouched
/// per the 3.15 refactor scope.
private extension STTEngineType {
    var requiresAPIKeyForOnboarding: Bool {
        switch self {
        case .openAIRealtime, .deepgram, .elevenLabsScribe: return true
        default: return false
        }
    }
}
