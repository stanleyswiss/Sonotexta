import SwiftUI

/// 14pt semibold section header with an optional 12pt secondary subtitle and
/// an optional trailing accessory (button, badge, etc.).
///
/// Two call sites:
///   `SectionHeader("Translation")`
///   `SectionHeader("Translation", subtitle: "Where it runs.")`
///   `SectionHeader("Translation", subtitle: "...") { Button("Reset", action: ...) }`
struct SectionHeader<Trailing: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    /// Convenience init when no trailing accessory is needed.
    init(_ title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle, trailing: { EmptyView() })
    }
}
