import SwiftUI

struct SupportView: View {
    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "v\(version) (Build \(build))"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Text("Support & Info")
                        .font(.title)
                        .fontWeight(.bold)
                    Text("Get help, read our policies, or get in touch.")
                        .foregroundStyle(.secondary)
                }

                // Quick Links
                SettingsCard {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Quick Links")
                            .font(.headline)

                        SupportLink(
                            icon: "globe",
                            iconColor: .blue,
                            title: "Sonotexta Website",
                            subtitle: "sonotexta.com",
                            url: "https://sonotexta.com"
                        )

                        Divider()

                        SupportLink(
                            icon: "envelope",
                            iconColor: .purple,
                            title: "Contact Us",
                            subtitle: "developer@sonotexta.com",
                            url: "mailto:developer@sonotexta.com"
                        )

                        Divider()

                        SupportLink(
                            icon: "chevron.left.forwardslash.chevron.right",
                            iconColor: .gray,
                            title: "Source Code on GitHub",
                            subtitle: "github.com/stanleyswiss/Sonotexta",
                            url: "https://github.com/stanleyswiss/Sonotexta"
                        )

                        Divider()

                        SupportLink(
                            icon: "cup.and.saucer",
                            iconColor: .brown,
                            title: "Buy Me a Coffee",
                            subtitle: "Sonotexta is free — support its development",
                            url: "https://buymeacoffee.com/stanelych"
                        )

                        Divider()

                        SupportLink(
                            icon: "lock.shield",
                            iconColor: .green,
                            title: "Privacy Policy",
                            subtitle: "How we handle your data",
                            url: "https://sonotexta.com/privacy.html"
                        )

                        Divider()

                        SupportLink(
                            icon: "doc.text",
                            iconColor: .orange,
                            title: "Terms of Service",
                            subtitle: "Usage terms and conditions",
                            url: "https://sonotexta.com/terms.html"
                        )
                    }
                }

                // About
                SettingsCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("About Sonotexta")
                            .font(.headline)

                        Text("Sonotexta is a free, open-source multilingual dictation app for macOS. Speak in any language, get clean text in any app — with real-time streaming, AI enhancement, and smart per-app profiles.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Divider()

                        HStack {
                            Text("Version")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(appVersion)
                                .foregroundStyle(.secondary)
                                .font(.system(.callout, design: .monospaced))
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 4) {
                            Text("\u{00A9} \(Calendar.current.component(.year, from: Date())) Stan Ivanov")
                                .font(.callout)
                                .foregroundStyle(.secondary)

                            HStack(spacing: 4) {
                                Text("Portfolio:")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                Link("stanmakes.com", destination: URL(string: "https://stanmakes.com")!)
                                    .font(.caption)
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
    }
}

// MARK: - Support Link Row

struct SupportLink: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    let url: String

    var body: some View {
        Button {
            if let linkURL = URL(string: url) {
                NSWorkspace.shared.open(linkURL)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(iconColor)
                    .frame(width: 28, height: 28)
                    .background(iconColor.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.callout)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .buttonStyle(.plain)
    }
}
