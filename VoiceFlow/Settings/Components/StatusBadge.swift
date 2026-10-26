import SwiftUI

/// Pill-shaped status indicator: filled dot + short label, tinted by status.
///
/// Use `.configured` for "ready to go", `.unknown` when we have a key but
/// haven't verified it, `.error` for an explicit failure, and `.missing`
/// for "no key set". The colors come from `DesignTokens` so they remain
/// accessible across light + dark mode.
struct StatusBadge: View {
    enum Status {
        case configured
        case unknown
        case error
        case missing
    }

    let status: Status
    let label: String

    private var color: Color {
        switch status {
        case .configured: return DesignTokens.statusSuccess
        case .unknown:    return DesignTokens.statusWarning
        case .error:      return DesignTokens.statusDanger
        case .missing:    return DesignTokens.statusNeutral
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 12))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.12), in: Capsule())
        .foregroundStyle(color)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }
}
