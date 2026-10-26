import SwiftUI

/// Single-shot "What's new" upsell sheet shown to upgrading users.
///
/// Presented as an NSWindow sheet attached to the Settings window the first
/// time the user opens Settings after upgrading to a new major.minor.
/// Dismissal sets `AppSettings.lastSeenMajorVersion = versionMarker` so the
/// sheet never fires again for this release line. Fresh installs run the
/// onboarding wizard instead and bypass this sheet entirely.
///
/// RELEASE CHECKLIST: the gate is derived from the bundle version and cannot
/// rot, but the cards below are hand-written — refresh them when a new
/// major.minor ships.
struct WhatsNewSheet: View {
    let onDismiss: () -> Void

    /// "major.minor" of the running app (e.g. "3.16" for 3.16.2-beta.2).
    /// Used both as the gate comparison and the dismissal stamp, so the
    /// sheet fires exactly once per major.minor line — previously this was
    /// a hardcoded "3.15.0" that silently disabled the sheet for 3.16+.
    static var versionMarker: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0"
        let parts = v.split(separator: ".")
        return parts.count >= 2 ? "\(parts[0]).\(parts[1])" : v
    }

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 4) {
                Text("What's new in \(Self.versionMarker)")
                    .font(.system(size: 22, weight: .bold))
                Text("A new live engine, safer updates, and auto-start at login.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                WhatsNewCard(
                    icon: "bolt.badge.waveform",
                    title: "Parakeet Live",
                    bodyText: "New streaming mode for the local Parakeet engine — text appears as you speak, fully offline."
                )
                WhatsNewCard(
                    icon: "power",
                    title: "Start at login",
                    bodyText: "Sonotexta can now launch automatically after a restart. Enable it in Dictation → Startup."
                )
                WhatsNewCard(
                    icon: "checkmark.shield",
                    title: "Updates you confirm",
                    bodyText: "Updates are never installed silently — Sonotexta always asks before downloading and installing."
                )
            }

            Button("Got it", action: onDismiss)
                .buttonStyle(.borderedProminent)
                .tint(DesignTokens.accent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
        .frame(width: 480)
        .padding(28)
    }
}

private struct WhatsNewCard: View {
    let icon: String
    let title: String
    /// Renamed from `body` to avoid clashing with `View.body`'s requirement.
    let bodyText: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(DesignTokens.accent)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(bodyText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DesignTokens.surfaceSecondary, in: RoundedRectangle(cornerRadius: 10))
    }
}
