import SwiftUI

struct StatsSettingsView: View {
    @ObservedObject var stats = DictationStats.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your Dictation Stats")
                        .font(.title)
                        .fontWeight(.bold)
                    if stats.totalSessions > 0 {
                        Text("Using Sonotexta for \(stats.daysSinceFirstUse) day\(stats.daysSinceFirstUse == 1 ? "" : "s")")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Start dictating to see your stats here.")
                            .foregroundStyle(.secondary)
                    }
                }

                // Hero stat — time saved
                if stats.totalWords > 0 {
                    SettingsCard {
                        VStack(spacing: 8) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 28))
                                .foregroundStyle(.green)

                            Text(stats.timeSavedFormatted)
                                .font(.system(size: 36, weight: .bold, design: .rounded))
                                .foregroundStyle(.green)

                            Text("time saved by dictating instead of typing")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)

                            Text("Based on average typing speed of 40 WPM vs speaking at 130 WPM")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                }

                // Main stats grid
                HStack(spacing: 12) {
                    StatCard(
                        icon: "text.bubble",
                        iconColor: .blue,
                        value: "\(formatNumber(stats.totalSessions))",
                        label: "Dictations"
                    )

                    StatCard(
                        icon: "character.cursor.ibeam",
                        iconColor: .purple,
                        value: "\(formatNumber(stats.totalWords))",
                        label: "Words Spoken"
                    )

                    StatCard(
                        icon: "timer",
                        iconColor: .orange,
                        value: stats.totalDictationFormatted,
                        label: "Time Dictating"
                    )

                    StatCard(
                        icon: "sparkles",
                        iconColor: .cyan,
                        value: "\(formatNumber(stats.totalAIProcessed))",
                        label: "AI Enhanced"
                    )
                }

                // Averages
                if stats.totalSessions > 0 {
                    SettingsCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Averages")
                                .font(.headline)

                            HStack(spacing: 24) {
                                AverageStat(
                                    label: "Words per session",
                                    value: "\(stats.avgWordsPerSession)"
                                )

                                AverageStat(
                                    label: "Sessions per day",
                                    value: String(format: "%.1f", stats.avgSessionsPerDay)
                                )

                                AverageStat(
                                    label: "AI usage rate",
                                    value: stats.totalSessions > 0 ? "\(stats.totalAIProcessed * 100 / stats.totalSessions)%" : "0%"
                                )
                            }
                        }
                    }
                }

                // Reset
                if stats.totalSessions > 0 {
                    HStack {
                        Spacer()
                        Button("Reset Stats") {
                            stats.reset()
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                        .font(.caption)
                    }
                }
            }
            .padding(24)
        }
    }

    private func formatNumber(_ n: Int) -> String {
        if n >= 1000 {
            return String(format: "%.1fk", Double(n) / 1000.0)
        }
        return "\(n)"
    }
}

// MARK: - Stat Card

struct StatCard: View {
    let icon: String
    let iconColor: Color
    let value: String
    let label: String

    var body: some View {
        SettingsCard {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundStyle(iconColor)

                Text(value)
                    .font(.system(size: 22, weight: .bold, design: .rounded))

                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
    }
}

// MARK: - Average Stat

struct AverageStat: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .rounded))

            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
