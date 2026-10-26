import SwiftUI

/// Standard "this list is empty, here's what to do" panel used by Profiles,
/// Vocabulary, and Custom Presets sections in the redesigned Settings IA.
///
/// Sized to live inside a `SettingsCard` — the parent provides the padding
/// and background; this view only contributes vertical space, an icon, two
/// stacked text lines, and the primary CTA button.
struct EmptyStateView: View {
    let icon: String
    let title: String
    let subtitle: String
    let ctaTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320)
            Button(ctaTitle, action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(DesignTokens.accent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}
