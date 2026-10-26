import Foundation
import Combine

/// Tracks dictation usage statistics persisted in UserDefaults.
final class DictationStats: ObservableObject {
    static let shared = DictationStats()

    // MARK: - Published Stats

    @Published var totalSessions: Int
    @Published var totalWords: Int
    @Published var totalDictationSeconds: Double
    @Published var totalAIProcessed: Int
    @Published var firstUsedDate: Date?

    // MARK: - Session Tracking

    private var currentSessionStart: Date?

    // MARK: - Constants

    /// Average typing speed in words per minute (for time saved calculation)
    private static let avgTypingWPM: Double = 40
    /// Average speaking speed in words per minute
    private static let avgSpeakingWPM: Double = 130

    // MARK: - Init

    private init() {
        self.totalSessions = UserDefaults.standard.integer(forKey: "stats.totalSessions")
        self.totalWords = UserDefaults.standard.integer(forKey: "stats.totalWords")
        self.totalDictationSeconds = UserDefaults.standard.double(forKey: "stats.totalDictationSeconds")
        self.totalAIProcessed = UserDefaults.standard.integer(forKey: "stats.totalAIProcessed")

        if let timestamp = UserDefaults.standard.object(forKey: "stats.firstUsedDate") as? Double, timestamp > 0 {
            self.firstUsedDate = Date(timeIntervalSince1970: timestamp)
        } else {
            self.firstUsedDate = nil
        }
    }

    // MARK: - Recording

    /// Call when dictation starts
    func sessionStarted() {
        currentSessionStart = Date()
    }

    /// Call when dictation delivers text. Records session count, word count, and duration.
    func sessionCompleted(text: String, usedAI: Bool) {
        let wordCount = text.split(separator: " ").count

        totalSessions += 1
        totalWords += wordCount

        if let start = currentSessionStart {
            let duration = Date().timeIntervalSince(start)
            totalDictationSeconds += duration
        }
        currentSessionStart = nil

        if usedAI {
            totalAIProcessed += 1
        }

        if firstUsedDate == nil {
            firstUsedDate = Date()
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "stats.firstUsedDate")
        }

        save()
    }

    /// Call if dictation is cancelled without delivering text
    func sessionCancelled() {
        currentSessionStart = nil
    }

    /// Reset all stats
    func reset() {
        totalSessions = 0
        totalWords = 0
        totalDictationSeconds = 0
        totalAIProcessed = 0
        firstUsedDate = nil
        save()
        UserDefaults.standard.removeObject(forKey: "stats.firstUsedDate")
    }

    // MARK: - Computed Display Values

    /// Time saved estimate: typing those words at 40 WPM vs speaking at 130 WPM
    var timeSavedSeconds: Double {
        guard totalWords > 0 else { return 0 }
        let typingTime = Double(totalWords) / Self.avgTypingWPM * 60  // seconds to type
        let speakingTime = Double(totalWords) / Self.avgSpeakingWPM * 60  // seconds to speak
        return max(0, typingTime - speakingTime)
    }

    /// Formatted time saved (e.g., "2h 15m" or "45m" or "3m")
    var timeSavedFormatted: String {
        formatDuration(timeSavedSeconds)
    }

    /// Formatted total dictation time
    var totalDictationFormatted: String {
        formatDuration(totalDictationSeconds)
    }

    /// Average words per session
    var avgWordsPerSession: Int {
        guard totalSessions > 0 else { return 0 }
        return totalWords / totalSessions
    }

    /// Days since first use
    var daysSinceFirstUse: Int {
        guard let first = firstUsedDate else { return 0 }
        return max(1, Calendar.current.dateComponents([.day], from: first, to: Date()).day ?? 1)
    }

    /// Average sessions per day
    var avgSessionsPerDay: Double {
        guard daysSinceFirstUse > 0 else { return 0 }
        return Double(totalSessions) / Double(daysSinceFirstUse)
    }

    // MARK: - Helpers

    private func formatDuration(_ seconds: Double) -> String {
        let totalMinutes = Int(seconds) / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else if minutes > 0 {
            return "\(minutes)m"
        } else {
            return "\(Int(seconds))s"
        }
    }

    private func save() {
        UserDefaults.standard.set(totalSessions, forKey: "stats.totalSessions")
        UserDefaults.standard.set(totalWords, forKey: "stats.totalWords")
        UserDefaults.standard.set(totalDictationSeconds, forKey: "stats.totalDictationSeconds")
        UserDefaults.standard.set(totalAIProcessed, forKey: "stats.totalAIProcessed")
    }
}
